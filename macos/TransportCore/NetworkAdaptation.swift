import Foundation

public struct NetworkAdaptationSample: Equatable, Sendable {
    public let roundTripMilliseconds: Double?
    public let senderQueueDepth: Int
    public let receiverQueueDepth: Int
    public let droppedFramesDelta: UInt64
    public let renderedFramesPerSecond: Double?
    public let senderFramesPerSecond: Double?
    public let hostDroppedFramesDelta: UInt64
    public let encodeP95Milliseconds: Double?
    public let contentIsActive: Bool
    public let targetFramesPerSecond: Int

    public init(
        roundTripMilliseconds: Double?,
        senderQueueDepth: Int,
        receiverQueueDepth: Int,
        droppedFramesDelta: UInt64,
        renderedFramesPerSecond: Double?,
        senderFramesPerSecond: Double? = nil,
        hostDroppedFramesDelta: UInt64 = 0,
        encodeP95Milliseconds: Double? = nil,
        contentIsActive: Bool = true,
        targetFramesPerSecond: Int
    ) {
        self.roundTripMilliseconds = roundTripMilliseconds
        self.senderQueueDepth = max(0, senderQueueDepth)
        self.receiverQueueDepth = max(0, receiverQueueDepth)
        self.droppedFramesDelta = droppedFramesDelta
        self.renderedFramesPerSecond = renderedFramesPerSecond
        self.senderFramesPerSecond = senderFramesPerSecond.map { max(0, $0) }
        self.hostDroppedFramesDelta = hostDroppedFramesDelta
        self.encodeP95Milliseconds = encodeP95Milliseconds.map { max(0, $0) }
        self.contentIsActive = contentIsActive
        self.targetFramesPerSecond = max(1, targetFramesPerSecond)
    }
}

public struct NetworkAdaptationDecision: Equatable, Sendable {
    public let bitrateCeiling: Int
    public let resolutionScale: Double
    public let requiresStreamRebuild: Bool
    public let reason: String
}

public struct NetworkAdaptiveController: Sendable {
    private let baseBitrate: Int
    private let allowsResolutionScaling: Bool
    private let warmupSamplesRequired: Int
    private var bitrateLevel = 0
    private var resolutionLevel = 0
    private var congestionSamples = 0
    private var severeCongestionSamples = 0
    private var mediaPressureSamples = 0
    private var healthySamples = 0
    private var resolutionHealthySamples = 0
    private var observedSamples = 0

    public init(
        baseBitrate: Int,
        initialResolutionScale: Double = 1,
        allowsResolutionScaling: Bool = true,
        warmupSamplesRequired: Int = 0
    ) {
        self.baseBitrate = min(max(baseBitrate, 8_000_000), 30_000_000)
        self.allowsResolutionScaling = allowsResolutionScaling
        self.warmupSamplesRequired = max(0, warmupSamplesRequired)
        self.resolutionLevel =
            allowsResolutionScaling
            ? Self.resolutionScales.enumerated().min {
                abs($0.element - initialResolutionScale)
                    < abs($1.element - initialResolutionScale)
            }?.offset ?? 0
            : 0
    }

    public mutating func observe(
        _ sample: NetworkAdaptationSample
    ) -> NetworkAdaptationDecision? {
        observedSamples += 1
        if observedSamples <= warmupSamplesRequired {
            congestionSamples = 0
            severeCongestionSamples = 0
            mediaPressureSamples = 0
            healthySamples = 0
            resolutionHealthySamples = 0
            return nil
        }

        let rtt = sample.roundTripMilliseconds ?? 0
        let targetFramesPerSecond = Double(sample.targetFramesPerSecond)
        let senderFramesPerSecond =
            sample.senderFramesPerSecond ?? targetFramesPerSecond
        let senderRatio = senderFramesPerSecond / targetFramesPerSecond
        let frameBudgetMilliseconds = 1_000 / targetFramesPerSecond
        let hostMediaPressure =
            sample.contentIsActive
            && (
                sample.hostDroppedFramesDelta
                    >= UInt64(max(2, Int(targetFramesPerSecond * 0.03)))
                || (sample.hostDroppedFramesDelta > 0 && senderRatio < 0.90)
                || (sample.encodeP95Milliseconds.map {
                    $0 > frameBudgetMilliseconds * 0.95
                } ?? false)
            )
        let renderedRatio: Double
        if senderFramesPerSecond >= targetFramesPerSecond * 0.5,
            let renderedFramesPerSecond = sample.renderedFramesPerSecond
        {
            // ScreenCaptureKit 在静止桌面会主动进入 idle。此时接收端 FPS 低不是网络拥塞，
            // 只有发送端确实在持续产帧时才评估接收端是否跟不上。
            let expectedFramesPerSecond = max(
                1,
                min(targetFramesPerSecond, senderFramesPerSecond))
            renderedRatio = renderedFramesPerSecond / expectedFramesPerSecond
        } else {
            renderedRatio = 1
        }
        // 接收端会主动释放已经过期、后方有更新画面的 Surface 输出。只要有效呈现
        // 仍跟得上目标且两端队列为空，这类 latest-wins 丢弃不是网络拥塞，不能降画质。
        let receiverDropPressure =
            sample.droppedFramesDelta > 0
            && (
                renderedRatio < 0.97
                || sample.senderQueueDepth > 0
                || sample.receiverQueueDepth > 1
            )
        let receiverMediaPressure =
            sample.contentIsActive
            && (
                sample.receiverQueueDepth >= 2
                || receiverDropPressure
                || renderedRatio < 0.88
            )
        let networkSevere =
            rtt >= 120 || sample.senderQueueDepth >= 2
        let networkCongested =
            networkSevere || rtt >= 70 || sample.senderQueueDepth >= 1
        let mediaPressure = hostMediaPressure || receiverMediaPressure

        // 网络拥塞与主机媒体压力必须分开处理。降低码率可以缓解网络队列，但在
        // 编解码器已经承压时继续降码率会形成 60 → 30 FPS 的正反馈锁死。接收端
        // latest-wins 和解码波动也不是网络拥塞，不能用降低发送码率来掩盖。
        if networkCongested {
            congestionSamples += 1
            severeCongestionSamples = networkSevere ? severeCongestionSamples + 1 : 0
            mediaPressureSamples = 0
            healthySamples = 0
            resolutionHealthySamples = 0
        } else {
            healthySamples += 1
            mediaPressureSamples = mediaPressure ? mediaPressureSamples + 1 : 0
            resolutionHealthySamples =
                mediaPressure ? 0 : resolutionHealthySamples + 1
            congestionSamples = 0
            severeCongestionSamples = 0
        }

        if !networkCongested, mediaPressure {
            if bitrateLevel > 0 {
                // 网络已经健康时，主机掉帧优先恢复协商基础码率，避免低码率限制让
                // 高复杂度全屏动画长期停留在约一半帧率。
                bitrateLevel = 0
                return decision(
                    rebuild: false,
                    reason: hostMediaPressure
                        ? "host media bitrate recovery" : "receiver media bitrate recovery")
            }
            if mediaPressureSamples >= 5,
                allowsResolutionScaling,
                resolutionLevel < Self.resolutionScales.count - 1
            {
                mediaPressureSamples = 0
                resolutionLevel += 1
                return decision(
                    rebuild: true,
                    reason: hostMediaPressure
                        ? "sustained host media pressure"
                        : "sustained receiver media pressure")
            }
        }

        if congestionSamples >= 2, bitrateLevel < Self.bitrateScales.count - 1 {
            congestionSamples = 0
            bitrateLevel += 1
            return decision(
                rebuild: false,
                reason: networkSevere ? "severe congestion" : "congestion")
        }
        if severeCongestionSamples >= 5,
            allowsResolutionScaling,
            bitrateLevel == Self.bitrateScales.count - 1,
            resolutionLevel < Self.resolutionScales.count - 1
        {
            // 先逐级降码率，只有持续严重拥塞才重建低分辨率流，减少不必要的黑屏与解码器重启。
            severeCongestionSamples = 0
            resolutionLevel += 1
            bitrateLevel = max(1, bitrateLevel - 1)
            return decision(
                rebuild: true,
                reason: "sustained congestion")
        }
        if healthySamples >= 8, bitrateLevel > 0 {
            healthySamples = 0
            bitrateLevel -= 1
            return decision(rebuild: false, reason: "network recovered")
        }
        if allowsResolutionScaling,
            resolutionHealthySamples >= 20,
            resolutionLevel > 0,
            bitrateLevel == 0
        {
            // 分辨率恢复至少等待 20 个健康采样，防止高动态场景在两个档位间反复重建。
            resolutionHealthySamples = 0
            resolutionLevel -= 1
            return decision(rebuild: true, reason: "sustained media recovery")
        }
        return nil
    }

    public var currentResolutionScale: Double {
        Self.resolutionScales[resolutionLevel]
    }

    private func decision(rebuild: Bool, reason: String) -> NetworkAdaptationDecision {
        NetworkAdaptationDecision(
            bitrateCeiling: max(
                8_000_000,
                Int(Double(baseBitrate) * Self.bitrateScales[bitrateLevel])
            ),
            resolutionScale: currentResolutionScale,
            requiresStreamRebuild: rebuild,
            reason: reason
        )
    }

    private static let bitrateScales = [1.0, 0.8, 0.6, 0.45]
    private static let resolutionScales = [1.0, 0.8, 2.0 / 3.0]
}

public struct FrameRateAdaptationSample: Equatable, Sendable {
    public let videoToolboxP95Milliseconds: Double
    public let encodeP95Milliseconds: Double
    public let senderQueueDepth: Int
    public let receiverQueueDepth: Int
    public let droppedFramesDelta: UInt64
    public let renderedFramesPerSecond: Double?
    public let displayFramesPerSecond: Double?
    public let displayIntervalP95Milliseconds: Double?
    public let decoderOutputP95Milliseconds: Double?
    public let hardwareAccelerated: Bool
    public let lowLatencyRateControlEnabled: Bool
    public let thermalConstrained: Bool
    public let contentIsActive: Bool
    public let fullResolution: Bool
    public let hasSufficientSamples: Bool
    public let roundTripMilliseconds: Double?

    public init(
        videoToolboxP95Milliseconds: Double,
        encodeP95Milliseconds: Double,
        senderQueueDepth: Int,
        receiverQueueDepth: Int,
        droppedFramesDelta: UInt64,
        renderedFramesPerSecond: Double?,
        displayFramesPerSecond: Double? = nil,
        displayIntervalP95Milliseconds: Double? = nil,
        decoderOutputP95Milliseconds: Double? = nil,
        hardwareAccelerated: Bool,
        lowLatencyRateControlEnabled: Bool,
        thermalConstrained: Bool,
        contentIsActive: Bool,
        fullResolution: Bool,
        hasSufficientSamples: Bool,
        roundTripMilliseconds: Double?
    ) {
        self.videoToolboxP95Milliseconds = max(0, videoToolboxP95Milliseconds)
        self.encodeP95Milliseconds = max(0, encodeP95Milliseconds)
        self.senderQueueDepth = max(0, senderQueueDepth)
        self.receiverQueueDepth = max(0, receiverQueueDepth)
        self.droppedFramesDelta = droppedFramesDelta
        self.renderedFramesPerSecond = renderedFramesPerSecond
        self.displayFramesPerSecond = displayFramesPerSecond.map { max(0, $0) }
        self.displayIntervalP95Milliseconds =
            displayIntervalP95Milliseconds.map { max(0, $0) }
        self.decoderOutputP95Milliseconds =
            decoderOutputP95Milliseconds.map { max(0, $0) }
        self.hardwareAccelerated = hardwareAccelerated
        self.lowLatencyRateControlEnabled = lowLatencyRateControlEnabled
        self.thermalConstrained = thermalConstrained
        self.contentIsActive = contentIsActive
        self.fullResolution = fullResolution
        self.hasSufficientSamples = hasSufficientSamples
        self.roundTripMilliseconds = roundTripMilliseconds
    }
}

public struct FrameRateAdaptationDecision: Equatable, Sendable {
    public let framesPerSecond: Int
    public let reason: String
}

/// 只在用户显式启用实验高刷后使用。升档保守、降档快速，避免高刷反而造成队列积压。
public struct FrameRateAdaptiveController: Sendable {
    private let supportedRates: [Int]
    private let healthySamplesRequired: Int
    private let unhealthySamplesRequired: Int
    private var currentRateIndex: Int
    private var healthySamples = 0
    private var unhealthySamples = 0

    public init(
        currentFramesPerSecond: Int,
        maximumFramesPerSecond: Int,
        healthySamplesRequired: Int = 30,
        unhealthySamplesRequired: Int = 2
    ) {
        supportedRates = [60, 90, 120].filter {
            $0 <= max(60, maximumFramesPerSecond)
        }
        currentRateIndex =
            supportedRates.firstIndex(of: currentFramesPerSecond)
            ?? supportedRates.lastIndex(where: { $0 <= currentFramesPerSecond })
            ?? 0
        self.healthySamplesRequired = max(1, healthySamplesRequired)
        self.unhealthySamplesRequired = max(1, unhealthySamplesRequired)
    }

    public mutating func observe(
        _ sample: FrameRateAdaptationSample
    ) -> FrameRateAdaptationDecision? {
        guard !supportedRates.isEmpty else { return nil }
        let currentRate = supportedRates[currentRateIndex]
        let renderedRatio =
            sample.renderedFramesPerSecond.map { $0 / Double(currentRate) }
        let displayRatio =
            sample.displayFramesPerSecond.map { $0 / Double(currentRate) }
        let currentFrameBudget = 1_000 / Double(currentRate)
        let unhealthy =
            sample.thermalConstrained
            || sample.senderQueueDepth > 0
            || sample.receiverQueueDepth > 1
            || sample.droppedFramesDelta > 0
            || sample.encodeP95Milliseconds > currentFrameBudget * 0.95
            || (sample.contentIsActive && (sample.decoderOutputP95Milliseconds.map {
                $0 > currentFrameBudget * 0.95
            } ?? false))
            || (sample.contentIsActive && (renderedRatio ?? 1) < 0.90)
            || (sample.contentIsActive && (displayRatio ?? 1) < 0.90)
            || (sample.contentIsActive && (sample.displayIntervalP95Milliseconds.map {
                $0 > currentFrameBudget * 1.5
            } ?? false))
            || (sample.roundTripMilliseconds ?? 0) >= 70

        if unhealthy {
            healthySamples = 0
            unhealthySamples += 1
            guard unhealthySamples >= unhealthySamplesRequired, currentRateIndex > 0 else {
                return nil
            }
            unhealthySamples = 0
            currentRateIndex -= 1
            return FrameRateAdaptationDecision(
                framesPerSecond: supportedRates[currentRateIndex],
                reason: sample.thermalConstrained
                    ? "sustained thermal pressure" : "sustained media pressure"
            )
        }

        unhealthySamples = 0
        guard currentRateIndex + 1 < supportedRates.count else {
            healthySamples = 0
            return nil
        }
        let nextRate = supportedRates[currentRateIndex + 1]
        let nextFrameBudget = 1_000 / Double(nextRate)
        let upgradeHealthy =
            sample.contentIsActive
            && sample.fullResolution
            && sample.hasSufficientSamples
            && sample.hardwareAccelerated
            && sample.lowLatencyRateControlEnabled
            && sample.senderQueueDepth == 0
            && sample.receiverQueueDepth <= 1
            && sample.droppedFramesDelta == 0
            && (sample.renderedFramesPerSecond.map {
                $0 / Double(currentRate) >= 0.97
            } ?? false)
            && (sample.displayFramesPerSecond.map {
                $0 / Double(currentRate) >= 0.97
            } ?? false)
            && (sample.displayIntervalP95Milliseconds.map {
                $0 <= currentFrameBudget * 1.25
            } ?? false)
            && (sample.decoderOutputP95Milliseconds.map {
                $0 <= nextFrameBudget * 0.45
            } ?? false)
            && sample.videoToolboxP95Milliseconds <= nextFrameBudget * 0.55
            && sample.encodeP95Milliseconds <= nextFrameBudget * 0.55
            && (sample.roundTripMilliseconds ?? 0) < 40

        guard upgradeHealthy else {
            healthySamples = 0
            return nil
        }
        healthySamples += 1
        guard healthySamples >= healthySamplesRequired else { return nil }
        healthySamples = 0
        currentRateIndex += 1
        return FrameRateAdaptationDecision(
            framesPerSecond: nextRate,
            reason: "sustained end-to-end headroom"
        )
    }
}
