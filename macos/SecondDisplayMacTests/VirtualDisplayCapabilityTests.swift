import Foundation
import SecondDisplayCore
@testable import VirtualDisplayCore
import XCTest

final class VirtualDisplayCapabilityTests: XCTestCase {
    func testCompatibilityManifestLoaderUsesValidCandidateAfterMissingCandidate() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missingBundle = temporaryDirectory.appendingPathComponent("Missing.bundle")
        let validBundle = temporaryDirectory.appendingPathComponent("Valid.bundle")
        try FileManager.default.createDirectory(
            at: validBundle, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let data = try JSONEncoder().encode(
            MacCompatibilityManifest(
                entries: [
                    .init(osBuild: "TEST", status: .supported, reason: "fixture"),
                ]
            )
        )
        try data.write(to: validBundle.appendingPathComponent("CompatibilityManifest.json"))

        let manifest = SystemMacCompatibilityChecker.loadManifest(
            from: [missingBundle, validBundle]
        )

        XCTAssertEqual(manifest.decision(for: "TEST").status, .supported)
    }

    func testCompatibilityManifestLoaderSafelyFallsBackWhenResourceIsMissing() {
        let manifest = SystemMacCompatibilityChecker.loadManifest(
            from: [URL(fileURLWithPath: "/nonexistent/SecondDisplay.bundle")]
        )

        XCTAssertEqual(manifest.decision(for: "UNKNOWN").status, .experimental)
    }

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
