import Foundation
import SecondDisplayCore

public struct LengthPrefixedControlCodec: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ message: T) throws -> Data {
        let payload = try ControlMessageCodec().encode(message)
        guard let length = UInt32(exactly: payload.count), length > 0 else {
            throw SessionError(code: .netProtocolMismatch, detail: "Invalid control message length")
        }
        var networkLength = length.bigEndian
        var framed = Data(bytes: &networkLength, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }
}

public struct IncrementalControlFrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [ControlMessage] {
        buffer.append(bytes)
        var messages: [ControlMessage] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = readUInt32(buffer, at: 0)
            guard length > 0, length <= UInt32(ProtocolConstants.maximumControlMessageBytes) else {
                buffer.removeAll(keepingCapacity: false)
                throw SessionError(code: .netProtocolMismatch, detail: "Invalid control frame length")
            }
            let frameSize = MemoryLayout<UInt32>.size + Int(length)
            guard buffer.count >= frameSize else { break }
            let payload = Data(buffer[MemoryLayout<UInt32>.size..<frameSize])
            buffer.removeSubrange(0..<frameSize)
            if let message = try ControlMessageCodec().decode(payload) {
                messages.append(message)
            }
        }
        return messages
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else {
            buffer.removeAll(keepingCapacity: false)
            throw SessionError(code: .netProtocolMismatch, detail: "Control channel ended with a partial frame")
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

public struct IncrementalVideoFrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [VideoFrame] {
        buffer.append(bytes)
        var frames: [VideoFrame] = []
        while buffer.count >= VideoFrame.headerSize {
            guard buffer.starts(with: Data("SDS1".utf8)) else {
                buffer.removeAll(keepingCapacity: false)
                throw SessionError(code: .netProtocolMismatch, detail: "Invalid video frame magic")
            }
            let payloadLength = readUInt32(buffer, at: 28)
            guard payloadLength <= UInt32(VideoFrame.maximumPayloadSize) else {
                buffer.removeAll(keepingCapacity: false)
                throw SessionError(code: .netProtocolMismatch, detail: "Video payload exceeds 16 MiB")
            }
            let frameSize = VideoFrame.headerSize + Int(payloadLength)
            guard buffer.count >= frameSize else { break }
            frames.append(try VideoFrameCodec().decode(Data(buffer[..<frameSize])))
            buffer.removeSubrange(0..<frameSize)
        }
        return frames
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else {
            buffer.removeAll(keepingCapacity: false)
            throw SessionError(code: .netProtocolMismatch, detail: "Video channel ended with a partial frame")
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
