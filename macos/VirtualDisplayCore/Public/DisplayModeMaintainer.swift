import CoreGraphics
import Foundation
import SecondDisplayCore

public struct DisplayModeMetrics: Sendable, Equatable {
    public let modeID: Int32
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double

    public init(
        modeID: Int32,
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double
    ) {
        self.modeID = modeID
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    public func isTwoTimesHiDPI(logicalSize: CGSize) -> Bool {
        logicalWidth == Int(logicalSize.width)
            && logicalHeight == Int(logicalSize.height)
            && pixelWidth == logicalWidth * 2
            && pixelHeight == logicalHeight * 2
            && abs(refreshRate - 60) < 0.01
    }
}

@MainActor
public protocol DisplayModeControlling: AnyObject {
    func currentMode(displayID: CGDirectDisplayID) -> DisplayModeMetrics?
    func availableModes(displayID: CGDirectDisplayID) -> [DisplayModeMetrics]
    func applyMode(displayID: CGDirectDisplayID, modeID: Int32) -> CGError
    func isMirrored(displayID: CGDirectDisplayID) -> Bool
    func detachMirror(displayID: CGDirectDisplayID) -> CGError
}

@MainActor
public final class CoreGraphicsDisplayModeController: DisplayModeControlling {
    public init() {}

    public func currentMode(displayID: CGDirectDisplayID) -> DisplayModeMetrics? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return metrics(for: mode)
    }

    public func availableModes(displayID: CGDirectDisplayID) -> [DisplayModeMetrics] {
        guard let values = copyAllModes(displayID: displayID) else { return [] }
        return values.map(metrics(for:))
    }

    public func applyMode(displayID: CGDirectDisplayID, modeID: Int32) -> CGError {
        guard let modes = copyAllModes(displayID: displayID),
            let mode = modes.first(where: { $0.ioDisplayModeID == modeID })
        else {
            return .illegalArgument
        }
        var configuration: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&configuration)
        guard beginError == .success, let configuration else { return beginError }
        let configureError = CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil)
        guard configureError == .success else {
            CGCancelDisplayConfiguration(configuration)
            return configureError
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession)
    }

    public func isMirrored(displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsInMirrorSet(displayID) != 0
    }

    public func detachMirror(displayID: CGDirectDisplayID) -> CGError {
        guard isMirrored(displayID: displayID) else { return .success }
        var count: UInt32 = 0
        let countError = CGGetOnlineDisplayList(0, nil, &count)
        guard countError == .success else { return countError }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listError = CGGetOnlineDisplayList(count, &displays, &count)
        guard listError == .success else { return listError }

        var configuration: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&configuration)
        guard beginError == .success, let configuration else { return beginError }

        var displaysToDetach: Set<CGDirectDisplayID> = [displayID]
        for candidate in displays.prefix(Int(count)) {
            if CGDisplayMirrorsDisplay(candidate) == displayID {
                displaysToDetach.insert(candidate)
            }
        }
        for candidate in displaysToDetach {
            let error = CGConfigureDisplayMirrorOfDisplay(configuration, candidate, kCGNullDirectDisplay)
            guard error == .success else {
                CGCancelDisplayConfiguration(configuration)
                return error
            }
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession)
    }

    private func metrics(for mode: CGDisplayMode) -> DisplayModeMetrics {
        DisplayModeMetrics(
            modeID: mode.ioDisplayModeID,
            logicalWidth: mode.width,
            logicalHeight: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate
        )
    }

    private func copyAllModes(displayID: CGDirectDisplayID) -> [CGDisplayMode]? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]
    }
}

@MainActor
public final class DisplayModeMaintainer {
    private let controller: any DisplayModeControlling

    public init(controller: any DisplayModeControlling = CoreGraphicsDisplayModeController()) {
        self.controller = controller
    }

    public func maintainOnce(displayID: CGDirectDisplayID, logicalSize: CGSize) throws {
        if controller.isMirrored(displayID: displayID) {
            let mirrorError = controller.detachMirror(displayID: displayID)
            guard mirrorError == .success, !controller.isMirrored(displayID: displayID) else {
                throw SessionError(code: .vdMirrorDetachFailed, detail: "Unable to detach virtual display mirror")
            }
        }

        if controller.currentMode(displayID: displayID)?.isTwoTimesHiDPI(logicalSize: logicalSize) == true {
            return
        }
        let target = controller.availableModes(displayID: displayID)
            .filter { $0.isTwoTimesHiDPI(logicalSize: logicalSize) }
            .sorted { lhs, rhs in
                abs(lhs.refreshRate - 60) < abs(rhs.refreshRate - 60)
            }
            .first
        guard let target else {
            throw SessionError(code: .vdHiDPIModeMissing, detail: "Required 2x HiDPI mode is unavailable")
        }
        if controller.currentMode(displayID: displayID)?.modeID != target.modeID {
            let applyError = controller.applyMode(displayID: displayID, modeID: target.modeID)
            guard applyError == .success else {
                throw SessionError(code: .vdHiDPIModeMissing, detail: "Unable to apply required 2x HiDPI mode")
            }
        }
        guard controller.currentMode(displayID: displayID)?.isTwoTimesHiDPI(logicalSize: logicalSize) == true else {
            throw SessionError(code: .vdHiDPIModeMissing, detail: "2x HiDPI mode did not remain active")
        }
    }

    public func stabilize(
        displayID: CGDirectDisplayID,
        logicalSize: CGSize,
        generation: UInt64,
        duration: Duration = .seconds(8),
        interval: Duration = .milliseconds(250),
        isCurrentGeneration: @escaping @Sendable (UInt64) -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        repeat {
            try Task.checkCancellation()
            guard isCurrentGeneration(generation) else { throw CancellationError() }
            try maintainOnce(displayID: displayID, logicalSize: logicalSize)
            if clock.now >= deadline { return }
            try await Task.sleep(for: interval)
        } while true
    }

    public func waitUntilStable(
        displayID: CGDirectDisplayID,
        logicalSize: CGSize,
        generation: UInt64,
        timeout: Duration = .seconds(8),
        interval: Duration = .milliseconds(100),
        isCurrentGeneration: @escaping @Sendable (UInt64) -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError = SessionError(code: .vdHiDPIModeMissing, detail: "Display mode did not stabilize")
        while true {
            try Task.checkCancellation()
            guard isCurrentGeneration(generation) else { throw CancellationError() }
            do {
                try maintainOnce(displayID: displayID, logicalSize: logicalSize)
                return
            } catch let error as SessionError {
                lastError = error
            }
            guard clock.now < deadline else { throw lastError }
            try await Task.sleep(for: interval)
        }
    }

    public func startWatchdog(
        displayID: CGDirectDisplayID,
        logicalSize: CGSize,
        generation: UInt64,
        interval: Duration = .seconds(5),
        isCurrentGeneration: @escaping @Sendable (UInt64) -> Bool,
        onFailure: @escaping @MainActor @Sendable (SessionError) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled, isCurrentGeneration(generation) {
                do {
                    try await Task.sleep(for: interval)
                    try Task.checkCancellation()
                    guard isCurrentGeneration(generation) else { return }
                    try self?.maintainOnce(displayID: displayID, logicalSize: logicalSize)
                } catch is CancellationError {
                    return
                } catch let error as SessionError {
                    onFailure(error)
                    return
                } catch {
                    onFailure(SessionError(code: .vdHiDPIModeMissing, detail: "Display watchdog failed"))
                    return
                }
            }
        }
    }
}
