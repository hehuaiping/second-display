import CoreGraphics
import Foundation
import SecondDisplayCore
import SharedProtocol
import XCTest

@testable import P3HostCore

final class P4SessionAndInputTests: XCTestCase {
    func testSessionCoordinatorFollowsStateTableAndRejectsOldGeneration() async {
        let coordinator = SessionCoordinator()
        let generation = await coordinator.begin()
        let validPath: [SessionState] = [
            .waitingForReceiver, .creatingVirtualDisplay, .waitingForDisplayEnumeration,
            .stabilizingDisplayMode, .startingCapture, .startingEncoder, .streaming,
        ]
        for state in validPath {
            let accepted = await coordinator.transition(to: state, generation: generation)
            XCTAssertTrue(accepted)
        }
        let illegal = await coordinator.transition(to: .waitingForReceiver, generation: generation)
        XCTAssertFalse(illegal)

        let stopGeneration = await coordinator.beginStopping()
        let oldGenerationAccepted = await coordinator.transition(to: .streaming, generation: generation)
        XCTAssertFalse(oldGenerationAccepted)
        let stopped = await coordinator.completeStopping(generation: stopGeneration)
        XCTAssertTrue(stopped)
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    func testStopCompletesFromEveryIntermediateState() async {
        let path: [SessionState] = [
            .waitingForReceiver,
            .creatingVirtualDisplay,
            .waitingForDisplayEnumeration,
            .stabilizingDisplayMode,
            .startingCapture,
            .startingEncoder,
            .streaming,
        ]
        for stopIndex in path.indices {
            let coordinator = SessionCoordinator()
            let generation = await coordinator.begin()
            for state in path.prefix(stopIndex + 1) {
                let accepted = await coordinator.transition(to: state, generation: generation)
                XCTAssertTrue(accepted)
            }
            let stopGeneration = await coordinator.beginStopping()
            let stopped = await coordinator.completeStopping(generation: stopGeneration)
            XCTAssertTrue(stopped)
            let finalState = await coordinator.state
            XCTAssertEqual(finalState, .idle)
        }
    }

    func testInputMappingUsesLogicalDisplayBoundsAndClamps() throws {
        let bounds = CGRect(x: -1280, y: 900, width: 1280, height: 800)
        XCTAssertEqual(
            try InputCoordinateMapper.project(normalizedX: 0.5, normalizedY: 0.25, displayBounds: bounds),
            CGPoint(x: -640, y: 1100)
        )
        XCTAssertEqual(
            try InputCoordinateMapper.project(normalizedX: 2, normalizedY: -1, displayBounds: bounds),
            CGPoint(x: 0, y: 900)
        )
        for origin in [
            CGPoint(x: -1280, y: 0), CGPoint(x: 1920, y: 0),
            CGPoint(x: 0, y: -800), CGPoint(x: 0, y: 1080),
        ] {
            let projected = try InputCoordinateMapper.project(
                normalizedX: 0.25,
                normalizedY: 0.75,
                displayBounds: CGRect(origin: origin, size: CGSize(width: 1280, height: 800))
            )
            XCTAssertEqual(projected, CGPoint(x: origin.x + 320, y: origin.y + 600))
        }
    }

    func testInputInjectorRejectsOldSessionAndSequenceAndReleasesMouseOnEnd() async throws {
        let poster = RecordingInputPoster()
        let injector = InputInjector(
            permission: FixedAccessibilityPermission(trusted: true),
            poster: poster,
            boundsProvider: { _ in CGRect(x: 100, y: -800, width: 1200, height: 800) }
        )
        await injector.begin(sessionID: "active", displayID: 42)
        try await injector.handle(InputEventMessage(
            sessionId: "old", sequence: 1, eventType: .leftDown,
            normalizedX: 0.5, normalizedY: 0.5
        ))
        try await injector.handle(InputEventMessage(
            sessionId: "active", sequence: 2, eventType: .leftDown,
            normalizedX: 0.5, normalizedY: 0.5
        ))
        try await injector.handle(InputEventMessage(
            sessionId: "active", sequence: 1, eventType: .drag,
            normalizedX: 1, normalizedY: 1
        ))
        await injector.end()

        let events = poster.events
        XCTAssertEqual(events.map(\.kind), [.leftDown, .leftUp])
        XCTAssertEqual(events[0].location, CGPoint(x: 700, y: -400))
        XCTAssertEqual(events[1].location, events[0].location)
    }

    func testMissingAccessibilityPermissionReturnsProjectError() async {
        let injector = InputInjector(
            permission: FixedAccessibilityPermission(trusted: false),
            poster: RecordingInputPoster(),
            boundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        await injector.begin(sessionID: "active", displayID: 1)
        do {
            try await injector.handle(InputEventMessage(
                sessionId: "active", sequence: 1, eventType: .move,
                normalizedX: 0.5, normalizedY: 0.5
            ))
            XCTFail("Expected input permission failure")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .inputPermissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testScrollPreservesPixelDeltasAndUsesCurrentLogicalPosition() async throws {
        let poster = RecordingInputPoster()
        let injector = InputInjector(
            permission: FixedAccessibilityPermission(trusted: true),
            poster: poster,
            boundsProvider: { _ in CGRect(x: 2000, y: 100, width: 1000, height: 600) }
        )
        await injector.begin(sessionID: "active", displayID: 7)
        try await injector.handle(InputEventMessage(
            sessionId: "active",
            sequence: 1,
            eventType: .scroll,
            normalizedX: 0.25,
            normalizedY: 0.75,
            deltaX: -8.5,
            deltaY: 14.25
        ))
        let event = try XCTUnwrap(poster.events.first)
        XCTAssertEqual(event.kind, .scroll)
        XCTAssertEqual(event.location, CGPoint(x: 2250, y: 550))
        XCTAssertEqual(event.deltaX, -8.5)
        XCTAssertEqual(event.deltaY, 14.25)
    }

    func testThreeFourAndFiveFingerGesturesFollowMacTrackpadMapping() async throws {
        let poster = RecordingInputPoster()
        let injector = InputInjector(
            permission: FixedAccessibilityPermission(trusted: true),
            poster: poster,
            boundsProvider: { _ in CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        await injector.begin(sessionID: "active", displayID: 1)
        let gestures: [(GestureType, GestureDirection)] = [
            (.swipe, .up),
            (.swipe, .down),
            (.swipe, .left),
            (.swipe, .right),
            (.pinch, .inward),
            (.pinch, .outward),
        ]
        var sequence: UInt64 = 0
        for fingerCount in 3...5 {
            for gesture in gestures {
                sequence += 1
                try await injector.handle(GestureEventMessage(
                    sessionId: "active",
                    sequence: sequence,
                    fingerCount: fingerCount,
                    gestureType: gesture.0,
                    direction: gesture.1,
                    magnitude: 0.25
                ))
            }
        }
        let navigation: [InjectedGestureAction] = [
            .shortcut(InjectedKeyboardShortcut(keyCode: 126, flags: .maskControl)),
            .shortcut(InjectedKeyboardShortcut(keyCode: 125, flags: .maskControl)),
            .shortcut(InjectedKeyboardShortcut(keyCode: 123, flags: .maskControl)),
            .shortcut(InjectedKeyboardShortcut(keyCode: 124, flags: .maskControl)),
        ]
        let apps = InjectedGestureAction.openApplication(bundleIdentifiers: [
            "com.apple.apps.launcher", "com.apple.launchpad.launcher",
        ])
        let desktop = InjectedGestureAction.shortcut(
            InjectedKeyboardShortcut(keyCode: 103, flags: .maskSecondaryFn)
        )
        let zoomActions: [InjectedGestureAction] = [
            .shortcut(InjectedKeyboardShortcut(keyCode: 27, flags: .maskCommand)),
            .shortcut(InjectedKeyboardShortcut(keyCode: 24, flags: .maskCommand)),
        ]
        var expectedActions = navigation
        expectedActions.append(contentsOf: zoomActions)
        expectedActions.append(contentsOf: navigation)
        expectedActions.append(contentsOf: [apps, desktop])
        expectedActions.append(contentsOf: navigation)
        expectedActions.append(contentsOf: [apps, desktop])
        XCTAssertEqual(poster.gestureActions, expectedActions)
    }

    func testKeyboardShortcutPlannerPostsRealModifierLifecycle() {
        let steps = KeyboardShortcutPlanner.steps(for: InjectedKeyboardShortcut(
            keyCode: 126,
            flags: .maskControl
        ))
        XCTAssertEqual(steps, [
            InjectedKeyboardStep(keyCode: 59, keyDown: true, flags: .maskControl),
            InjectedKeyboardStep(keyCode: 126, keyDown: true, flags: .maskControl),
            InjectedKeyboardStep(keyCode: 126, keyDown: false, flags: .maskControl),
            InjectedKeyboardStep(keyCode: 59, keyDown: false, flags: []),
        ])
    }

    func testScreenCaptureRequestOnlyOccursFromExplicitAction() {
        let authorization = RecordingScreenCaptureAuthorization()
        let controller = ScreenCapturePermissionController(authorization: authorization)
        XCTAssertFalse(controller.preflight())
        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertTrue(controller.requestFromUserAction())
        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertFalse(controller.requestFromUserAction())
        XCTAssertEqual(authorization.requestCount, 1)

        // 新应用进程会创建新控制器；ad-hoc 更新导致旧 TCC 条目失效时必须能重新注册。
        let relaunchedController = ScreenCapturePermissionController(authorization: authorization)
        XCTAssertTrue(relaunchedController.requestFromUserAction())
        XCTAssertEqual(authorization.requestCount, 2)
    }
}

private struct FixedAccessibilityPermission: AccessibilityPermissionChecking {
    let trusted: Bool
    func isTrusted() -> Bool { trusted }
}

private final class RecordingInputPoster: InputEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InjectedInputEvent] = []
    private var shortcutStorage: [InjectedKeyboardShortcut] = []
    private var gestureActionStorage: [InjectedGestureAction] = []
    var events: [InjectedInputEvent] { lock.withLock { storage } }
    var shortcuts: [InjectedKeyboardShortcut] { lock.withLock { shortcutStorage } }
    var gestureActions: [InjectedGestureAction] { lock.withLock { gestureActionStorage } }

    func post(_ event: InjectedInputEvent) {
        lock.withLock { storage.append(event) }
    }

    func post(_ shortcut: InjectedKeyboardShortcut) {
        lock.withLock { shortcutStorage.append(shortcut) }
    }

    func post(_ action: InjectedGestureAction) {
        lock.withLock { gestureActionStorage.append(action) }
    }
}

private final class RecordingScreenCaptureAuthorization: ScreenCaptureAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }

    func isAuthorized() -> Bool { false }
    func requestAuthorization() -> Bool {
        lock.withLock { requests += 1 }
        return true
    }
}
