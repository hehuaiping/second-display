import CoreGraphics
import Foundation
import SecondDisplayCore
import VirtualDisplayCore
import XCTest

@MainActor
final class DisplayModeMaintainerTests: XCTestCase {
    func testRestoresTwoTimesMode() throws {
        let controller = FakeModeController()
        controller.modes = [lowMode, hiDPIMode]
        controller.current = lowMode
        let maintainer = DisplayModeMaintainer(controller: controller)
        try maintainer.maintainOnce(displayID: 7, logicalSize: logicalSize)
        XCTAssertEqual(controller.current, hiDPIMode)
        XCTAssertEqual(controller.appliedModeIDs, [2])
    }

    func testMissingModeReturnsProjectError() {
        let controller = FakeModeController()
        controller.modes = [lowMode]
        controller.current = lowMode
        XCTAssertThrowsError(
            try DisplayModeMaintainer(controller: controller)
                .maintainOnce(displayID: 7, logicalSize: logicalSize)
        ) { error in
            XCTAssertEqual((error as? SessionError)?.code, .vdHiDPIModeMissing)
        }
    }

    func testMirrorIsDetachedForSessionBeforeModeValidation() throws {
        let controller = FakeModeController()
        controller.modes = [hiDPIMode]
        controller.current = hiDPIMode
        controller.mirrored = true
        try DisplayModeMaintainer(controller: controller)
            .maintainOnce(displayID: 7, logicalSize: logicalSize)
        XCTAssertEqual(controller.detachCount, 1)
        XCTAssertFalse(controller.mirrored)
    }

    func testMirrorDetachFailureReturnsProjectError() {
        let controller = FakeModeController()
        controller.modes = [hiDPIMode]
        controller.current = hiDPIMode
        controller.mirrored = true
        controller.detachError = .failure
        XCTAssertThrowsError(
            try DisplayModeMaintainer(controller: controller)
                .maintainOnce(displayID: 7, logicalSize: logicalSize)
        ) { error in
            XCTAssertEqual((error as? SessionError)?.code, .vdMirrorDetachFailed)
        }
    }

    func testWatchdogRestoresManualLowResolutionChange() async throws {
        let controller = FakeModeController()
        controller.modes = [lowMode, hiDPIMode]
        controller.current = hiDPIMode
        let maintainer = DisplayModeMaintainer(controller: controller)
        let watchdog = maintainer.startWatchdog(
            displayID: 7,
            logicalSize: logicalSize,
            generation: 9,
            interval: .milliseconds(5),
            isCurrentGeneration: { $0 == 9 },
            onFailure: { _ in XCTFail("Watchdog should restore the mode") }
        )
        defer { watchdog.cancel() }
        controller.current = lowMode
        try await waitForMode(hiDPIMode, controller: controller)
        XCTAssertEqual(controller.current, hiDPIMode)
    }

    func testStabilizationRejectsOldGeneration() async {
        let controller = FakeModeController()
        controller.modes = [hiDPIMode]
        controller.current = hiDPIMode
        do {
            try await DisplayModeMaintainer(controller: controller).stabilize(
                displayID: 7,
                logicalSize: logicalSize,
                generation: 4,
                duration: .milliseconds(1),
                interval: .milliseconds(1),
                isCurrentGeneration: { $0 == 5 }
            )
            XCTFail("Expected stale generation cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private var logicalSize: CGSize { CGSize(width: 1280, height: 800) }
    private var lowMode: DisplayModeMetrics {
        DisplayModeMetrics(
            modeID: 1,
            logicalWidth: 1280,
            logicalHeight: 800,
            pixelWidth: 1280,
            pixelHeight: 800,
            refreshRate: 60
        )
    }
    private var hiDPIMode: DisplayModeMetrics {
        DisplayModeMetrics(
            modeID: 2,
            logicalWidth: 1280,
            logicalHeight: 800,
            pixelWidth: 2560,
            pixelHeight: 1600,
            refreshRate: 60
        )
    }

    private func waitForMode(
        _ expectedMode: DisplayModeMetrics,
        controller: FakeModeController,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if controller.current == expectedMode { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw SessionError(
            code: .vdHiDPIModeMissing,
            detail: "Timed out waiting for the display watchdog to restore the HiDPI mode"
        )
    }
}

@MainActor
private final class FakeModeController: DisplayModeControlling {
    var modes: [DisplayModeMetrics] = []
    var current: DisplayModeMetrics?
    var mirrored = false
    var detachError: CGError = .success
    var appliedModeIDs: [Int32] = []
    var detachCount = 0

    func currentMode(displayID: CGDirectDisplayID) -> DisplayModeMetrics? { current }
    func availableModes(displayID: CGDirectDisplayID) -> [DisplayModeMetrics] { modes }

    func applyMode(displayID: CGDirectDisplayID, modeID: Int32) -> CGError {
        appliedModeIDs.append(modeID)
        current = modes.first(where: { $0.modeID == modeID })
        return current == nil ? .failure : .success
    }

    func isMirrored(displayID: CGDirectDisplayID) -> Bool { mirrored }

    func detachMirror(displayID: CGDirectDisplayID) -> CGError {
        detachCount += 1
        if detachError == .success { mirrored = false }
        return detachError
    }
}
