import Foundation

public struct NetworkAdaptationSample: Equatable, Sendable {
    public let roundTripMilliseconds: Double?
    public let senderQueueDepth: Int
    public let receiverQueueDepth: Int
    public let droppedFramesDelta: UInt64
    public let renderedFramesPerSecond: Double?
    public let targetFramesPerSecond: Int

    public init(
        roundTripMilliseconds: Double?,
        senderQueueDepth: Int,
        receiverQueueDepth: Int,
        droppedFramesDelta: UInt64,
        renderedFramesPerSecond: Double?,
        targetFramesPerSecond: Int
    ) {
        self.roundTripMilliseconds = roundTripMilliseconds
        self.senderQueueDepth = max(0, senderQueueDepth)
        self.receiverQueueDepth = max(0, receiverQueueDepth)
        self.droppedFramesDelta = droppedFramesDelta
        self.renderedFramesPerSecond = renderedFramesPerSecond
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
    private var bitrateLevel = 0
    private var resolutionLevel = 0
    private var congestionSamples = 0
    private var severeCongestionSamples = 0
    private var healthySamples = 0

    public init(baseBitrate: Int, initialResolutionScale: Double = 1) {
        self.baseBitrate = min(max(baseBitrate, 8_000_000), 30_000_000)
        self.resolutionLevel =
            Self.resolutionScales.enumerated().min {
                abs($0.element - initialResolutionScale)
                    < abs($1.element - initialResolutionScale)
            }?.offset ?? 0
    }

    public mutating func observe(
        _ sample: NetworkAdaptationSample
    ) -> NetworkAdaptationDecision? {
        let rtt = sample.roundTripMilliseconds ?? 0
        let renderedRatio =
            sample.renderedFramesPerSecond.map {
                $0 / Double(sample.targetFramesPerSecond)
            } ?? 1
        let severe =
            rtt >= 120 || sample.senderQueueDepth >= 2 || sample.receiverQueueDepth >= 4
            || sample.droppedFramesDelta >= 4 || renderedRatio < 0.72
        let congested =
            severe || rtt >= 70 || sample.senderQueueDepth >= 1
            || sample.receiverQueueDepth >= 2 || sample.droppedFramesDelta > 0
            || renderedRatio < 0.88

        // 使用连续样本而不是单点阈值，防止 Wi‑Fi 瞬时抖动导致码率和分辨率来回振荡。
        if congested {
            congestionSamples += 1
            severeCongestionSamples = severe ? severeCongestionSamples + 1 : 0
            healthySamples = 0
        } else {
            healthySamples += 1
            congestionSamples = 0
            severeCongestionSamples = 0
        }

        if congestionSamples >= 2, bitrateLevel < Self.bitrateScales.count - 1 {
            congestionSamples = 0
            bitrateLevel += 1
            return decision(rebuild: false, reason: severe ? "severe congestion" : "congestion")
        }
        if severeCongestionSamples >= 5,
            bitrateLevel == Self.bitrateScales.count - 1,
            resolutionLevel < Self.resolutionScales.count - 1
        {
            // 先逐级降码率，只有持续严重拥塞才重建低分辨率流，减少不必要的黑屏与解码器重启。
            severeCongestionSamples = 0
            resolutionLevel += 1
            bitrateLevel = max(1, bitrateLevel - 1)
            return decision(rebuild: true, reason: "sustained congestion")
        }
        if healthySamples >= 8 {
            // 恢复路径比降级路径更保守，确认链路稳定后才逐级恢复画质。
            healthySamples = 0
            if resolutionLevel > 0 {
                resolutionLevel -= 1
                bitrateLevel = min(bitrateLevel + 1, Self.bitrateScales.count - 1)
                return decision(rebuild: true, reason: "network recovered")
            }
            if bitrateLevel > 0 {
                bitrateLevel -= 1
                return decision(rebuild: false, reason: "network recovered")
            }
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
