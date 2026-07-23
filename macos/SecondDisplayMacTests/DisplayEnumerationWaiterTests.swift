import CoreGraphics
import Foundation
import SecondDisplayCore
import VirtualDisplayCore
import XCTest

final class DisplayEnumerationWaiterTests: XCTestCase {
    func testVirtualDelaysFromPointOneToTwelveSecondsComplete() async throws {
        for visibleAfter in [100_000_000, 2_000_000_000, 8_000_000_000, 12_000_000_000] as [UInt64] {
            let clock = VirtualEnumerationClock()
            let enumerator = DelayedEnumerator(displayID: 88, visibleAfter: visibleAfter, clock: clock)
            let waiter = DisplayEnumerationWaiter(
                enumerator: enumerator,
                onlineChecker: FixedOnlineChecker(online: true),
                clock: clock
            )
            let result = try await waiter.waitForDisplay(
                displayID: 88,
                generation: 3,
                isCurrentGeneration: { $0 == 3 }
            )
            XCTAssertEqual(result, 88)
            let elapsed = await clock.nowNanoseconds()
            XCTAssertGreaterThanOrEqual(elapsed, visibleAfter)
            XCTAssertLessThanOrEqual(elapsed, 13_000_000_000)
        }
    }

    func testTimeoutReturnsProjectError() async {
        let clock = VirtualEnumerationClock()
        let waiter = DisplayEnumerationWaiter(
            enumerator: NeverVisibleEnumerator(),
            onlineChecker: FixedOnlineChecker(online: true),
            clock: clock
        )
        do {
            _ = try await waiter.waitForDisplay(
                displayID: 88,
                generation: 3,
                isCurrentGeneration: { $0 == 3 }
            )
            XCTFail("Expected enumeration timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .vdEnumerationTimeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStopImmediatelyCancelsWaitingTask() async throws {
        let waiter = DisplayEnumerationWaiter(
            enumerator: SlowEnumerator(),
            onlineChecker: FixedOnlineChecker(online: true)
        )
        let task = Task {
            try await waiter.waitForDisplay(
                displayID: 88,
                generation: 3,
                isCurrentGeneration: { $0 == 3 }
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        await waiter.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLateOldGenerationResultCannotComplete() async throws {
        let generation = GenerationState(value: 10)
        let enumerator = GatedEnumerator(displayID: 88)
        let waiter = DisplayEnumerationWaiter(
            enumerator: enumerator,
            onlineChecker: FixedOnlineChecker(online: true)
        )
        let task = Task {
            try await waiter.waitForDisplay(
                displayID: 88,
                generation: 10,
                isCurrentGeneration: { value in await generation.matches(value) }
            )
        }
        await enumerator.waitUntilRequested()
        await generation.set(11)
        await enumerator.release()
        do {
            _ = try await task.value
            XCTFail("Expected stale generation cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDisplayDisappearanceReturnsTerminationError() async {
        let waiter = DisplayEnumerationWaiter(
            enumerator: NeverVisibleEnumerator(),
            onlineChecker: FixedOnlineChecker(online: false),
            clock: VirtualEnumerationClock()
        )
        do {
            _ = try await waiter.waitForDisplay(
                displayID: 88,
                generation: 3,
                isCurrentGeneration: { $0 == 3 }
            )
            XCTFail("Expected display termination")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .vdTerminatedBySystem)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor VirtualEnumerationClock: DisplayEnumerationClock {
    private var value: UInt64 = 0

    func nowNanoseconds() -> UInt64 { value }

    func sleep(nanoseconds: UInt64) throws {
        try Task.checkCancellation()
        value += nanoseconds
    }
}

private actor DelayedEnumerator: ShareableDisplayEnumerating {
    let displayID: CGDirectDisplayID
    let visibleAfter: UInt64
    let clock: VirtualEnumerationClock

    init(displayID: CGDirectDisplayID, visibleAfter: UInt64, clock: VirtualEnumerationClock) {
        self.displayID = displayID
        self.visibleAfter = visibleAfter
        self.clock = clock
    }

    func displayIDs() async -> Set<CGDirectDisplayID> {
        await clock.nowNanoseconds() >= visibleAfter ? [displayID] : []
    }
}

private struct NeverVisibleEnumerator: ShareableDisplayEnumerating {
    func displayIDs() async -> Set<CGDirectDisplayID> { [] }
}

private struct SlowEnumerator: ShareableDisplayEnumerating {
    func displayIDs() async throws -> Set<CGDirectDisplayID> {
        try await Task.sleep(for: .seconds(10))
        return []
    }
}

private actor GatedEnumerator: ShareableDisplayEnumerating {
    private let displayID: CGDirectDisplayID
    private var requested = false
    private var released = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func displayIDs() async -> Set<CGDirectDisplayID> {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return [displayID]
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor GenerationState {
    private var value: UInt64

    init(value: UInt64) { self.value = value }
    func matches(_ candidate: UInt64) -> Bool { candidate == value }
    func set(_ newValue: UInt64) { value = newValue }
}

private struct FixedOnlineChecker: DisplayOnlineChecking {
    let online: Bool
    func isOnline(_ displayID: CGDirectDisplayID) -> Bool { online }
}
