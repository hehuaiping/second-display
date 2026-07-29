@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import SecondDisplayCore
import SharedProtocol
@preconcurrency import VideoToolbox

public protocol VideoEncoding: Sendable {
    func configure(_ spec: EncoderSpec) async throws
    func encode(_ frame: CapturedFrame, forceKeyFrame: Bool) async throws -> EncodedFrame?
    func updateBitrate(_ bitsPerSecond: Int) async throws
    func invalidate() async
}

public enum VideoEncoderCapability {
    public static var supportsHardwareHEVC: Bool {
        var encoderList: CFArray?
        guard VTCopyVideoEncoderList(nil, &encoderList) == noErr,
            let encoders = encoderList as? [[CFString: Any]]
        else {
            return false
        }
        return encoders.contains { encoder in
            let codec = (encoder[kVTVideoEncoderList_CodecType] as? NSNumber)?.uint32Value
            let hardware = (encoder[kVTVideoEncoderList_IsHardwareAccelerated] as? NSNumber)?.boolValue
            return codec == kCMVideoCodecType_HEVC && hardware == true
        }
    }
}

struct VideoEncoderRateControlPlan: Equatable, Sendable {
    static let lowLatencyBurstNumerator = 2
    static let lowLatencyBurstDenominator = 1

    let maximumKeyFrameIntervalFrames: Int?
    let maximumKeyFrameIntervalDurationSeconds: Int?
    let dataRateLimitBytesPerSecond: Int

    init(spec: EncoderSpec, lowLatencyRateControlEnabled: Bool) {
        if lowLatencyRateControlEnabled {
            // VideoToolbox 的低延迟码率控制本身使用无限 GOP。恢复路径会显式请求 IDR，
            // 因此不再每两秒插入周期 IDR，避免关键帧突发挤压后续帧。
            maximumKeyFrameIntervalFrames = nil
            maximumKeyFrameIntervalDurationSeconds = nil
        } else {
            maximumKeyFrameIntervalFrames =
                spec.framesPerSecond * spec.maximumKeyFrameIntervalSeconds
            maximumKeyFrameIntervalDurationSeconds = spec.maximumKeyFrameIntervalSeconds
        }

        let averageBytesPerSecond = max(1, spec.bitrate / 8)
        if lowLatencyRateControlEnabled {
            // AverageBitRate 仍控制长期均值，DataRateLimits 允许一秒窗口内最多 2 倍突发。
            // 复杂桌面动画和显式 IDR 不应因瞬时码量被编码器主动隔帧丢弃；发送队列仍保持有界。
            dataRateLimitBytesPerSecond =
                averageBytesPerSecond * Self.lowLatencyBurstNumerator
                / Self.lowLatencyBurstDenominator
        } else {
            dataRateLimitBytesPerSecond = averageBytesPerSecond
        }
    }

    init(bitsPerSecond: Int, lowLatencyRateControlEnabled: Bool) {
        let averageBytesPerSecond = max(1, bitsPerSecond / 8)
        maximumKeyFrameIntervalFrames = nil
        maximumKeyFrameIntervalDurationSeconds = nil
        dataRateLimitBytesPerSecond =
            lowLatencyRateControlEnabled
            ? averageBytesPerSecond * Self.lowLatencyBurstNumerator
                / Self.lowLatencyBurstDenominator
            : averageBytesPerSecond
    }
}

public actor H264EncoderService: VideoEncoding {
    private var sessionBox: CompressionSessionBox?
    private var configurationToken: UInt64 = 0
    private var sequence: UInt32 = 0
    private var pending: [UUID: EncodeResultGate] = [:]
    private var frameDuration = CMTime(value: 1, timescale: 60)
    private var codec: VideoEncoderCodec = .h264
    private var encoderHardwareAccelerated: Bool?
    private var lowLatencyRateControlEnabled: Bool?

    public init() {}

    public func configure(_ spec: EncoderSpec) async throws {
        invalidateSession(with: CancellationError())

        let imageBufferAttributes =
            [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ] as CFDictionary

        let attempts: [(lowLatency: Bool, requireHardware: Bool)]
        if spec.codec == .hevc {
            attempts = [(true, true), (false, true)]
        } else if spec.profile == .high {
            attempts = [(true, true), (false, true), (true, false), (false, false)]
        } else {
            attempts = [(false, true), (false, false)]
        }
        var status: OSStatus = kVTVideoEncoderNotAvailableNowErr
        var created: VTCompressionSession?
        var enabledLowLatency = false
        var hardwareGuaranteed = false
        for attempt in attempts {
            let creation = Self.createSession(
                spec: spec,
                imageBufferAttributes: imageBufferAttributes,
                enableLowLatencyRateControl: attempt.lowLatency,
                requireHardwareAcceleration: attempt.requireHardware
            )
            status = creation.status
            if status == noErr, let session = creation.session {
                created = session
                enabledLowLatency = attempt.lowLatency
                hardwareGuaranteed = attempt.requireHardware
                break
            }
            if let session = creation.session { VTCompressionSessionInvalidate(session) }
        }
        guard status == noErr, let created else {
            throw SessionError(
                code: .encCreateFailed, detail: "VTCompressionSessionCreate failed with OSStatus \(status)")
        }

        do {
            let rateControlPlan = VideoEncoderRateControlPlan(
                spec: spec,
                lowLatencyRateControlEnabled: enabledLowLatency)
            try setProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            try setProperty(
                created,
                key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                value: kCFBooleanTrue,
                allowUnsupported: true
            )
            try setProperty(
                created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            try setProperty(
                created, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: spec.framesPerSecond))
            try setProperty(
                created,
                key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                value: NSNumber(value: 0),
                allowUnsupported: true
            )
            if let maximumKeyFrameIntervalFrames =
                rateControlPlan.maximumKeyFrameIntervalFrames
            {
                try setProperty(
                    created,
                    key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                    value: NSNumber(value: maximumKeyFrameIntervalFrames)
                )
            }
            if let maximumKeyFrameIntervalDurationSeconds =
                rateControlPlan.maximumKeyFrameIntervalDurationSeconds
            {
                try setProperty(
                    created,
                    key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                    value: NSNumber(value: maximumKeyFrameIntervalDurationSeconds)
                )
            }
            let profile: CFString =
                spec.codec == .hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel
                : spec.profile == .high
                    ? kVTProfileLevel_H264_High_AutoLevel
                    : kVTProfileLevel_H264_Main_AutoLevel
            try setProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
            try Self.setBitrate(
                spec.bitrate,
                lowLatencyRateControlEnabled: enabledLowLatency,
                on: created)
            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepareStatus == noErr else {
                throw SessionError(
                    code: .encCreateFailed,
                    detail: "VTCompressionSessionPrepareToEncodeFrames failed with OSStatus \(prepareStatus)"
                )
            }
        } catch {
            VTCompressionSessionInvalidate(created)
            throw error
        }

        configurationToken &+= 1
        sequence = 0
        codec = spec.codec
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(spec.framesPerSecond))
        if hardwareGuaranteed {
            encoderHardwareAccelerated = true
        } else {
            encoderHardwareAccelerated =
                Self.boolProperty(
                    kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                    on: created
                ) ?? false
        }
        lowLatencyRateControlEnabled = enabledLowLatency
        sessionBox = CompressionSessionBox(created)
    }

    public func encode(_ frame: CapturedFrame, forceKeyFrame: Bool) async throws -> EncodedFrame? {
        try Task.checkCancellation()
        guard let session = sessionBox?.session else {
            throw SessionError(code: .encCreateFailed, detail: "Encoder is not configured")
        }
        guard pending.count < 2 else {
            throw SessionError(code: .encBackpressure, detail: "Encoder already has two frames in flight")
        }
        let token = configurationToken
        let frameSequence = sequence
        sequence &+= 1
        let requestID = UUID()
        let gate = EncodeResultGate()
        pending[requestID] = gate
        let frameProperties: CFDictionary? =
            forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        let duration = frameDuration
        let lowLatencyRateControl = lowLatencyRateControlEnabled
        let codec = self.codec
        let submitStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { status, infoFlags, sampleBuffer in
            let callbackUs = MediaClock.monotonicMicroseconds()
            if status != noErr {
                gate.complete(
                    .failure(
                        SessionError(
                            code: .encBackpressure,
                            detail: "VideoToolbox callback failed with OSStatus \(status)")
                    )
                )
                return
            }
            if infoFlags.contains(.frameDropped) {
                gate.complete(.success(nil))
                return
            }
            guard let sampleBuffer else {
                gate.complete(
                    .failure(
                        SessionError(code: .encBackpressure, detail: "Encoder returned no sample buffer")))
                return
            }
            do {
                let converted = try H264AnnexB.convert(
                    sampleBuffer: sampleBuffer,
                    codec: codec,
                    makePrefix: { payloadLength, isKeyFrame in
                        try VideoFrameCodec().encodeHeader(
                            frameType: .video,
                            flags: isKeyFrame ? [.keyframe] : [],
                            sequence: frameSequence,
                            ptsUs: MediaClock.microseconds(frame.presentationTimeStamp),
                            captureUs: frame.captureTimestampUs,
                            payloadLength: payloadLength)
                    }
                )
                let completedUs = MediaClock.monotonicMicroseconds()
                gate.complete(
                    .success(
                        EncodedFrame(
                            sequence: frameSequence,
                            presentationTimeStampUs: MediaClock.microseconds(frame.presentationTimeStamp),
                            isKeyFrame: converted.isKeyFrame,
                            captureTimestampUs: frame.captureTimestampUs,
                            encodeCallbackTimestampUs: callbackUs,
                            encodeCompleteTimestampUs: completedUs,
                            lowLatencyRateControlEnabled: lowLatencyRateControl,
                            payload: converted.payload,
                            preframedData: converted.preframedData,
                            generation: frame.generation
                        )
                    )
                )
            } catch {
                gate.complete(.failure(error))
            }
        }

        guard submitStatus == noErr else {
            pending.removeValue(forKey: requestID)
            let error = SessionError(
                code: .encBackpressure,
                detail: "VTCompressionSessionEncodeFrame failed with OSStatus \(submitStatus)"
            )
            gate.complete(.failure(error))
            throw error
        }

        let framePeriodNanoseconds = UInt64(
            max(1, (CMTimeGetSeconds(duration) * 1_000_000_000).rounded()))
        let callbackTimeoutNanoseconds = max(
            250_000_000,
            framePeriodNanoseconds.multipliedReportingOverflow(by: 8).partialValue)
        let result = try await waitForEncodeResult(
            gate,
            timeoutNanoseconds: callbackTimeoutNanoseconds)
        pending.removeValue(forKey: requestID)
        try Task.checkCancellation()
        guard session === sessionBox?.session, token == configurationToken else {
            throw CancellationError()
        }
        guard let encoded = result else { return nil }
        // 编码器实例在整个 session 生命周期内不会在软硬件之间切换，避免逐帧同步查询属性。
        let hardwareAccelerated = encoderHardwareAccelerated
        return EncodedFrame(
            sequence: encoded.sequence,
            presentationTimeStampUs: encoded.presentationTimeStampUs,
            isKeyFrame: encoded.isKeyFrame,
            captureTimestampUs: encoded.captureTimestampUs,
            encodeCallbackTimestampUs: encoded.encodeCallbackTimestampUs,
            encodeCompleteTimestampUs: encoded.encodeCompleteTimestampUs,
            encoderHardwareAccelerated: hardwareAccelerated,
            lowLatencyRateControlEnabled: encoded.lowLatencyRateControlEnabled,
            payload: encoded.payload,
            preframedData: encoded.preframedData,
            generation: encoded.generation
        )
    }

    public func updateBitrate(_ bitsPerSecond: Int) async throws {
        guard EncoderSpec.bitrateRange.contains(bitsPerSecond) else {
            throw SessionError(
                code: .encCreateFailed, detail: "Encoder bitrate must be between 8 and 30 Mbps")
        }
        guard let session = sessionBox?.session else {
            throw SessionError(code: .encCreateFailed, detail: "Encoder is not configured")
        }
        try Self.setBitrate(
            bitsPerSecond,
            lowLatencyRateControlEnabled: lowLatencyRateControlEnabled == true,
            on: session)
    }

    public func invalidate() async {
        invalidateSession(with: CancellationError())
    }

    private func invalidateSession(with error: Error) {
        configurationToken &+= 1
        encoderHardwareAccelerated = nil
        lowLatencyRateControlEnabled = nil
        let current = pending.values
        pending.removeAll(keepingCapacity: false)
        for gate in current {
            gate.complete(.failure(error))
        }
        guard let box = sessionBox else { return }
        sessionBox = nil
        box.invalidate()
    }

    private func setProperty(
        _ session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef,
        allowUnsupported: Bool = false
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if allowUnsupported, status == kVTPropertyNotSupportedErr { return }
        guard status == noErr else {
            throw SessionError(
                code: .encCreateFailed,
                detail: "Unable to set VideoToolbox property \(key): OSStatus \(status)"
            )
        }
    }

    private static func setBitrate(
        _ bitsPerSecond: Int,
        lowLatencyRateControlEnabled: Bool,
        on session: VTCompressionSession
    ) throws {
        let averageStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitsPerSecond)
        )
        guard averageStatus == noErr else {
            throw SessionError(
                code: .encCreateFailed, detail: "Unable to update bitrate: OSStatus \(averageStatus)")
        }
        let plan = VideoEncoderRateControlPlan(
            bitsPerSecond: bitsPerSecond,
            lowLatencyRateControlEnabled: lowLatencyRateControlEnabled)
        let limits = [
            NSNumber(value: plan.dataRateLimitBytesPerSecond),
            NSNumber(value: 1),
        ] as CFArray
        let limitStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: limits
        )
        guard limitStatus == noErr else {
            throw SessionError(
                code: .encCreateFailed, detail: "Unable to set data-rate limit: OSStatus \(limitStatus)")
        }
    }

    private static func createSession(
        spec: EncoderSpec,
        imageBufferAttributes: CFDictionary,
        enableLowLatencyRateControl: Bool,
        requireHardwareAcceleration: Bool
    ) -> (status: OSStatus, session: VTCompressionSession?) {
        var encoderSpecification: [String: Any] = [:]
        encoderSpecification[
            (requireHardwareAcceleration
                ? kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder
                : kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder) as String
        ] = true
        if enableLowLatencyRateControl {
            encoderSpecification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
        }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(spec.width),
            height: Int32(spec.height),
            codecType: spec.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        return (status, session)
    }

    private static func boolProperty(_ key: CFString, on session: VTCompressionSession) -> Bool? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session,
                key: key,
                allocator: nil,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        guard status == noErr,
            let number = value as? NSNumber
        else { return nil }
        return number.boolValue
    }
}

private final class CompressionSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSession: VTCompressionSession?

    init(_ session: VTCompressionSession) {
        storedSession = session
    }

    var session: VTCompressionSession? {
        lock.withLock { storedSession }
    }

    func invalidate() {
        let session = lock.withLock { () -> VTCompressionSession? in
            let current = storedSession
            storedSession = nil
            return current
        }
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    deinit {
        invalidate()
    }
}

final class EncodeResultGate: @unchecked Sendable {
    typealias ResultType = Result<EncodedFrame?, Error>

    private let lock = NSLock()
    private var result: ResultType?
    private var continuation: CheckedContinuation<EncodedFrame?, Error>?
    private var completed = false

    func value() async throws -> EncodedFrame? {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> ResultType? in
                if let result {
                    self.result = nil
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(with: immediate)
            }
        }
    }

    func complete(_ result: ResultType) {
        let continuation = lock.withLock { () -> CheckedContinuation<EncodedFrame?, Error>? in
            guard !completed else { return nil }
            completed = true
            guard let continuation = self.continuation else {
                self.result = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

func waitForEncodeResult(
    _ gate: EncodeResultGate,
    timeoutNanoseconds: UInt64
) async throws -> EncodedFrame? {
    let timeoutTask = Task {
        do {
            try await Task.sleep(nanoseconds: max(1, timeoutNanoseconds))
            gate.complete(
                .failure(
                    SessionError(
                        code: .encBackpressure,
                        detail: "VideoToolbox produced no output before the encode watchdog deadline")))
        } catch {
            // 正常编码完成或外层任务取消时会取消 watchdog，不覆盖原始结果。
        }
    }
    defer { timeoutTask.cancel() }
    return try await withTaskCancellationHandler {
        try await gate.value()
    } onCancel: {
        gate.complete(.failure(CancellationError()))
    }
}

public enum H264AnnexB {
    private struct PayloadStorage {
        let payload: Data
        let preframedData: Data?
    }

    private struct NALRange {
        let offset: Int
        let length: Int
    }

    private struct ParameterSet {
        let pointer: UnsafePointer<UInt8>
        let length: Int
    }

    public static func convertAVCC(_ data: Data, nalUnitHeaderLength: Int = 4) throws -> Data {
        guard (1...4).contains(nalUnitHeaderLength) else {
            throw SessionError(code: .encBackpressure, detail: "Invalid AVCC NAL length field")
        }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let ranges = try nalRanges(in: bytes, nalUnitHeaderLength: nalUnitHeaderLength)
            return try makePayload(parameterSets: [], nalRanges: ranges) { offset, length, destination in
                guard let source = bytes.baseAddress?.advanced(by: offset) else {
                    return kCMBlockBufferBadPointerParameterErr
                }
                memcpy(destination, source, length)
                return noErr
            }.payload
        }
    }

    public static func nalUnitTypes(in payload: Data) -> [UInt8] {
        var result: [UInt8] = []
        let bytes = [UInt8](payload)
        guard bytes.count >= 5 else { return result }
        var index = 0
        while index + 4 < bytes.count {
            let isFourByteStart =
                bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 0 && bytes[index + 3] == 1
            let isThreeByteStart = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            if isFourByteStart {
                result.append(bytes[index + 4] & 0x1f)
                index += 5
            } else if isThreeByteStart {
                result.append(bytes[index + 3] & 0x1f)
                index += 4
            } else {
                index += 1
            }
        }
        return result
    }

    static func convert(
        sampleBuffer: CMSampleBuffer,
        codec: VideoEncoderCodec = .h264,
        makePrefix: ((_ payloadLength: Int, _ isKeyFrame: Bool) throws -> Data)? = nil
    ) throws -> (payload: Data, isKeyFrame: Bool, preframedData: Data?) {
        let isKeyFrame = keyFrameStatus(sampleBuffer)
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw SessionError(code: .encBackpressure, detail: "Encoded sample has no block buffer")
        }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else {
            throw SessionError(code: .encBackpressure, detail: "Encoder emitted an empty access unit")
        }

        var nalHeaderLength: Int32 = 4
        var parameterSets: [ParameterSet] = []
        if isKeyFrame {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                throw SessionError(code: .encBackpressure, detail: "IDR sample has no format description")
            }
            var parameterSetCount = 0
            var firstPointer: UnsafePointer<UInt8>?
            var firstSize = 0
            let firstStatus =
                codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &firstPointer,
                    parameterSetSizeOut: &firstSize,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: &nalHeaderLength
                )
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &firstPointer,
                    parameterSetSizeOut: &firstSize,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: &nalHeaderLength
                )
            let requiredParameterSets = codec == .hevc ? 3 : 2
            guard firstStatus == noErr, parameterSetCount >= requiredParameterSets else {
                throw SessionError(
                    code: .encBackpressure,
                    detail: codec == .hevc
                        ? "IDR sample is missing VPS/SPS/PPS"
                        : "IDR sample is missing SPS/PPS"
                )
            }
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status =
                    codec == .hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        format,
                        parameterSetIndex: index,
                        parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    )
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format,
                        parameterSetIndex: index,
                        parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    )
                guard status == noErr, let pointer, size > 0 else {
                    throw SessionError(
                        code: .encBackpressure,
                        detail: "Unable to read \(codec == .hevc ? "HEVC" : "H.264") parameter set"
                    )
                }
                parameterSets.append(ParameterSet(pointer: pointer, length: size))
            }
        }
        let headerLength = Int(nalHeaderLength)
        guard (1...4).contains(headerLength) else {
            throw SessionError(code: .encBackpressure, detail: "Invalid AVCC NAL length field")
        }

        var contiguousLength = 0
        var reportedTotalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &contiguousLength,
            totalLengthOut: &reportedTotalLength,
            dataPointerOut: &pointer
        )
        let storage: PayloadStorage
        if pointerStatus == noErr,
            contiguousLength == totalLength,
            reportedTotalLength == totalLength,
            let pointer
        {
            let bytes = UnsafeRawBufferPointer(start: pointer, count: totalLength)
            let ranges = try nalRanges(in: bytes, nalUnitHeaderLength: headerLength)
            storage = try makePayload(
                parameterSets: parameterSets,
                nalRanges: ranges,
                makePrefix: makePrefix.map { factory in
                    { length in try factory(length, isKeyFrame) }
                }
            ) {
                offset, length, destination in
                memcpy(destination, pointer.advanced(by: offset), length)
                return noErr
            }
        } else {
            let ranges = try nalRanges(
                in: blockBuffer,
                totalLength: totalLength,
                nalUnitHeaderLength: headerLength)
            storage = try makePayload(
                parameterSets: parameterSets,
                nalRanges: ranges,
                makePrefix: makePrefix.map { factory in
                    { length in try factory(length, isKeyFrame) }
                }
            ) {
                offset, length, destination in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: offset,
                    dataLength: length,
                    destination: destination)
            }
        }
        return (storage.payload, isKeyFrame, storage.preframedData)
    }

    private static func nalRanges(
        in bytes: UnsafeRawBufferPointer,
        nalUnitHeaderLength: Int
    ) throws -> [NALRange] {
        guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else {
            throw SessionError(code: .encBackpressure, detail: "Encoder emitted an empty access unit")
        }
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        var ranges: [NALRange] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + nalUnitHeaderLength <= bytes.count else {
                throw SessionError(code: .encBackpressure, detail: "Truncated AVCC NAL length")
            }
            var length = 0
            for index in 0..<nalUnitHeaderLength {
                length = (length << 8) | Int(source[offset + index])
            }
            offset += nalUnitHeaderLength
            guard length > 0, length <= bytes.count - offset else {
                throw SessionError(code: .encBackpressure, detail: "Invalid AVCC NAL payload length")
            }
            ranges.append(NALRange(offset: offset, length: length))
            offset += length
        }
        guard !ranges.isEmpty else {
            throw SessionError(code: .encBackpressure, detail: "Encoder emitted an empty access unit")
        }
        return ranges
    }

    private static func nalRanges(
        in blockBuffer: CMBlockBuffer,
        totalLength: Int,
        nalUnitHeaderLength: Int
    ) throws -> [NALRange] {
        var ranges: [NALRange] = []
        var offset = 0
        var header = [UInt8](repeating: 0, count: nalUnitHeaderLength)
        while offset < totalLength {
            guard offset + nalUnitHeaderLength <= totalLength else {
                throw SessionError(code: .encBackpressure, detail: "Truncated AVCC NAL length")
            }
            let status = header.withUnsafeMutableBytes { destination -> OSStatus in
                guard let baseAddress = destination.baseAddress else {
                    return kCMBlockBufferBadPointerParameterErr
                }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: offset,
                    dataLength: nalUnitHeaderLength,
                    destination: baseAddress)
            }
            guard status == noErr else {
                throw SessionError(
                    code: .encBackpressure,
                    detail: "Unable to read encoded block buffer: OSStatus \(status)")
            }
            var length = 0
            for byte in header { length = (length << 8) | Int(byte) }
            offset += nalUnitHeaderLength
            guard length > 0, length <= totalLength - offset else {
                throw SessionError(code: .encBackpressure, detail: "Invalid AVCC NAL payload length")
            }
            ranges.append(NALRange(offset: offset, length: length))
            offset += length
        }
        guard !ranges.isEmpty else {
            throw SessionError(code: .encBackpressure, detail: "Encoder emitted an empty access unit")
        }
        return ranges
    }

    private static func makePayload(
        parameterSets: [ParameterSet],
        nalRanges: [NALRange],
        makePrefix: ((Int) throws -> Data)? = nil,
        copyNAL: (_ offset: Int, _ length: Int, _ destination: UnsafeMutableRawPointer) -> OSStatus
    ) throws -> PayloadStorage {
        var payloadLength = 0
        for length in parameterSets.map(\.length) + nalRanges.map(\.length) {
            let (nextLength, overflow) = payloadLength.addingReportingOverflow(4 + length)
            guard !overflow else {
                throw SessionError(code: .encBackpressure, detail: "Encoded access unit is too large")
            }
            payloadLength = nextLength
        }
        guard payloadLength > 0 else {
            throw SessionError(code: .encBackpressure, detail: "Encoder emitted an empty access unit")
        }
        let prefix = try makePrefix?(payloadLength) ?? Data()
        let (outputLength, overflow) = prefix.count.addingReportingOverflow(payloadLength)
        guard !overflow else {
            throw SessionError(code: .encBackpressure, detail: "Encoded access unit is too large")
        }
        var output = Data(count: outputLength)
        let status = output.withUnsafeMutableBytes { destination -> OSStatus in
            guard let baseAddress = destination.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            if !prefix.isEmpty {
                prefix.copyBytes(to: bytes, count: prefix.count)
            }
            var cursor = prefix.count
            func writeStartCode() {
                bytes[cursor] = 0
                bytes[cursor + 1] = 0
                bytes[cursor + 2] = 0
                bytes[cursor + 3] = 1
                cursor += 4
            }
            for parameterSet in parameterSets {
                writeStartCode()
                memcpy(bytes.advanced(by: cursor), parameterSet.pointer, parameterSet.length)
                cursor += parameterSet.length
            }
            for range in nalRanges {
                writeStartCode()
                let result = copyNAL(range.offset, range.length, bytes.advanced(by: cursor))
                guard result == noErr else { return result }
                cursor += range.length
            }
            return noErr
        }
        guard status == noErr else {
            throw SessionError(
                code: .encBackpressure,
                detail: "Unable to copy encoded block buffer: OSStatus \(status)")
        }
        guard !prefix.isEmpty else {
            return PayloadStorage(payload: output, preframedData: nil)
        }
        return PayloadStorage(
            payload: output.dropFirst(prefix.count),
            preframedData: output)
    }

    private static func keyFrameStatus(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false),
            let attachments = (attachmentArray as NSArray).firstObject as? [CFString: Any]
        else {
            return true
        }
        return !(attachments[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}

public enum HEVCAnnexB {
    public static func convertHVCC(_ data: Data, nalUnitHeaderLength: Int = 4) throws -> Data {
        try H264AnnexB.convertAVCC(data, nalUnitHeaderLength: nalUnitHeaderLength)
    }

    public static func nalUnitTypes(in payload: Data) -> [UInt8] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 6 else { return [] }
        var result: [UInt8] = []
        var index = 0
        while index + 5 < bytes.count {
            let fourByteStart =
                bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 0 && bytes[index + 3] == 1
            let threeByteStart =
                bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            if fourByteStart {
                result.append((bytes[index + 4] >> 1) & 0x3f)
                index += 6
            } else if threeByteStart {
                result.append((bytes[index + 3] >> 1) & 0x3f)
                index += 5
            } else {
                index += 1
            }
        }
        return result
    }
}
