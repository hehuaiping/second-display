import Foundation
import SecondDisplayCore
import XCTest

final class DiagnosticsTests: XCTestCase {
    func testAllErrorCodesHaveStableWireValues() {
        XCTAssertEqual(SessionErrorCode.allCases.count, 13)
        XCTAssertEqual(SessionErrorCode.vdCapabilityMissing.rawValue, "VD_CAPABILITY_MISSING")
        XCTAssertEqual(SessionErrorCode.netProtocolMismatch.rawValue, "NET_PROTOCOL_MISMATCH")
        XCTAssertEqual(SessionErrorCode.inputPermissionDenied.rawValue, "INPUT_PERMISSION_DENIED")
    }

    func testJSONLineContainsContextAndRedactsSensitiveValues() throws {
        let sessionId = "9e24c419-01f4-4e5a-8f72-aabbccddeeff"
        let rawIP = "192.168.1.52"
        let rawPath = "/Users/alice/Library/state.json"
        let rawDeviceName = "Alice's Harmony Tablet"
        let event = LogEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            level: .error,
            sessionId: sessionId,
            generation: 4,
            component: "transport",
            event: "connectionFailed",
            errorCode: .netProtocolMismatch,
            fields: [
                "ipAddress": rawIP,
                "path": rawPath,
                "deviceName": rawDeviceName,
                "detail": "peer \(rawIP) used \(rawPath) for \(sessionId)",
            ]
        )
        let line = try XCTUnwrap(try JSONLinesLogEncoder().encode(event))
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertTrue(line.contains("\"generation\":4"))
        XCTAssertTrue(line.contains("NET_PROTOCOL_MISMATCH"))
        XCTAssertFalse(line.contains(sessionId))
        XCTAssertFalse(line.contains(rawIP))
        XCTAssertFalse(line.contains(rawPath))
        XCTAssertFalse(line.contains(rawDeviceName))
    }

    func testFrameLevelLoggingCanBeDisabled() throws {
        let event = LogEvent(
            level: .debug,
            sessionId: "session",
            generation: 1,
            component: "capture",
            event: "frame",
            isFrameLevel: true
        )
        XCTAssertNil(try JSONLinesLogEncoder(frameDebugEnabled: false).encode(event))
    }

    #if !DEBUG
        func testReleaseDefaultDisablesFrameLevelLogging() {
            XCTAssertFalse(BuildLogPolicy.frameDebugEnabled)
        }
    #endif
}

