import Darwin
import Foundation
import P3HostCore
import SecondDisplayCore

@main
struct P3PoCHost {
    static func main() async {
        do {
            try await run()
        } catch is CancellationError {
            writeStatus("P3 PoC cancelled")
        } catch let error as SessionError {
            writeStatus(error.errorDescription ?? error.code.rawValue)
        } catch {
            writeStatus("NET_PROTOCOL_MISMATCH: P3 PoC failed")
        }
    }

    private static func run() async throws {
        let tlsDirectory: URL
        if let configured = ProcessInfo.processInfo.environment["P3_POC_TLS_DIRECTORY"],
            !configured.isEmpty
        {
            tlsDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            tlsDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/p3-poc-tls", directoryHint: .isDirectory)
        }
        let identityData: Data
        let passwordData: Data
        do {
            identityData = try Data(contentsOf: tlsDirectory.appending(path: "identity.p12"))
            passwordData = try Data(contentsOf: tlsDirectory.appending(path: "password"))
        } catch {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "P3 TLS pairing identity is unavailable"
            )
        }
        guard
            let password = String(data: passwordData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !password.isEmpty
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "P3 TLS password is invalid")
        }

        let duration =
            ProcessInfo.processInfo.environment["P3_POC_DURATION_SECONDS"]
            .flatMap(UInt64.init) ?? 1_800
        let maximumFramesPerSecond =
            ProcessInfo.processInfo.environment["P3_POC_MAX_FPS"]
            .flatMap(Int.init) ?? 60
        let allowsAdaptiveResolution: Bool
        switch ProcessInfo.processInfo.environment["P3_POC_ADAPTIVE_RESOLUTION"] {
        case nil, "0":
            allowsAdaptiveResolution = false
        case "1":
            allowsAdaptiveResolution = true
        default:
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "P3_POC_ADAPTIVE_RESOLUTION must be 0 or 1"
            )
        }
        let showsAnimatedTestPattern: Bool
        switch ProcessInfo.processInfo.environment["P3_POC_ANIMATED_TEST_PATTERN"] {
        case nil, "1":
            showsAnimatedTestPattern = true
        case "0":
            showsAnimatedTestPattern = false
        default:
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "P3_POC_ANIMATED_TEST_PATTERN must be 0 or 1"
            )
        }
        let configuration = P3HostConfiguration(
            identityData: identityData,
            identityPassword: password,
            durationSeconds: duration,
            showsAnimatedTestPattern: showsAnimatedTestPattern,
            maximumFramesPerSecond: maximumFramesPerSecond,
            allowsAdaptiveResolution: allowsAdaptiveResolution
        )
        let service = P3HostService()
        let printer = CLIEventPrinter()
        await service.start(configuration: configuration) { event in
            await printer.record(event)
        }
        let terminationSignal = SignalCancellationSource(signalNumber: SIGTERM) {
            Task { await service.stop() }
        }
        let interruptSignal = SignalCancellationSource(signalNumber: SIGINT) {
            Task { await service.stop() }
        }
        _ = terminationSignal
        _ = interruptSignal
        if let failure = await service.waitUntilInactive() { throw failure }
    }

    fileprivate static func writeStatus(_ value: String) {
        FileHandle.standardError.write(Data((value + "\n").utf8))
    }
}

private actor CLIEventPrinter {
    private var lastPhase: P3HostPhase?
    private var lastMetricsReport = Date.distantPast

    func record(_ event: P3HostEvent) {
        let now = Date()
        let phaseChanged = event.phase != lastPhase
        let shouldReportMetrics =
            event.encodedFrameCount != nil
            && now.timeIntervalSince(lastMetricsReport) >= 10
        guard phaseChanged || shouldReportMetrics || event.phase == .failed else { return }
        lastPhase = event.phase
        if shouldReportMetrics { lastMetricsReport = now }
        var value = "P3 PoC \(event.phase.rawValue): \(event.message)"
        if let frameCount = event.encodedFrameCount {
            value += " encoded=\(frameCount)"
        }
        if let dropCount = event.droppedFrameCount {
            value += " drops=\(dropCount)"
        }
        P3PoCHost.writeStatus(value)
    }
}

private final class SignalCancellationSource: @unchecked Sendable {
    private let source: DispatchSourceSignal

    init(signalNumber: Int32, handler: @escaping @Sendable () -> Void) {
        Darwin.signal(signalNumber, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
