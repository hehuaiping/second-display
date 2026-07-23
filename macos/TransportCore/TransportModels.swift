import Foundation
import SecondDisplayCore
import SharedProtocol

public enum TransportConnectionState: Equatable, Sendable {
    case setup
    case connecting
    case ready
    case failed(SessionError)
    case cancelled
}

public protocol ByteTransportConnection: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    func receive(maximumLength: Int) async throws -> Data?
    func cancel() async
}

public protocol TransportClock: Sendable {
    func nowMicroseconds() -> UInt64
    func sleep(nanoseconds: UInt64) async throws
}

public struct SystemTransportClock: TransportClock {
    public init() {}

    public func nowMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }

    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public actor HeartbeatMonitor {
    private let clock: any TransportClock
    private let intervalNanoseconds: UInt64
    private let timeoutMicroseconds: UInt64
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastAcknowledgementUs: UInt64 = 0
    private var lastRTTUs: UInt64?

    public init(
        clock: any TransportClock = SystemTransportClock(),
        intervalNanoseconds: UInt64 = 2_000_000_000,
        timeoutMicroseconds: UInt64 = 6_000_000
    ) {
        self.clock = clock
        self.intervalNanoseconds = intervalNanoseconds
        self.timeoutMicroseconds = timeoutMicroseconds
    }

    public func start(
        sessionId: String,
        generation: UInt64,
        send: @escaping @Sendable (Heartbeat) async throws -> Void,
        onTimeout: @escaping @Sendable (SessionError) async -> Void
    ) {
        task?.cancel()
        self.generation = generation
        lastAcknowledgementUs = clock.nowMicroseconds()
        lastRTTUs = nil
        let clock = self.clock
        let interval = intervalNanoseconds
        let timeout = timeoutMicroseconds
        task = Task {
            var sequence: UInt64 = 0
            while !Task.isCancelled {
                do {
                    try await clock.sleep(nanoseconds: interval)
                    try Task.checkCancellation()
                    guard self.isCurrent(generation) else { return }
                    let now = clock.nowMicroseconds()
                    let lastAck = self.lastAcknowledgement()
                    if now >= lastAck, now - lastAck > timeout {
                        await onTimeout(
                            SessionError(code: .netProtocolMismatch, detail: "Control heartbeat timed out")
                        )
                        return
                    }
                    try await send(Heartbeat(sessionId: sessionId, sequence: sequence, sentAtUs: now))
                    sequence &+= 1
                } catch is CancellationError {
                    return
                } catch {
                    await onTimeout(
                        SessionError(code: .netProtocolMismatch, detail: "Unable to send heartbeat")
                    )
                    return
                }
            }
        }
    }

    public func acknowledge(_ acknowledgement: HeartbeatAck, generation: UInt64) {
        guard generation == self.generation else { return }
        let now = clock.nowMicroseconds()
        lastAcknowledgementUs = max(lastAcknowledgementUs, now)
        if now >= acknowledgement.sentAtUs {
            lastRTTUs = now - acknowledgement.sentAtUs
        }
    }

    public func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    public var currentRTTMilliseconds: Double? {
        lastRTTUs.map { Double($0) / 1_000 }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation
    }

    private func lastAcknowledgement() -> UInt64 {
        lastAcknowledgementUs
    }
}

public actor BoundedVideoSendQueue {
    public struct EnqueueResult: Equatable, Sendable {
        public let accepted: Bool
        public let droppedFrames: Int
        public let requiresKeyFrame: Bool
    }

    private let maximumFrames: Int
    private let maximumBytes: Int
    private var frames: [VideoFrame] = []
    private var byteCount = 0
    private var waiter: CheckedContinuation<VideoFrame?, Never>?
    private var finished = false

    public init(maximumFrames: Int = 2, maximumBytes: Int = 8 * 1024 * 1024) {
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
    }

    public func enqueue(_ frame: VideoFrame) -> EnqueueResult {
        guard !finished, frame.payload.count <= maximumBytes else {
            return EnqueueResult(accepted: false, droppedFrames: 1, requiresKeyFrame: true)
        }
        if let waiter, frames.isEmpty {
            self.waiter = nil
            waiter.resume(returning: frame)
            return EnqueueResult(accepted: true, droppedFrames: 0, requiresKeyFrame: false)
        }

        var dropped = 0
        while frames.count >= maximumFrames || byteCount + frame.payload.count > maximumBytes {
            guard let index = frames.firstIndex(where: { !$0.flags.contains(.keyframe) }) else {
                return EnqueueResult(accepted: false, droppedFrames: dropped + 1, requiresKeyFrame: true)
            }
            byteCount -= frames[index].payload.count
            frames.remove(at: index)
            dropped += 1
        }
        frames.append(frame)
        byteCount += frame.payload.count
        return EnqueueResult(accepted: true, droppedFrames: dropped, requiresKeyFrame: dropped > 0)
    }

    public func next() async -> VideoFrame? {
        if !frames.isEmpty {
            let frame = frames.removeFirst()
            byteCount -= frame.payload.count
            return frame
        }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        frames.removeAll(keepingCapacity: false)
        byteCount = 0
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(returning: nil)
    }

    public var depth: Int { frames.count }
    public var bytes: Int { byteCount }
}
