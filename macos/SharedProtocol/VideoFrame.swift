import Foundation
import SecondDisplayCore

public enum VideoFrameType: UInt8, Sendable {
    case video = 1
    case codecConfig = 2
}

public struct VideoFrameFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let keyframe = VideoFrameFlags(rawValue: 1 << 0)
    public static let discontinuity = VideoFrameFlags(rawValue: 1 << 1)
}

public struct VideoFrame: Equatable, Sendable {
    public static let headerSize = 32
    public static let maximumPayloadSize = 16 * 1024 * 1024

    public let frameType: VideoFrameType
    public let flags: VideoFrameFlags
    public let sequence: UInt32
    public let ptsUs: UInt64
    public let captureUs: UInt64
    public let payload: Data
    package let preframedData: Data?

    public init(
        frameType: VideoFrameType,
        flags: VideoFrameFlags,
        sequence: UInt32,
        ptsUs: UInt64,
        captureUs: UInt64,
        payload: Data
    ) {
        self.frameType = frameType
        self.flags = flags
        self.sequence = sequence
        self.ptsUs = ptsUs
        self.captureUs = captureUs
        self.payload = payload
        self.preframedData = nil
    }

    package init(
        frameType: VideoFrameType,
        flags: VideoFrameFlags,
        sequence: UInt32,
        ptsUs: UInt64,
        captureUs: UInt64,
        payload: Data,
        preframedData: Data?
    ) {
        self.frameType = frameType
        self.flags = flags
        self.sequence = sequence
        self.ptsUs = ptsUs
        self.captureUs = captureUs
        self.payload = payload
        self.preframedData = preframedData
    }

    public static func == (lhs: VideoFrame, rhs: VideoFrame) -> Bool {
        lhs.frameType == rhs.frameType
            && lhs.flags == rhs.flags
            && lhs.sequence == rhs.sequence
            && lhs.ptsUs == rhs.ptsUs
            && lhs.captureUs == rhs.captureUs
            && lhs.payload == rhs.payload
    }
}

public struct VideoFrameCodec: Sendable {
    private static let magic: [UInt8] = Array("SDS1".utf8)

    public init() {}

    public func encode(_ frame: VideoFrame) throws -> Data {
        let header = try encodeHeader(
            frameType: frame.frameType,
            flags: frame.flags,
            sequence: frame.sequence,
            ptsUs: frame.ptsUs,
            captureUs: frame.captureUs,
            payloadLength: frame.payload.count)
        if let preframedData = frame.preframedData,
            preframedData.count == VideoFrame.headerSize + frame.payload.count,
            preframedData.prefix(VideoFrame.headerSize) == header
        {
            return preframedData
        }
        var data = header
        data.reserveCapacity(VideoFrame.headerSize + frame.payload.count)
        data.append(frame.payload)
        return data
    }

    package func encodeHeader(
        frameType: VideoFrameType,
        flags: VideoFrameFlags,
        sequence: UInt32,
        ptsUs: UInt64,
        captureUs: UInt64,
        payloadLength: Int
    ) throws -> Data {
        guard payloadLength <= VideoFrame.maximumPayloadSize else {
            throw SessionError(code: .netProtocolMismatch, detail: "Video payload exceeds 16 MiB")
        }
        guard let networkPayloadLength = UInt32(exactly: payloadLength) else {
            throw SessionError(code: .netProtocolMismatch, detail: "Video payload length is invalid")
        }
        var data = Data(Self.magic)
        data.reserveCapacity(VideoFrame.headerSize)
        data.append(1)
        data.append(frameType.rawValue)
        append(flags.rawValue, to: &data)
        append(sequence, to: &data)
        append(ptsUs, to: &data)
        append(captureUs, to: &data)
        append(networkPayloadLength, to: &data)
        return data
    }

    public func decode(_ data: Data) throws -> VideoFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= VideoFrame.headerSize else {
            throw SessionError(code: .netProtocolMismatch, detail: "Truncated video frame header")
        }
        guard Array(bytes[0..<4]) == Self.magic else {
            throw SessionError(code: .netProtocolMismatch, detail: "Invalid video frame magic")
        }
        guard bytes[4] == 1 else {
            throw SessionError(code: .netProtocolMismatch, detail: "Unsupported video frame version")
        }
        guard let frameType = VideoFrameType(rawValue: bytes[5]) else {
            throw SessionError(code: .netProtocolMismatch, detail: "Invalid video frame type")
        }
        let flags = readUInt16(bytes, at: 6)
        let sequence = readUInt32(bytes, at: 8)
        let ptsUs = readUInt64(bytes, at: 12)
        let captureUs = readUInt64(bytes, at: 20)
        let payloadLength = readUInt32(bytes, at: 28)
        guard payloadLength <= UInt32(VideoFrame.maximumPayloadSize) else {
            throw SessionError(code: .netProtocolMismatch, detail: "Video payload exceeds 16 MiB")
        }
        guard let expectedSize = Int(exactly: payloadLength).map({ VideoFrame.headerSize + $0 }),
            bytes.count == expectedSize
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Truncated or trailing video payload")
        }
        return VideoFrame(
            frameType: frameType,
            flags: VideoFrameFlags(rawValue: flags),
            sequence: sequence,
            ptsUs: ptsUs,
            captureUs: captureUs,
            payload: Data(bytes[VideoFrame.headerSize..<bytes.count])
        )
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var networkValue = value.bigEndian
        withUnsafeBytes(of: &networkValue) { data.append(contentsOf: $0) }
    }

    private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
    }

    private func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
    }
}
