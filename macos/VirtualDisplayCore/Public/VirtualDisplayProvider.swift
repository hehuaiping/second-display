import CoreGraphics
import Foundation
import PrivateAPIShim
import SecondDisplayCore

public struct VirtualDisplayHandle: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    public let identity: DisplayIdentity
    public let logicalSize: CGSize
    public let framebufferSize: CGSize

    fileprivate let providerToken: UUID

    public static func == (lhs: VirtualDisplayHandle, rhs: VirtualDisplayHandle) -> Bool {
        lhs.displayID == rhs.displayID
            && lhs.identity == rhs.identity
            && lhs.logicalSize == rhs.logicalSize
            && lhs.framebufferSize == rhs.framebufferSize
            && lhs.providerToken == rhs.providerToken
    }
}

@MainActor
public protocol VirtualDisplayProviding: AnyObject {
    func capabilityReport() -> VirtualDisplayCapabilityReport
    func create(spec: VirtualDisplaySpec) throws -> VirtualDisplayHandle
    func destroy(_ handle: VirtualDisplayHandle) async
}

public struct VirtualDisplayBackendDisplay: Sendable, Equatable {
    public let token: UUID
    public let displayID: CGDirectDisplayID

    public init(token: UUID, displayID: CGDirectDisplayID) {
        self.token = token
        self.displayID = displayID
    }
}

@MainActor
public protocol VirtualDisplayBackend: AnyObject {
    func create(
        spec: VirtualDisplaySpec,
        identity: DisplayIdentity,
        termination: @escaping @Sendable (CGDirectDisplayID) -> Void
    ) throws -> VirtualDisplayBackendDisplay

    func destroy(token: UUID)
}

public protocol DisplayOnlineChecking: Sendable {
    func isOnline(_ displayID: CGDirectDisplayID) -> Bool
}

public struct SystemDisplayOnlineChecker: DisplayOnlineChecking {
    public init() {}

    public func isOnline(_ displayID: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains(displayID)
    }
}

@MainActor
public final class CGVirtualDisplayProvider: VirtualDisplayProviding {
    private struct ManagedDisplay {
        let backendToken: UUID
        let handle: VirtualDisplayHandle
        let deviceId: UUID
    }

    private let capabilityProbe: VirtualDisplayCapabilityProbe
    private let backend: any VirtualDisplayBackend
    private let onlineChecker: any DisplayOnlineChecking
    private let identityGenerator: DisplayIdentityGenerator
    private let identityRegistry: DisplayIdentityRegistry
    private let compatibilityChecker: any MacCompatibilityChecking
    private var displaysByProviderToken: [UUID: ManagedDisplay] = [:]

    public init(
        capabilityProbe: VirtualDisplayCapabilityProbe = VirtualDisplayCapabilityProbe(),
        backend: (any VirtualDisplayBackend)? = nil,
        onlineChecker: any DisplayOnlineChecking = SystemDisplayOnlineChecker(),
        identityGenerator: DisplayIdentityGenerator = DisplayIdentityGenerator(),
        identityRegistry: DisplayIdentityRegistry = .shared,
        compatibilityChecker: any MacCompatibilityChecking = SystemMacCompatibilityChecker()
    ) {
        self.capabilityProbe = capabilityProbe
        self.backend = backend ?? SystemVirtualDisplayBackend()
        self.onlineChecker = onlineChecker
        self.identityGenerator = identityGenerator
        self.identityRegistry = identityRegistry
        self.compatibilityChecker = compatibilityChecker
    }

    public func capabilityReport() -> VirtualDisplayCapabilityReport {
        capabilityProbe.report()
    }

    public func create(spec: VirtualDisplaySpec) throws -> VirtualDisplayHandle {
        try compatibilityChecker.decision().requireCreationAllowed()
        try capabilityReport().requireSupport()
        let identity = identityGenerator.identity(deviceId: spec.deviceId, orientation: spec.orientation)
        try identityRegistry.claim(identity, deviceId: spec.deviceId)
        let backendDisplay: VirtualDisplayBackendDisplay
        do {
            backendDisplay = try backend.create(spec: spec, identity: identity) { [weak self] displayID in
                Task { @MainActor [weak self] in
                    self?.handleSystemTermination(displayID: displayID)
                }
            }
        } catch {
            identityRegistry.release(identity, deviceId: spec.deviceId)
            throw error
        }
        guard backendDisplay.displayID != kCGNullDirectDisplay,
            waitForInitialOnlineState(displayID: backendDisplay.displayID)
        else {
            backend.destroy(token: backendDisplay.token)
            identityRegistry.release(identity, deviceId: spec.deviceId)
            throw SessionError(code: .vdApplyFailed, detail: "Created display did not become online")
        }
        let providerToken = UUID()
        let handle = VirtualDisplayHandle(
            displayID: backendDisplay.displayID,
            identity: identity,
            logicalSize: spec.logicalSize,
            framebufferSize: spec.framebufferSize,
            providerToken: providerToken
        )
        displaysByProviderToken[providerToken] = ManagedDisplay(
            backendToken: backendDisplay.token,
            handle: handle,
            deviceId: spec.deviceId
        )
        return handle
    }

    public func destroy(_ handle: VirtualDisplayHandle) async {
        guard let display = displaysByProviderToken.removeValue(forKey: handle.providerToken) else { return }
        backend.destroy(token: display.backendToken)
        identityRegistry.release(display.handle.identity, deviceId: display.deviceId)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while onlineChecker.isOnline(display.handle.displayID), ContinuousClock.now < deadline {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    public func destroyAll() async {
        let handles = displaysByProviderToken.values.map(\.handle)
        for handle in handles {
            if Task.isCancelled { return }
            await destroy(handle)
        }
    }

    public var activeDisplayIDs: Set<CGDirectDisplayID> {
        Set(displaysByProviderToken.values.map(\.handle.displayID))
    }

    private func waitForInitialOnlineState(displayID: CGDirectDisplayID) -> Bool {
        if onlineChecker.isOnline(displayID) { return true }
        guard onlineChecker is SystemDisplayOnlineChecker else { return false }

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if onlineChecker.isOnline(displayID) { return true }
        }
        return false
    }

    private func handleSystemTermination(displayID: CGDirectDisplayID) {
        guard let entry = displaysByProviderToken.first(where: { $0.value.handle.displayID == displayID })
        else {
            return
        }
        displaysByProviderToken.removeValue(forKey: entry.key)
        backend.destroy(token: entry.value.backendToken)
        identityRegistry.release(entry.value.handle.identity, deviceId: entry.value.deviceId)
    }
}

@MainActor
public final class SystemVirtualDisplayBackend: VirtualDisplayBackend {
    fileprivate final class TerminationRelay: @unchecked Sendable {
        let handler: @Sendable (CGDirectDisplayID) -> Void

        init(handler: @escaping @Sendable (CGDirectDisplayID) -> Void) {
            self.handler = handler
        }
    }

    private struct Entry: @unchecked Sendable {
        let rawToken: UnsafeMutableRawPointer
        let relay: TerminationRelay
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    deinit {
        for entry in entries.values {
            SDVDDestroyDisplay(entry.rawToken)
        }
    }

    public func create(
        spec: VirtualDisplaySpec,
        identity: DisplayIdentity,
        termination: @escaping @Sendable (CGDirectDisplayID) -> Void
    ) throws -> VirtualDisplayBackendDisplay {
        let relay = TerminationRelay(handler: termination)
        let context = Unmanaged.passUnretained(relay).toOpaque()
        let result: SDVDCreateResult = spec.name.withCString { name in
            let configuration = SDVDCreateConfiguration(
                name: name,
                vendorID: identity.vendorId,
                productID: identity.productId,
                serialNumber: identity.serialNumber,
                framebufferWidth: UInt32(spec.framebufferWidth),
                framebufferHeight: UInt32(spec.framebufferHeight),
                logicalWidth: UInt32(spec.framebufferWidth / spec.scaleFactor),
                logicalHeight: UInt32(spec.framebufferHeight / spec.scaleFactor),
                physicalWidthMM: spec.physicalWidthMM,
                physicalHeightMM: spec.physicalHeightMM,
                refreshRate: spec.refreshRate
            )
            return SDVDCreateDisplay(configuration, systemTerminationCallback, context)
        }
        guard result.status.rawValue == SDVDCreateStatusSuccess.rawValue,
            let rawToken = result.token
        else {
            throw error(for: result.status)
        }
        let token = UUID()
        entries[token] = Entry(rawToken: rawToken, relay: relay)
        return VirtualDisplayBackendDisplay(token: token, displayID: result.displayID)
    }

    public func destroy(token: UUID) {
        guard let entry = entries.removeValue(forKey: token) else { return }
        SDVDDestroyDisplay(entry.rawToken)
        _ = entry.relay
    }

    private func error(for status: SDVDCreateStatus) -> SessionError {
        switch status.rawValue {
        case SDVDCreateStatusCapabilityMissing.rawValue:
            return SessionError(
                code: .vdCapabilityMissing, detail: "Runtime capability disappeared before create")
        case SDVDCreateStatusApplyFailed.rawValue:
            return SessionError(code: .vdApplyFailed, detail: "Virtual display settings were rejected")
        case SDVDCreateStatusInvalidArgument.rawValue:
            return SessionError(code: .vdApplyFailed, detail: "Invalid virtual display configuration")
        default:
            return SessionError(code: .vdApplyFailed, detail: "Unable to allocate virtual display objects")
        }
    }
}

private func systemTerminationCallback(
    _ displayID: CGDirectDisplayID,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let relay = Unmanaged<SystemVirtualDisplayBackend.TerminationRelay>
        .fromOpaque(context)
        .takeUnretainedValue()
    relay.handler(displayID)
}
