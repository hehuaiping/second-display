import Foundation
import SecondDisplayCore
import VirtualDisplayCore
import XCTest

final class VirtualDisplayCapabilityTests: XCTestCase {
    func testSystemCapabilityProbeIsSupportedOnCurrentMac() throws {
        let report = VirtualDisplayCapabilityProbe().report()
        XCTAssertEqual(report.probeVersion, 1)
        XCTAssertFalse(report.architecture.isEmpty)
        try report.requireSupport()
    }

    func testFakeRuntimeReportsMissingClassAndSelector() {
        let checker = FakeRuntimeChecker(
            missingClasses: [.settings],
            missingSelectors: [.applySettings]
        )
        let report = VirtualDisplayCapabilityProbe(checker: checker).report(
            osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            architecture: "test"
        )
        XCTAssertFalse(report.supported)
        XCTAssertEqual(report.missingClasses, ["settings"])
        XCTAssertEqual(report.missingSelectors, ["applySettings"])
        XCTAssertThrowsError(try report.requireSupport()) { error in
            XCTAssertEqual((error as? SessionError)?.code, .vdCapabilityMissing)
        }
    }
}

private struct FakeRuntimeChecker: VirtualDisplayRuntimeChecking {
    let missingClasses: Set<VirtualDisplayPrivateClassRole>
    let missingSelectors: Set<VirtualDisplayPrivateSelectorRole>

    func hasClass(_ role: VirtualDisplayPrivateClassRole) -> Bool {
        !missingClasses.contains(role)
    }

    func hasSelector(_ role: VirtualDisplayPrivateSelectorRole) -> Bool {
        !missingSelectors.contains(role)
    }
}

