import AppKit
import CapturePipeline
import CryptoKit
import Foundation
import Network
import SecondDisplayCore
import SharedProtocol
import TransportCore
import VirtualDisplayCore

final class P3HostSessionRunner: P3HostSessionRunning, @unchecked Sendable {
    private let leaseLock = NSLock()
    private var storedDisplayLease: P3DisplayLease?
    private let adaptationLock = NSLock()
    private var resolutionScalesByDeviceID: [String: Double] = [:]
    private var refreshRatesByDeviceID: [String: Int] = [:]
    private var refreshRateCeilingsByDeviceID: [String: Int] = [:]

    init() {}

    func run(
        configuration: P3HostConfiguration,
        generation: UInt64,
        onUpdate: @escaping @Sendable (P3HostUpdate) async -> Void
    ) async throws {
        try Task.checkCancellation()
        let identity = try TLSIdentityLoader.loadPKCS12(
            data: configuration.identityData,
            password: configuration.identityPassword
        )
        let advertisedFingerprint = try
            configuration.certificateFingerprint
            ?? TLSIdentityLoader.certificateSHA256Fingerprint(identity: identity)
        guard let controlPort = NWEndpoint.Port(rawValue: configuration.controlPort),
            let videoPort = NWEndpoint.Port(rawValue: configuration.videoPort)
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Listener ports are invalid")
        }

        let controlListener = try NWTransportListener(
            port: controlPort,
            parameters: try TLSNetworkParameters.server(identity: identity)
        )
        let videoListener = try NWTransportListener(
            port: videoPort,
            parameters: try TLSNetworkParameters.server(identity: identity)
        )
        let displayLease = await persistentDisplayLease()
        let mediaMetrics = MediaPipelineMetrics()
        let capture = ScreenCaptureService(metrics: mediaMetrics)
        let pipeline = CaptureEncoderPipeline(videoEncoder: H264EncoderService(), metrics: mediaMetrics)
        let lifecycle = P3SessionLifecycle()
        let frameCounter = P3FrameCounter()
        let heartbeat = HeartbeatMonitor(
            intervalNanoseconds: 1_000_000_000,
            timeoutMicroseconds: 3_000_000
        )
        let cursorSideChannel = CursorSideChannel()
        let inputInjector = InputInjector()
        let receiverFeedback = P3ReceiverFeedbackStore()
        let networkPathState = P3NetworkPathState(sessionGeneration: generation)
        let networkPathObserver = NetworkPathObserver()
        networkPathObserver.start { snapshot in
            Task {
                let changed = await networkPathState.accept(
                    snapshot,
                    sessionGeneration: generation
                )
                if changed {
                    await lifecycle.fail(
                        SessionError(
                            code: .netProtocolMismatch,
                            detail: "Network interface changed; performing fast path migration"
                        )
                    )
                }
            }
        }
        defer { networkPathObserver.stop() }
        var controlChannel: ControlChannel?
        var videoChannel: VideoChannel?
        var controlConnection: (any ByteTransportConnection)?
        var videoConnection: (any ByteTransportConnection)?
        var displayObserver: DisplayReconfigurationObserver?
        var displayObserverTask: Task<Void, Never>?

        do {
            // 两个端口先进入 ready，再发布控制端口对应的 DNS-SD 服务，避免发现后连接到半启动服务。
            try await videoListener.start()
            try await controlListener.start()
            let codecs = VideoEncoderCapability.supportsHardwareHEVC
                ? ["h264", "hevc"] : ["h264"]
            let service = try SecondDisplayBonjourService(
                name: configuration.bonjourServiceName,
                controlPort: configuration.controlPort,
                videoPort: configuration.videoPort,
                certificateFingerprint: advertisedFingerprint,
                capabilities: codecs
            )
            try await controlListener.advertise(service)
            await onUpdate(
                P3HostUpdate(
                    phase: .listening,
                    message:
                        "Discoverable on the local network · TLS \(configuration.controlPort)/\(configuration.videoPort)"
                )
            )
            async let acceptedControl = controlListener.accept()
            async let acceptedVideo = videoListener.accept()
            let accepted = try await (acceptedControl, acceptedVideo)
            // 单设备 MVP 在占用状态不继续广播，避免其他接收端连接后才发现服务忙。
            controlListener.stopAdvertising()
            controlConnection = accepted.0
            videoConnection = accepted.1
            try Task.checkCancellation()

            let controlStartTask = startConnection(
                accepted.0,
                label: "Control",
                lifecycle: lifecycle
            )
            let videoStartTask = startConnection(
                accepted.1,
                label: "Video",
                lifecycle: lifecycle
            )
            let hello = try await receiveClientHello(connection: accepted.0)
            try Task.checkCancellation()
            await onUpdate(
                P3HostUpdate(
                    phase: .connected,
                    message: "HarmonyOS receiver connected",
                    deviceName: hello.deviceName
                )
            )

            let sessionID = UUID().uuidString
            let deviceID = Self.stableDeviceID(from: hello.deviceId)
            let orientation: VirtualDisplayOrientation =
                hello.orientation == .portrait ? .portrait : .landscape
            let supportedCodecs = Self.preferredLowLatencyCodecs(
                supportsHardwareHEVC: VideoEncoderCapability.supportsHardwareHEVC)
            let resolutionScale = currentResolutionScale(for: hello.deviceId)
            let preferredDimensions = Self.scaledDimensions(
                width: hello.nativeWidth,
                height: hello.nativeHeight,
                scale: resolutionScale
            )
            let preferredWidth = preferredDimensions.width
            let preferredHeight = preferredDimensions.height
            let preferredFramesPerSecond =
                configuration.allowsAdaptiveHighRefreshRate
                ? currentRefreshRate(
                    for: hello.deviceId,
                    maximumFramesPerSecond: min(
                        configuration.maximumFramesPerSecond, hello.maxFps)
                )
                : configuration.maximumFramesPerSecond
            var negotiator = ServerHandshakeNegotiator(
                preferredWidth: preferredWidth,
                preferredHeight: preferredHeight,
                preferredFramesPerSecond: preferredFramesPerSecond,
                supportedCodecs: supportedCodecs,
                supportedTransports: [.tlsTCP]
            )
            let proposedReady = try negotiator.negotiate(
                hello,
                sessionId: sessionID,
                serialNumber: 1
            )
            let displayCreation = try await displayLease.create(
                framebufferWidth: proposedReady.display.framebufferWidth,
                framebufferHeight: proposedReady.display.framebufferHeight,
                preferredRefreshRate: proposedReady.display.refreshRate,
                deviceID: deviceID,
                orientation: orientation
            )
            if displayCreation.refreshRate != proposedReady.display.refreshRate {
                negotiator = ServerHandshakeNegotiator(
                    preferredWidth: preferredWidth,
                    preferredHeight: preferredHeight,
                    preferredFramesPerSecond: displayCreation.refreshRate,
                    supportedCodecs: supportedCodecs,
                    supportedTransports: [.tlsTCP]
                )
            }
            if configuration.allowsAdaptiveHighRefreshRate {
                if displayCreation.refreshRate < proposedReady.display.refreshRate {
                    setRefreshRateCeiling(
                        displayCreation.refreshRate,
                        for: hello.deviceId
                    )
                }
                setRefreshRate(displayCreation.refreshRate, for: hello.deviceId)
            }
            let handle = displayCreation.handle
            let createdDisplayObserver = try DisplayReconfigurationObserver(generation: generation)
            displayObserver = createdDisplayObserver
            displayObserverTask = Task {
                for await event in createdDisplayObserver.events {
                    guard event.belongs(to: generation), event.displayID == handle.displayID else {
                        continue
                    }
                    if event.kinds.contains(.removed) {
                        await lifecycle.fail(
                            SessionError(
                                code: .vdTerminatedBySystem,
                                detail: "Virtual display was removed by the system"
                            )
                        )
                        return
                    }
                }
            }
            let ready = try negotiator.negotiate(
                hello,
                sessionId: sessionID,
                serialNumber: handle.identity.serialNumber
            )
            let usesCursorSideChannel = hello.features.contains(.cursorSideChannelV1)
            await inputInjector.begin(sessionID: ready.sessionId, displayID: handle.displayID)
            await onUpdate(
                P3HostUpdate(
                    phase: .preparingDisplay,
                    message: "Preparing virtual display \(handle.displayID)",
                    displayID: handle.displayID,
                    deviceName: hello.deviceName,
                    sessionID: ready.sessionId
                )
            )

            let createdVideoChannel = VideoChannel(
                connection: accepted.1,
                queue: BoundedVideoSendQueue(maximumFrames: 1)
            )
            videoChannel = createdVideoChannel
            try await createdVideoChannel.start(
                generation: generation,
                startConnection: false,
                onFailure: { error in await lifecycle.fail(error) }
            )

            let createdControlChannel = ControlChannel(connection: accepted.0)
            controlChannel = createdControlChannel
            try await createdControlChannel.start(
                generation: generation,
                startConnection: false,
                onMessage: { message in
                    switch message {
                    case .heartbeatAck(let acknowledgement):
                        await heartbeat.acknowledge(acknowledgement, generation: generation)
                    case .requestKeyFrame(let request) where request.sessionId == ready.sessionId:
                        await pipeline.requestKeyFrame()
                    case .receiverFeedback(let feedback)
                    where feedback.sessionId == ready.sessionId:
                        await receiverFeedback.accept(feedback)
                    case .inputEvent(let input) where input.sessionId == ready.sessionId:
                        do {
                            try await inputInjector.handle(input)
                        } catch let error as SessionError where error.code == .inputPermissionDenied {
                            // Display-only sessions remain valid. The app exposes
                            // the Accessibility action without failing streaming.
                            break
                        } catch let error as SessionError {
                            await lifecycle.fail(error)
                        } catch {
                            await lifecycle.fail(
                                SessionError(
                                    code: .netProtocolMismatch,
                                    detail: "Input event injection failed"
                                ))
                        }
                    case .gestureEvent(let gesture) where gesture.sessionId == ready.sessionId:
                        do {
                            try await inputInjector.handle(gesture)
                        } catch let error as SessionError where error.code == .inputPermissionDenied {
                            break
                        } catch let error as SessionError {
                            await lifecycle.fail(error)
                        } catch {
                            await lifecycle.fail(
                                SessionError(
                                    code: .netProtocolMismatch,
                                    detail: "Gesture injection failed"
                                ))
                        }
                    case .heartbeat(let request) where request.sessionId == ready.sessionId:
                        let acknowledgement = HeartbeatAck(
                            sessionId: request.sessionId,
                            sequence: request.sequence,
                            sentAtUs: request.sentAtUs,
                            receivedAtUs: SystemTransportClock().nowMicroseconds()
                        )
                        do {
                            try await createdControlChannel.send(acknowledgement)
                        } catch let error as SessionError {
                            await lifecycle.fail(error)
                        } catch {
                            await lifecycle.fail(
                                SessionError(
                                    code: .netProtocolMismatch,
                                    detail: "Heartbeat acknowledgement failed"
                                )
                            )
                        }
                    default:
                        break
                    }
                },
                onFailure: { error in await lifecycle.fail(error) }
            )
            try await createdControlChannel.send(ready)
            await heartbeat.start(
                sessionId: ready.sessionId,
                generation: generation,
                send: { try await createdControlChannel.send($0) },
                onTimeout: { await lifecycle.fail($0) }
            )

            let display = try await capture.waitForDisplay(
                id: handle.displayID,
                generation: generation,
                timeoutNanoseconds: 15_000_000_000,
                isCurrentGeneration: { candidate in
                    guard candidate == generation else { return false }
                    return await lifecycle.isRunning
                }
            )
            if configuration.showsAnimatedTestPattern {
                try await displayLease.startTestPattern(
                    displayID: handle.displayID,
                    framesPerSecond: ready.stream.fps
                )
            }
            let captureSpec = try CaptureSpec(
                width: ready.stream.width,
                height: ready.stream.height,
                framesPerSecond: ready.stream.fps,
                queueDepth: 3,
                showsCursor: !usesCursorSideChannel
            )
            let frames = try await capture.start(
                display: display,
                configuration: captureSpec,
                generation: generation
            )
            let encoderSpec = try EncoderSpec(
                width: ready.stream.width,
                height: ready.stream.height,
                framesPerSecond: ready.stream.fps,
                bitrate: ready.stream.bitrate,
                codec: ready.stream.codec == .hevc ? .hevc : .h264
            )
            try await pipeline.start(
                frames: frames,
                encoderConfiguration: encoderSpec,
                generation: generation,
                isCurrentGeneration: { candidate in
                    guard candidate == generation else { return false }
                    return await lifecycle.isRunning
                },
                onEncodedFrame: { encoded in
                    guard await frameCounter.recordEncodedFrame(isKeyFrame: encoded.isKeyFrame) else {
                        throw SessionError(
                            code: .encBackpressure,
                            detail: "First frame after session start was not an IDR"
                        )
                    }
                    let frame = VideoFrame(
                        frameType: .video,
                        flags: encoded.isKeyFrame ? [.keyframe] : [],
                        sequence: encoded.sequence,
                        ptsUs: encoded.presentationTimeStampUs,
                        captureUs: encoded.captureTimestampUs,
                        payload: encoded.payload,
                        preframedData: encoded.preframedData
                    )
                    let result = await createdVideoChannel.send(frame)
                    if result.requiresKeyFrame { await pipeline.requestKeyFrame() }
                },
                onFailure: { [self] error in await lifecycle.fail(map(error)) }
            )
            if usesCursorSideChannel {
                await cursorSideChannel.start(
                    sessionId: ready.sessionId,
                    displayID: handle.displayID,
                    sessionGeneration: generation,
                    isCurrentGeneration: { candidate in
                        guard candidate == generation else { return false }
                        return await lifecycle.isRunning
                    },
                    send: { try await createdControlChannel.send($0) },
                    onFailure: { await lifecycle.fail($0) }
                )
            }
            _ = await controlStartTask.result
            _ = await videoStartTask.result
            try Task.checkCancellation()
            await onUpdate(
                P3HostUpdate(
                    phase: .streaming,
                    message:
                        "Streaming \(ready.stream.width)×\(ready.stream.height) at \(ready.stream.fps) fps",
                    displayID: handle.displayID,
                    deviceName: hello.deviceName,
                    sessionID: ready.sessionId,
                    encodedFrameCount: 0,
                    droppedFrameCount: 0,
                    streamWidth: ready.stream.width,
                    streamHeight: ready.stream.height,
                    framesPerSecond: ready.stream.fps,
                    bitrate: ready.stream.bitrate,
                    networkRTTMilliseconds: nil,
                    videoQueueDepth: 0
                )
            )

            try await monitorSession(
                configuration: configuration,
                lifecycle: lifecycle,
                pipeline: pipeline,
                heartbeat: heartbeat,
                videoChannel: createdVideoChannel,
                frameCounter: frameCounter,
                displayID: handle.displayID,
                deviceName: hello.deviceName,
                sessionID: ready.sessionId,
                stream: ready.stream,
                deviceID: hello.deviceId,
                nativeWidth: hello.nativeWidth,
                nativeHeight: hello.nativeHeight,
                receiverMaximumFramesPerSecond: hello.maxFps,
                adaptiveMaximumFramesPerSecond: currentRefreshRateCeiling(
                    for: hello.deviceId,
                    configuredMaximum: min(
                        configuration.maximumFramesPerSecond,
                        hello.maxFps
                    )
                ),
                initialResolutionScale: resolutionScale,
                receiverFeedback: receiverFeedback,
                networkPathState: networkPathState,
                onUpdate: onUpdate
            )
        } catch is CancellationError {
            await cleanup(
                lifecycle: lifecycle,
                heartbeat: heartbeat,
                cursorSideChannel: cursorSideChannel,
                inputInjector: inputInjector,
                pipeline: pipeline,
                capture: capture,
                videoChannel: videoChannel,
                controlChannel: controlChannel,
                videoConnection: videoConnection,
                controlConnection: controlConnection,
                videoListener: videoListener,
                controlListener: controlListener,
                displayLease: displayLease,
                destroyDisplay: true,
                displayObserver: displayObserver,
                displayObserverTask: displayObserverTask
            )
            throw CancellationError()
        } catch {
            let displayID = await displayLease.displayID
            let mappedError = map(error)
            let recoverable = displayID != nil && Self.isRecoverable(mappedError)
            let retainDisplay = recoverable && mappedError.code != .vdTerminatedBySystem
            await cleanup(
                lifecycle: lifecycle,
                heartbeat: heartbeat,
                cursorSideChannel: cursorSideChannel,
                inputInjector: inputInjector,
                pipeline: pipeline,
                capture: capture,
                videoChannel: videoChannel,
                controlChannel: controlChannel,
                videoConnection: videoConnection,
                controlConnection: controlConnection,
                videoListener: videoListener,
                controlListener: controlListener,
                displayLease: displayLease,
                destroyDisplay: !retainDisplay,
                displayObserver: displayObserver,
                displayObserverTask: displayObserverTask
            )
            if recoverable {
                if retainDisplay { await displayLease.retainForReconnect(seconds: 10) }
                throw P3RecoverableSessionFailure(
                    error: mappedError,
                    retainedDisplay: retainDisplay,
                    displayID: displayID
                )
            }
            throw mappedError
        }

        await cleanup(
            lifecycle: lifecycle,
            heartbeat: heartbeat,
            cursorSideChannel: cursorSideChannel,
            inputInjector: inputInjector,
            pipeline: pipeline,
            capture: capture,
            videoChannel: videoChannel,
            controlChannel: controlChannel,
            videoConnection: videoConnection,
            controlConnection: controlConnection,
            videoListener: videoListener,
            controlListener: controlListener,
            displayLease: displayLease,
            destroyDisplay: true,
            displayObserver: displayObserver,
            displayObserverTask: displayObserverTask
        )
    }

    private func startConnection(
        _ connection: any ByteTransportConnection,
        label: String,
        lifecycle: P3SessionLifecycle
    ) -> Task<Void, Never> {
        Task {
            do {
                try await connection.start()
            } catch is CancellationError {
                return
            } catch let error as SessionError {
                await lifecycle.fail(error)
            } catch {
                await lifecycle.fail(
                    SessionError(
                        code: .netProtocolMismatch,
                        detail: "\(label) TLS handshake failed"
                    )
                )
            }
        }
    }

    private func receiveClientHello(
        connection: any ByteTransportConnection
    ) async throws -> ClientHello {
        var parser = IncrementalControlFrameParser()
        while !Task.isCancelled {
            guard let bytes = try await connection.receive(maximumLength: 64 * 1024) else {
                try parser.finish()
                throw SessionError(
                    code: .netProtocolMismatch,
                    detail: "Control closed before clientHello"
                )
            }
            for message in try parser.append(bytes) {
                if case .clientHello(let hello) = message { return hello }
                throw SessionError(code: .netProtocolMismatch, detail: "Expected clientHello")
            }
        }
        throw CancellationError()
    }

    private func monitorSession(
        configuration: P3HostConfiguration,
        lifecycle: P3SessionLifecycle,
        pipeline: CaptureEncoderPipeline,
        heartbeat: HeartbeatMonitor,
        videoChannel: VideoChannel,
        frameCounter: P3FrameCounter,
        displayID: UInt32,
        deviceName: String,
        sessionID: String,
        stream: StreamConfiguration,
        deviceID: String,
        nativeWidth: Int,
        nativeHeight: Int,
        receiverMaximumFramesPerSecond: Int,
        adaptiveMaximumFramesPerSecond: Int,
        initialResolutionScale: Double,
        receiverFeedback: P3ReceiverFeedbackStore,
        networkPathState: P3NetworkPathState,
        onUpdate: @escaping @Sendable (P3HostUpdate) async -> Void
    ) async throws {
        var tick: UInt64 = 0
        var adaptation = NetworkAdaptiveController(
            baseBitrate: stream.bitrate,
            initialResolutionScale: initialResolutionScale
        )
        var frameRateAdaptation =
            configuration.allowsAdaptiveHighRefreshRate
            ? FrameRateAdaptiveController(
                currentFramesPerSecond: stream.fps,
                maximumFramesPerSecond: min(
                    adaptiveMaximumFramesPerSecond,
                    min(
                        configuration.maximumFramesPerSecond,
                        receiverMaximumFramesPerSecond
                    )
                )
            )
            : nil
        var lastReceiverDroppedFrames: UInt64 = 0
        var lastHostDroppedFrames: UInt64 = 0
        var lastObservedEncodedFrameCount: UInt64 = 0
        var lastAdaptationSampleTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        while true {
            if let durationSeconds = configuration.durationSeconds,
                tick >= durationSeconds * 10
            {
                break
            }
            try Task.checkCancellation()
            if let failure = await lifecycle.failure { throw failure }
            if tick > 0, tick % 10 == 0 {
                let metrics = await pipeline.metricsSnapshot()
                let encodedFrameCount = await frameCounter.encodedFrameCount
                let adaptationSampleTimestampNanoseconds =
                    DispatchTime.now().uptimeNanoseconds
                let adaptationSampleDurationNanoseconds = max(
                    1,
                    adaptationSampleTimestampNanoseconds
                        >= lastAdaptationSampleTimestampNanoseconds
                        ? adaptationSampleTimestampNanoseconds
                            - lastAdaptationSampleTimestampNanoseconds : 1)
                let encodedFramesDelta =
                    encodedFrameCount >= lastObservedEncodedFrameCount
                    ? encodedFrameCount - lastObservedEncodedFrameCount : 0
                let senderFramesPerSecond =
                    Double(encodedFramesDelta) * 1_000_000_000
                    / Double(adaptationSampleDurationNanoseconds)
                lastObservedEncodedFrameCount = encodedFrameCount
                lastAdaptationSampleTimestampNanoseconds =
                    adaptationSampleTimestampNanoseconds
                let networkRTTMilliseconds = await heartbeat.currentRTTMilliseconds
                let videoQueue = await videoChannel.queueSnapshot()
                let feedback = await receiverFeedback.latest
                let networkInterface = await networkPathState.kind.rawValue
                let receiverDroppedDelta: UInt64
                if let feedback {
                    receiverDroppedDelta =
                        feedback.droppedFrames >= lastReceiverDroppedFrames
                        ? feedback.droppedFrames - lastReceiverDroppedFrames
                        : 0
                    lastReceiverDroppedFrames = feedback.droppedFrames
                } else {
                    receiverDroppedDelta = 0
                }
                let hostDroppedFrames =
                    metrics.captureDropCount + metrics.encodeDropCount + metrics.sendDropCount
                let hostDroppedDelta =
                    hostDroppedFrames >= lastHostDroppedFrames
                    ? hostDroppedFrames - lastHostDroppedFrames
                    : 0
                lastHostDroppedFrames = hostDroppedFrames
                let adaptationSample = NetworkAdaptationSample(
                    roundTripMilliseconds: networkRTTMilliseconds,
                    senderQueueDepth: videoQueue.depth,
                    receiverQueueDepth: feedback?.decoderQueueDepth ?? 0,
                    droppedFramesDelta: receiverDroppedDelta,
                    renderedFramesPerSecond: feedback.flatMap {
                        $0.renderedFramesPerSecond > 0 ? $0.renderedFramesPerSecond : nil
                    },
                    senderFramesPerSecond: senderFramesPerSecond,
                    targetFramesPerSecond: stream.fps
                )
                if let decision = adaptation.observe(adaptationSample) {
                    try await pipeline.setNetworkBitrateCeiling(decision.bitrateCeiling)
                    let candidateDimensions = Self.scaledDimensions(
                        width: nativeWidth,
                        height: nativeHeight,
                        scale: decision.resolutionScale
                    )
                    if decision.requiresStreamRebuild
                        && (candidateDimensions.width != stream.width
                            || candidateDimensions.height != stream.height)
                    {
                        setResolutionScale(decision.resolutionScale, for: deviceID)
                        throw SessionError(
                            code: .encBackpressure,
                            detail:
                                "Adaptive resolution rebuild requested after \(decision.reason)"
                        )
                    }
                }
                if let frameRateDecision = frameRateAdaptation?.observe(
                    FrameRateAdaptationSample(
                        videoToolboxP95Milliseconds: metrics.videoToolboxP95Milliseconds,
                        encodeP95Milliseconds: metrics.encodeP95Milliseconds,
                        senderQueueDepth: videoQueue.depth,
                        receiverQueueDepth: feedback?.decoderQueueDepth ?? 0,
                        droppedFramesDelta: hostDroppedDelta &+ receiverDroppedDelta,
                        renderedFramesPerSecond: feedback.flatMap {
                            $0.renderedFramesPerSecond > 0
                                ? $0.renderedFramesPerSecond : nil
                        },
                        hardwareAccelerated: metrics.encoderHardwareAccelerated == true,
                        lowLatencyRateControlEnabled:
                            metrics.lowLatencyRateControlEnabled == true,
                        thermalConstrained: Self.isThermallyConstrained,
                        contentIsActive: metrics.contentActivity == .active,
                        fullResolution: adaptation.currentResolutionScale >= 0.999,
                        hasSufficientSamples:
                            metrics.encodedFrameCount >= UInt64(stream.fps * 5),
                        roundTripMilliseconds: networkRTTMilliseconds
                    )
                ), frameRateDecision.framesPerSecond != stream.fps {
                    setRefreshRate(frameRateDecision.framesPerSecond, for: deviceID)
                    throw SessionError(
                        code: .encBackpressure,
                        detail:
                            "Adaptive frame-rate rebuild requested after "
                            + frameRateDecision.reason
                    )
                }
                let dropCount = hostDroppedFrames
                let encoderPath =
                    metrics.encoderHardwareAccelerated.map { $0 ? "HW" : "SW" } ?? "unknown"
                let lowLatencyMode =
                    metrics.lowLatencyRateControlEnabled.map { $0 ? "on" : "off" } ?? "unknown"
                let activity =
                    metrics.contentActivity == .active ? "active" : "static"
                let metricsFormat =
                    "Streaming %d×%d %@ at %d fps · drops C/E/S %llu/%llu/%llu · "
                    + "p95 cap %.1f q %.1f VT %.1f pack %.1f enc %.1f send %.1f ms · "
                    + "dirty %.1f%% %@ %.1f Mbps · %@ LL %@ · net %@"
                await onUpdate(
                    P3HostUpdate(
                        phase: .streaming,
                        message: String(
                            format: metricsFormat,
                            stream.width,
                            stream.height,
                            stream.codec.rawValue.uppercased(),
                            stream.fps,
                            metrics.captureDropCount,
                            metrics.encodeDropCount,
                            metrics.sendDropCount,
                            metrics.captureDeliveryP95Milliseconds,
                            metrics.encodeQueueP95Milliseconds,
                            metrics.videoToolboxP95Milliseconds,
                            metrics.bitstreamConversionP95Milliseconds,
                            metrics.encodeP95Milliseconds,
                            metrics.sendQueueP95Milliseconds,
                            metrics.dirtyAreaP95Percent,
                            activity,
                            Double(metrics.currentBitrate) / 1_000_000,
                            encoderPath,
                            lowLatencyMode,
                            networkInterface
                        ),
                        displayID: displayID,
                        deviceName: deviceName,
                        sessionID: sessionID,
                        encodedFrameCount: encodedFrameCount,
                        droppedFrameCount: dropCount,
                        streamWidth: stream.width,
                        streamHeight: stream.height,
                        framesPerSecond: stream.fps,
                        bitrate: metrics.currentBitrate,
                        networkRTTMilliseconds: networkRTTMilliseconds,
                        videoQueueDepth: videoQueue.depth
                    )
                )
            }
            tick &+= 1
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let failure = await lifecycle.failure { throw failure }
    }

    private func cleanup(
        lifecycle: P3SessionLifecycle,
        heartbeat: HeartbeatMonitor,
        cursorSideChannel: CursorSideChannel,
        inputInjector: InputInjector,
        pipeline: CaptureEncoderPipeline,
        capture: ScreenCaptureService,
        videoChannel: VideoChannel?,
        controlChannel: ControlChannel?,
        videoConnection: (any ByteTransportConnection)?,
        controlConnection: (any ByteTransportConnection)?,
        videoListener: NWTransportListener,
        controlListener: NWTransportListener,
        displayLease: P3DisplayLease,
        destroyDisplay: Bool,
        displayObserver: DisplayReconfigurationObserver?,
        displayObserverTask: Task<Void, Never>?
    ) async {
        await lifecycle.stop()
        displayObserverTask?.cancel()
        displayObserver?.stop()
        await inputInjector.end()
        await heartbeat.stop()
        await cursorSideChannel.stop()
        await pipeline.stop()
        await capture.stop()
        if let videoChannel { await videoChannel.stop() }
        if let controlChannel { await controlChannel.stop() }
        if let videoConnection { await videoConnection.cancel() }
        if let controlConnection { await controlConnection.cancel() }
        videoListener.cancel()
        controlListener.cancel()
        if destroyDisplay { await displayLease.destroy() }
    }

    private func map(_ error: Error) -> SessionError {
        if let error = error as? SessionError { return error }
        return SessionError(code: .capStreamStopped, detail: "Media pipeline stopped")
    }

    private func persistentDisplayLease() async -> P3DisplayLease {
        if let existing = leaseLock.withLock({ storedDisplayLease }) { return existing }
        let created = await MainActor.run { P3DisplayLease() }
        return leaseLock.withLock {
            if let existing = storedDisplayLease { return existing }
            storedDisplayLease = created
            return created
        }
    }

    static func preferredLowLatencyCodecs(supportsHardwareHEVC: Bool) -> [VideoCodec] {
        // 当前 Apple Silicon 实测 H.264 的 P95/P99 编码延迟低于 HEVC。
        // HEVC 仍保留为回退能力，但桌面交互链路优先选择更低尾延迟的 H.264。
        supportsHardwareHEVC ? [.h264, .hevc] : [.h264]
    }

    private func currentResolutionScale(for deviceID: String) -> Double {
        adaptationLock.withLock { resolutionScalesByDeviceID[deviceID] ?? 1 }
    }

    private func setResolutionScale(_ scale: Double, for deviceID: String) {
        adaptationLock.withLock {
            resolutionScalesByDeviceID[deviceID] = scale
        }
    }

    private func currentRefreshRate(
        for deviceID: String,
        maximumFramesPerSecond: Int
    ) -> Int {
        adaptationLock.withLock {
            let stored = refreshRatesByDeviceID[deviceID] ?? 60
            let ceiling =
                refreshRateCeilingsByDeviceID[deviceID]
                ?? maximumFramesPerSecond
            return [120, 90, 60].first {
                $0 <= stored && $0 <= maximumFramesPerSecond && $0 <= ceiling
            } ?? 60
        }
    }

    private func setRefreshRate(_ framesPerSecond: Int, for deviceID: String) {
        guard [60, 90, 120].contains(framesPerSecond) else { return }
        adaptationLock.withLock {
            refreshRatesByDeviceID[deviceID] = framesPerSecond
        }
    }

    private func currentRefreshRateCeiling(
        for deviceID: String,
        configuredMaximum: Int
    ) -> Int {
        adaptationLock.withLock {
            min(
                configuredMaximum,
                refreshRateCeilingsByDeviceID[deviceID] ?? configuredMaximum
            )
        }
    }

    private func setRefreshRateCeiling(_ framesPerSecond: Int, for deviceID: String) {
        guard [60, 90, 120].contains(framesPerSecond) else { return }
        adaptationLock.withLock {
            refreshRateCeilingsByDeviceID[deviceID] = min(
                refreshRateCeilingsByDeviceID[deviceID] ?? 120,
                framesPerSecond
            )
        }
    }

    private static var isThermallyConstrained: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            true
        default:
            false
        }
    }

    static func scaledDimensions(
        width: Int,
        height: Int,
        scale: Double
    ) -> (width: Int, height: Int) {
        let boundedScale = min(max(scale.isFinite ? scale : 1, 0.1), 1)
        let shortEdge = max(1, min(width, height))
        let longEdge = max(1, max(width, height))
        let minimumScale = max(
            1_200 / Double(shortEdge),
            1_600 / Double(longEdge)
        )
        let effectiveScale = min(max(boundedScale, minimumScale), 1)
        func evenDimension(_ value: Int) -> Int {
            min(value, max(2, Int(ceil(Double(value) * effectiveScale / 2)) * 2))
        }
        return (evenDimension(width), evenDimension(height))
    }

    private static func stableDeviceID(from value: String) -> UUID {
        if let uuid = UUID(uuidString: value) { return uuid }
        var bytes = Array(SHA256.hash(data: Data(value.utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    private static func isRecoverable(_ error: SessionError) -> Bool {
        switch error.code {
        case .netProtocolMismatch, .capStreamStopped, .encCreateFailed, .encBackpressure,
            .vdTerminatedBySystem:
            return true
        default:
            return false
        }
    }
}

struct P3RecoverableSessionFailure: Error, Sendable {
    let error: SessionError
    let retainedDisplay: Bool
    let displayID: UInt32?
}

private actor P3SessionLifecycle {
    private(set) var failure: SessionError?
    private(set) var isRunning = true

    func fail(_ error: SessionError) {
        guard isRunning, failure == nil else { return }
        failure = error
    }

    func stop() {
        isRunning = false
    }
}

private actor P3FrameCounter {
    private(set) var encodedFrameCount: UInt64 = 0

    func recordEncodedFrame(isKeyFrame: Bool) -> Bool {
        guard encodedFrameCount > 0 || isKeyFrame else { return false }
        encodedFrameCount &+= 1
        return true
    }
}

private actor P3ReceiverFeedbackStore {
    private(set) var latest: ReceiverFeedback?

    func accept(_ feedback: ReceiverFeedback) {
        if let latest, feedback.sequence <= latest.sequence { return }
        latest = feedback
    }
}

private actor P3NetworkPathState {
    private let sessionGeneration: UInt64
    private(set) var kind: NetworkInterfaceKind = .unavailable
    private var hasObservedUsablePath = false

    init(sessionGeneration: UInt64) {
        self.sessionGeneration = sessionGeneration
    }

    func accept(
        _ snapshot: NetworkPathSnapshot,
        sessionGeneration candidate: UInt64
    ) -> Bool {
        guard candidate == sessionGeneration else { return false }
        let previous = kind
        kind = snapshot.kind
        guard snapshot.kind != .unavailable else { return false }
        if !hasObservedUsablePath {
            hasObservedUsablePath = true
            return false
        }
        return previous != .unavailable && previous != snapshot.kind
    }
}

@MainActor
private final class P3DisplayLease {
    private let provider = CGVirtualDisplayProvider()
    private var handle: VirtualDisplayHandle?
    private var testPattern: P3AnimatedTestPattern?
    private var activeRefreshRate: Int?
    private var activeDeviceID: UUID?
    private var activeOrientation: VirtualDisplayOrientation?
    private var retentionTask: Task<Void, Never>?

    var displayID: UInt32? { handle?.displayID }

    func create(
        framebufferWidth: Int,
        framebufferHeight: Int,
        preferredRefreshRate: Int,
        deviceID: UUID,
        orientation: VirtualDisplayOrientation
    ) async throws -> (handle: VirtualDisplayHandle, refreshRate: Int) {
        if let handle, let activeRefreshRate,
            Int(handle.framebufferSize.width) == framebufferWidth,
            Int(handle.framebufferSize.height) == framebufferHeight,
            activeRefreshRate == preferredRefreshRate,
            activeDeviceID == deviceID,
            activeOrientation == orientation
        {
            retentionTask?.cancel()
            retentionTask = nil
            return (handle, activeRefreshRate)
        }
        if handle != nil {
            await destroy()
        }
        guard framebufferWidth > 0, framebufferHeight > 0 else {
            throw SessionError(code: .vdApplyFailed, detail: "P3 display dimensions are invalid")
        }
        var lastError = SessionError(code: .vdApplyFailed, detail: "Virtual display creation failed")
        let refreshRates = [120, 90, 60].filter { $0 <= preferredRefreshRate }
        for refreshRate in refreshRates {
            let spec = try VirtualDisplaySpec(
                name: "HarmonyOS Second Display",
                deviceId: deviceID,
                orientation: orientation,
                framebufferWidth: framebufferWidth,
                framebufferHeight: framebufferHeight,
                refreshRate: Double(refreshRate),
                physicalWidthMM: 260,
                physicalHeightMM: 260 * Double(framebufferHeight) / Double(framebufferWidth)
            )
            for attempt in 0..<3 {
                try Task.checkCancellation()
                do {
                    let created = try provider.create(spec: spec)
                    handle = created
                    activeRefreshRate = refreshRate
                    activeDeviceID = deviceID
                    activeOrientation = orientation
                    retentionTask?.cancel()
                    retentionTask = nil
                    return (created, refreshRate)
                } catch let error as SessionError {
                    lastError = error
                    guard error.code == .vdApplyFailed else { throw error }
                    if attempt < 2 { try await Task.sleep(for: .seconds(2)) }
                } catch {
                    throw SessionError(code: .vdApplyFailed, detail: "Virtual display creation failed")
                }
            }
        }
        throw lastError
    }

    func startTestPattern(displayID: UInt32, framesPerSecond: Int) async throws {
        guard let handle, handle.displayID == displayID else {
            throw SessionError(code: .vdApplyFailed, detail: "P3 display lease is not ready")
        }
        if testPattern != nil { return }
        guard [60, 90, 120].contains(framesPerSecond) else {
            throw SessionError(code: .vdApplyFailed, detail: "P3 test pattern frame rate is invalid")
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var targetScreen: NSScreen?
        while ContinuousClock.now < deadline, targetScreen == nil {
            targetScreen = NSScreen.screens.first { screen in
                guard
                    let number = screen.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")
                    ] as? NSNumber
                else { return false }
                return number.uint32Value == displayID
            }
            if targetScreen == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let targetScreen else {
            throw SessionError(code: .vdApplyFailed, detail: "P3 virtual NSScreen did not appear")
        }
        let pattern = P3AnimatedTestPattern(
            screen: targetScreen,
            framebufferWidth: Int(handle.framebufferSize.width),
            framebufferHeight: Int(handle.framebufferSize.height),
            framesPerSecond: framesPerSecond
        )
        pattern.start()
        testPattern = pattern
    }

    func destroy() async {
        retentionTask?.cancel()
        retentionTask = nil
        testPattern?.stop()
        testPattern = nil
        guard let handle else { return }
        self.handle = nil
        activeRefreshRate = nil
        activeDeviceID = nil
        activeOrientation = nil
        await provider.destroy(handle)
    }

    func retainForReconnect(seconds: UInt64) {
        retentionTask?.cancel()
        retentionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            retentionTask = nil
            await destroy()
        }
    }
}
