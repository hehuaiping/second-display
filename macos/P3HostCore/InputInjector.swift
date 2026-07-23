import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import SecondDisplayCore
import SharedProtocol

struct InjectedInputEvent: Equatable, Sendable {
    let kind: InputEventKind
    let location: CGPoint
    let deltaX: Double
    let deltaY: Double
}

struct InjectedKeyboardShortcut: Equatable, Sendable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

struct InjectedKeyboardStep: Equatable, Sendable {
    let keyCode: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

enum KeyboardShortcutPlanner {
    static func steps(for shortcut: InjectedKeyboardShortcut) -> [InjectedKeyboardStep] {
        let supportedModifiers: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
            (.maskShift, 56),
            (.maskControl, 59),
            (.maskAlternate, 58),
            (.maskCommand, 55),
            (.maskSecondaryFn, 63),
        ]
        let modifiers = supportedModifiers.filter { shortcut.flags.contains($0.flag) }
        var activeFlags: CGEventFlags = []
        var result: [InjectedKeyboardStep] = []
        for modifier in modifiers {
            activeFlags.formUnion(modifier.flag)
            result.append(InjectedKeyboardStep(
                keyCode: modifier.keyCode,
                keyDown: true,
                flags: activeFlags
            ))
        }
        result.append(InjectedKeyboardStep(
            keyCode: shortcut.keyCode,
            keyDown: true,
            flags: shortcut.flags
        ))
        result.append(InjectedKeyboardStep(
            keyCode: shortcut.keyCode,
            keyDown: false,
            flags: shortcut.flags
        ))
        for modifier in modifiers.reversed() {
            activeFlags.subtract(modifier.flag)
            result.append(InjectedKeyboardStep(
                keyCode: modifier.keyCode,
                keyDown: false,
                flags: activeFlags
            ))
        }
        return result
    }
}

enum InjectedGestureAction: Equatable, Sendable {
    case shortcut(InjectedKeyboardShortcut)
    case openApplication(bundleIdentifiers: [String])
}

protocol InputEventPosting: Sendable {
    func post(_ event: InjectedInputEvent) throws
    func post(_ shortcut: InjectedKeyboardShortcut) throws
    func post(_ action: InjectedGestureAction) throws
}

struct SystemInputEventPoster: InputEventPosting {
    func post(_ event: InjectedInputEvent) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SessionError(code: .inputPermissionDenied, detail: "Unable to create HID event source")
        }
        let created: CGEvent?
        switch event.kind {
        case .move:
            created = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: event.location, mouseButton: .left)
        case .leftDown:
            created = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: event.location, mouseButton: .left)
        case .leftUp:
            created = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: event.location, mouseButton: .left)
        case .drag:
            created = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: event.location, mouseButton: .left)
        case .scroll:
            created = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(event.deltaY.rounded())),
                wheel2: Int32(clamping: Int(event.deltaX.rounded())),
                wheel3: 0
            )
        }
        guard let created else {
            throw SessionError(code: .inputPermissionDenied, detail: "Unable to create input event")
        }
        created.post(tap: .cghidEventTap)
    }

    func post(_ shortcut: InjectedKeyboardShortcut) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SessionError(code: .inputPermissionDenied, detail: "Unable to create keyboard event")
        }
        let events = try KeyboardShortcutPlanner.steps(for: shortcut).map { step in
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: step.keyCode,
                keyDown: step.keyDown
            ) else {
                throw SessionError(
                    code: .inputPermissionDenied,
                    detail: "Unable to create keyboard chord event"
                )
            }
            event.flags = step.flags
            return event
        }
        events.forEach { $0.post(tap: .cghidEventTap) }
    }

    func post(_ action: InjectedGestureAction) throws {
        switch action {
        case .shortcut(let shortcut):
            try post(shortcut)
        case .openApplication(let bundleIdentifiers):
            guard let applicationURL = bundleIdentifiers.lazy.compactMap({ identifier in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            }).first,
                NSWorkspace.shared.open(applicationURL)
            else {
                throw SessionError(
                    code: .inputPermissionDenied,
                    detail: "Unable to invoke the macOS Apps gesture action"
                )
            }
        }
    }
}

protocol AccessibilityPermissionChecking: Sendable {
    func isTrusted() -> Bool
}

struct SystemAccessibilityPermissionChecker: AccessibilityPermissionChecking {
    func isTrusted() -> Bool { AXIsProcessTrusted() }
}

public enum InputCoordinateMapper {
    public static func project(normalizedX: Double, normalizedY: Double, displayBounds: CGRect) throws -> CGPoint {
        guard normalizedX.isFinite, normalizedY.isFinite, !displayBounds.isEmpty else {
            throw SessionError(code: .netProtocolMismatch, detail: "Input coordinates are invalid")
        }
        let x = min(max(normalizedX, 0), 1)
        let y = min(max(normalizedY, 0), 1)
        return CGPoint(
            x: displayBounds.origin.x + x * displayBounds.width,
            y: displayBounds.origin.y + y * displayBounds.height
        )
    }
}

actor InputInjector {
    private let permission: any AccessibilityPermissionChecking
    private let poster: any InputEventPosting
    private let boundsProvider: @Sendable (CGDirectDisplayID) -> CGRect
    private var sessionID: String?
    private var displayID: CGDirectDisplayID?
    private var lastSequence: UInt64?
    private var lastLocation = CGPoint.zero
    private var leftButtonDown = false

    init(
        permission: any AccessibilityPermissionChecking = SystemAccessibilityPermissionChecker(),
        poster: any InputEventPosting = SystemInputEventPoster(),
        boundsProvider: @escaping @Sendable (CGDirectDisplayID) -> CGRect = CGDisplayBounds
    ) {
        self.permission = permission
        self.poster = poster
        self.boundsProvider = boundsProvider
    }

    func begin(sessionID: String, displayID: CGDirectDisplayID) {
        self.sessionID = sessionID
        self.displayID = displayID
        lastSequence = nil
        lastLocation = CGPoint(x: boundsProvider(displayID).midX, y: boundsProvider(displayID).midY)
        leftButtonDown = false
    }

    func handle(_ message: InputEventMessage) throws {
        guard message.sessionId == sessionID, let displayID else { return }
        if let lastSequence, message.sequence <= lastSequence { return }
        guard permission.isTrusted() else {
            throw SessionError(code: .inputPermissionDenied, detail: "Accessibility permission is required")
        }
        let needsLocation = message.eventType != .scroll
        if needsLocation || (message.normalizedX != nil && message.normalizedY != nil) {
            guard let x = message.normalizedX, let y = message.normalizedY else {
                throw SessionError(code: .netProtocolMismatch, detail: "Pointer event has no coordinates")
            }
            lastLocation = try InputCoordinateMapper.project(
                normalizedX: x,
                normalizedY: y,
                displayBounds: boundsProvider(displayID)
            )
        }
        try poster.post(InjectedInputEvent(
            kind: message.eventType,
            location: lastLocation,
            deltaX: message.deltaX,
            deltaY: message.deltaY
        ))
        lastSequence = message.sequence
        if message.eventType == .leftDown { leftButtonDown = true }
        if message.eventType == .leftUp { leftButtonDown = false }
    }

    func handle(_ message: GestureEventMessage) throws {
        guard message.sessionId == sessionID else { return }
        if let lastSequence, message.sequence <= lastSequence { return }
        guard permission.isTrusted() else {
            throw SessionError(code: .inputPermissionDenied, detail: "Accessibility permission is required")
        }
        guard (3...5).contains(message.fingerCount), message.magnitude.isFinite,
            message.magnitude >= 0
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Gesture event is invalid")
        }
        let action: InjectedGestureAction
        switch (message.gestureType, message.direction) {
        case (.swipe, .up):
            action = .shortcut(InjectedKeyboardShortcut(keyCode: 126, flags: .maskControl))
        case (.swipe, .down):
            action = .shortcut(InjectedKeyboardShortcut(keyCode: 125, flags: .maskControl))
        case (.swipe, .left):
            action = .shortcut(InjectedKeyboardShortcut(keyCode: 123, flags: .maskControl))
        case (.swipe, .right):
            action = .shortcut(InjectedKeyboardShortcut(keyCode: 124, flags: .maskControl))
        case (.pinch, .inward) where message.fingerCount == 3:
            action = .shortcut(InjectedKeyboardShortcut(keyCode: 27, flags: .maskCommand))
        case (.pinch, .outward) where message.fingerCount == 3:
            action = .shortcut(InjectedKeyboardShortcut(keyCode: 24, flags: .maskCommand))
        case (.pinch, .inward):
            action = .openApplication(bundleIdentifiers: [
                "com.apple.apps.launcher",
                "com.apple.launchpad.launcher",
            ])
        case (.pinch, .outward):
            action = .shortcut(InjectedKeyboardShortcut(keyCode: 103, flags: .maskSecondaryFn))
        default:
            throw SessionError(code: .netProtocolMismatch, detail: "Gesture direction does not match its type")
        }
        try poster.post(action)
        lastSequence = message.sequence
    }

    func end() {
        defer {
            sessionID = nil
            displayID = nil
            lastSequence = nil
            leftButtonDown = false
        }
        guard leftButtonDown, permission.isTrusted() else { return }
        try? poster.post(InjectedInputEvent(
            kind: .leftUp,
            location: lastLocation,
            deltaX: 0,
            deltaY: 0
        ))
    }
}
