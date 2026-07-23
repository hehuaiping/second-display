import CoreGraphics
import Foundation
import SecondDisplayCore

public enum DisplayReconfigurationKind: String, Sendable, Equatable {
    case added
    case removed
    case modeChanged
    case moved
    case other
}

public struct DisplayReconfigurationEvent: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    public let flags: UInt32
    public let kinds: Set<DisplayReconfigurationKind>
    public let generation: UInt64

    public init(
        displayID: CGDirectDisplayID,
        flags: UInt32,
        kinds: Set<DisplayReconfigurationKind>,
        generation: UInt64
    ) {
        self.displayID = displayID
        self.flags = flags
        self.kinds = kinds
        self.generation = generation
    }

    public func belongs(to currentGeneration: UInt64) -> Bool {
        generation == currentGeneration
    }
}

public protocol DisplayReconfigurationRegistering: Sendable {
    func register(
        _ handler: @escaping @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void
    ) throws -> UInt

    func unregister(token: UInt)
}

public final class DisplayReconfigurationObserver: @unchecked Sendable {
    public let events: AsyncStream<DisplayReconfigurationEvent>

    private let registrar: any DisplayReconfigurationRegistering
    private let generation: UInt64
    private let continuation: AsyncStream<DisplayReconfigurationEvent>.Continuation
    private let lock = NSLock()
    private var registrationToken: UInt?

    public init(
        generation: UInt64,
        registrar: any DisplayReconfigurationRegistering = SystemDisplayReconfigurationRegistrar.shared
    ) throws {
        self.generation = generation
        self.registrar = registrar
        let pair = AsyncStream<DisplayReconfigurationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.events = pair.stream
        self.continuation = pair.continuation
        let token = try registrar.register { [continuation = pair.continuation] displayID, flags in
            continuation.yield(
                DisplayReconfigurationEvent(
                    displayID: displayID,
                    flags: flags.rawValue,
                    kinds: Self.kinds(for: flags),
                    generation: generation
                )
            )
        }
        self.registrationToken = token
    }

    deinit {
        stop()
    }

    public func stop() {
        let token: UInt? = lock.withLock {
            defer { registrationToken = nil }
            return registrationToken
        }
        guard let token else { return }
        registrar.unregister(token: token)
        continuation.finish()
    }

    private static func kinds(for flags: CGDisplayChangeSummaryFlags) -> Set<DisplayReconfigurationKind> {
        var result = Set<DisplayReconfigurationKind>()
        if flags.contains(.addFlag) { result.insert(.added) }
        if flags.contains(.removeFlag) { result.insert(.removed) }
        if flags.contains(.setModeFlag) { result.insert(.modeChanged) }
        if flags.contains(.movedFlag) { result.insert(.moved) }
        if result.isEmpty { result.insert(.other) }
        return result
    }
}

public final class SystemDisplayReconfigurationRegistrar: DisplayReconfigurationRegistering, @unchecked Sendable {
    public static let shared = SystemDisplayReconfigurationRegistrar()

    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void

        init(handler: @escaping @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void) {
            self.handler = handler
        }
    }

    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var callbacks: [UInt: CallbackBox] = [:]

    private init() {}

    public func register(
        _ handler: @escaping @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void
    ) throws -> UInt {
        let token: UInt = lock.withLock {
            let value = nextToken
            nextToken = nextToken == UInt.max ? 1 : nextToken + 1
            callbacks[value] = CallbackBox(handler: handler)
            return value
        }
        guard let context = UnsafeMutableRawPointer(bitPattern: token) else {
            removeCallback(token: token)
            throw SessionError(code: .vdApplyFailed, detail: "Unable to allocate display observer token")
        }
        let error = CGDisplayRegisterReconfigurationCallback(systemDisplayReconfigurationCallback, context)
        guard error == .success else {
            removeCallback(token: token)
            throw SessionError(code: .vdApplyFailed, detail: "Unable to register display observer")
        }
        return token
    }

    public func unregister(token: UInt) {
        removeCallback(token: token)
        guard let context = UnsafeMutableRawPointer(bitPattern: token) else { return }
        CGDisplayRemoveReconfigurationCallback(systemDisplayReconfigurationCallback, context)
    }

    fileprivate func dispatch(
        token: UInt,
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        let callback = lock.withLock { callbacks[token] }
        callback?.handler(displayID, flags)
    }

    private func removeCallback(token: UInt) {
        _ = lock.withLock {
            callbacks.removeValue(forKey: token)
        }
    }
}

private func systemDisplayReconfigurationCallback(
    _ displayID: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    SystemDisplayReconfigurationRegistrar.shared.dispatch(
        token: UInt(bitPattern: context),
        displayID: displayID,
        flags: flags
    )
}
