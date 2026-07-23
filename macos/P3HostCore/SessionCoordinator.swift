import Foundation
import SecondDisplayCore

public enum ReconfigureReason: String, Equatable, Sendable {
    case displayModeChanged
    case surfaceChanged
    case orientationChanged
}

public enum SessionState: Equatable, Sendable {
    case idle
    case checkingCapability
    case waitingForReceiver
    case creatingVirtualDisplay
    case waitingForDisplayEnumeration
    case stabilizingDisplayMode
    case startingCapture
    case startingEncoder
    case streaming
    case reconfiguring(reason: ReconfigureReason)
    case recovering(attempt: Int)
    case stopping
    case failed(SessionError)
}

public actor SessionCoordinator {
    public private(set) var state: SessionState = .idle
    public private(set) var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public func begin() -> UInt64 {
        // 每次启动生成新的代次，所有异步回调都必须携带并校验这个值。
        generation &+= 1
        state = .checkingCapability
        return generation
    }

    @discardableResult
    public func transition(to next: SessionState, generation candidate: UInt64) -> Bool {
        guard candidate == generation, Self.allows(from: state, to: next) else { return false }
        state = next
        return true
    }

    @discardableResult
    public func fail(_ error: SessionError, generation candidate: UInt64) -> Bool {
        guard candidate == generation, state != .idle, state != .stopping else { return false }
        state = .failed(error)
        return true
    }

    public func beginStopping() -> UInt64 {
        // 停止时先使旧 generation 失效，再进入资源回收，杜绝迟到回调把状态改回 streaming。
        generation &+= 1
        state = .stopping
        return generation
    }

    @discardableResult
    public func completeStopping(generation candidate: UInt64) -> Bool {
        guard candidate == generation, state == .stopping else { return false }
        state = .idle
        return true
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation && state != .idle && state != .stopping
    }

    public static func allows(from: SessionState, to: SessionState) -> Bool {
        if case .failed = to { return from != .idle && from != .stopping }
        if to == .stopping { return from != .idle && from != .stopping }
        switch (from, to) {
        case (.idle, .checkingCapability),
            (.checkingCapability, .waitingForReceiver),
            (.waitingForReceiver, .creatingVirtualDisplay),
            (.creatingVirtualDisplay, .waitingForDisplayEnumeration),
            (.waitingForDisplayEnumeration, .stabilizingDisplayMode),
            (.stabilizingDisplayMode, .startingCapture),
            (.startingCapture, .startingEncoder),
            (.startingEncoder, .streaming),
            (.streaming, .reconfiguring),
            (.reconfiguring, .streaming),
            (.streaming, .recovering),
            (.creatingVirtualDisplay, .recovering),
            (.waitingForDisplayEnumeration, .recovering),
            (.stabilizingDisplayMode, .recovering),
            (.startingCapture, .recovering),
            (.startingEncoder, .recovering),
            (.recovering, .waitingForReceiver),
            (.recovering, .waitingForDisplayEnumeration),
            (.stopping, .idle),
            (.failed, .checkingCapability):
            return true
        default:
            return false
        }
    }
}
