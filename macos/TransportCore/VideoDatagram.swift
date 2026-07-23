import Foundation
import SecondDisplayCore

public struct VideoDatagramPacketizer: Sendable {
    // 固定头保存序号、分片编号和原始帧长度；所有长度在分配内存前都要先校验。
    public static let headerBytes = 20
    public static let maximumFrameBytes = 8 * 1024 * 1024

    public let maximumDatagramBytes: Int

    public init(maximumDatagramBytes: Int = 1_200) {
        self.maximumDatagramBytes = max(Self.headerBytes + 1, maximumDatagramBytes)
    }

    public func packetize(_ frame: Data, sequence: UInt32) throws -> [Data] {
        guard !frame.isEmpty, frame.count <= Self.maximumFrameBytes else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "QUIC video frame exceeds the bounded datagram payload"
            )
        }
        let fragmentPayloadBytes = maximumDatagramBytes - Self.headerBytes
        let fragmentCount = (frame.count + fragmentPayloadBytes - 1) / fragmentPayloadBytes
        guard fragmentCount <= Int(UInt16.max) else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "QUIC video frame requires too many datagrams"
            )
        }
        return (0..<fragmentCount).map { fragmentIndex in
            let start = fragmentIndex * fragmentPayloadBytes
            let end = min(start + fragmentPayloadBytes, frame.count)
            var packet = Data(capacity: Self.headerBytes + end - start)
            packet.append(contentsOf: [0x53, 0x44, 0x51, 0x31])
            packet.append(1)
            packet.append(0)
            packet.append(contentsOf: [0, 0])
            packet.appendInteger(sequence)
            packet.appendInteger(UInt16(fragmentIndex))
            packet.appendInteger(UInt16(fragmentCount))
            packet.appendInteger(UInt32(frame.count))
            packet.append(frame[start..<end])
            return packet
        }
    }
}

public actor VideoDatagramReassembler {
    public struct Result: Equatable, Sendable {
        public let frame: Data?
        public let droppedFrames: Int
        public let requiresKeyFrame: Bool
    }

    private struct PendingFrame {
        let generation: UInt64
        let totalBytes: Int
        let fragmentCount: Int
        let firstReceivedAtUs: UInt64
        var fragments: [Int: Data]
        var receivedBytes: Int
    }

    private let maximumPendingFrames: Int
    private let timeoutMicroseconds: UInt64
    private var generation: UInt64 = 0
    private var pending: [UInt32: PendingFrame] = [:]

    public init(maximumPendingFrames: Int = 4, timeoutMicroseconds: UInt64 = 100_000) {
        self.maximumPendingFrames = max(1, maximumPendingFrames)
        self.timeoutMicroseconds = max(1, timeoutMicroseconds)
    }

    public func begin(generation: UInt64) {
        // 新 generation 不继承旧连接的残片，避免序号碰撞拼出跨会话数据。
        self.generation = generation
        pending.removeAll(keepingCapacity: true)
    }

    public func append(
        _ datagram: Data,
        generation candidateGeneration: UInt64,
        receivedAtUs: UInt64
    ) throws -> Result {
        guard candidateGeneration == generation else {
            return Result(frame: nil, droppedFrames: 0, requiresKeyFrame: false)
        }
        var droppedFrames = expire(at: receivedAtUs)
        guard datagram.count > VideoDatagramPacketizer.headerBytes else {
            throw SessionError(code: .netProtocolMismatch, detail: "QUIC video datagram is truncated")
        }
        let bytes = [UInt8](datagram.prefix(VideoDatagramPacketizer.headerBytes))
        guard bytes[0...3].elementsEqual([0x53, 0x44, 0x51, 0x31]), bytes[4] == 1 else {
            throw SessionError(code: .netProtocolMismatch, detail: "QUIC video datagram header is invalid")
        }
        let sequence = bytes.uint32(at: 8)
        let fragmentIndex = Int(bytes.uint16(at: 12))
        let fragmentCount = Int(bytes.uint16(at: 14))
        let totalBytes = Int(bytes.uint32(at: 16))
        guard fragmentCount > 0, fragmentIndex < fragmentCount,
            totalBytes > 0, totalBytes <= VideoDatagramPacketizer.maximumFrameBytes
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "QUIC video fragment bounds are invalid")
        }
        if pending[sequence] == nil {
            // 重组窗口有硬上限；达到上限时淘汰最旧帧，并让上层请求新的关键帧。
            if pending.count >= maximumPendingFrames,
                let oldest = pending.min(by: {
                    $0.value.firstReceivedAtUs < $1.value.firstReceivedAtUs
                })?.key
            {
                pending.removeValue(forKey: oldest)
                droppedFrames += 1
            }
            pending[sequence] = PendingFrame(
                generation: generation,
                totalBytes: totalBytes,
                fragmentCount: fragmentCount,
                firstReceivedAtUs: receivedAtUs,
                fragments: [:],
                receivedBytes: 0
            )
        }
        guard var frame = pending[sequence],
            frame.generation == generation,
            frame.totalBytes == totalBytes,
            frame.fragmentCount == fragmentCount
        else {
            pending.removeValue(forKey: sequence)
            throw SessionError(code: .netProtocolMismatch, detail: "QUIC video fragment metadata changed")
        }
        if frame.fragments[fragmentIndex] == nil {
            let payload = Data(datagram.dropFirst(VideoDatagramPacketizer.headerBytes))
            guard payload.count <= frame.totalBytes - frame.receivedBytes else {
                pending.removeValue(forKey: sequence)
                throw SessionError(
                    code: .netProtocolMismatch,
                    detail: "QUIC video fragments exceed the declared frame length"
                )
            }
            frame.fragments[fragmentIndex] = payload
            frame.receivedBytes += payload.count
            pending[sequence] = frame
        }
        guard frame.fragments.count == fragmentCount else {
            return Result(
                frame: nil,
                droppedFrames: droppedFrames,
                requiresKeyFrame: droppedFrames > 0
            )
        }
        guard frame.receivedBytes == totalBytes else {
            pending.removeValue(forKey: sequence)
            throw SessionError(code: .netProtocolMismatch, detail: "QUIC video frame length is invalid")
        }
        var completed = Data(capacity: totalBytes)
        for index in 0..<fragmentCount {
            guard let fragment = frame.fragments[index] else {
                throw SessionError(code: .netProtocolMismatch, detail: "QUIC video fragment is missing")
            }
            completed.append(fragment)
        }
        pending.removeValue(forKey: sequence)
        return Result(
            frame: completed,
            droppedFrames: droppedFrames,
            requiresKeyFrame: droppedFrames > 0
        )
    }

    public func stop() {
        // 先推进 generation，再清空缓存；并发到达的旧数据包会被 append 的首个 guard 丢弃。
        generation &+= 1
        pending.removeAll(keepingCapacity: false)
    }

    private func expire(at nowUs: UInt64) -> Int {
        let expired = pending.filter {
            nowUs >= $0.value.firstReceivedAtUs
                && nowUs - $0.value.firstReceivedAtUs >= timeoutMicroseconds
        }.map(\.key)
        for key in expired { pending.removeValue(forKey: key) }
        return expired.count
    }
}

extension Data {
    fileprivate mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}

extension [UInt8] {
    fileprivate func uint16(at index: Int) -> UInt16 {
        (UInt16(self[index]) << 8) | UInt16(self[index + 1])
    }

    fileprivate func uint32(at index: Int) -> UInt32 {
        (UInt32(self[index]) << 24) | (UInt32(self[index + 1]) << 16)
            | (UInt32(self[index + 2]) << 8) | UInt32(self[index + 3])
    }
}
