import CoreGraphics
import Foundation
import SecondDisplayCore
import SharedProtocol
import XCTest

@testable import P3HostCore

final class P3HostServiceTests: XCTestCase {
    func testAdaptiveResolutionKeepsHiDPILogicalMinimumForSystemAspectRatio() {
        let landscape = P3HostSessionRunner.scaledDimensions(
            width: 2720,
            height: 1260,
            scale: 0.8
        )
        XCTAssertGreaterThanOrEqual(min(landscape.width, landscape.height), 1200)
        XCTAssertGreaterThanOrEqual(max(landscape.width, landscape.height), 1600)
        XCTAssertLessThan(landscape.width, 2720)

        let portrait = P3HostSessionRunner.scaledDimensions(
            width: 1260,
            height: 2720,
            scale: 2.0 / 3.0
        )
        XCTAssertEqual(portrait.width, landscape.height)
        XCTAssertEqual(portrait.height, landscape.width)
    }

    func testHostUsesStableDefaultAndNormalizesExperimentalRefreshRates() {
        XCTAssertEqual(configuration().maximumFramesPerSecond, 60)
        XCTAssertEqual(
            P3HostConfiguration(
                identityData: Data([0]), identityPassword: "test", maximumFramesPerSecond: 95
            ).maximumFramesPerSecond,
            90
        )
        XCTAssertEqual(
            P3HostConfiguration(
                identityData: Data([0]), identityPassword: "test", maximumFramesPerSecond: 120
            ).maximumFramesPerSecond,
            120
        )
    }

    func testCursorProjectionUsesLogicalDisplayBoundsAndHidesOutside() {
        let bounds = CGRect(x: -1360, y: 20, width: 1360, height: 630)
        let center = CursorCoordinateProjector.project(point: CGPoint(x: -680, y: 335), displayBounds: bounds)
        XCTAssertTrue(center.visible)
        XCTAssertEqual(center.normalizedX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(center.normalizedY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            CursorCoordinateProjector.project(point: CGPoint(x: 100, y: 100), displayBounds: bounds),
            .hidden
        )
    }

    func testCursorSideChannelStopCancelsSampling() async throws {
        let provider = AlternatingCursorProvider()
        let recorder = CursorMessageRecorder()
        let channel = CursorSideChannel(
            intervalNanoseconds: 1_000_000,
            sampleProvider: { _ in provider.next() }
        )
        await channel.start(
            sessionId: "cursor-session",
            displayID: 42,
            sessionGeneration: 8,
            isCurrentGeneration: { $0 == 8 },
            send: { await recorder.append($0) },
            onFailure: { _ in }
        )
        for _ in 0..<50 where await recorder.count < 3 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await channel.stop()
        let stoppedCount = await recorder.count
        try await Task.sleep(nanoseconds: 5_000_000)
        let finalMessages = await recorder.messages
        XCTAssertGreaterThanOrEqual(stoppedCount, 1)
        XCTAssertEqual(finalMessages.count, stoppedCount)
        XCTAssertTrue(finalMessages.allSatisfy { $0.sessionId == "cursor-session" })
    }

    func testStopCancelsRunnerAndSuppressesLateGenerationUpdate() async throws {
        let runner = LateUpdateRunner()
        let service = P3HostService(runner: runner)
        let recorder = P3HostEventRecorder()
        await service.start(configuration: configuration()) { event in
            await recorder.append(event)
        }
        try await waitForPhase(.listening, recorder: recorder)

        await service.stop()

        let events = await recorder.events
        XCTAssertTrue(events.contains { $0.phase == .stopping })
        XCTAssertEqual(events.last?.phase, .stopped)
        XCTAssertFalse(events.contains { $0.message == "late callback" })
        let isActive = await service.isActive
        XCTAssertFalse(isActive)
    }

    func testRestartRejectsOldRunnerCallbackAndUsesNewGeneration() async throws {
        let runner = LateUpdateRunner()
        let service = P3HostService(runner: runner)
        let firstRecorder = P3HostEventRecorder()
        let secondRecorder = P3HostEventRecorder()
        await service.start(configuration: configuration()) { event in
            await firstRecorder.append(event)
        }
        try await waitForPhase(.listening, recorder: firstRecorder)

        await service.start(configuration: configuration()) { event in
            await secondRecorder.append(event)
        }
        try await waitForPhase(.listening, recorder: secondRecorder)

        let firstEvents = await firstRecorder.events
        let secondEvents = await secondRecorder.events
        XCTAssertFalse(firstEvents.contains { $0.message == "late callback" })
        XCTAssertFalse(secondEvents.contains { $0.message == "late callback" })
        XCTAssertGreaterThan(
            secondEvents.first?.generation ?? 0,
            firstEvents.first?.generation ?? UInt64.max
        )
        await service.stop()
    }

    func testRecoverableDisconnectKeepsServiceGenerationAndRestartsSession() async throws {
        let runner = RecoveringRunner()
        let service = P3HostService(runner: runner)
        let recorder = P3HostEventRecorder()
        await service.start(configuration: configuration()) { event in
            await recorder.append(event)
        }
        for _ in 0..<200 {
            let streamingEvents = await recorder.events.filter { $0.phase == .streaming }
            if streamingEvents.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let events = await recorder.events
        let streamingEvents = events.filter { $0.phase == .streaming }
        XCTAssertEqual(streamingEvents.count, 2)
        XCTAssertTrue(events.contains { $0.phase == .recovering })
        XCTAssertEqual(streamingEvents.first?.generation, streamingEvents.last?.generation)
        XCTAssertEqual(streamingEvents.last?.recoveryCount, 1)
        XCTAssertEqual(streamingEvents.first?.displayID, streamingEvents.last?.displayID)
        await service.stop()
    }

    func testDiagnosticExportRedactsDeviceSessionIPAndUserPath() throws {
        let rawUUID = "9e24c419-01f4-4e5a-8f72-aabbccddeeff"
        let rawIP = "192.168.1.52"
        let rawPath = "/Users/alice/Library/state.json"
        let rawDevice = "Alice Harmony Tablet"
        let event = P3HostEvent(
            phase: .failed,
            message: "peer \(rawIP) used \(rawPath)",
            generation: 4,
            deviceName: rawDevice,
            sessionID: rawUUID,
            error: SessionError(code: .netProtocolMismatch, detail: "connection failed")
        )
        let data = try P3DiagnosticExporter.makeReport(
            events: [event], generatedAt: Date(timeIntervalSince1970: 0))
        let report = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(report.contains(rawUUID))
        XCTAssertFalse(report.contains(rawIP))
        XCTAssertFalse(report.contains(rawPath))
        XCTAssertFalse(report.contains(rawDevice))
        XCTAssertTrue(report.contains(SessionErrorCode.netProtocolMismatch.rawValue))
    }

    func testTenSleepWakeCyclesRestartWithNewGenerations() async throws {
        let runner = CountingRunner()
        let service = P3HostService(runner: runner)
        let recorder = P3HostEventRecorder()
        await service.start(configuration: configuration()) { event in
            await recorder.append(event)
        }
        try await waitForRunCount(1, runner: runner)
        for expectedRunCount in 2...11 {
            await service.handlePowerEvent(.sleep)
            await service.handlePowerEvent(.wake)
            try await waitForRunCount(expectedRunCount, runner: runner)
        }
        let startingGenerations = await recorder.events
            .filter { $0.phase == .starting }
            .map(\.generation)
        XCTAssertEqual(startingGenerations.count, 11)
        XCTAssertEqual(Set(startingGenerations).count, 11)
        await service.stop()
    }

    private func waitForRunCount(
        _ expected: Int,
        runner: CountingRunner
    ) async throws {
        for _ in 0..<100 {
            if await runner.runCount == expected { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for runner invocation \(expected)")
    }

    private func configuration() -> P3HostConfiguration {
        P3HostConfiguration(identityData: Data([0]), identityPassword: "test")
    }

    private func waitForPhase(
        _ phase: P3HostPhase,
        recorder: P3HostEventRecorder
    ) async throws {
        for _ in 0..<100 {
            if await recorder.events.contains(where: { $0.phase == phase }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for \(phase.rawValue)")
    }
}

private final class AlternatingCursorProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0

    func next() -> CursorPositionSample {
        lock.withLock {
            sequence += 1
            return CursorPositionSample(
                normalizedX: Double(sequence % 100) / 100,
                normalizedY: 0.5,
                visible: true
            )
        }
    }
}

private actor CursorMessageRecorder {
    private(set) var messages: [CursorPositionMessage] = []
    var count: Int { messages.count }

    func append(_ message: CursorPositionMessage) {
        messages.append(message)
    }
}

private struct LateUpdateRunner: P3HostSessionRunning {
    func run(
        configuration: P3HostConfiguration,
        generation: UInt64,
        onUpdate: @escaping @Sendable (P3HostUpdate) async -> Void
    ) async throws {
        await onUpdate(P3HostUpdate(phase: .listening, message: "listening"))
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            await onUpdate(P3HostUpdate(phase: .streaming, message: "late callback"))
            throw CancellationError()
        }
    }
}

private actor RecoveringRunner: P3HostSessionRunning {
    private var attempt = 0

    func run(
        configuration: P3HostConfiguration,
        generation: UInt64,
        onUpdate: @escaping @Sendable (P3HostUpdate) async -> Void
    ) async throws {
        attempt += 1
        await onUpdate(P3HostUpdate(phase: .listening, message: "listening"))
        await onUpdate(P3HostUpdate(phase: .connected, message: "connected"))
        await onUpdate(
            P3HostUpdate(phase: .preparingDisplay, message: "display", displayID: 77))
        await onUpdate(
            P3HostUpdate(
                phase: .streaming,
                message: "streaming",
                displayID: 77,
                framesPerSecond: 60,
                bitrate: 12_000_000
            ))
        if attempt == 1 {
            throw P3RecoverableSessionFailure(
                error: SessionError(code: .netProtocolMismatch, detail: "network disconnected"),
                retainedDisplay: true,
                displayID: 77
            )
        }
        try await Task.sleep(for: .seconds(30))
    }
}

private actor CountingRunner: P3HostSessionRunning {
    private(set) var runCount = 0

    func run(
        configuration: P3HostConfiguration,
        generation: UInt64,
        onUpdate: @escaping @Sendable (P3HostUpdate) async -> Void
    ) async throws {
        runCount += 1
        await onUpdate(P3HostUpdate(phase: .listening, message: "listening"))
        try await Task.sleep(for: .seconds(30))
    }
}

private actor P3HostEventRecorder {
    private(set) var events: [P3HostEvent] = []

    func append(_ event: P3HostEvent) {
        events.append(event)
    }
}
