import CoreGraphics
import Foundation
import SecondDisplayCore
import VirtualDisplayCore
import XCTest

@MainActor
final class VirtualDisplayProviderTests: XCTestCase {
    func testProviderCreatesOpaqueHandleAndDestroysIdempotently() async throws {
        let backend = FakeDisplayBackend(displayID: 91)
        let onlineChecker = FakeOnlineChecker(onlineDisplayIDs: [91])
        let provider = CGVirtualDisplayProvider(
            capabilityProbe: supportedProbe(),
            backend: backend,
            onlineChecker: onlineChecker
        )
        let handle = try provider.create(spec: makeSpec())
        XCTAssertEqual(handle.displayID, 91)
        XCTAssertEqual(provider.activeDisplayIDs, [91])
        onlineChecker.onlineDisplayIDs.remove(91)
        await provider.destroy(handle)
        await provider.destroy(handle)
        XCTAssertEqual(backend.destroyCount, 1)
        XCTAssertTrue(provider.activeDisplayIDs.isEmpty)
    }

    func testBackendFailureLeavesNoManagedDisplay() throws {
        let backend = FakeDisplayBackend(displayID: 91)
        backend.createError = SessionError(code: .vdApplyFailed, detail: "fake apply failure")
        let provider = CGVirtualDisplayProvider(
            capabilityProbe: supportedProbe(),
            backend: backend,
            onlineChecker: FakeOnlineChecker(onlineDisplayIDs: [])
        )
        XCTAssertThrowsError(try provider.create(spec: makeSpec())) { error in
            XCTAssertEqual((error as? SessionError)?.code, .vdApplyFailed)
        }
        XCTAssertTrue(provider.activeDisplayIDs.isEmpty)
        XCTAssertEqual(backend.destroyCount, 0)
    }

    func testOfflineResultIsDestroyedBeforeErrorReturns() throws {
        let backend = FakeDisplayBackend(displayID: 91)
        let provider = CGVirtualDisplayProvider(
            capabilityProbe: supportedProbe(),
            backend: backend,
            onlineChecker: FakeOnlineChecker(onlineDisplayIDs: [])
        )
        XCTAssertThrowsError(try provider.create(spec: makeSpec())) { error in
            XCTAssertEqual((error as? SessionError)?.code, .vdApplyFailed)
        }
        XCTAssertEqual(backend.destroyCount, 1)
        XCTAssertTrue(provider.activeDisplayIDs.isEmpty)
    }

    func testBlockedCompatibilityBuildNeverEntersBackendCreatePath() throws {
        let backend = FakeDisplayBackend(displayID: 91)
        let provider = CGVirtualDisplayProvider(
            capabilityProbe: supportedProbe(),
            backend: backend,
            onlineChecker: FakeOnlineChecker(onlineDisplayIDs: [91]),
            compatibilityChecker: FixedCompatibilityChecker(status: .blocked)
        )
        XCTAssertThrowsError(try provider.create(spec: makeSpec())) { error in
            XCTAssertEqual((error as? SessionError)?.code, .vdCapabilityMissing)
        }
        XCTAssertEqual(backend.createCount, 0)
    }

    func testUnknownCompatibilityBuildRemainsExperimental() {
        let manifest = MacCompatibilityManifest(
            entries: [
                .init(osBuild: "known", status: .supported, reason: "verified")
            ])
        XCTAssertEqual(manifest.decision(for: "new-beta").status, .experimental)
    }

    func testDefaultRegistryCoordinatesMultipleProvidersAndSerialCollisions() async throws {
        let firstBackend = FakeDisplayBackend(displayID: 101)
        let secondBackend = FakeDisplayBackend(displayID: 102)
        let firstOnline = FakeOnlineChecker(onlineDisplayIDs: [101])
        let secondOnline = FakeOnlineChecker(onlineDisplayIDs: [102])
        let firstProvider = CGVirtualDisplayProvider(
            capabilityProbe: supportedProbe(),
            backend: firstBackend,
            onlineChecker: firstOnline
        )
        let secondProvider = CGVirtualDisplayProvider(
            capabilityProbe: supportedProbe(),
            backend: secondBackend,
            onlineChecker: secondOnline
        )
        let firstDevice = UUID()
        let firstSpec = try VirtualDisplaySpec(
            name: "First",
            deviceId: firstDevice,
            orientation: .landscape
        )
        let firstHandle = try firstProvider.create(spec: firstSpec)
        XCTAssertThrowsError(try secondProvider.create(spec: firstSpec)) { error in
            XCTAssertEqual((error as? SessionError)?.code, .vdApplyFailed)
        }

        let secondSpec = try VirtualDisplaySpec(
            name: "Second",
            deviceId: UUID(),
            orientation: .landscape
        )
        let secondHandle = try secondProvider.create(spec: secondSpec)
        XCTAssertNotEqual(firstHandle.identity.serialNumber, secondHandle.identity.serialNumber)
        firstOnline.onlineDisplayIDs.remove(101)
        secondOnline.onlineDisplayIDs.remove(102)
        await firstProvider.destroy(firstHandle)
        await secondProvider.destroy(secondHandle)

        secondOnline.onlineDisplayIDs.insert(102)
        let reused = try secondProvider.create(spec: firstSpec)
        secondOnline.onlineDisplayIDs.remove(102)
        await secondProvider.destroy(reused)
    }

    func testRealDisplayCreateDestroyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_VIRTUAL_DISPLAY_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_VIRTUAL_DISPLAY_INTEGRATION=1 for the real display diagnostic")
        }
        let cycles = Int(ProcessInfo.processInfo.environment["VD_CYCLES"] ?? "1") ?? 1
        let provider = CGVirtualDisplayProvider()
        let integrationDeviceId = UUID()
        for cycle in 0..<cycles {
            let spec = try VirtualDisplaySpec(
                name: "Second Display Integration \(cycle)",
                deviceId: integrationDeviceId,
                orientation: .landscape
            )
            let handle = try provider.create(spec: spec)
            XCTAssertNotEqual(handle.displayID, kCGNullDirectDisplay)
            XCTAssertEqual(CGDisplayIsInMirrorSet(handle.displayID), 0)
            XCTAssertGreaterThan(CGDisplayBounds(handle.displayID).width, 0)
            let shouldValidateMode =
                cycles == 1
                || ProcessInfo.processInfo.environment["VD_VALIDATE_MODE_EACH_CYCLE"] == "1"
            if ProcessInfo.processInfo.environment["VD_DUMP_MODES"] == "1" {
                print(
                    "DISPLAY_MODES",
                    CoreGraphicsDisplayModeController().availableModes(displayID: handle.displayID))
                print(
                    "CURRENT_MODE",
                    String(
                        describing: CoreGraphicsDisplayModeController().currentMode(
                            displayID: handle.displayID)))
            }
            if shouldValidateMode {
                do {
                    try await DisplayModeMaintainer().waitUntilStable(
                        displayID: handle.displayID,
                        logicalSize: handle.logicalSize,
                        generation: UInt64(cycle),
                        timeout: .seconds(8),
                        isCurrentGeneration: { $0 == UInt64(cycle) }
                    )
                } catch {
                    print("FAILED_CYCLE", cycle)
                    print("FAILED_DISPLAY_ID", handle.displayID)
                    print("FAILED_BOUNDS", CGDisplayBounds(handle.displayID))
                    print(
                        "FAILED_MODES",
                        CoreGraphicsDisplayModeController().availableModes(displayID: handle.displayID))
                    print(
                        "FAILED_CURRENT",
                        String(
                            describing: CoreGraphicsDisplayModeController().currentMode(
                                displayID: handle.displayID)))
                    await provider.destroy(handle)
                    throw error
                }
            }
            await provider.destroy(handle)
            XCTAssertFalse(SystemDisplayOnlineChecker().isOnline(handle.displayID))
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testRealOriginPersistenceWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_VIRTUAL_DISPLAY_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_VIRTUAL_DISPLAY_INTEGRATION=1 for the real display diagnostic")
        }
        let provider = CGVirtualDisplayProvider()
        let deviceId = UUID()
        let spec = try VirtualDisplaySpec(
            name: "Second Display Arrangement Integration",
            deviceId: deviceId,
            orientation: .landscape
        )
        let store = IntegrationOriginStore()
        let controller = CoreGraphicsDisplayOriginController()
        let manager = DisplayArrangementManager(store: store, controller: controller)
        let first = try provider.create(spec: spec)
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let requested = CGPoint(x: mainBounds.minX - first.logicalSize.width, y: mainBounds.minY)
        XCTAssertEqual(controller.applyOrigin(displayID: first.displayID, origin: requested), .success)
        let saved = try manager.saveActualOrigin(
            displayID: first.displayID,
            deviceId: deviceId,
            orientation: .landscape
        )
        XCTAssertLessThanOrEqual(saved.originX, mainBounds.minX)
        await provider.destroy(first)
        try await Task.sleep(for: .milliseconds(500))

        let second = try provider.create(spec: spec)
        let restored = try manager.restoreOrigin(
            displayID: second.displayID,
            deviceId: deviceId,
            orientation: .landscape,
            newLogicalSize: second.logicalSize
        )
        XCTAssertEqual(restored?.originX ?? .infinity, saved.originX, accuracy: 1)
        XCTAssertEqual(restored?.originY ?? .infinity, saved.originY, accuracy: 1)
        await provider.destroy(second)
    }

    private func makeSpec() throws -> VirtualDisplaySpec {
        try VirtualDisplaySpec(name: "Fake", deviceId: UUID(), orientation: .landscape)
    }

    private func supportedProbe() -> VirtualDisplayCapabilityProbe {
        VirtualDisplayCapabilityProbe(checker: AlwaysSupportedRuntimeChecker())
    }
}

private struct AlwaysSupportedRuntimeChecker: VirtualDisplayRuntimeChecking {
    func hasClass(_ role: VirtualDisplayPrivateClassRole) -> Bool { true }
    func hasSelector(_ role: VirtualDisplayPrivateSelectorRole) -> Bool { true }
}

@MainActor
private final class FakeDisplayBackend: VirtualDisplayBackend {
    let displayID: CGDirectDisplayID
    var createError: SessionError?
    var destroyCount = 0
    var createCount = 0
    var onlineDisplayIDs: Set<CGDirectDisplayID> = []

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func create(
        spec: VirtualDisplaySpec,
        identity: DisplayIdentity,
        termination: @escaping @Sendable (CGDirectDisplayID) -> Void
    ) throws -> VirtualDisplayBackendDisplay {
        createCount += 1
        if let createError { throw createError }
        onlineDisplayIDs.insert(displayID)
        return VirtualDisplayBackendDisplay(token: UUID(), displayID: displayID)
    }

    func destroy(token: UUID) {
        destroyCount += 1
        onlineDisplayIDs.remove(displayID)
    }
}

private struct FixedCompatibilityChecker: MacCompatibilityChecking {
    let status: MacCompatibilityStatus

    func decision() -> MacCompatibilityDecision {
        MacCompatibilityDecision(osBuild: "test", status: status, reason: "test policy")
    }
}

private final class FakeOnlineChecker: DisplayOnlineChecking, @unchecked Sendable {
    var onlineDisplayIDs: Set<CGDirectDisplayID>

    init(onlineDisplayIDs: Set<CGDirectDisplayID>) {
        self.onlineDisplayIDs = onlineDisplayIDs
    }

    func isOnline(_ displayID: CGDirectDisplayID) -> Bool {
        onlineDisplayIDs.contains(displayID)
    }
}

@MainActor
private final class IntegrationOriginStore: DisplayOriginStoring {
    private var value: DisplayOriginRecord?

    func record(deviceId: UUID, orientation: VirtualDisplayOrientation) -> DisplayOriginRecord? {
        guard value?.deviceId == deviceId, value?.orientation == orientation else { return nil }
        return value
    }

    func save(_ record: DisplayOriginRecord) throws {
        value = record
    }
}
