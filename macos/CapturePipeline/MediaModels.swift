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
        self.generation = generation
    }
}

public struct MediaMetricsSnapshot: Equatable, Sendable {
    public let captureDropCount: UInt64
    public let encodeDropCount: UInt64
    public let sendDropCount: UInt64
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

public actor MediaPipelineMetrics {
    private var captureDrops: UInt64 = 0
    private var encodeDrops: UInt64 = 0
    private var sendDrops: UInt64 = 0
    private var captureDeliveryLatenciesUs: [UInt64] = []
    private var encodeQueueLatenciesUs: [UInt64] = []
    private var encodeLatenciesUs: [UInt64] = []
    private var videoToolboxLatenciesUs: [UInt64] = []
    private var bitstreamConversionLatenciesUs: [UInt64] = []
    private var encoderHardwareAccelerated: Bool?
    private var lowLatencyRateControlEnabled: Bool?
    private var sendQueueLatenciesUs: [UInt64] = []
    private var dirtyAreaPermille: [UInt64] = []
    private var currentBitrate = 0
    private var contentActivity: ContentActivity = .active

    public init() {}

    public func recordCaptureDrop(count: UInt64 = 1) {
        captureDrops &+= count
    }

    public func recordEncodeDrop(count: UInt64 = 1) {
        encodeDrops &+= count
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
        let captureDelivery = captureDeliveryLatenciesUs.sorted()
        let encodeQueue = encodeQueueLatenciesUs.sorted()
        let encode = encodeLatenciesUs.sorted()
        let videoToolbox = videoToolboxLatenciesUs.sorted()
        let bitstreamConversion = bitstreamConversionLatenciesUs.sorted()
        let sendQueue = sendQueueLatenciesUs.sorted()
        let dirtyArea = dirtyAreaPermille.sorted()
        return MediaMetricsSnapshot(
            captureDropCount: captureDrops,
            encodeDropCount: encodeDrops,
            sendDropCount: sendDrops,
            encodedFrameCount: UInt64(encodeLatenciesUs.count),
            captureDeliveryP50Milliseconds: percentile(captureDelivery, fraction: 0.50),
            captureDeliveryP95Milliseconds: percentile(captureDelivery, fraction: 0.95),
            encodeQueueP50Milliseconds: percentile(encodeQueue, fraction: 0.50),
            encodeQueueP95Milliseconds: percentile(encodeQueue, fraction: 0.95),
            encodeP50Milliseconds: percentile(encode, fraction: 0.50),
            encodeP95Milliseconds: percentile(encode, fraction: 0.95),
            videoToolboxP50Milliseconds: percentile(videoToolbox, fraction: 0.50),
            videoToolboxP95Milliseconds: percentile(videoToolbox, fraction: 0.95),
            bitstreamConversionP50Milliseconds: percentile(bitstreamConversion, fraction: 0.50),
            bitstreamConversionP95Milliseconds: percentile(bitstreamConversion, fraction: 0.95),
            encoderHardwareAccelerated: encoderHardwareAccelerated,
            lowLatencyRateControlEnabled: lowLatencyRateControlEnabled,
            sendQueueP50Milliseconds: percentile(sendQueue, fraction: 0.50),
            sendQueueP95Milliseconds: percentile(sendQueue, fraction: 0.95),
            dirtyAreaP95Percent: percentileRaw(dirtyArea, fraction: 0.95) / 10,
            currentBitrate: currentBitrate,
            contentActivity: contentActivity
        )
    }

    private func append(_ latencyUs: UInt64, to values: inout [UInt64]) {
        if values.count == 4_096 {
            values.removeFirst(1_024)
        }
        values.append(latencyUs)
    }

    private func percentile(_ sorted: [UInt64], fraction: Double) -> Double {
        percentileRaw(sorted, fraction: fraction) / 1_000
    }

    private func percentileRaw(_ sorted: [UInt64], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        return Double(sorted[index])
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
