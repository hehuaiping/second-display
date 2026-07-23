import Foundation
import SecondDisplayCore
import VirtualDisplayCore
import XCTest

final class VirtualDisplaySpecTests: XCTestCase {
    func testIdentityIsStableAndOrientationIsolated() {
        let deviceId = UUID(uuidString: "a3a6d287-fabc-4f6b-b019-112233445566")
        guard let deviceId else {
            XCTFail("Fixture UUID is invalid")
            return
        }
        let generator = DisplayIdentityGenerator()
        let first = generator.identity(deviceId: deviceId, orientation: .landscape)
        let second = generator.identity(deviceId: deviceId, orientation: .landscape)
        let portrait = generator.identity(deviceId: deviceId, orientation: .portrait)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first.serialNumber, portrait.serialNumber)
        XCTAssertEqual(first.serialNumber & 0x8000_0000, 0)
        XCTAssertNotEqual(portrait.serialNumber & 0x8000_0000, 0)
        XCTAssertNotEqual(first.serialNumber, 0)
        XCTAssertNotEqual(portrait.serialNumber, 0)
    }

    func testTenThousandDeterministicUUIDsDoNotCollide() {
        let generator = DisplayIdentityGenerator()
        var serials = Set<UInt32>()
        for value in UInt32(0)..<10_000 {
            let deviceId = UUID(
                uuid: (
                    0x53, 0x44, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0,
                    UInt8((value >> 24) & 0xff),
                    UInt8((value >> 16) & 0xff),
                    UInt8((value >> 8) & 0xff),
                    UInt8(value & 0xff)
                ))
            let serial = generator.identity(deviceId: deviceId, orientation: .landscape).serialNumber
            XCTAssertNotEqual(serial, 0)
            XCTAssertTrue(serials.insert(serial).inserted)
        }
    }

    func testDefaultSpecMapsToHiDPILogicalSize() throws {
        let spec = try VirtualDisplaySpec(
            name: "Harmony Tablet",
            deviceId: UUID(),
            orientation: .landscape
        )
        XCTAssertEqual(spec.framebufferSize.width, 2560)
        XCTAssertEqual(spec.framebufferSize.height, 1600)
        XCTAssertEqual(spec.logicalSize.width, 1280)
        XCTAssertEqual(spec.logicalSize.height, 800)
    }

    func testInvalidDimensionsScaleAndRefreshAreRejected() {
        assertApplyFailure {
            _ = try VirtualDisplaySpec(
                name: "Invalid",
                deviceId: UUID(),
                orientation: .landscape,
                framebufferWidth: -2
            )
        }
        assertApplyFailure {
            _ = try VirtualDisplaySpec(
                name: "Invalid",
                deviceId: UUID(),
                orientation: .landscape,
                framebufferWidth: 2559
            )
        }
        assertApplyFailure {
            _ = try VirtualDisplaySpec(
                name: "Invalid",
                deviceId: UUID(),
                orientation: .landscape,
                scaleFactor: 1
            )
        }
        assertApplyFailure {
            _ = try VirtualDisplaySpec(
                name: "Invalid",
                deviceId: UUID(),
                orientation: .landscape,
                refreshRate: 59
            )
        }
    }

    func testHighRefreshVirtualDisplaySpecificationsAreAccepted() throws {
        for refreshRate in [60.0, 90.0, 120.0] {
            let spec = try VirtualDisplaySpec(
                name: "High Refresh",
                deviceId: UUID(),
                orientation: .landscape,
                refreshRate: refreshRate)
            XCTAssertEqual(spec.refreshRate, refreshRate)
        }
    }

    func testPortraitSystemResolutionIsAcceptedAndKeepsOrientationIdentity() throws {
        let deviceID = UUID()
        let spec = try VirtualDisplaySpec(
            name: "Portrait Receiver",
            deviceId: deviceID,
            orientation: .portrait,
            framebufferWidth: 1260,
            framebufferHeight: 2720
        )
        XCTAssertEqual(spec.logicalSize.width, 630)
        XCTAssertEqual(spec.logicalSize.height, 1360)
        let identity = DisplayIdentityGenerator().identity(
            deviceId: deviceID,
            orientation: spec.orientation
        )
        XCTAssertNotEqual(identity.serialNumber & 0x8000_0000, 0)
    }

    func testRegistryRejectsCollisionAndAllowsOwnerReuse() throws {
        let registry = DisplayIdentityRegistry()
        let firstDevice = UUID()
        let secondDevice = UUID()
        let identity = DisplayIdentity(vendorId: 1, productId: 2, serialNumber: 3)
        try registry.claim(identity, deviceId: firstDevice)
        XCTAssertThrowsError(try registry.claim(identity, deviceId: firstDevice))
        do {
            try registry.claim(identity, deviceId: secondDevice)
            XCTFail("Expected serial collision")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .vdApplyFailed)
        }
        registry.release(identity, deviceId: firstDevice)
        try registry.claim(identity, deviceId: secondDevice)
    }

    private func assertApplyFailure(_ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual((error as? SessionError)?.code, .vdApplyFailed)
        }
    }
}
