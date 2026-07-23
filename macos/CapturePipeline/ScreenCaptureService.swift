@preconcurrency import CoreGraphics
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Dispatch
import Foundation
@preconcurrency import ScreenCaptureKit
import SecondDisplayCore
import VirtualDisplayCore

public protocol ScreenCapturePermissionChecking: Sendable {
    func isAuthorized() -> Bool
}

public struct SystemScreenCapturePermissionChecker: ScreenCapturePermissionChecking {
    public init() {}

    public func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}

public final class CaptureDisplay: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    fileprivate let rawDisplay: SCDisplay?

    fileprivate init(rawDisplay: SCDisplay) {
        self.rawDisplay = rawDisplay
        self.displayID = rawDisplay.displayID
    }

    init(displayID: CGDirectDisplayID) {
        self.rawDisplay = nil
        self.displayID = displayID
    }
}

public protocol ShareableContentProviding: Sendable {
    func displays() async throws -> [CaptureDisplay]
}

public struct SystemShareableContentProvider: ShareableContentProviding {
    public init() {}

    public func displays() async throws -> [CaptureDisplay] {
        let content = try await SCShareableContent.current
        return content.displays.map(CaptureDisplay.init(rawDisplay:))
    }
}

public struct ScreenCaptureDisplayEnumerator: ShareableDisplayEnumerating {
    private let contentProvider: any ShareableContentProviding
    private let permissionChecker: any ScreenCapturePermissionChecking

    public init(
        contentProvider: any ShareableContentProviding = SystemShareableContentProvider(),
        permissionChecker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker()
    ) {
        self.contentProvider = contentProvider
        self.permissionChecker = permissionChecker
    }

    public func displayIDs() async throws -> Set<CGDirectDisplayID> {
        guard permissionChecker.isAuthorized() else {
            throw SessionError(code: .capPermissionDenied, detail: "Screen Recording permission is required")
        }
        do {
            return Set(try await contentProvider.displays().map(\.displayID))
        } catch let error as SessionError {
            throw error
        } catch {
            throw Self.mapCaptureError(error)
        }
    }

    static func mapCaptureError(_ error: Error) -> SessionError {
        if !CGPreflightScreenCaptureAccess() {
            return SessionError(code: .capPermissionDenied, detail: "Screen Recording permission is required")
        }
        return SessionError(
            code: .capStreamStopped,
            detail: "ScreenCaptureKit operation failed: \(error.localizedDescription)")
    }
}

public protocol DisplayCaptureServicing: Sendable {
    func waitForDisplay(
        id: CGDirectDisplayID,
        generation: UInt64,
        timeoutNanoseconds: UInt64,
        isCurrentGeneration: @escaping @Sendable (UInt64) async -> Bool
    ) async throws -> CaptureDisplay

    func start(
        display: CaptureDisplay,
        configuration: CaptureSpec,
        generation: UInt64
    ) async throws -> AsyncThrowingStream<CapturedFrame, Error>

    func stop() async
}

public actor ScreenCaptureService: DisplayCaptureServicing {
    private struct ActiveCapture {
        let token: UUID
        let stream: SCStream
        let bridge: ScreenCaptureOutputBridge
        let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    }

    private let contentProvider: any ShareableContentProviding
    private let permissionChecker: any ScreenCapturePermissionChecking
    private let onlineChecker: any DisplayOnlineChecking
    private let metrics: MediaPipelineMetrics
    private let callbackQueue: DispatchQueue
    private var activeCapture: ActiveCapture?

    public init(
        contentProvider: any ShareableContentProviding = SystemShareableContentProvider(),
        permissionChecker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker(),
        onlineChecker: any DisplayOnlineChecking = SystemDisplayOnlineChecker(),
        metrics: MediaPipelineMetrics = MediaPipelineMetrics()
    ) {
        self.contentProvider = contentProvider
        self.permissionChecker = permissionChecker
        self.onlineChecker = onlineChecker
        self.metrics = metrics
        self.callbackQueue = DispatchQueue(label: "second-display.capture.frames", qos: .userInteractive)
    }

    public func waitForDisplay(
        id: CGDirectDisplayID,
        generation: UInt64,
        timeoutNanoseconds: UInt64 = 15_000_000_000,
        isCurrentGeneration: @escaping @Sendable (UInt64) async -> Bool
    ) async throws -> CaptureDisplay {
        guard permissionChecker.isAuthorized() else {
            throw SessionError(code: .capPermissionDenied, detail: "Screen Recording permission is required")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let backoffs: [UInt64] = [100_000_000, 200_000_000, 400_000_000, 800_000_000, 1_000_000_000]
        var backoffIndex = 0
        while true {
            try Task.checkCancellation()
            guard await isCurrentGeneration(generation) else { throw CancellationError() }
            guard onlineChecker.isOnline(id) else {
                throw SessionError(
                    code: .vdTerminatedBySystem,
                    detail: "Display disappeared while waiting for ScreenCaptureKit enumeration"
                )
            }
            do {
                if let display = try await contentProvider.displays().first(where: { $0.displayID == id }) {
                    try Task.checkCancellation()
                    guard await isCurrentGeneration(generation) else { throw CancellationError() }
                    return display
                }
            } catch let error as SessionError {
                throw error
            } catch {
                throw ScreenCaptureDisplayEnumerator.mapCaptureError(error)
            }

            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= started ? now - started : 0
            guard elapsed < timeoutNanoseconds else {
                throw SessionError(
                    code: .vdEnumerationTimeout, detail: "ScreenCaptureKit did not enumerate display \(id)")
            }
            let delay = min(backoffs[min(backoffIndex, backoffs.count - 1)], timeoutNanoseconds - elapsed)
            backoffIndex += 1
            try await Task.sleep(nanoseconds: delay)
        }
    }

    public func start(
        display: CaptureDisplay,
        configuration: CaptureSpec,
        generation: UInt64
    ) async throws -> AsyncThrowingStream<CapturedFrame, Error> {
        await stop()
        try Task.checkCancellation()
        guard permissionChecker.isAuthorized() else {
            throw SessionError(code: .capPermissionDenied, detail: "Screen Recording permission is required")
        }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.width
        streamConfiguration.height = configuration.height
        let sourceRefreshRate = CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0
        streamConfiguration.minimumFrameInterval = captureMinimumFrameInterval(
            framesPerSecond: configuration.framesPerSecond,
            sourceRefreshRate: sourceRefreshRate
        )
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfiguration.queueDepth = configuration.queueDepth
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.capturesAudio = false

        guard let rawDisplay = display.rawDisplay else {
            throw SessionError(
                code: .capStreamStopped, detail: "Capture display has no ScreenCaptureKit object")
        }
        let filter = SCContentFilter(display: rawDisplay, excludingWindows: [])
        let pair = makeLatestCaptureFrameStream()
        let bridge = ScreenCaptureOutputBridge(
            generation: generation,
            continuation: pair.continuation,
            metrics: metrics
        )
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: bridge)
        do {
            try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: callbackQueue)
        } catch {
            bridge.deactivate()
            pair.continuation.finish(throwing: ScreenCaptureDisplayEnumerator.mapCaptureError(error))
            throw ScreenCaptureDisplayEnumerator.mapCaptureError(error)
        }

        let token = UUID()
        activeCapture = ActiveCapture(
            token: token, stream: stream, bridge: bridge, continuation: pair.continuation)
        do {
            try await stream.startCapture()
            guard activeCapture?.token == token else {
                bridge.deactivate()
                try? await stream.stopCapture()
                try? stream.removeStreamOutput(bridge, type: .screen)
                throw CancellationError()
            }
            return pair.stream
        } catch {
            if activeCapture?.token == token {
                activeCapture = nil
            }
            bridge.deactivate()
            try? stream.removeStreamOutput(bridge, type: .screen)
            let mapped =
                error is CancellationError
                ? error
                : ScreenCaptureDisplayEnumerator.mapCaptureError(error)
            pair.continuation.finish(throwing: mapped)
            throw mapped
        }
    }

    public func stop() async {
        guard let capture = activeCapture else { return }
        activeCapture = nil
        capture.bridge.deactivate()
        do {
            try await capture.stream.stopCapture()
        } catch {
            capture.continuation.finish(throwing: ScreenCaptureDisplayEnumerator.mapCaptureError(error))
        }
        try? capture.stream.removeStreamOutput(capture.bridge, type: .screen)
        capture.continuation.finish()
    }
}

func captureMinimumFrameInterval(framesPerSecond: Int, sourceRefreshRate: Double) -> CMTime {
    if sourceRefreshRate.isFinite,
        sourceRefreshRate > 0,
        Double(framesPerSecond) + 0.5 >= sourceRefreshRate
    {
        return .zero
    }
    return CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
}

func makeLatestCaptureFrameStream() -> (
    stream: AsyncThrowingStream<CapturedFrame, Error>,
    continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
) {
    AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
}

enum CaptureFrameStatusDisposition: Equatable {
    case complete
    case idle
    case dropped
}

func captureFrameStatusDisposition(_ rawValue: Int?) -> CaptureFrameStatusDisposition {
    guard let rawValue, let status = SCFrameStatus(rawValue: rawValue) else { return .dropped }
    if status == .complete { return .complete }
    if status == .idle { return .idle }
    return .dropped
}

private final class ScreenCaptureOutputBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable
{
    private enum CaptureSample {
        case frame(CapturedFrame)
        case idle
        case dropped
    }

    private let lock = NSLock()
    private let generation: UInt64
    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private let metrics: MediaPipelineMetrics
    private var active = true
    private var nextFrameIsDiscontinuous = false

    init(
        generation: UInt64,
        continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation,
        metrics: MediaPipelineMetrics
    ) {
        self.generation = generation
        self.continuation = continuation
        self.metrics = metrics
    }

    func deactivate() {
        lock.withLock { active = false }
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen, lock.withLock({ active }) else { return }
        let discontinuity = lock.withLock { nextFrameIsDiscontinuous }
        switch Self.frame(
            from: sampleBuffer,
            generation: generation,
            isDiscontinuous: discontinuity
        ) {
        case .idle:
            return
        case .dropped:
            lock.withLock { nextFrameIsDiscontinuous = true }
            Task { await metrics.recordCaptureDrop() }
            return
        case .frame(let frame):
            lock.withLock { nextFrameIsDiscontinuous = false }
            switch continuation.yield(frame) {
            case .dropped:
                Task { await metrics.recordCaptureDrop() }
                // Replace the just-enqueued frame with an equivalent discontinuous frame so
                // recovery does not depend on another ScreenCaptureKit callback arriving.
                _ = continuation.yield(frame.markingDiscontinuous())
            case .enqueued, .terminated:
                break
            @unknown default:
                break
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let shouldFinish = lock.withLock {
            let wasActive = active
            active = false
            return wasActive
        }
        guard shouldFinish else { return }
        continuation.finish(
            throwing: SessionError(
                code: .capStreamStopped, detail: "ScreenCaptureKit stopped: \(error.localizedDescription)")
        )
    }

    private static func frame(
        from sampleBuffer: CMSampleBuffer,
        generation: UInt64,
        isDiscontinuous: Bool
    ) -> CaptureSample {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return .dropped }
        guard
            let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false),
            let attachments = (attachmentArray as NSArray).firstObject as? [SCStreamFrameInfo: Any],
            let statusRaw = attachments[.status] as? Int
        else {
            return .dropped
        }
        switch captureFrameStatusDisposition(statusRaw) {
        case .idle:
            return .idle
        case .dropped:
            return .dropped
        case .complete:
            break
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return .dropped }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTimeStamp.isValid, presentationTimeStamp.isNumeric else { return .dropped }
        let captureTimestampUs: UInt64
        if let displayTime = attachments[.displayTime] as? UInt64 {
            captureTimestampUs = MediaClock.microseconds(machAbsoluteTime: displayTime)
        } else {
            captureTimestampUs = MediaClock.microseconds(presentationTimeStamp)
        }
        let contentRect: CGRect
        if let value = attachments[.contentRect] as? NSValue {
            contentRect = value.rectValue
        } else {
            contentRect = CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        return .frame(
            CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: presentationTimeStamp,
                captureTimestampUs: captureTimestampUs,
                callbackTimestampUs: MediaClock.monotonicMicroseconds(),
                contentRect: contentRect,
                generation: generation,
                isDiscontinuous: isDiscontinuous,
                dirtyAreaRatio: captureDirtyAreaRatio(
                    attachments[.dirtyRects], contentRect: contentRect)
            ))
    }
}

func captureDirtyAreaRatio(_ rawValue: Any?, contentRect: CGRect) -> Double {
    let rectangles: [CGRect]
    if let values = rawValue as? [CGRect] {
        rectangles = values
    } else if let values = rawValue as? [NSValue] {
        rectangles = values.map(\.rectValue)
    } else {
        return 1
    }
    let bounds = contentRect.standardized
    let totalArea = bounds.width * bounds.height
    guard totalArea.isFinite, totalArea > 0 else { return 1 }
    var dirtyArea = 0.0
    for rectangle in rectangles {
        let clipped = bounds.intersection(rectangle.standardized)
        guard !clipped.isNull, !clipped.isInfinite else { continue }
        dirtyArea += max(0, clipped.width) * max(0, clipped.height)
        if dirtyArea >= totalArea { return 1 }
    }
    return min(max(dirtyArea / totalArea, 0), 1)
}
