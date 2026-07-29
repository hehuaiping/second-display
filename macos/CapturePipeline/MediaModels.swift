@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Darwin
import Foundation
import SecondDisplayCore

public struct CaptureSpec: Equatable, Sendable {
    public static let queueDepthRange = 3...8

    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let queueDepth: Int
    public let showsCursor: Bool

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int = 60,
        queueDepth: Int = 3,
        showsCursor: Bool = true
    ) throws {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw SessionError(
                code: .capStreamStopped, detail: "Capture dimensions must be positive and even")
        }
        guard width <= 8_192, height <= 8_192 else {
            throw SessionError(
                code: .capStreamStopped, detail: "Capture dimensions exceed the supported limit")
        }
        guard (1...120).contains(framesPerSecond) else {
            throw SessionError(
                code: .capStreamStopped, detail: "Capture frame rate must be between 1 and 120")
        }
        guard Self.queueDepthRange.contains(queueDepth) else {
            throw SessionError(code: .capStreamStopped, detail: "Capture queueDepth must be between 3 and 8")
        }
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.queueDepth = queueDepth
        self.showsCursor = showsCursor
    }
}

public struct CapturedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTimeStamp: CMTime
    public let captureTimestampUs: UInt64
    public let callbackTimestampUs: UInt64
    public let contentRect: CGRect
    public let generation: UInt64
    public let isDiscontinuous: Bool
    public let dirtyAreaRatio: Double

    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        captureTimestampUs: UInt64,
        callbackTimestampUs: UInt64,
        contentRect: CGRect,
        generation: UInt64,
        isDiscontinuous: Bool = false,
        dirtyAreaRatio: Double = 1
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTimeStamp = presentationTimeStamp
        self.captureTimestampUs = captureTimestampUs
        self.callbackTimestampUs = callbackTimestampUs
        self.contentRect = contentRect
        self.generation = generation
        self.isDiscontinuous = isDiscontinuous
        self.dirtyAreaRatio = min(max(dirtyAreaRatio.isFinite ? dirtyAreaRatio : 1, 0), 1)
    }

    func markingDiscontinuous() -> CapturedFrame {
        CapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            captureTimestampUs: captureTimestampUs,
            callbackTimestampUs: callbackTimestampUs,
            contentRect: contentRect,
            generation: generation,
            isDiscontinuous: true,
            dirtyAreaRatio: dirtyAreaRatio
        )
    }
}

public enum ContentActivity: String, Sendable {
    case active
    case staticContent
}

public enum H264Profile: String, Codable, Sendable {
    case high
    case main
}

public enum VideoEncoderCodec: String, Codable, Sendable {
    case h264
    case hevc
}

public struct EncoderSpec: Equatable, Sendable {
    public static let bitrateRange = 8_000_000...30_000_000

    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let bitrate: Int
    public let profile: H264Profile
    public let codec: VideoEncoderCodec
    public let maximumKeyFrameIntervalSeconds: Int

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int = 60,
        bitrate: Int = 16_000_000,
        profile: H264Profile = .high,
        codec: VideoEncoderCodec = .h264,
        maximumKeyFrameIntervalSeconds: Int = 2
    ) throws {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw SessionError(code: .encCreateFailed, detail: "Encoder dimensions must be positive and even")
        }
        guard width <= 8_192, height <= 8_192 else {
            throw SessionError(
                code: .encCreateFailed, detail: "Encoder dimensions exceed the supported limit")
        }
        guard (1...120).contains(framesPerSecond) else {
            throw SessionError(code: .encCreateFailed, detail: "Encoder frame rate must be between 1 and 120")
        }
        guard Self.bitrateRange.contains(bitrate) else {
            throw SessionError(
                code: .encCreateFailed, detail: "Encoder bitrate must be between 8 and 30 Mbps")
        }
        guard (1...10).contains(maximumKeyFrameIntervalSeconds) else {
            throw SessionError(
                code: .encCreateFailed, detail: "Keyframe interval must be between 1 and 10 seconds")
        }
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.profile = profile
        self.codec = codec
        self.maximumKeyFrameIntervalSeconds = maximumKeyFrameIntervalSeconds
    }
}

public struct EncodedFrame: Equatable, Sendable {
    public let sequence: UInt32
    public let presentationTimeStampUs: UInt64
    public let isKeyFrame: Bool
    public let captureTimestampUs: UInt64
    public let encodeCallbackTimestampUs: UInt64
    public let encodeCompleteTimestampUs: UInt64
    public let encoderHardwareAccelerated: Bool?
    public let lowLatencyRateControlEnabled: Bool?
    public let payload: Data
    package let preframedData: Data?
    public let generation: UInt64

    public init(
        sequence: UInt32,
        presentationTimeStampUs: UInt64,
        isKeyFrame: Bool,
        captureTimestampUs: UInt64,
        encodeCallbackTimestampUs: UInt64? = nil,
        encodeCompleteTimestampUs: UInt64,
        encoderHardwareAccelerated: Bool? = nil,
        lowLatencyRateControlEnabled: Bool? = nil,
        payload: Data,
        generation: UInt64
    ) {
        self.sequence = sequence
        self.presentationTimeStampUs = presentationTimeStampUs
        self.isKeyFrame = isKeyFrame
        self.captureTimestampUs = captureTimestampUs
        self.encodeCallbackTimestampUs = encodeCallbackTimestampUs ?? encodeCompleteTimestampUs
        self.encodeCompleteTimestampUs = encodeCompleteTimestampUs
        self.encoderHardwareAccelerated = encoderHardwareAccelerated
        self.lowLatencyRateControlEnabled = lowLatencyRateControlEnabled
        self.payload = payload
        self.preframedData = nil
        self.generation = generation
    }

    package init(
        sequence: UInt32,
        presentationTimeStampUs: UInt64,
        isKeyFrame: Bool,
        captureTimestampUs: UInt64,
        encodeCallbackTimestampUs: UInt64? = nil,
        encodeCompleteTimestampUs: UInt64,
        encoderHardwareAccelerated: Bool? = nil,
        lowLatencyRateControlEnabled: Bool? = nil,
        payload: Data,
        preframedData: Data?,
        generation: UInt64
    ) {
        self.sequence = sequence
        self.presentationTimeStampUs = presentationTimeStampUs
        self.isKeyFrame = isKeyFrame
        self.captureTimestampUs = captureTimestampUs
        self.encodeCallbackTimestampUs = encodeCallbackTimestampUs ?? encodeCompleteTimestampUs
        self.encodeCompleteTimestampUs = encodeCompleteTimestampUs
        self.encoderHardwareAccelerated = encoderHardwareAccelerated
        self.lowLatencyRateControlEnabled = lowLatencyRateControlEnabled
        self.payload = payload
        self.preframedData = preframedData
        self.generation = generation
    }

    public static func == (lhs: EncodedFrame, rhs: EncodedFrame) -> Bool {
        lhs.sequence == rhs.sequence
            && lhs.presentationTimeStampUs == rhs.presentationTimeStampUs
            && lhs.isKeyFrame == rhs.isKeyFrame
            && lhs.captureTimestampUs == rhs.captureTimestampUs
            && lhs.encodeCallbackTimestampUs == rhs.encodeCallbackTimestampUs
            && lhs.encodeCompleteTimestampUs == rhs.encodeCompleteTimestampUs
            && lhs.encoderHardwareAccelerated == rhs.encoderHardwareAccelerated
            && lhs.lowLatencyRateControlEnabled == rhs.lowLatencyRateControlEnabled
            && lhs.payload == rhs.payload
            && lhs.generation == rhs.generation
    }
}

public struct MediaMetricsSnapshot: Equatable, Sendable {
    public let captureDropCount: UInt64
    public let encodeDropCount: UInt64
    public let encodeDropBreakdown: EncodeDropBreakdown
    public let sendDropCount: UInt64
    public let capturedFrameCount: UInt64
    public let encodedFrameCount: UInt64
    public let captureDeliveryP50Milliseconds: Double
    public let captureDeliveryP95Milliseconds: Double
    public let encodeQueueP50Milliseconds: Double
    public let encodeQueueP95Milliseconds: Double
    public let encodeP50Milliseconds: Double
    public let encodeP95Milliseconds: Double
    public let videoToolboxP50Milliseconds: Double
    public let videoToolboxP95Milliseconds: Double
    public let bitstreamConversionP50Milliseconds: Double
    public let bitstreamConversionP95Milliseconds: Double
    public let encoderHardwareAccelerated: Bool?
    public let lowLatencyRateControlEnabled: Bool?
    public let sendQueueP50Milliseconds: Double
    public let sendQueueP95Milliseconds: Double
    public let dirtyAreaP95Percent: Double
    public let currentBitrate: Int
    public let contentActivity: ContentActivity
}

public enum EncodeDropReason: Sendable {
    case staleBeforeEncode
    case queueReplacement
    case encoderRejected
    case recoveryDiscard
    case failure
    case unspecified
}

/// 将编码阶段丢帧按原因拆分，避免把码率受限、应用排队和恢复门禁混为同一种压力。
/// `encodeDropCount` 继续作为兼容的总计数，详细计数用于诊断和自适应决策。
public struct EncodeDropBreakdown: Equatable, Sendable {
    public internal(set) var staleBeforeEncode: UInt64 = 0
    public internal(set) var queueReplacement: UInt64 = 0
    public internal(set) var encoderRejected: UInt64 = 0
    public internal(set) var recoveryDiscard: UInt64 = 0
    public internal(set) var failure: UInt64 = 0
    public internal(set) var unspecified: UInt64 = 0

    public var total: UInt64 {
        staleBeforeEncode
            &+ queueReplacement
            &+ encoderRejected
            &+ recoveryDiscard
            &+ failure
            &+ unspecified
    }

    mutating func record(_ reason: EncodeDropReason, count: UInt64) {
        switch reason {
        case .staleBeforeEncode:
            staleBeforeEncode &+= count
        case .queueReplacement:
            queueReplacement &+= count
        case .encoderRejected:
            encoderRejected &+= count
        case .recoveryDiscard:
            recoveryDiscard &+= count
        case .failure:
            failure &+= count
        case .unspecified:
            unspecified &+= count
        }
    }
}

/// 固定窗口直方图避免长时间推流时反复 `removeFirst` 和排序整组样本。
/// 延迟采用 100 微秒分桶；超过上限的异常值归入最后一桶，仍能反映尾延迟恶化。
private struct SlidingHistogram: Sendable {
    private let capacity: Int
    private let bucketWidth: UInt64
    private let maximumValue: UInt64
    private var ring: [Int]
    private var buckets: [UInt32]
    private var count = 0
    private var writeIndex = 0

    init(capacity: Int, bucketWidth: UInt64, maximumValue: UInt64) {
        self.capacity = max(1, capacity)
        self.bucketWidth = max(1, bucketWidth)
        self.maximumValue = maximumValue
        self.ring = [Int](repeating: 0, count: max(1, capacity))
        let bucketCount = Int(maximumValue / max(1, bucketWidth)) + 1
        self.buckets = [UInt32](repeating: 0, count: max(1, bucketCount))
    }

    mutating func append(_ value: UInt64) {
        let bucket = Int(min(value, maximumValue) / bucketWidth)
        if count == capacity {
            let replaced = ring[writeIndex]
            buckets[replaced] -= 1
        } else {
            count += 1
        }
        ring[writeIndex] = bucket
        buckets[bucket] += 1
        writeIndex = (writeIndex + 1) % capacity
    }

    func percentile(_ fraction: Double) -> Double {
        guard count > 0 else { return 0 }
        let normalized = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        let zeroBasedIndex = min(
            count - 1,
            Int((Double(count - 1) * normalized).rounded(.up)))
        let targetRank = zeroBasedIndex + 1
        var observed = 0
        for (index, frequency) in buckets.enumerated() {
            observed += Int(frequency)
            if observed >= targetRank {
                return Double(UInt64(index) * bucketWidth)
            }
        }
        return Double(maximumValue)
    }

    var sampleCount: Int { count }
}

public actor MediaPipelineMetrics {
    private static let latencyBucketWidthUs: UInt64 = 100
    private static let maximumTrackedLatencyUs: UInt64 = 2_000_000

    private var captureDrops: UInt64 = 0
    private var encodeDrops: UInt64 = 0
    private var encodeDropBreakdown = EncodeDropBreakdown()
    private var sendDrops: UInt64 = 0
    private var captureDeliveryLatenciesUs: SlidingHistogram
    private var encodeQueueLatenciesUs: SlidingHistogram
    private var encodeLatenciesUs: SlidingHistogram
    private var videoToolboxLatenciesUs: SlidingHistogram
    private var bitstreamConversionLatenciesUs: SlidingHistogram
    private var encoderHardwareAccelerated: Bool?
    private var lowLatencyRateControlEnabled: Bool?
    private var sendQueueLatenciesUs: SlidingHistogram
    private var dirtyAreaPermille: SlidingHistogram
    private var totalCapturedFrames: UInt64 = 0
    private var totalEncodedFrames: UInt64 = 0
    private var currentBitrate = 0
    private var contentActivity: ContentActivity = .active

    /// 默认 600 个样本对应 60 FPS 下约 10 秒、120 FPS 下约 5 秒。
    /// 总帧数单独累计，滑动窗口只负责反映近期延迟。
    public init(sampleCapacity: Int = 600) {
        let capacity = max(1, sampleCapacity)
        captureDeliveryLatenciesUs = Self.makeLatencyHistogram(capacity: capacity)
        encodeQueueLatenciesUs = Self.makeLatencyHistogram(capacity: capacity)
        encodeLatenciesUs = Self.makeLatencyHistogram(capacity: capacity)
        videoToolboxLatenciesUs = Self.makeLatencyHistogram(capacity: capacity)
        bitstreamConversionLatenciesUs = Self.makeLatencyHistogram(capacity: capacity)
        sendQueueLatenciesUs = Self.makeLatencyHistogram(capacity: capacity)
        dirtyAreaPermille = SlidingHistogram(
            capacity: capacity,
            bucketWidth: 1,
            maximumValue: 1_000)
    }

    public func recordCaptureDrop(count: UInt64 = 1) {
        captureDrops &+= count
    }

    public func recordCaptureObserved() {
        totalCapturedFrames &+= 1
    }

    public func recordEncodeDrop(count: UInt64 = 1) {
        recordEncodeDrop(reason: .unspecified, count: count)
    }

    public func recordEncodeDrop(reason: EncodeDropReason, count: UInt64 = 1) {
        encodeDrops &+= count
        encodeDropBreakdown.record(reason, count: count)
    }

    public func recordSendDrop(count: UInt64 = 1) {
        sendDrops &+= count
    }

    public func recordCapturedFrame(deliveryLatencyUs: UInt64) {
        append(deliveryLatencyUs, to: &captureDeliveryLatenciesUs)
    }

    public func recordEncodeStarted(queueLatencyUs: UInt64) {
        append(queueLatencyUs, to: &encodeQueueLatenciesUs)
    }

    public func recordEncodeStarted(captureDeliveryLatencyUs: UInt64, queueLatencyUs: UInt64) {
        append(captureDeliveryLatencyUs, to: &captureDeliveryLatenciesUs)
        append(queueLatencyUs, to: &encodeQueueLatenciesUs)
    }

    public func recordEncodedFrame(
        latencyUs: UInt64,
        videoToolboxLatencyUs: UInt64? = nil,
        bitstreamConversionLatencyUs: UInt64? = nil,
        encoderHardwareAccelerated: Bool? = nil,
        lowLatencyRateControlEnabled: Bool? = nil
    ) {
        totalEncodedFrames &+= 1
        append(latencyUs, to: &encodeLatenciesUs)
        if let videoToolboxLatencyUs {
            append(videoToolboxLatencyUs, to: &videoToolboxLatenciesUs)
        }
        if let bitstreamConversionLatencyUs {
            append(bitstreamConversionLatencyUs, to: &bitstreamConversionLatenciesUs)
        }
        if let encoderHardwareAccelerated {
            self.encoderHardwareAccelerated = encoderHardwareAccelerated
        }
        if let lowLatencyRateControlEnabled {
            self.lowLatencyRateControlEnabled = lowLatencyRateControlEnabled
        }
    }

    public func recordSendStarted(queueLatencyUs: UInt64) {
        append(queueLatencyUs, to: &sendQueueLatenciesUs)
    }

    public func recordContentActivity(
        dirtyAreaRatio: Double,
        currentBitrate: Int,
        activity: ContentActivity
    ) {
        let normalized = min(max(dirtyAreaRatio.isFinite ? dirtyAreaRatio : 1, 0), 1)
        append(UInt64((normalized * 1_000).rounded()), to: &dirtyAreaPermille)
        self.currentBitrate = currentBitrate
        self.contentActivity = activity
    }

    public func snapshot() -> MediaMetricsSnapshot {
        return MediaMetricsSnapshot(
            captureDropCount: captureDrops,
            encodeDropCount: encodeDrops,
            encodeDropBreakdown: encodeDropBreakdown,
            sendDropCount: sendDrops,
            capturedFrameCount: totalCapturedFrames,
            encodedFrameCount: totalEncodedFrames,
            captureDeliveryP50Milliseconds: milliseconds(
                captureDeliveryLatenciesUs.percentile(0.50)),
            captureDeliveryP95Milliseconds: milliseconds(
                captureDeliveryLatenciesUs.percentile(0.95)),
            encodeQueueP50Milliseconds: milliseconds(encodeQueueLatenciesUs.percentile(0.50)),
            encodeQueueP95Milliseconds: milliseconds(encodeQueueLatenciesUs.percentile(0.95)),
            encodeP50Milliseconds: milliseconds(encodeLatenciesUs.percentile(0.50)),
            encodeP95Milliseconds: milliseconds(encodeLatenciesUs.percentile(0.95)),
            videoToolboxP50Milliseconds: milliseconds(
                videoToolboxLatenciesUs.percentile(0.50)),
            videoToolboxP95Milliseconds: milliseconds(
                videoToolboxLatenciesUs.percentile(0.95)),
            bitstreamConversionP50Milliseconds: milliseconds(
                bitstreamConversionLatenciesUs.percentile(0.50)),
            bitstreamConversionP95Milliseconds: milliseconds(
                bitstreamConversionLatenciesUs.percentile(0.95)),
            encoderHardwareAccelerated: encoderHardwareAccelerated,
            lowLatencyRateControlEnabled: lowLatencyRateControlEnabled,
            sendQueueP50Milliseconds: milliseconds(sendQueueLatenciesUs.percentile(0.50)),
            sendQueueP95Milliseconds: milliseconds(sendQueueLatenciesUs.percentile(0.95)),
            dirtyAreaP95Percent: dirtyAreaPermille.percentile(0.95) / 10,
            currentBitrate: currentBitrate,
            contentActivity: contentActivity
        )
    }

    private static func makeLatencyHistogram(capacity: Int) -> SlidingHistogram {
        SlidingHistogram(
            capacity: capacity,
            bucketWidth: latencyBucketWidthUs,
            maximumValue: maximumTrackedLatencyUs)
    }

    private func append(_ latencyUs: UInt64, to values: inout SlidingHistogram) {
        values.append(latencyUs)
    }

    private func milliseconds(_ microseconds: Double) -> Double {
        microseconds / 1_000
    }
}

enum MediaClock {
    private static let machTimebase: mach_timebase_info_data_t = {
        var information = mach_timebase_info_data_t()
        mach_timebase_info(&information)
        return information
    }()

    static func monotonicMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    static func microseconds(machAbsoluteTime: UInt64) -> UInt64 {
        let numerator = UInt64(machTimebase.numer)
        let denominator = UInt64(machTimebase.denom)
        guard numerator > 0, denominator > 0 else { return 0 }
        let quotient = machAbsoluteTime / denominator
        let remainder = machAbsoluteTime % denominator
        let (wholeNanoseconds, overflow) = quotient.multipliedReportingOverflow(by: numerator)
        guard !overflow else { return 0 }
        let remainderNanoseconds = remainder * numerator / denominator
        return (wholeNanoseconds + remainderNanoseconds) / 1_000
    }

    static func microseconds(_ time: CMTime) -> UInt64 {
        guard time.isValid, time.isNumeric, time.seconds.isFinite, time.seconds >= 0 else { return 0 }
        return UInt64((time.seconds * 1_000_000).rounded())
    }
}
