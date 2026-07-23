import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import P3HostCore
import SecondDisplayCore
import SwiftUI
import UniformTypeIdentifiers
import VirtualDisplayCore

@main
struct SecondDisplayMacApp: App {
    @NSApplicationDelegateAdaptor(SecondDisplayAppDelegate.self) private var appDelegate
    @StateObject private var model = HostServiceModel.shared

    var body: some Scene {
        WindowGroup {
            HostServiceView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private final class SecondDisplayAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard HostServiceModel.shared.isServiceActive else { return .terminateNow }
        Task {
            await HostServiceModel.shared.stopService()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct HostServiceView: View {
    @ObservedObject var model: HostServiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "display.2")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Second Display Host")
                        .font(.title2.bold())
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.statusColor)
                            .frame(width: 9, height: 9)
                        Text(model.phaseLabel)
                            .font(.headline)
                    }
                }
                Spacer()
                Button("Start Service") {
                    Task { await model.startService() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isServiceActive || !model.pairingReady)
                Button("Stop Service") {
                    Task { await model.stopService() }
                }
                .disabled(!model.isServiceActive)
            }

            Text(model.statusMessage)
                .foregroundStyle(model.phase == .failed ? Color.red : Color.secondary)
                .textSelection(.enabled)

            HStack(alignment: .top, spacing: 12) {
                GroupBox("Network") {
                    DetailGrid(rows: [
                        ("Mac IP", model.localIPAddress),
                        ("Control", "TCP/TLS 52340"),
                        ("Video", "TCP/TLS 52341"),
                    ])
                }
                GroupBox("Connection") {
                    DetailGrid(rows: [
                        ("Receiver", model.deviceName),
                        ("Display ID", model.displayID),
                        ("Encoded", model.encodedFrames),
                        ("Dropped", model.droppedFrames),
                    ])
                }
            }

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 10) {
                    DetailGrid(rows: [
                        ("Capability", model.capabilitySummary),
                        ("Mode", model.streamMode),
                        ("Bitrate", model.currentBitrate),
                        ("RTT", model.networkRTT),
                        ("Video queue", model.videoQueueDepth),
                        ("Recoveries", model.recoveryCount),
                        ("Recent error", model.recentErrorCode),
                        ("Self-test", model.selfTestSummary),
                    ])
                    HStack {
                        Button("Run Display Self-Test") {
                            Task { await model.runDisplaySelfTest() }
                        }
                        .disabled(model.isServiceActive || !model.screenCaptureAllowed)
                        Button("Export Diagnostics") {
                            model.exportDiagnostics()
                        }
                        Button("Copy Error Code") {
                            model.copyRecentErrorCode()
                        }
                        .disabled(model.recentErrorCode == "—")
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Permissions") {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Label(
                            model.screenCaptureAllowed
                                ? "Screen Recording allowed" : "Screen Recording permission required",
                            systemImage: model.screenCaptureAllowed
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(model.screenCaptureAllowed ? Color.green : Color.orange)
                        Spacer()
                        Button("Open System Settings") {
                            model.openScreenRecordingSettings()
                        }
                        .disabled(model.screenCaptureAllowed)
                    }
                    HStack(spacing: 12) {
                        Label(
                            model.accessibilityAllowed
                                ? "Touch control allowed" : "Touch control requires Accessibility",
                            systemImage: model.accessibilityAllowed
                                ? "checkmark.circle.fill" : "hand.tap.fill"
                        )
                        .foregroundStyle(model.accessibilityAllowed ? Color.green : Color.orange)
                        Spacer()
                        Button("Enable Touch Control") {
                            model.requestAccessibilityPermission()
                        }
                        .disabled(model.accessibilityAllowed)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Pairing") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            model.pairingReady ? "Pairing identity ready" : "Pairing identity missing",
                            systemImage: model.pairingReady
                                ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(model.pairingReady ? Color.green : Color.orange)
                        Spacer()
                        Text("TLS 1.3 · pinned CA")
                            .foregroundStyle(.secondary)
                    }
                    Text("Certificate SHA-256")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.certificateFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text(model.pairingLocation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in model.refreshPermissions()
        }
    }
}

private struct DetailGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Text(row.1)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

@MainActor
private final class HostServiceModel: ObservableObject {
    static let shared = HostServiceModel()

    @Published private(set) var phase: P3HostPhase = .stopped
    @Published private(set) var statusMessage = "Service is stopped"
    @Published private(set) var localIPAddress = "Unavailable"
    @Published private(set) var deviceName = "Waiting for receiver"
    @Published private(set) var displayID = "—"
    @Published private(set) var encodedFrames = "0"
    @Published private(set) var droppedFrames = "0"
    @Published private(set) var pairingReady = false
    @Published private(set) var screenCaptureAllowed = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var certificateFingerprint = "Unavailable"
    @Published private(set) var pairingLocation = ""
    @Published private(set) var capabilitySummary = "Checking"
    @Published private(set) var streamMode = "—"
    @Published private(set) var currentBitrate = "—"
    @Published private(set) var networkRTT = "—"
    @Published private(set) var videoQueueDepth = "—"
    @Published private(set) var recoveryCount = "0"
    @Published private(set) var recentErrorCode = "—"
    @Published private(set) var selfTestSummary = "Not run"

    private let service = P3HostService()
    private let screenCapturePermission = ScreenCapturePermissionController()
    private var credentials: PairingCredentials?
    private var latestGeneration: UInt64 = 0
    private var eventHistory: [P3HostEvent] = []
    private var latestSelfTest: P3DiagnosticSelfTestResult?

    private init() {
        localIPAddress = LocalNetworkInfo.preferredIPv4Address() ?? "Unavailable"
        refreshPermissions()
        reloadPairing()
        let capability = VirtualDisplayCapabilityProbe().report()
        let compatibility = SystemMacCompatibilityChecker().decision()
        capabilitySummary =
            capability.supported
            ? "\(compatibility.status.rawValue.capitalized) · build \(compatibility.osBuild) · probe v\(capability.probeVersion)"
            : "Unsupported · missing \(capability.missingClasses.count + capability.missingSelectors.count)"
    }

    var isServiceActive: Bool {
        switch phase {
        case .starting, .listening, .connected, .preparingDisplay, .streaming, .recovering, .stopping:
            return true
        case .stopped, .failed:
            return false
        }
    }

    var phaseLabel: String {
        switch phase {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .listening: "Listening"
        case .connected: "Receiver connected"
        case .preparingDisplay: "Preparing display"
        case .streaming: "Streaming"
        case .recovering: "Recovering"
        case .stopping: "Stopping"
        case .failed: "Failed"
        }
    }

    var statusColor: Color {
        switch phase {
        case .streaming: .green
        case .starting, .listening, .connected, .preparingDisplay, .recovering, .stopping: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    func startService() async {
        guard !isServiceActive else { return }
        refreshPermissions()
        guard screenCapturePermission.requestFromUserAction() else {
            phase = .failed
            statusMessage = "CAP_PERMISSION_DENIED: Screen Recording permission is required"
            return
        }
        screenCaptureAllowed = true
        reloadPairing()
        guard let credentials else {
            phase = .failed
            statusMessage = "NET_PROTOCOL_MISMATCH: pairing identity is unavailable"
            return
        }
        deviceName = "Waiting for receiver"
        displayID = "—"
        encodedFrames = "0"
        droppedFrames = "0"
        streamMode = "—"
        currentBitrate = "—"
        networkRTT = "—"
        videoQueueDepth = "—"
        recoveryCount = "0"
        recentErrorCode = "—"
        let configuration = P3HostConfiguration(
            identityData: credentials.identityData,
            identityPassword: credentials.password
        )
        await service.start(configuration: configuration) { [weak self] event in
            await self?.apply(event)
        }
    }

    func stopService() async {
        await service.stop()
    }

    func refreshPermissions() {
        screenCaptureAllowed = screenCapturePermission.preflight()
        accessibilityAllowed = AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        accessibilityAllowed = AXIsProcessTrusted()
    }

    func openScreenRecordingSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        else {
            phase = .failed
            statusMessage = "CAP_PERMISSION_DENIED: unable to open Screen Recording settings"
            return
        }
        if !NSWorkspace.shared.open(url) {
            phase = .failed
            statusMessage = "CAP_PERMISSION_DENIED: unable to open Screen Recording settings"
        }
    }

    func runDisplaySelfTest() async {
        guard !isServiceActive else { return }
        do {
            statusMessage = "Running create / enumerate / destroy diagnostic"
            let result = try await P3DiagnosticSelfTest.run()
            latestSelfTest = result
            selfTestSummary = String(
                format: "Passed · create %.0f ms · enumerate %.0f ms · destroy %.0f ms",
                result.createMilliseconds,
                result.enumerationMilliseconds,
                result.destroyMilliseconds
            )
            statusMessage = "Virtual display self-test passed"
        } catch let error as SessionError {
            recentErrorCode = error.code.rawValue
            selfTestSummary = "Failed · \(error.code.rawValue)"
            statusMessage = error.errorDescription ?? error.code.rawValue
        } catch is CancellationError {
            statusMessage = "Diagnostic self-test cancelled"
        } catch {
            recentErrorCode = SessionErrorCode.vdApplyFailed.rawValue
            selfTestSummary = "Failed · \(recentErrorCode)"
            statusMessage = "VD_APPLY_FAILED: diagnostic self-test failed"
        }
    }

    func exportDiagnostics() {
        do {
            let data = try P3DiagnosticExporter.makeReport(
                events: eventHistory,
                selfTest: latestSelfTest
            )
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "SecondDisplay-Diagnostics.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusMessage = "Diagnostics exported"
        } catch let error as SessionError {
            recentErrorCode = error.code.rawValue
            statusMessage = error.errorDescription ?? error.code.rawValue
        } catch {
            recentErrorCode = SessionErrorCode.netProtocolMismatch.rawValue
            statusMessage = "NET_PROTOCOL_MISMATCH: unable to export diagnostics"
        }
    }

    func copyRecentErrorCode() {
        guard recentErrorCode != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recentErrorCode, forType: .string)
    }

    private func apply(_ event: P3HostEvent) {
        guard event.generation >= latestGeneration else { return }
        latestGeneration = event.generation
        eventHistory.append(event)
        if eventHistory.count > 200 { eventHistory.removeFirst(eventHistory.count - 200) }
        phase = event.phase
        statusMessage = event.message
        if let value = event.deviceName { deviceName = value }
        if let value = event.displayID { displayID = String(value) }
        if let value = event.encodedFrameCount { encodedFrames = value.formatted() }
        if let value = event.droppedFrameCount { droppedFrames = value.formatted() }
        if let width = event.streamWidth, let height = event.streamHeight {
            streamMode = "\(width)×\(height) · \(event.framesPerSecond ?? 0) FPS"
        } else if let fps = event.framesPerSecond {
            streamMode = "\(fps) FPS"
        }
        if let bitrate = event.bitrate {
            currentBitrate = String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        }
        if let rtt = event.networkRTTMilliseconds {
            networkRTT = String(format: "%.1f ms", rtt)
        }
        if let depth = event.videoQueueDepth { videoQueueDepth = String(depth) }
        recoveryCount = event.recoveryCount.formatted()
        if let error = event.error { recentErrorCode = error.code.rawValue }
        if event.phase == .stopped {
            displayID = "—"
            deviceName = "Waiting for receiver"
        }
        if event.error?.code == .capPermissionDenied {
            refreshPermissions()
        }
    }

    private func reloadPairing() {
        do {
            let loaded = try PairingCredentials.load()
            credentials = loaded
            pairingReady = true
            certificateFingerprint = loaded.fingerprint
            pairingLocation = loaded.directory.path
        } catch let error as SessionError {
            credentials = nil
            pairingReady = false
            certificateFingerprint = "Unavailable"
            pairingLocation = error.errorDescription ?? error.code.rawValue
        } catch {
            credentials = nil
            pairingReady = false
            certificateFingerprint = "Unavailable"
            pairingLocation = "NET_PROTOCOL_MISMATCH: unable to load pairing identity"
        }
    }
}

private struct PairingCredentials {
    let identityData: Data
    let password: String
    let fingerprint: String
    let directory: URL

    static func load() throws -> PairingCredentials {
        let directory = try pairingDirectory()
        let identityData: Data
        let passwordData: Data
        let certificateData: Data
        do {
            identityData = try Data(contentsOf: directory.appending(path: "identity.p12"))
            passwordData = try Data(contentsOf: directory.appending(path: "password"))
            certificateData = try Data(contentsOf: directory.appending(path: "cert.pem"))
        } catch {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Pairing files are missing at \(directory.path)"
            )
        }
        guard
            let password = String(data: passwordData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !password.isEmpty,
            let certificatePEM = String(data: certificateData, encoding: .utf8),
            let certificateDER = decodeCertificatePEM(certificatePEM)
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Pairing files are invalid")
        }
        let digest = SHA256.hash(data: certificateDER)
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        return PairingCredentials(
            identityData: identityData,
            password: password,
            fingerprint: fingerprint,
            directory: directory
        )
    }

    private static func pairingDirectory() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["P3_POC_TLS_DIRECTORY"],
            !configured.isEmpty
        {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        guard
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Application Support directory is unavailable"
            )
        }
        let installed =
            applicationSupport
            .appending(path: "Second Display", directoryHint: .isDirectory)
            .appending(path: "Pairing", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: installed.path) { return installed }

        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/p3-poc-tls", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: development.path) { return development }
        return installed
    }

    private static func decodeCertificatePEM(_ value: String) -> Data? {
        let base64 =
            value
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: base64)
    }
}

private enum LocalNetworkInfo {
    static func preferredIPv4Address() -> String? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var values: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let socketAddress = interface.pointee.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET),
                interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var ipv4 = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in.self)
                .pointee.sin_addr
            guard inet_ntop(AF_INET, &ipv4, &address, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let bytes = address.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let value = String(decoding: bytes, as: UTF8.self)
            if !values.contains(value) { values.append(value) }
        }
        return values.sorted { lhs, rhs in
            let lhsPreferred = lhs.hasPrefix("192.168.43.")
            let rhsPreferred = rhs.hasPrefix("192.168.43.")
            return lhsPreferred == rhsPreferred ? lhs < rhs : lhsPreferred
        }.first
    }
}
