import CapturePipeline
import Foundation
import SecondDisplayCore
import VirtualDisplayCore

public struct P3DiagnosticSelfTestResult: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let createMilliseconds: Double
    public let enumerationMilliseconds: Double
    public let destroyMilliseconds: Double

    public init(
        displayID: UInt32,
        createMilliseconds: Double,
        enumerationMilliseconds: Double,
        destroyMilliseconds: Double
    ) {
        self.displayID = displayID
        self.createMilliseconds = createMilliseconds
        self.enumerationMilliseconds = enumerationMilliseconds
        self.destroyMilliseconds = destroyMilliseconds
    }
}

public enum P3DiagnosticExporter {
    public static func makeReport(
        events: [P3HostEvent],
        selfTest: P3DiagnosticSelfTestResult? = nil,
        generatedAt: Date = Date()
    ) throws -> Data {
        let capability = VirtualDisplayCapabilityProbe().report()
        let compatibility = SystemMacCompatibilityChecker().decision()
        let redactor = LogRedactor()
        let payload = Report(
            schemaVersion: 1,
            generatedAt: generatedAt,
            system: SystemReport(
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                osBuild: SystemMacCompatibilityChecker.currentOSBuild,
                architecture: capability.architecture
            ),
            capability: CapabilityReport(
                supported: capability.supported,
                probeVersion: capability.probeVersion,
                missingClasses: capability.missingClasses,
                missingSelectors: capability.missingSelectors,
                compatibilityStatus: compatibility.status.rawValue,
                compatibilityReason: compatibility.reason
            ),
            events: events.suffix(200).map { event in
                let fields = redactor.redact(fields: [
                    "message": event.message,
                    "deviceName": event.deviceName ?? "",
                    "displayID": event.displayID.map(String.init) ?? "",
                ])
                return EventReport(
                    timestamp: generatedAt,
                    phase: event.phase.rawValue,
                    generation: event.generation,
                    message: fields["message"] ?? "",
                    device: fields["deviceName"] ?? "",
                    session: event.sessionID.map(redactor.redactSessionId) ?? "",
                    displayID: fields["displayID"] ?? "",
                    streamWidth: event.streamWidth,
                    streamHeight: event.streamHeight,
                    framesPerSecond: event.framesPerSecond,
                    bitrate: event.bitrate,
                    networkRTTMilliseconds: event.networkRTTMilliseconds,
                    videoQueueDepth: event.videoQueueDepth,
                    encodedFrameCount: event.encodedFrameCount,
                    droppedFrameCount: event.droppedFrameCount,
                    recoveryCount: event.recoveryCount,
                    errorCode: event.error?.code.rawValue
                )
            },
            selfTest: selfTest
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(payload)
        } catch {
            throw SessionError(code: .netProtocolMismatch, detail: "Unable to encode diagnostics")
        }
    }

    private struct Report: Codable {
        let schemaVersion: Int
        let generatedAt: Date
        let system: SystemReport
        let capability: CapabilityReport
        let events: [EventReport]
        let selfTest: P3DiagnosticSelfTestResult?
    }

    private struct SystemReport: Codable {
        let osVersion: String
        let osBuild: String
        let architecture: String
    }

    private struct CapabilityReport: Codable {
        let supported: Bool
        let probeVersion: Int
        let missingClasses: [String]
        let missingSelectors: [String]
        let compatibilityStatus: String
        let compatibilityReason: String
    }

    private struct EventReport: Codable {
        let timestamp: Date
        let phase: String
        let generation: UInt64
        let message: String
        let device: String
        let session: String
        let displayID: String
        let streamWidth: Int?
        let streamHeight: Int?
        let framesPerSecond: Int?
        let bitrate: Int?
        let networkRTTMilliseconds: Double?
        let videoQueueDepth: Int?
        let encodedFrameCount: UInt64?
        let droppedFrameCount: UInt64?
        let recoveryCount: UInt64
        let errorCode: String?
    }
}

@MainActor
public enum P3DiagnosticSelfTest {
    public static func run() async throws -> P3DiagnosticSelfTestResult {
        let provider = CGVirtualDisplayProvider()
        try provider.capabilityReport().requireSupport()
        let spec = try VirtualDisplaySpec(
            name: "Second Display Diagnostic",
            deviceId: UUID(),
            orientation: .landscape,
            framebufferWidth: 1600,
            framebufferHeight: 1200,
            refreshRate: 60,
            physicalWidthMM: 240,
            physicalHeightMM: 180
        )
        let createStarted = ContinuousClock.now
        let handle = try provider.create(spec: spec)
        let createDuration = createStarted.duration(to: .now)
        do {
            let enumerationStarted = ContinuousClock.now
            let enumerator = ScreenCaptureDisplayEnumerator()
            let deadline = ContinuousClock.now + .seconds(15)
            var enumerated = false
            while ContinuousClock.now < deadline, !enumerated {
                try Task.checkCancellation()
                enumerated = try await enumerator.displayIDs().contains(handle.displayID)
                if !enumerated { try await Task.sleep(for: .milliseconds(100)) }
            }
            guard enumerated else {
                throw SessionError(
                    code: .vdEnumerationTimeout,
                    detail: "Diagnostic display was not enumerated by ScreenCaptureKit"
                )
            }
            let enumerationDuration = enumerationStarted.duration(to: .now)
            let destroyStarted = ContinuousClock.now
            await provider.destroy(handle)
            let destroyDuration = destroyStarted.duration(to: .now)
            return P3DiagnosticSelfTestResult(
                displayID: handle.displayID,
                createMilliseconds: createDuration.milliseconds,
                enumerationMilliseconds: enumerationDuration.milliseconds,
                destroyMilliseconds: destroyDuration.milliseconds
            )
        } catch {
            await provider.destroy(handle)
            if let error = error as? SessionError { throw error }
            if error is CancellationError { throw CancellationError() }
            throw SessionError(code: .vdApplyFailed, detail: "Diagnostic display test failed")
        }
    }
}

extension Duration {
    fileprivate var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
