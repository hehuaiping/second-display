import Foundation
import SecondDisplayCore

public enum P3HostPhase: String, CaseIterable, Sendable {
    case stopped
    case starting
    case listening
    case connected
    case preparingDisplay
    case streaming
    case recovering
    case stopping
    case failed
}

public struct P3HostEvent: Equatable, Sendable {
    public let phase: P3HostPhase
    public let message: String
    public let generation: UInt64
    public let displayID: UInt32?
    public let deviceName: String?
    public let sessionID: String?
    public let encodedFrameCount: UInt64?
    public let droppedFrameCount: UInt64?
    public let streamWidth: Int?
    public let streamHeight: Int?
    public let framesPerSecond: Int?
    public let bitrate: Int?
    public let networkRTTMilliseconds: Double?
    public let videoQueueDepth: Int?
    public let recoveryCount: UInt64
    public let error: SessionError?

    public init(
        phase: P3HostPhase,
        message: String,
        generation: UInt64,
        displayID: UInt32? = nil,
        deviceName: String? = nil,
        sessionID: String? = nil,
        encodedFrameCount: UInt64? = nil,
        droppedFrameCount: UInt64? = nil,
        streamWidth: Int? = nil,
        streamHeight: Int? = nil,
        framesPerSecond: Int? = nil,
        bitrate: Int? = nil,
        networkRTTMilliseconds: Double? = nil,
        videoQueueDepth: Int? = nil,
        recoveryCount: UInt64 = 0,
        error: SessionError? = nil
    ) {
        self.phase = phase
        self.message = message
        self.generation = generation
        self.displayID = displayID
        self.deviceName = deviceName
        self.sessionID = sessionID
        self.encodedFrameCount = encodedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.networkRTTMilliseconds = networkRTTMilliseconds
        self.videoQueueDepth = videoQueueDepth
        self.recoveryCount = recoveryCount
        self.error = error
    }
}

public struct P3HostConfiguration: Sendable {
    public let identityData: Data
    public let identityPassword: String
    public let controlPort: UInt16
    public let videoPort: UInt16
    public let durationSeconds: UInt64?
    public let showsAnimatedTestPattern: Bool
    public let maximumFramesPerSecond: Int
    public let certificateFingerprint: String?
    public let bonjourServiceName: String

    public init(
        identityData: Data,
        identityPassword: String,
        controlPort: UInt16 = 52_340,
        videoPort: UInt16 = 52_341,
        durationSeconds: UInt64? = nil,
        showsAnimatedTestPattern: Bool = false,
        maximumFramesPerSecond: Int = 60,
        certificateFingerprint: String? = nil,
        bonjourServiceName: String = Host.current().localizedName ?? "Second Display Mac"
    ) {
        self.identityData = identityData
        self.identityPassword = identityPassword
        self.controlPort = controlPort
        self.videoPort = videoPort
        self.durationSeconds = durationSeconds.map { min(max($0, 1), 24 * 60 * 60) }
        self.showsAnimatedTestPattern = showsAnimatedTestPattern
        self.maximumFramesPerSecond = [120, 90, 60].first { $0 <= maximumFramesPerSecond } ?? 60
        self.certificateFingerprint = certificateFingerprint
        let trimmedName = bonjourServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bonjourServiceName = trimmedName.isEmpty ? "Second Display Mac" : trimmedName
    }
}

struct P3HostUpdate: Sendable {
    let phase: P3HostPhase
    let message: String
    var displayID: UInt32?
    var deviceName: String?
    var sessionID: String?
    var encodedFrameCount: UInt64?
    var droppedFrameCount: UInt64?
    var streamWidth: Int?
    var streamHeight: Int?
    var framesPerSecond: Int?
    var bitrate: Int?
    var networkRTTMilliseconds: Double?
    var videoQueueDepth: Int?
    var recoveryCount: UInt64 = 0
}

protocol P3HostSessionRunning: Sendable {
    func run(
        configuration: P3HostConfiguration,
        generation: UInt64,
        onUpdate: @escaping @Sendable (P3HostUpdate) async -> Void
    ) async throws
}

enum P3PowerEvent: Sendable {
    case sleep
    case wake
}

public actor P3HostService {
    public typealias EventHandler = @Sendable (P3HostEvent) async -> Void

    private let runner: any P3HostSessionRunning
    private let coordinator: SessionCoordinator
    private var generation: UInt64 = 0
    private var sessionTask: Task<Void, Never>?
    private var eventHandler: EventHandler?
    private var lastError: SessionError?
    private var activeConfiguration: P3HostConfiguration?
    private var desiredRunning = false
    private var powerMonitor: WorkspacePowerMonitor?

    public init() {
        runner = P3HostSessionRunner()
        coordinator = SessionCoordinator()
    }

    init(runner: any P3HostSessionRunning) {
        self.runner = runner
        coordinator = SessionCoordinator()
    }

    public func start(
        configuration: P3HostConfiguration,
        onEvent: @escaping EventHandler
    ) async {
        await stop()
        desiredRunning = true
        activeConfiguration = configuration
        eventHandler = onEvent
        await ensurePowerMonitor()
        await beginSession(configuration: configuration, onEvent: onEvent)
    }

    private func beginSession(
        configuration: P3HostConfiguration,
        onEvent: @escaping EventHandler
    ) async {
        let activeGeneration = await coordinator.begin()
        generation = activeGeneration
        lastError = nil
        eventHandler = onEvent
        await publish(
            P3HostUpdate(phase: .starting, message: "Preparing TLS listeners"),
            generation: activeGeneration
        )
        let runner = self.runner
        sessionTask = Task { [weak self] in
            var recoveryCount: UInt64 = 0
            let recoveryWindow = P3RecoveryWindow()
            do {
                while !Task.isCancelled {
                    let attemptGeneration = activeGeneration &* 1_000 &+ recoveryCount
                    let attemptRecoveryCount = recoveryCount
                    do {
                        try await runner.run(
                            configuration: configuration,
                            generation: attemptGeneration,
                            onUpdate: { [weak self] update in
                                var update = update
                                update.recoveryCount = attemptRecoveryCount
                                if update.phase == .streaming {
                                    await recoveryWindow.markStreaming()
                                }
                                await self?.publish(update, generation: activeGeneration)
                            }
                        )
                        break
                    } catch let recovery as P3RecoverableSessionFailure {
                        recoveryCount &+= 1
                        guard await recoveryWindow.beginOrContinueRecovery() else {
                            throw SessionError(
                                code: recovery.error.code,
                                detail: "Recovery exceeded 30 seconds: \(recovery.error.detail)"
                            )
                        }
                        await self?.publish(
                            P3HostUpdate(
                                phase: .recovering,
                                message: recovery.retainedDisplay
                                    ? "Connection lost · preserving display for up to 10 seconds"
                                    : "Session interrupted · rebuilding display",
                                displayID: recovery.displayID,
                                recoveryCount: recoveryCount
                            ),
                            generation: activeGeneration
                        )
                    }
                }
                try Task.checkCancellation()
                await self?.finish(generation: activeGeneration, error: nil)
            } catch is CancellationError {
                await self?.finish(generation: activeGeneration, error: nil)
            } catch let error as SessionError {
                await self?.finish(generation: activeGeneration, error: error)
            } catch {
                await self?.finish(
                    generation: activeGeneration,
                    error: SessionError(
                        code: .netProtocolMismatch,
                        detail: "Host service stopped unexpectedly"
                    )
                )
            }
        }
    }

    public func stop() async {
        desiredRunning = false
        activeConfiguration = nil
        if let powerMonitor {
            await MainActor.run { powerMonitor.stop() }
            self.powerMonitor = nil
        }
        let stoppedGeneration = await coordinator.beginStopping()
        generation = stoppedGeneration
        let task = sessionTask
        sessionTask = nil
        let handler = eventHandler
        if task != nil {
            await handler?(
                P3HostEvent(
                    phase: .stopping,
                    message: "Stopping service and releasing virtual display",
                    generation: stoppedGeneration
                )
            )
        }
        task?.cancel()
        _ = await task?.result
        lastError = nil
        await handler?(
            P3HostEvent(
                phase: .stopped,
                message: "Service stopped",
                generation: stoppedGeneration
            )
        )
        _ = await coordinator.completeStopping(generation: stoppedGeneration)
        eventHandler = nil
    }

    public func waitUntilInactive() async -> SessionError? {
        let task = sessionTask
        _ = await task?.result
        return lastError
    }

    public var isActive: Bool {
        sessionTask != nil
    }

    public var sessionState: SessionState {
        get async { await coordinator.state }
    }

    private func publish(_ update: P3HostUpdate, generation: UInt64) async {
        guard generation == self.generation,
            await advanceCoordinator(for: update.phase, generation: generation),
            let eventHandler
        else { return }
        await eventHandler(
            P3HostEvent(
                phase: update.phase,
                message: update.message,
                generation: generation,
                displayID: update.displayID,
                deviceName: update.deviceName,
                sessionID: update.sessionID,
                encodedFrameCount: update.encodedFrameCount,
                droppedFrameCount: update.droppedFrameCount,
                streamWidth: update.streamWidth,
                streamHeight: update.streamHeight,
                framesPerSecond: update.framesPerSecond,
                bitrate: update.bitrate,
                networkRTTMilliseconds: update.networkRTTMilliseconds,
                videoQueueDepth: update.videoQueueDepth,
                recoveryCount: update.recoveryCount
            )
        )
    }

    private func finish(generation: UInt64, error: SessionError?) async {
        guard generation == self.generation else { return }
        sessionTask = nil
        lastError = error
        desiredRunning = false
        activeConfiguration = nil
        if let powerMonitor {
            await MainActor.run { powerMonitor.stop() }
            self.powerMonitor = nil
        }
        guard let eventHandler else { return }
        if let error {
            guard await coordinator.fail(error, generation: generation) else { return }
            await eventHandler(
                P3HostEvent(
                    phase: .failed,
                    message: error.errorDescription ?? error.code.rawValue,
                    generation: generation,
                    error: error
                )
            )
        } else {
            guard await coordinator.transition(to: .stopping, generation: generation) else { return }
            await eventHandler(
                P3HostEvent(
                    phase: .stopped,
                    message: "Service stopped",
                    generation: generation
                )
            )
            _ = await coordinator.completeStopping(generation: generation)
        }
    }

    private func advanceCoordinator(for phase: P3HostPhase, generation: UInt64) async -> Bool {
        switch phase {
        case .starting:
            return await coordinator.state == .checkingCapability
        case .listening:
            return await coordinator.transition(to: .waitingForReceiver, generation: generation)
        case .connected:
            return await coordinator.transition(to: .creatingVirtualDisplay, generation: generation)
        case .preparingDisplay:
            return await coordinator.transition(to: .waitingForDisplayEnumeration, generation: generation)
        case .streaming:
            if await coordinator.state == .streaming { return true }
            guard await coordinator.transition(to: .stabilizingDisplayMode, generation: generation),
                await coordinator.transition(to: .startingCapture, generation: generation),
                await coordinator.transition(to: .startingEncoder, generation: generation)
            else { return false }
            return await coordinator.transition(to: .streaming, generation: generation)
        case .recovering:
            return await coordinator.transition(
                to: .recovering(attempt: 1), generation: generation)
        case .stopping:
            return await coordinator.transition(to: .stopping, generation: generation)
        case .stopped:
            return await coordinator.state == .idle
        case .failed:
            return true
        }
    }

    private func ensurePowerMonitor() async {
        guard powerMonitor == nil else { return }
        powerMonitor = await MainActor.run {
            let monitor = WorkspacePowerMonitor(
                onSleep: { [weak self] in Task { await self?.handlePowerEvent(.sleep) } },
                onWake: { [weak self] in Task { await self?.handlePowerEvent(.wake) } }
            )
            monitor.start()
            return monitor
        }
    }

    func handlePowerEvent(_ event: P3PowerEvent) async {
        switch event {
        case .sleep:
            await suspendForSleep()
        case .wake:
            await resumeAfterWake()
        }
    }

    private func suspendForSleep() async {
        guard desiredRunning, sessionTask != nil else { return }
        let suspendedGeneration = await coordinator.beginStopping()
        generation = suspendedGeneration
        let task = sessionTask
        sessionTask = nil
        await eventHandler?(
            P3HostEvent(
                phase: .recovering,
                message: "Mac is sleeping · media objects will be rebuilt after wake",
                generation: suspendedGeneration,
                recoveryCount: 1
            )
        )
        task?.cancel()
        _ = await task?.result
        _ = await coordinator.completeStopping(generation: suspendedGeneration)
    }

    private func resumeAfterWake() async {
        guard desiredRunning, sessionTask == nil,
            let activeConfiguration, let eventHandler
        else { return }
        await beginSession(configuration: activeConfiguration, onEvent: eventHandler)
    }
}

private actor P3RecoveryWindow {
    private var startedAt: ContinuousClock.Instant?

    func markStreaming() {
        startedAt = nil
    }

    func beginOrContinueRecovery() -> Bool {
        let now = ContinuousClock.now
        guard let startedAt else {
            self.startedAt = now
            return true
        }
        return now - startedAt < .seconds(30)
    }
}
