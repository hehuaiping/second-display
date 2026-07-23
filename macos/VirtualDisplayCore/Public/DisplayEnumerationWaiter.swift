import CoreGraphics
import Dispatch
import Foundation
import SecondDisplayCore

public protocol ShareableDisplayEnumerating: Sendable {
    func displayIDs() async throws -> Set<CGDirectDisplayID>
}

public protocol DisplayEnumerationClock: Sendable {
    func nowNanoseconds() async -> UInt64
    func sleep(nanoseconds: UInt64) async throws
}

public struct SystemDisplayEnumerationClock: DisplayEnumerationClock {
    public init() {}

    public func nowNanoseconds() async -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public actor DisplayEnumerationWaiter {
    private static let backoffNanoseconds: [UInt64] = [
        100_000_000,
        200_000_000,
        400_000_000,
        800_000_000,
        1_000_000_000,
    ]

    private let enumerator: any ShareableDisplayEnumerating
    private let onlineChecker: any DisplayOnlineChecking
    private let clock: any DisplayEnumerationClock
    private var activeTask: Task<CGDirectDisplayID, Error>?
    private var activeToken: UUID?

    public init(
        enumerator: any ShareableDisplayEnumerating,
        onlineChecker: any DisplayOnlineChecking = SystemDisplayOnlineChecker(),
        clock: any DisplayEnumerationClock = SystemDisplayEnumerationClock()
    ) {
        self.enumerator = enumerator
        self.onlineChecker = onlineChecker
        self.clock = clock
    }

    public func waitForDisplay(
        displayID: CGDirectDisplayID,
        generation: UInt64,
        timeoutNanoseconds: UInt64 = 15_000_000_000,
        isCurrentGeneration: @escaping @Sendable (UInt64) async -> Bool
    ) async throws -> CGDirectDisplayID {
        activeTask?.cancel()
        let token = UUID()
        let enumerator = self.enumerator
        let onlineChecker = self.onlineChecker
        let clock = self.clock
        let task = Task<CGDirectDisplayID, Error> {
            let start = await clock.nowNanoseconds()
            var backoffIndex = 0
            while true {
                try Task.checkCancellation()
                guard await isCurrentGeneration(generation) else { throw CancellationError() }
                guard onlineChecker.isOnline(displayID) else {
                    throw SessionError(
                        code: .vdTerminatedBySystem,
                        detail: "Virtual display disappeared during enumeration"
                    )
                }
                let displayIDs = try await enumerator.displayIDs()
                try Task.checkCancellation()
                guard await isCurrentGeneration(generation) else { throw CancellationError() }
                if displayIDs.contains(displayID) {
                    return displayID
                }

                let now = await clock.nowNanoseconds()
                let elapsed = now >= start ? now - start : 0
                guard elapsed < timeoutNanoseconds else {
                    throw SessionError(
                        code: .vdEnumerationTimeout,
                        detail: "Shareable display enumeration exceeded 15 seconds"
                    )
                }
                let backoff = Self.backoffNanoseconds[min(backoffIndex, Self.backoffNanoseconds.count - 1)]
                backoffIndex += 1
                try await clock.sleep(nanoseconds: min(backoff, timeoutNanoseconds - elapsed))
            }
        }
        activeToken = token
        activeTask = task
        do {
            let result = try await task.value
            clearActiveTask(ifMatching: token)
            return result
        } catch {
            clearActiveTask(ifMatching: token)
            throw error
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeToken = nil
    }

    public func confirmReleased(
        displayID: CGDirectDisplayID,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws {
        let start = await clock.nowNanoseconds()
        while onlineChecker.isOnline(displayID) {
            try Task.checkCancellation()
            let now = await clock.nowNanoseconds()
            let elapsed = now >= start ? now - start : 0
            guard elapsed < timeoutNanoseconds else {
                throw SessionError(code: .vdApplyFailed, detail: "Old virtual display is still registered")
            }
            try await clock.sleep(nanoseconds: min(100_000_000, timeoutNanoseconds - elapsed))
        }
    }

    private func clearActiveTask(ifMatching token: UUID) {
        guard activeToken == token else { return }
        activeTask = nil
        activeToken = nil
    }
}

