import CoreGraphics
import Foundation
import SecondDisplayCore
import SharedProtocol

struct CursorPositionSample: Equatable, Sendable {
    let normalizedX: Double
    let normalizedY: Double
    let visible: Bool

    static let hidden = CursorPositionSample(normalizedX: 0, normalizedY: 0, visible: false)
}

enum CursorCoordinateProjector {
    static func project(point: CGPoint, displayBounds: CGRect) -> CursorPositionSample {
        guard displayBounds.width > 0, displayBounds.height > 0, displayBounds.contains(point) else {
            return .hidden
        }
        return CursorPositionSample(
            normalizedX: min(max((point.x - displayBounds.minX) / displayBounds.width, 0), 1),
            normalizedY: min(max((point.y - displayBounds.minY) / displayBounds.height, 0), 1),
            visible: true
        )
    }
}

private struct SystemCursorPositionSampler: Sendable {
    func sample(displayID: CGDirectDisplayID) -> CursorPositionSample {
        guard let event = CGEvent(source: nil) else { return .hidden }
        return CursorCoordinateProjector.project(
            point: event.location,
            displayBounds: CGDisplayBounds(displayID)
        )
    }
}

actor CursorSideChannel {
    typealias SampleProvider = @Sendable (CGDirectDisplayID) -> CursorPositionSample
    typealias Sender = @Sendable (CursorPositionMessage) async throws -> Void
    typealias FailureHandler = @Sendable (SessionError) async -> Void

    private let intervalNanoseconds: UInt64
    private let sampleProvider: SampleProvider
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(
        intervalNanoseconds: UInt64 = 8_333_333,
        sampleProvider: @escaping SampleProvider = { displayID in
            SystemCursorPositionSampler().sample(displayID: displayID)
        }
    ) {
        self.intervalNanoseconds = max(intervalNanoseconds, 1_000_000)
        self.sampleProvider = sampleProvider
    }

    func start(
        sessionId: String,
        displayID: CGDirectDisplayID,
        sessionGeneration: UInt64,
        isCurrentGeneration: @escaping @Sendable (UInt64) async -> Bool,
        send: @escaping Sender,
        onFailure: @escaping FailureHandler
    ) async {
        await stop()
        generation &+= 1
        let activeGeneration = generation
        let intervalNanoseconds = self.intervalNanoseconds
        let sampleProvider = self.sampleProvider
        task = Task(priority: .userInitiated) {
            var sequence: UInt64 = 0
            var previous: CursorPositionSample?
            while !Task.isCancelled {
                guard self.isCurrent(activeGeneration),
                    await isCurrentGeneration(sessionGeneration)
                else { return }
                let sample = sampleProvider(displayID)
                if sample != previous {
                    let message = CursorPositionMessage(
                        sessionId: sessionId,
                        sequence: sequence,
                        normalizedX: sample.normalizedX,
                        normalizedY: sample.normalizedY,
                        visible: sample.visible
                    )
                    do {
                        try await send(message)
                    } catch is CancellationError {
                        return
                    } catch let error as SessionError {
                        guard self.isCurrent(activeGeneration) else { return }
                        await onFailure(error)
                        return
                    } catch {
                        guard self.isCurrent(activeGeneration) else { return }
                        await onFailure(
                            SessionError(
                                code: .netProtocolMismatch,
                                detail: "Cursor side channel send failed"
                            )
                        )
                        return
                    }
                    guard self.isCurrent(activeGeneration) else { return }
                    previous = sample
                    sequence &+= 1
                }
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func stop() async {
        generation &+= 1
        let current = task
        task = nil
        current?.cancel()
        _ = await current?.result
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation && task != nil
    }
}
