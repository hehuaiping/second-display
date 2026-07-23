import Foundation
import SecondDisplayCore
import SharedProtocol

public actor ControlChannel {
    private let connection: any ByteTransportConnection
    private var receiveTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(connection: any ByteTransportConnection) {
        self.connection = connection
    }

    public func start(
        generation: UInt64,
        startConnection: Bool = true,
        onMessage: @escaping @Sendable (ControlMessage) async -> Void,
        onFailure: @escaping @Sendable (SessionError) async -> Void
    ) async throws {
        if receiveTask != nil {
            await stop()
        } else {
            self.generation &+= 1
        }
        if startConnection { try await connection.start() }
        self.generation = generation
        let connection = self.connection
        receiveTask = Task {
            var parser = IncrementalControlFrameParser()
            do {
                while !Task.isCancelled {
                    guard let bytes = try await connection.receive(maximumLength: 64 * 1024) else {
                        try parser.finish()
                        guard self.isCurrent(generation) else { return }
                        await onFailure(
                            SessionError(code: .netProtocolMismatch, detail: "Control connection closed")
                        )
                        return
                    }
                    if bytes.isEmpty { continue }
                    for message in try parser.append(bytes) {
                        guard self.isCurrent(generation) else { return }
                        await onMessage(message)
                    }
                }
            } catch is CancellationError {
                return
            } catch let error as SessionError {
                guard self.isCurrent(generation) else { return }
                let response = ErrorControlMessage(
                    errorCode: error.code,
                    message: error.detail,
                    generation: generation
                )
                if let bytes = try? LengthPrefixedControlCodec().encode(response) {
                    try? await connection.send(bytes)
                }
                await onFailure(error)
            } catch {
                guard self.isCurrent(generation) else { return }
                await onFailure(SessionError(code: .netProtocolMismatch, detail: "Control receive failed"))
            }
        }
    }

    public func send<T: Encodable>(_ message: T) async throws {
        try await connection.send(LengthPrefixedControlCodec().encode(message))
    }

    public func stop() async {
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        await connection.cancel()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation
    }
}

public actor VideoChannel {
    public struct QueueSnapshot: Equatable, Sendable {
        public let depth: Int
        public let bytes: Int
    }

    private let connection: any ByteTransportConnection
    private let queue: BoundedVideoSendQueue
    private var sendTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        connection: any ByteTransportConnection,
        queue: BoundedVideoSendQueue = BoundedVideoSendQueue()
    ) {
        self.connection = connection
        self.queue = queue
    }

    public func start(
        generation: UInt64 = 0,
        startConnection: Bool = true,
        onFailure: @escaping @Sendable (SessionError) async -> Void
    ) async throws {
        if startConnection { try await connection.start() }
        self.generation = generation
        let connection = self.connection
        let queue = self.queue
        sendTask = Task {
            while !Task.isCancelled, let frame = await queue.next() {
                guard self.isCurrent(generation) else { return }
                do {
                    try await connection.send(VideoFrameCodec().encode(frame))
                } catch is CancellationError {
                    return
                } catch let error as SessionError {
                    guard self.isCurrent(generation) else { return }
                    await onFailure(error)
                    return
                } catch {
                    guard self.isCurrent(generation) else { return }
                    await onFailure(SessionError(code: .netProtocolMismatch, detail: "Video send failed"))
                    return
                }
            }
        }
    }

    @discardableResult
    public func send(_ frame: VideoFrame) async -> BoundedVideoSendQueue.EnqueueResult {
        await queue.enqueue(frame)
    }

    public func stop() async {
        generation &+= 1
        sendTask?.cancel()
        sendTask = nil
        await queue.finish()
        await connection.cancel()
    }

    public func queueSnapshot() async -> QueueSnapshot {
        QueueSnapshot(depth: await queue.depth, bytes: await queue.bytes)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation
    }
}
