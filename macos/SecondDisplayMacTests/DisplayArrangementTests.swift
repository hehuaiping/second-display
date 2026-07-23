import CoreGraphics
import Foundation
import VirtualDisplayCore
import XCTest

@MainActor
final class DisplayArrangementTests: XCTestCase {
    func testReconnectRestoresSavedLeftSideOrigin() throws {
        let deviceId = UUID()
        let store = MemoryOriginStore()
        let controller = FakeOriginController(bounds: CGRect(x: -1280, y: 0, width: 1280, height: 800))
        let manager = DisplayArrangementManager(store: store, controller: controller)
        let saved = try manager.saveActualOrigin(
            displayID: 7,
            deviceId: deviceId,
            orientation: .landscape
        )
        XCTAssertEqual(saved.originX, -1280)

        controller.currentBounds = CGRect(x: 1728, y: 0, width: 1280, height: 800)
        let restored = try manager.restoreOrigin(
            displayID: 7,
            deviceId: deviceId,
            orientation: .landscape,
            newLogicalSize: CGSize(width: 1280, height: 800)
        )
        XCTAssertEqual(controller.requestedOrigins.last, CGPoint(x: -1280, y: 0))
        XCTAssertEqual(restored?.originX, -1280)
    }

    func testSystemSnappedActualOriginOverwritesRequestedValue() throws {
        let deviceId = UUID()
        let store = MemoryOriginStore()
        let controller = FakeOriginController(bounds: CGRect(x: 1728, y: 0, width: 1280, height: 800))
        controller.snappedOrigin = CGPoint(x: 1800, y: 0)
        let manager = DisplayArrangementManager(store: store, controller: controller)
        try store.save(
            DisplayOriginRecord(
                deviceId: deviceId,
                orientation: .landscape,
                logicalWidth: 1280,
                logicalHeight: 800,
                originX: 1728,
                originY: 0
            )
        )
        let actual = try manager.restoreOrigin(
            displayID: 7,
            deviceId: deviceId,
            orientation: .landscape,
            newLogicalSize: CGSize(width: 1280, height: 800)
        )
        XCTAssertEqual(actual?.originX, 1800)
        XCTAssertEqual(store.record(deviceId: deviceId, orientation: .landscape)?.originX, 1800)
    }

    func testResolutionChangePreservesCenterBeforeSystemSnap() throws {
        let deviceId = UUID()
        let store = MemoryOriginStore()
        let controller = FakeOriginController(bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let manager = DisplayArrangementManager(store: store, controller: controller)
        try store.save(
            DisplayOriginRecord(
                deviceId: deviceId,
                orientation: .portrait,
                logicalWidth: 800,
                logicalHeight: 1280,
                originX: -800,
                originY: -240
            )
        )
        _ = try manager.restoreOrigin(
            displayID: 7,
            deviceId: deviceId,
            orientation: .portrait,
            newLogicalSize: CGSize(width: 1000, height: 1600)
        )
        XCTAssertEqual(controller.requestedOrigins.last, CGPoint(x: -900, y: -400))
    }

    func testRecordsAreIsolatedByDeviceAndOrientation() throws {
        let first = UUID()
        let second = UUID()
        let store = MemoryOriginStore()
        try store.save(
            DisplayOriginRecord(
                deviceId: first,
                orientation: .landscape,
                logicalWidth: 1280,
                logicalHeight: 800,
                originX: 1,
                originY: 2
            )
        )
        try store.save(
            DisplayOriginRecord(
                deviceId: second,
                orientation: .portrait,
                logicalWidth: 800,
                logicalHeight: 1280,
                originX: 3,
                originY: 4
            )
        )
        XCTAssertEqual(store.record(deviceId: first, orientation: .landscape)?.originX, 1)
        XCTAssertNil(store.record(deviceId: first, orientation: .portrait))
        XCTAssertEqual(store.record(deviceId: second, orientation: .portrait)?.originX, 3)
    }
}

@MainActor
private final class MemoryOriginStore: DisplayOriginStoring {
    private var values: [String: DisplayOriginRecord] = [:]

    func record(deviceId: UUID, orientation: VirtualDisplayOrientation) -> DisplayOriginRecord? {
        values[key(deviceId, orientation)]
    }

    func save(_ record: DisplayOriginRecord) throws {
        values[key(record.deviceId, record.orientation)] = record
    }

    private func key(_ deviceId: UUID, _ orientation: VirtualDisplayOrientation) -> String {
        "\(deviceId.uuidString)|\(orientation.rawValue)"
    }
}

@MainActor
private final class FakeOriginController: DisplayOriginControlling {
    var currentBounds: CGRect
    var requestedOrigins: [CGPoint] = []
    var snappedOrigin: CGPoint?

    init(bounds: CGRect) {
        self.currentBounds = bounds
    }

    func bounds(displayID: CGDirectDisplayID) -> CGRect { currentBounds }

    func applyOrigin(displayID: CGDirectDisplayID, origin: CGPoint) -> CGError {
        requestedOrigins.append(origin)
        currentBounds.origin = snappedOrigin ?? origin
        return .success
    }
}

