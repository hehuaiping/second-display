import Foundation
import SecondDisplayCore

public typealias EncodedFrameSink = @Sendable (EncodedFrame) async throws -> Void
public typealias MediaPipelineFailureHandler = @Sendable (Error) async -> Void

public actor CaptureEncoderPipeline {
    // 一条活动管线拆成采集、编码、发送三个可取消任务。停止时必须全部等待退出，
    // 避免旧任务继续向已经重建的显示会话发送帧。
    private struct ActivePipeline {
        let token: UUID
        let discontinuityState: PipelineDiscontinuityState
        let bitrateControl: AdaptiveBitrateState
        let frameContinuation: AsyncStream<CapturedFrame>.Continuation
        let sendQueue: BoundedEncodedFrameQueue
        let producer: Task<Void, Never>
        let encoder: Task<Void, Never>
        let sender: Task<Void, Never>
    }

    private let videoEncoder: any VideoEncoding
    private let metrics: MediaPipelineMetrics
    private let monotonicMicroseconds: @Sendable () -> UInt64
    private var active: ActivePipeline?

    public init(videoEncoder: any VideoEncoding, metrics: MediaPipelineMetrics = MediaPipelineMetrics()) {
        self.videoEncoder = videoEncoder
        self.metrics = metrics
        self.monotonicMicroseconds = MediaClock.monotonicMicroseconds
    }

    init(
        videoEncoder: any VideoEncoding,
        metrics: MediaPipelineMetrics = MediaPipelineMetrics(),
        monotonicMicroseconds: @escaping @Sendable () -> UInt64
    ) {
        self.videoEncoder = videoEncoder
        self.metrics = metrics
        self.monotonicMicroseconds = monotonicMicroseconds
    }

    public func start(
        frames: AsyncThrowingStream<CapturedFrame, Error>,
        encoderConfiguration: EncoderSpec,
        generation: UInt64,
        isCurrentGeneration: @escaping @Sendable (UInt64) async -> Bool,
        onEncodedFrame: @escaping EncodedFrameSink,
        onFailure: @escaping MediaPipelineFailureHandler = { _ in }
    ) async throws {
        await stop()
        try Task.checkCancellation()
        try await videoEncoder.configure(encoderConfiguration)

        let token = UUID()
        let state = PipelineDiscontinuityState()
        let bitrateControl = AdaptiveBitrateState(baseBitrate: encoderConfiguration.bitrate)
        let sendQueue = BoundedEncodedFrameQueue(maximumFrames: 1, maximumBytes: 8 * 1024 * 1024)
        let framePair = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let metrics = self.metrics
        let videoEncoder = self.videoEncoder
        let monotonicMicroseconds = self.monotonicMicroseconds
        let frameDurationUs = UInt64(
            (1_000_000 + encoderConfiguration.framesPerSecond - 1)
                / encoderConfiguration.framesPerSecond)
        let maximumPreEncodeAgeUs = max(UInt64(20_000), frameDurationUs * 2)

        // 采集侧只保留最新一帧：桌面串流宁可丢弃过期画面，也不能让队列累积成可感知延迟。
        let producer = Task(priority: .userInitiated) {
            do {
                for try await frame in frames {
                    try Task.checkCancellation()
                    guard frame.generation == generation else { throw CancellationError() }
                    let nowUs = monotonicMicroseconds()
                    let callbackAgeUs =
                        nowUs >= frame.callbackTimestampUs
                        ? nowUs - frame.callbackTimestampUs : 0
                    let captureAgeUs =
                        frame.captureTimestampUs > 0 && nowUs >= frame.captureTimestampUs
                        ? nowUs - frame.captureTimestampUs : 0
                    if callbackAgeUs > maximumPreEncodeAgeUs
                        || captureAgeUs > maximumPreEncodeAgeUs
                    {
                        await metrics.recordEncodeDrop()
                        await state.markDiscontinuity()
                        continue
                    }
                    if frame.isDiscontinuous {
                        if await state.markDiscontinuity() {
                            let removed = await sendQueue.discardNonKeyFrames()
                            if removed > 0 { await metrics.recordSendDrop(count: UInt64(removed)) }
                        }
                    }
                    if case .dropped = framePair.continuation.yield(frame) {
                        await metrics.recordEncodeDrop()
                        if await state.markDiscontinuity() {
                            let removed = await sendQueue.discardNonKeyFrames()
                            if removed > 0 { await metrics.recordSendDrop(count: UInt64(removed)) }
                        }
                    }
                }
                framePair.continuation.finish()
            } catch is CancellationError {
                framePair.continuation.finish()
            } catch {
                framePair.continuation.finish()
                await onFailure(error)
            }
        }

        let encoderTask = Task(priority: .userInitiated) {
            var isFirstFrame = true
            await metrics.recordContentActivity(
                dirtyAreaRatio: 1,
                currentBitrate: encoderConfiguration.bitrate,
                activity: .active)
            for await frame in framePair.stream {
                if Task.isCancelled { break }
                guard frame.generation == generation else { break }
                let request = await state.request()
                // 发生丢帧或不连续后请求关键帧，使接收端尽快重新建立可解码参考链。
                let forceKeyFrame = isFirstFrame || request.forceKeyFrame
                isFirstFrame = false
                if let decision = await bitrateControl.observe(
                    dirtyAreaRatio: frame.dirtyAreaRatio,
                    timestampUs: frame.callbackTimestampUs)
                {
                    do {
                        try await videoEncoder.updateBitrate(decision.bitrate)
                        await bitrateControl.commit(decision)
                    } catch {
                        await bitrateControl.disable()
                    }
                }
                let bitrateStatus = await bitrateControl.status()
                await metrics.recordContentActivity(
                    dirtyAreaRatio: frame.dirtyAreaRatio,
                    currentBitrate: bitrateStatus.bitrate,
                    activity: bitrateStatus.activity)
                let startedUs = MediaClock.monotonicMicroseconds()
                let captureDeliveryUs =
                    frame.callbackTimestampUs >= frame.captureTimestampUs
                    ? frame.callbackTimestampUs - frame.captureTimestampUs : 0
                let queueLatencyUs =
                    startedUs >= frame.callbackTimestampUs
                    ? startedUs - frame.callbackTimestampUs : 0
                await metrics.recordEncodeStarted(
                    captureDeliveryLatencyUs: captureDeliveryUs,
                    queueLatencyUs: queueLatencyUs)
                do {
                    guard let encoded = try await videoEncoder.encode(frame, forceKeyFrame: forceKeyFrame)
                    else {
                        await metrics.recordEncodeDrop()
                        await state.markDiscontinuity()
                        continue
                    }
                    guard encoded.generation == generation else { break }
                    guard await state.isCurrent(request.version) else {
                        await metrics.recordEncodeDrop()
                        continue
                    }
                    if forceKeyFrame, !encoded.isKeyFrame {
                        await metrics.recordEncodeDrop()
                        await state.markDiscontinuity()
                        continue
                    }
                    if encoded.isKeyFrame {
                        await state.completeKeyFrame(for: request.version)
                    }
                    let completedUs = MediaClock.monotonicMicroseconds()
                    await metrics.recordEncodedFrame(
                        latencyUs: completedUs >= startedUs ? completedUs - startedUs : 0,
                        videoToolboxLatencyUs: encoded.encodeCallbackTimestampUs >= startedUs
                            ? encoded.encodeCallbackTimestampUs - startedUs : 0,
                        bitstreamConversionLatencyUs: encoded.encodeCompleteTimestampUs
                            >= encoded.encodeCallbackTimestampUs
                            ? encoded.encodeCompleteTimestampUs - encoded.encodeCallbackTimestampUs : 0,
                        encoderHardwareAccelerated: encoded.encoderHardwareAccelerated,
                        lowLatencyRateControlEnabled: encoded.lowLatencyRateControlEnabled
                    )
                    let dropped = await sendQueue.enqueue(encoded)
                    if dropped > 0 {
                        await metrics.recordSendDrop(count: UInt64(dropped))
                        await state.markDiscontinuity()
                        let removed = await sendQueue.discardNonKeyFrames()
                        if removed > 0 { await metrics.recordSendDrop(count: UInt64(removed)) }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    await metrics.recordEncodeDrop()
                    await state.markDiscontinuity()
                    await onFailure(error)
                    break
                }
            }
            await sendQueue.finish()
        }

        let sender = Task(priority: .userInitiated) {
            while !Task.isCancelled, let encoded = await sendQueue.next() {
                // generation 是会话隔离边界；即使取消与网络回调竞态，旧帧也不能复活。
                guard encoded.generation == generation, await isCurrentGeneration(generation) else { break }
                let sendStartedUs = MediaClock.monotonicMicroseconds()
                await metrics.recordSendStarted(
                    queueLatencyUs: sendStartedUs >= encoded.encodeCompleteTimestampUs
                        ? sendStartedUs - encoded.encodeCompleteTimestampUs : 0)
                do {
                    try await onEncodedFrame(encoded)
                } catch is CancellationError {
                    break
                } catch {
                    await metrics.recordSendDrop()
                    await state.markDiscontinuity()
                    await onFailure(error)
                    break
                }
            }
        }

        active = ActivePipeline(
            token: token,
            discontinuityState: state,
            bitrateControl: bitrateControl,
            frameContinuation: framePair.continuation,
            sendQueue: sendQueue,
            producer: producer,
            encoder: encoderTask,
            sender: sender
        )
    }

    public func stop() async {
        guard let pipeline = active else {
            await videoEncoder.invalidate()
            return
        }
        active = nil
        pipeline.producer.cancel()
        pipeline.encoder.cancel()
        pipeline.sender.cancel()
        pipeline.frameContinuation.finish()
        await pipeline.sendQueue.finish()
        _ = await pipeline.producer.result
        _ = await pipeline.encoder.result
        _ = await pipeline.sender.result
        await videoEncoder.invalidate()
    }

    public func requestKeyFrame() async {
        guard let active else { return }
        await active.discontinuityState.markDiscontinuity()
    }

    public func setNetworkBitrateCeiling(_ bitsPerSecond: Int) async throws {
        guard let active else {
            throw SessionError(code: .encCreateFailed, detail: "Encoder pipeline is not active")
        }
        guard let decision = await active.bitrateControl.setNetworkCeiling(bitsPerSecond) else {
            return
        }
        do {
            try await videoEncoder.updateBitrate(decision.bitrate)
            await active.bitrateControl.commit(decision)
            let status = await active.bitrateControl.status()
            await metrics.recordContentActivity(
                dirtyAreaRatio: status.activity == .active ? 1 : 0,
                currentBitrate: status.bitrate,
                activity: status.activity
            )
        } catch {
            await active.bitrateControl.disable()
            throw error
        }
    }

    public func metricsSnapshot() async -> MediaMetricsSnapshot {
        await metrics.snapshot()
    }
}

struct AdaptiveBitrateController {
    struct Decision: Equatable {
        let bitrate: Int
        let activity: ContentActivity
    }

    private let baseBitrate: Int
    private var networkCeiling: Int
    private var staticCandidateSinceUs: UInt64?
    private(set) var currentBitrate: Int
    private(set) var activity: ContentActivity = .active
    private var isEnabled = true

    init(baseBitrate: Int) {
        self.baseBitrate = baseBitrate
        self.networkCeiling = baseBitrate
        self.currentBitrate = baseBitrate
    }

    mutating func observe(dirtyAreaRatio: Double, timestampUs: UInt64) -> Decision? {
        guard isEnabled else { return nil }
        let ratio = min(max(dirtyAreaRatio.isFinite ? dirtyAreaRatio : 1, 0), 1)
        if ratio >= 0.01 {
            staticCandidateSinceUs = nil
            let activeBitrate = min(baseBitrate, networkCeiling)
            guard currentBitrate != activeBitrate || activity != .active else { return nil }
            return Decision(bitrate: activeBitrate, activity: .active)
        }
        if ratio > 0.002 {
            staticCandidateSinceUs = nil
            return nil
        }
        let staticBitrate = max(
            EncoderSpec.bitrateRange.lowerBound,
            Int(Double(min(baseBitrate, networkCeiling)) * 0.55)
        )
        guard currentBitrate != staticBitrate || activity != .staticContent else { return nil }
        guard let candidateSinceUs = staticCandidateSinceUs else {
            staticCandidateSinceUs = timestampUs
            return nil
        }
        guard timestampUs >= candidateSinceUs, timestampUs - candidateSinceUs >= 750_000 else {
            return nil
        }
        return Decision(bitrate: staticBitrate, activity: .staticContent)
    }

    mutating func setNetworkCeiling(_ bitsPerSecond: Int) -> Decision? {
        guard isEnabled else { return nil }
        networkCeiling = min(
            baseBitrate,
            max(EncoderSpec.bitrateRange.lowerBound, bitsPerSecond)
        )
        let target =
            activity == .active
            ? networkCeiling
            : max(
                EncoderSpec.bitrateRange.lowerBound,
                Int(Double(networkCeiling) * 0.55)
            )
        guard target != currentBitrate else { return nil }
        return Decision(bitrate: target, activity: activity)
    }

    mutating func commit(_ decision: Decision) {
        currentBitrate = decision.bitrate
        activity = decision.activity
        staticCandidateSinceUs = nil
    }

    mutating func disable() {
        isEnabled = false
        staticCandidateSinceUs = nil
    }
}

private actor AdaptiveBitrateState {
    struct Status: Sendable {
        let bitrate: Int
        let activity: ContentActivity
    }

    private var controller: AdaptiveBitrateController

    init(baseBitrate: Int) {
        controller = AdaptiveBitrateController(baseBitrate: baseBitrate)
    }

    func observe(dirtyAreaRatio: Double, timestampUs: UInt64) -> AdaptiveBitrateController.Decision? {
        controller.observe(dirtyAreaRatio: dirtyAreaRatio, timestampUs: timestampUs)
    }

    func setNetworkCeiling(_ bitsPerSecond: Int) -> AdaptiveBitrateController.Decision? {
        controller.setNetworkCeiling(bitsPerSecond)
    }

    func commit(_ decision: AdaptiveBitrateController.Decision) {
        controller.commit(decision)
    }

    func disable() {
        controller.disable()
    }

    func status() -> Status {
        Status(bitrate: controller.currentBitrate, activity: controller.activity)
    }
}

private actor PipelineDiscontinuityState {
    struct Request: Sendable {
        let version: UInt64
        let forceKeyFrame: Bool
    }

    private var version: UInt64 = 0
    private var completedVersion: UInt64 = 0
    private var recoveryPending = false

    @discardableResult
    func markDiscontinuity() -> Bool {
        guard !recoveryPending else { return false }
        version &+= 1
        recoveryPending = true
        return true
    }

    func request() -> Request {
        Request(version: version, forceKeyFrame: recoveryPending || version != completedVersion)
    }

    func isCurrent(_ requestVersion: UInt64) -> Bool {
        requestVersion == version
    }

    func completeKeyFrame(for requestVersion: UInt64) {
        guard requestVersion == version else { return }
        completedVersion = requestVersion
        recoveryPending = false
    }
}

private actor BoundedEncodedFrameQueue {
    private let maximumFrames: Int
    private let maximumBytes: Int
    private var frames: [EncodedFrame] = []
    private var byteCount = 0
    private var waiter: CheckedContinuation<EncodedFrame?, Never>?
    private var isFinished = false

    init(maximumFrames: Int, maximumBytes: Int) {
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
    }

    func enqueue(_ frame: EncodedFrame) -> Int {
        guard !isFinished else { return 1 }
        guard frame.payload.count <= maximumBytes else { return 1 }
        if let waiter, frames.isEmpty {
            self.waiter = nil
            waiter.resume(returning: frame)
            return 0
        }

        var dropped = 0
        while frames.count >= maximumFrames || byteCount + frame.payload.count > maximumBytes {
            guard let index = frames.firstIndex(where: { !$0.isKeyFrame }) else {
                return dropped + 1
            }
            byteCount -= frames[index].payload.count
            frames.remove(at: index)
            dropped += 1
        }
        frames.append(frame)
        byteCount += frame.payload.count
        return dropped
    }

    func discardNonKeyFrames() -> Int {
        let previousCount = frames.count
        frames.removeAll { !$0.isKeyFrame }
        byteCount = frames.reduce(0) { $0 + $1.payload.count }
        return previousCount - frames.count
    }

    func next() async -> EncodedFrame? {
        if !frames.isEmpty {
            let frame = frames.removeFirst()
            byteCount -= frame.payload.count
            return frame
        }
        if isFinished { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        frames.removeAll(keepingCapacity: false)
        byteCount = 0
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(returning: nil)
    }
}
