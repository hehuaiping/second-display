@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CryptoKit
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit
import SecondDisplayCore
import SharedProtocol
@preconcurrency import VideoToolbox
import VirtualDisplayCore
import XCTest

@testable import CapturePipeline

final class MediaPipelineTests: XCTestCase {
    func testCaptureIdleStatusIsNotClassifiedAsDrop() {
        XCTAssertEqual(captureFrameStatusDisposition(SCFrameStatus.complete.rawValue), .complete)
        XCTAssertEqual(captureFrameStatusDisposition(SCFrameStatus.idle.rawValue), .idle)
        XCTAssertEqual(captureFrameStatusDisposition(SCFrameStatus.blank.rawValue), .dropped)
        XCTAssertEqual(captureFrameStatusDisposition(nil), .dropped)
    }

    func testCaptureAndEncoderSpecificationsRejectUnsafeValues() throws {
        XCTAssertThrowsError(try CaptureSpec(width: 1279, height: 800))
        XCTAssertThrowsError(try CaptureSpec(width: 1280, height: 800, queueDepth: 2))
        XCTAssertThrowsError(try CaptureSpec(width: 1280, height: 800, queueDepth: 9))
        let capture = try CaptureSpec(width: 2560, height: 1600)
        XCTAssertEqual(capture.queueDepth, 3)
        XCTAssertEqual(capture.framesPerSecond, 60)

        XCTAssertThrowsError(try EncoderSpec(width: 1279, height: 800))
        XCTAssertThrowsError(try EncoderSpec(width: 1280, height: 800, bitrate: 7_999_999))
        XCTAssertThrowsError(try EncoderSpec(width: 1280, height: 800, bitrate: 30_000_001))
        XCTAssertEqual(try EncoderSpec(width: 1920, height: 1200).profile, .high)
    }

    func testLowLatencyRateControlAvoidsPeriodicIDRAndAllowsBoundedBurst() throws {
        let spec = try EncoderSpec(
            width: 2720,
            height: 1260,
            framesPerSecond: 60,
            bitrate: 8_000_000,
            maximumKeyFrameIntervalSeconds: 2)

        let lowLatencyPlan = VideoEncoderRateControlPlan(
            spec: spec,
            lowLatencyRateControlEnabled: true)
        XCTAssertNil(lowLatencyPlan.maximumKeyFrameIntervalFrames)
        XCTAssertNil(lowLatencyPlan.maximumKeyFrameIntervalDurationSeconds)
        XCTAssertEqual(lowLatencyPlan.dataRateLimitBytesPerSecond, 2_000_000)

        let fallbackPlan = VideoEncoderRateControlPlan(
            spec: spec,
            lowLatencyRateControlEnabled: false)
        XCTAssertEqual(fallbackPlan.maximumKeyFrameIntervalFrames, 120)
        XCTAssertEqual(fallbackPlan.maximumKeyFrameIntervalDurationSeconds, 2)
        XCTAssertEqual(fallbackPlan.dataRateLimitBytesPerSecond, 1_000_000)
    }

    func testCaptureUsesMaximumSourceCadenceAtRequestedRefreshRate() {
        XCTAssertEqual(
            captureMinimumFrameInterval(framesPerSecond: 60, sourceRefreshRate: 60),
            .zero
        )
        XCTAssertEqual(
            captureMinimumFrameInterval(framesPerSecond: 60, sourceRefreshRate: 59.94),
            .zero
        )
        XCTAssertEqual(
            captureMinimumFrameInterval(framesPerSecond: 30, sourceRefreshRate: 60),
            CMTime(value: 1, timescale: 30)
        )
    }

    func testMachDisplayTimeUsesCallbackMonotonicClockDomain() {
        let displayTimeUs = MediaClock.microseconds(machAbsoluteTime: mach_absolute_time())
        let callbackTimeUs = MediaClock.monotonicMicroseconds()
        let difference =
            displayTimeUs >= callbackTimeUs
            ? displayTimeUs - callbackTimeUs : callbackTimeUs - displayTimeUs
        XCTAssertLessThan(difference, 5_000)
    }

    func testCaptureFrameStreamRetainsOnlyNewestFrame() async throws {
        let pair = makeLatestCaptureFrameStream()
        let first = try makeFrame(width: 64, height: 64, sequence: 1, generation: 4)
        let newest = try makeFrame(width: 64, height: 64, sequence: 2, generation: 4)
        guard case .enqueued = pair.continuation.yield(first) else {
            return XCTFail("Expected the first capture frame to be enqueued")
        }
        guard case .dropped = pair.continuation.yield(newest) else {
            return XCTFail("Expected the older capture frame to be replaced")
        }
        pair.continuation.finish()

        let received = try await awaitValue(from: pair.stream)
        XCTAssertEqual(received.presentationTimeStamp, newest.presentationTimeStamp)
    }

    func testDirtyAreaRatioClipsRectsAndTreatsMissingMetadataAsActive() {
        let contentRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(captureDirtyAreaRatio(nil, contentRect: contentRect), 1)
        XCTAssertEqual(captureDirtyAreaRatio([CGRect](), contentRect: contentRect), 0)
        let dirtyRects = [
            NSValue(rect: CGRect(x: -10, y: -10, width: 60, height: 60)),
            NSValue(rect: CGRect(x: 90, y: 90, width: 20, height: 20)),
        ]
        XCTAssertEqual(
            captureDirtyAreaRatio(dirtyRects, contentRect: contentRect),
            0.26,
            accuracy: 0.0001)
    }

    func testAdaptiveBitrateUsesHysteresisAndRestoresActiveRateImmediately() {
        var controller = AdaptiveBitrateController(baseBitrate: 24_000_000)
        XCTAssertNil(controller.observe(dirtyAreaRatio: 0, timestampUs: 1_000_000))
        XCTAssertNil(controller.observe(dirtyAreaRatio: 0, timestampUs: 1_749_999))
        let staticDecision = controller.observe(dirtyAreaRatio: 0, timestampUs: 1_750_000)
        XCTAssertEqual(staticDecision?.bitrate, 13_200_000)
        XCTAssertEqual(staticDecision?.activity, .staticContent)
        guard let staticDecision else {
            return XCTFail("Expected a static bitrate transition")
        }
        controller.commit(staticDecision)
        XCTAssertEqual(controller.activity, .staticContent)

        let activeDecision = controller.observe(dirtyAreaRatio: 0.02, timestampUs: 1_760_000)
        XCTAssertEqual(activeDecision?.bitrate, 24_000_000)
        XCTAssertEqual(activeDecision?.activity, .active)
    }

    func testPipelineAppliesStaticBitrateAndRestoresItOnActivity() async throws {
        let encoder = FakeVideoEncoder(delayNanoseconds: 0, payloadBytes: 128)
        let pipeline = CaptureEncoderPipeline(videoEncoder: encoder)
        let output = EncodedFrameRecorder()
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .unbounded)
        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(width: 64, height: 64, bitrate: 12_000_000),
            generation: 12,
            isCurrentGeneration: { $0 == 12 },
            onEncodedFrame: { frame in await output.append(frame) }
        )
        let startedUs = MediaClock.monotonicMicroseconds()
        pair.continuation.yield(
            try makeFrame(
                width: 64, height: 64, sequence: 1, generation: 12,
                callbackTimestampUs: startedUs, dirtyAreaRatio: 0))
        try await waitForFrameCount(1, recorder: output)
        pair.continuation.yield(
            try makeFrame(
                width: 64, height: 64, sequence: 2, generation: 12,
                callbackTimestampUs: startedUs + 750_000, dirtyAreaRatio: 0))
        try await waitForFrameCount(2, recorder: output)
        pair.continuation.yield(
            try makeFrame(
                width: 64, height: 64, sequence: 3, generation: 12,
                callbackTimestampUs: startedUs + 760_000, dirtyAreaRatio: 0.02))
        pair.continuation.finish()
        try await waitForFrameCount(3, recorder: output)
        await pipeline.stop()

        let bitrateUpdates = await encoder.bitrateUpdates
        XCTAssertEqual(bitrateUpdates, [8_000_000, 12_000_000])
    }

    func testAnnexBConversionRejectsTruncationAndReportsNALTypes() throws {
        let avcc = Data([
            0, 0, 0, 3, 0x67, 0x64, 0,
            0, 0, 0, 2, 0x68, 0xee,
            0, 0, 0, 3, 0x65, 0x88, 0x84,
        ])
        let annexB = try H264AnnexB.convertAVCC(avcc)
        XCTAssertEqual(H264AnnexB.nalUnitTypes(in: annexB), [7, 8, 5])
        let twoByteLengths = Data([0, 2, 0x41, 0xaa, 0, 3, 0x65, 0xbb, 0xcc])
        XCTAssertEqual(
            H264AnnexB.nalUnitTypes(
                in: try H264AnnexB.convertAVCC(twoByteLengths, nalUnitHeaderLength: 2)),
            [1, 5])
        XCTAssertThrowsError(try H264AnnexB.convertAVCC(Data([0, 0, 0])))
        XCTAssertThrowsError(try H264AnnexB.convertAVCC(Data([0, 0, 0, 8, 0x65])))
    }

    func testHEVCAnnexBConversionReportsVPSAndIDRTypes() throws {
        let hvcc = Data([
            0, 0, 0, 2, 0x40, 0x01,
            0, 0, 0, 2, 0x42, 0x01,
            0, 0, 0, 2, 0x44, 0x01,
            0, 0, 0, 3, 0x26, 0x01, 0xaa,
        ])
        let annexB = try HEVCAnnexB.convertHVCC(hvcc)
        XCTAssertEqual(HEVCAnnexB.nalUnitTypes(in: annexB), [32, 33, 34, 19])
    }

    func testScreenCaptureEnumeratorMapsPermissionFailure() async {
        let enumerator = ScreenCaptureDisplayEnumerator(
            contentProvider: FakeShareableContentProvider(results: []),
            permissionChecker: FixedCapturePermission(isAuthorized: false)
        )
        do {
            _ = try await enumerator.displayIDs()
            XCTFail("Expected permission failure")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .capPermissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMediaMetricsCalculatePercentilesAndSeparateDropTypes() async {
        let metrics = MediaPipelineMetrics()
        await metrics.recordCaptureDrop(count: 2)
        await metrics.recordEncodeDrop()
        await metrics.recordEncodeDrop(reason: .staleBeforeEncode)
        await metrics.recordEncodeDrop(reason: .encoderRejected)
        await metrics.recordSendDrop(count: 4)
        await metrics.recordCaptureObserved()
        await metrics.recordCaptureObserved()
        await metrics.recordCapturedFrame(deliveryLatencyUs: 3_000)
        await metrics.recordCapturedFrame(deliveryLatencyUs: 9_000)
        await metrics.recordEncodeStarted(queueLatencyUs: 4_000)
        await metrics.recordEncodeStarted(queueLatencyUs: 12_000)
        await metrics.recordEncodedFrame(latencyUs: 1_000)
        await metrics.recordEncodedFrame(latencyUs: 2_000)
        await metrics.recordEncodedFrame(
            latencyUs: 10_000,
            videoToolboxLatencyUs: 8_000,
            bitstreamConversionLatencyUs: 2_000,
            encoderHardwareAccelerated: true,
            lowLatencyRateControlEnabled: true
        )
        await metrics.recordSendStarted(queueLatencyUs: 5_000)
        await metrics.recordSendStarted(queueLatencyUs: 15_000)
        await metrics.recordContentActivity(
            dirtyAreaRatio: 0.25,
            currentBitrate: 8_000_000,
            activity: .staticContent)
        let snapshot = await metrics.snapshot()
        XCTAssertEqual(snapshot.captureDropCount, 2)
        XCTAssertEqual(snapshot.encodeDropCount, 3)
        XCTAssertEqual(snapshot.encodeDropBreakdown.staleBeforeEncode, 1)
        XCTAssertEqual(snapshot.encodeDropBreakdown.queueReplacement, 0)
        XCTAssertEqual(snapshot.encodeDropBreakdown.encoderRejected, 1)
        XCTAssertEqual(snapshot.encodeDropBreakdown.recoveryDiscard, 0)
        XCTAssertEqual(snapshot.encodeDropBreakdown.failure, 0)
        XCTAssertEqual(snapshot.encodeDropBreakdown.unspecified, 1)
        XCTAssertEqual(snapshot.encodeDropBreakdown.total, snapshot.encodeDropCount)
        XCTAssertEqual(snapshot.sendDropCount, 4)
        XCTAssertEqual(snapshot.capturedFrameCount, 2)
        XCTAssertEqual(snapshot.captureDeliveryP50Milliseconds, 9)
        XCTAssertEqual(snapshot.captureDeliveryP95Milliseconds, 9)
        XCTAssertEqual(snapshot.encodeQueueP50Milliseconds, 12)
        XCTAssertEqual(snapshot.encodeQueueP95Milliseconds, 12)
        XCTAssertEqual(snapshot.encodeP50Milliseconds, 2)
        XCTAssertEqual(snapshot.encodeP95Milliseconds, 10)
        XCTAssertEqual(snapshot.videoToolboxP95Milliseconds, 8)
        XCTAssertEqual(snapshot.bitstreamConversionP95Milliseconds, 2)
        XCTAssertEqual(snapshot.encoderHardwareAccelerated, true)
        XCTAssertEqual(snapshot.lowLatencyRateControlEnabled, true)
        XCTAssertEqual(snapshot.sendQueueP50Milliseconds, 15)
        XCTAssertEqual(snapshot.sendQueueP95Milliseconds, 15)
        XCTAssertEqual(snapshot.dirtyAreaP95Percent, 25)
        XCTAssertEqual(snapshot.currentBitrate, 8_000_000)
        XCTAssertEqual(snapshot.contentActivity, .staticContent)
    }

    func testMediaMetricsSlidingWindowOverwritesOldSamplesWithoutChangingCapacity() async {
        let metrics = MediaPipelineMetrics(sampleCapacity: 4)
        for value in [1_000, 2_000, 3_000, 4_000, 8_000, 9_000] {
            await metrics.recordEncodedFrame(latencyUs: UInt64(value))
        }
        let snapshot = await metrics.snapshot()
        XCTAssertEqual(snapshot.encodedFrameCount, 6)
        XCTAssertEqual(snapshot.encodeP50Milliseconds, 8)
        XCTAssertEqual(snapshot.encodeP95Milliseconds, 9)
    }

    func testEncodeWatchdogReturnsProjectErrorAndSupportsCancellation() async throws {
        let timeoutGate = EncodeResultGate()
        do {
            _ = try await waitForEncodeResult(timeoutGate, timeoutNanoseconds: 1_000_000)
            XCTFail("Expected encode watchdog timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .encBackpressure)
        }

        let cancellationGate = EncodeResultGate()
        let task = Task {
            try await waitForEncodeResult(
                cancellationGate,
                timeoutNanoseconds: 10_000_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected encode wait cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCaptureServiceWaitsByDisplayIDAndRejectsOldGeneration() async throws {
        let provider = FakeShareableContentProvider(results: [
            [],
            [CaptureDisplay(displayID: 42)],
        ])
        let service = ScreenCaptureService(
            contentProvider: provider,
            permissionChecker: FixedCapturePermission(isAuthorized: true),
            onlineChecker: FixedDisplayOnlineChecker(isOnline: true)
        )
        let display = try await service.waitForDisplay(
            id: 42,
            generation: 7,
            timeoutNanoseconds: 1_000_000_000,
            isCurrentGeneration: { $0 == 7 }
        )
        XCTAssertEqual(display.displayID, 42)

        do {
            _ = try await service.waitForDisplay(
                id: 42,
                generation: 6,
                timeoutNanoseconds: 1_000_000_000,
                isCurrentGeneration: { $0 == 7 }
            )
            XCTFail("Expected cancellation for stale generation")
        } catch is CancellationError {
            // Expected.
        }
        await service.stop()
        await service.stop()
    }

    func testVideoToolboxProducesAnnexBIDRWithParameterSets() async throws {
        let encoder = H264EncoderService()
        try await encoder.configure(EncoderSpec(width: 1280, height: 800, bitrate: 8_000_000))
        let frame = try makeFrame(width: 1280, height: 800, sequence: 0, generation: 1)
        let optionalEncoded = try await encodeWhenVideoToolboxIsAvailable(encoder, frame: frame)
        let encoded = try XCTUnwrap(optionalEncoded)
        XCTAssertTrue(encoded.isKeyFrame)
        let types = H264AnnexB.nalUnitTypes(in: encoded.payload)
        XCTAssertTrue(types.contains(7), "IDR must contain SPS")
        XCTAssertTrue(types.contains(8), "IDR must contain PPS")
        XCTAssertTrue(types.contains(5), "Forced keyframe must contain an IDR slice")
        XCTAssertLessThanOrEqual(encoded.encodeCallbackTimestampUs, encoded.encodeCompleteTimestampUs)
        XCTAssertNotNil(encoded.encoderHardwareAccelerated)
        XCTAssertNotNil(encoded.lowLatencyRateControlEnabled)
        let framed = try XCTUnwrap(encoded.preframedData)
        let protocolFrame = VideoFrame(
            frameType: .video,
            flags: [.keyframe],
            sequence: encoded.sequence,
            ptsUs: encoded.presentationTimeStampUs,
            captureUs: encoded.captureTimestampUs,
            payload: encoded.payload,
            preframedData: framed)
        XCTAssertEqual(try VideoFrameCodec().encode(protocolFrame), framed)
        XCTAssertEqual(try VideoFrameCodec().decode(framed), protocolFrame)
        try await encoder.updateBitrate(12_000_000)
        await encoder.invalidate()
        do {
            _ = try await encoder.encode(frame, forceKeyFrame: false)
            XCTFail("Expected invalidated encoder to reject frames")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .encCreateFailed)
        }
    }

    func testHardwareHEVCProducesAnnexBIDRWithParameterSetsWhenAvailable() async throws {
        guard VideoEncoderCapability.supportsHardwareHEVC else {
            throw XCTSkip("Hardware HEVC encoder is unavailable")
        }
        let encoder = H264EncoderService()
        try await encoder.configure(
            EncoderSpec(
                width: 1280,
                height: 800,
                bitrate: 8_000_000,
                codec: .hevc
            )
        )
        let frame = try makeFrame(width: 1280, height: 800, sequence: 0, generation: 2)
        let optionalEncoded = try await encodeWhenVideoToolboxIsAvailable(encoder, frame: frame)
        let encoded = try XCTUnwrap(optionalEncoded)
        XCTAssertTrue(encoded.isKeyFrame)
        let types = HEVCAnnexB.nalUnitTypes(in: encoded.payload)
        XCTAssertTrue(types.contains(32), "HEVC IDR must contain VPS")
        XCTAssertTrue(types.contains(33), "HEVC IDR must contain SPS")
        XCTAssertTrue(types.contains(34), "HEVC IDR must contain PPS")
        XCTAssertTrue(types.contains(19) || types.contains(20), "Forced keyframe must contain HEVC IDR")
        XCTAssertEqual(encoded.encoderHardwareAccelerated, true)
        await encoder.invalidate()
    }

    func testHardwareEncoderLatencyBenchmarkWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_ENCODER_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RUN_ENCODER_BENCHMARK=1 to run the hardware encoder benchmark")
        }

        let codecs: [VideoEncoderCodec] =
            VideoEncoderCapability.supportsHardwareHEVC ? [.h264, .hevc] : [.h264]
        for codec in codecs {
            let encoder = H264EncoderService()
            try await encoder.configure(
                EncoderSpec(
                    width: 2720,
                    height: 1260,
                    framesPerSecond: 60,
                    bitrate: 8_000_000,
                    codec: codec))
            var callbackLatenciesUs: [UInt64] = []
            callbackLatenciesUs.reserveCapacity(180)
            for sequence in 0..<180 {
                let frame = try makeFrame(
                    width: 2720,
                    height: 1260,
                    sequence: sequence,
                    generation: 99)
                let submittedUs = MediaClock.monotonicMicroseconds()
                let encoded = try await encoder.encode(
                    frame,
                    forceKeyFrame: sequence == 0)
                guard let encoded else { continue }
                callbackLatenciesUs.append(
                    encoded.encodeCallbackTimestampUs >= submittedUs
                    ? encoded.encodeCallbackTimestampUs - submittedUs : 0)
            }
            await encoder.invalidate()

            let sorted = callbackLatenciesUs.sorted()
            XCTAssertGreaterThanOrEqual(sorted.count, 170)
            let p50 = percentile(sorted, percentile: 0.50)
            let p95 = percentile(sorted, percentile: 0.95)
            let p99 = percentile(sorted, percentile: 0.99)
            print(
                "ENCODER_BENCHMARK codec=\(codec.rawValue) frames=\(sorted.count) "
                    + "p50=\(formatMilliseconds(p50))ms "
                    + "p95=\(formatMilliseconds(p95))ms "
                    + "p99=\(formatMilliseconds(p99))ms")
        }
    }

    func testBackpressureDropsOldFramesAndForcesIDR() async throws {
        let encoder = FakeVideoEncoder(delayNanoseconds: 40_000_000, payloadBytes: 128)
        let metrics = MediaPipelineMetrics()
        let pipeline = CaptureEncoderPipeline(videoEncoder: encoder, metrics: metrics)
        let output = EncodedFrameRecorder()
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .unbounded)

        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(width: 64, height: 64, bitrate: 8_000_000),
            generation: 3,
            isCurrentGeneration: { $0 == 3 },
            onEncodedFrame: { frame in await output.append(frame) }
        )
        for index in 0..<12 {
            pair.continuation.yield(try makeFrame(width: 64, height: 64, sequence: index, generation: 3))
        }
        pair.continuation.finish()
        try await Task.sleep(nanoseconds: 500_000_000)
        await pipeline.stop()

        let snapshot = await metrics.snapshot()
        let frames = await output.frames
        XCTAssertGreaterThan(snapshot.encodeDropCount, 0)
        XCTAssertGreaterThan(snapshot.encodeDropBreakdown.queueReplacement, 0)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.first?.isKeyFrame == true)
        let maximumConcurrentEncodes = await encoder.maximumConcurrentEncodes
        let forcedKeyFrameRequests = await encoder.forcedKeyFrameRequests
        XCTAssertLessThanOrEqual(maximumConcurrentEncodes, 1)
        XCTAssertGreaterThanOrEqual(forcedKeyFrameRequests, 1)
    }

    func testContinuousCaptureDropsStillProduceRecoveryIDRBeforeBurstEnds() async throws {
        let encoder = FakeVideoEncoder(delayNanoseconds: 40_000_000, payloadBytes: 128)
        let pipeline = CaptureEncoderPipeline(videoEncoder: encoder)
        let output = EncodedFrameRecorder()
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .unbounded)

        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(width: 64, height: 64, bitrate: 8_000_000),
            generation: 13,
            isCurrentGeneration: { $0 == 13 },
            onEncodedFrame: { frame in await output.append(frame) }
        )
        pair.continuation.yield(try makeFrame(width: 64, height: 64, sequence: 0, generation: 13))
        try await Task.sleep(nanoseconds: 5_000_000)
        let producer = Task {
            for index in 1..<60 {
                pair.continuation.yield(
                    try makeFrame(width: 64, height: 64, sequence: index, generation: 13))
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            pair.continuation.finish()
        }
        try await Task.sleep(nanoseconds: 180_000_000)
        let framesDuringBurst = await output.frames
        XCTAssertFalse(
            framesDuringBurst.isEmpty, "A coalesced recovery IDR must escape during sustained input")
        XCTAssertTrue(framesDuringBurst.contains(where: \.isKeyFrame))
        _ = try await producer.value
        try await Task.sleep(nanoseconds: 150_000_000)
        await pipeline.stop()
    }

    func testPreEncodeAgeGateDropsOldCaptureAndSendsFreshIDR() async throws {
        let nowUs: UInt64 = 1_000_000
        let encoder = FakeVideoEncoder(delayNanoseconds: 0, payloadBytes: 128)
        let metrics = MediaPipelineMetrics()
        let pipeline = CaptureEncoderPipeline(
            videoEncoder: encoder,
            metrics: metrics,
            monotonicMicroseconds: { nowUs }
        )
        let output = EncodedFrameRecorder()
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .unbounded)
        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(width: 64, height: 64, bitrate: 8_000_000),
            generation: 17,
            isCurrentGeneration: { $0 == 17 },
            onEncodedFrame: { frame in await output.append(frame) }
        )

        let source = try makeFrame(
            width: 64,
            height: 64,
            sequence: 0,
            generation: 17,
            callbackTimestampUs: nowUs
        )
        let stale = CapturedFrame(
            pixelBuffer: source.pixelBuffer,
            presentationTimeStamp: source.presentationTimeStamp,
            captureTimestampUs: source.captureTimestampUs,
            callbackTimestampUs: nowUs > 100_000 ? nowUs - 100_000 : 0,
            contentRect: source.contentRect,
            generation: source.generation
        )
        pair.continuation.yield(stale)
        pair.continuation.yield(
            try makeFrame(
                width: 64,
                height: 64,
                sequence: 1,
                generation: 17,
                callbackTimestampUs: nowUs
            ))
        pair.continuation.finish()
        try await waitForFrameCount(1, recorder: output)
        await pipeline.stop()

        let snapshot = await metrics.snapshot()
        let frames = await output.frames
        let frame = try XCTUnwrap(frames.first)
        XCTAssertGreaterThanOrEqual(snapshot.encodeDropCount, 1)
        XCTAssertGreaterThanOrEqual(snapshot.encodeDropBreakdown.staleBeforeEncode, 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frame.isKeyFrame)
    }

    func testCaptureTimestampAgeGateDropsWindowServerBacklog() async throws {
        let nowUs: UInt64 = 1_000_000
        let encoder = FakeVideoEncoder(delayNanoseconds: 0, payloadBytes: 128)
        let metrics = MediaPipelineMetrics()
        let pipeline = CaptureEncoderPipeline(
            videoEncoder: encoder,
            metrics: metrics,
            monotonicMicroseconds: { nowUs }
        )
        let output = EncodedFrameRecorder()
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .unbounded)
        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(width: 64, height: 64, bitrate: 8_000_000),
            generation: 18,
            isCurrentGeneration: { $0 == 18 },
            onEncodedFrame: { frame in await output.append(frame) }
        )

        let source = try makeFrame(
            width: 64,
            height: 64,
            sequence: 0,
            generation: 18,
            callbackTimestampUs: nowUs
        )
        let stale = CapturedFrame(
            pixelBuffer: source.pixelBuffer,
            presentationTimeStamp: source.presentationTimeStamp,
            captureTimestampUs: nowUs > 100_000 ? nowUs - 100_000 : 1,
            callbackTimestampUs: nowUs,
            contentRect: source.contentRect,
            generation: source.generation
        )
        pair.continuation.yield(stale)
        pair.continuation.yield(
            try makeFrame(
                width: 64,
                height: 64,
                sequence: 1,
                generation: 18,
                callbackTimestampUs: nowUs
            ))
        pair.continuation.finish()
        try await waitForFrameCount(1, recorder: output)
        await pipeline.stop()

        let snapshot = await metrics.snapshot()
        let frames = await output.frames
        let frame = try XCTUnwrap(frames.first)
        XCTAssertGreaterThanOrEqual(snapshot.encodeDropCount, 1)
        XCTAssertGreaterThanOrEqual(snapshot.encodeDropBreakdown.staleBeforeEncode, 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frame.isKeyFrame)
    }

    func testCaptureTimestampAgeGateAcceptsBoundedSystemDeliveryLatency() async throws {
        let nowUs: UInt64 = 1_000_000
        let encoder = FakeVideoEncoder(delayNanoseconds: 0, payloadBytes: 128)
        let metrics = MediaPipelineMetrics()
        let pipeline = CaptureEncoderPipeline(
            videoEncoder: encoder,
            metrics: metrics,
            monotonicMicroseconds: { nowUs }
        )
        let output = EncodedFrameRecorder()
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(
            bufferingPolicy: .unbounded)
        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(
                width: 64, height: 64, framesPerSecond: 60, bitrate: 8_000_000),
            generation: 19,
            isCurrentGeneration: { $0 == 19 },
            onEncodedFrame: { frame in await output.append(frame) }
        )

        let source = try makeFrame(
            width: 64,
            height: 64,
            sequence: 0,
            generation: 19,
            callbackTimestampUs: nowUs
        )
        pair.continuation.yield(
            CapturedFrame(
                pixelBuffer: source.pixelBuffer,
                presentationTimeStamp: source.presentationTimeStamp,
                captureTimestampUs: nowUs - 40_000,
                callbackTimestampUs: nowUs,
                contentRect: source.contentRect,
                generation: source.generation
            ))
        pair.continuation.finish()
        try await waitForFrameCount(1, recorder: output)
        await pipeline.stop()

        let snapshot = await metrics.snapshot()
        let frames = await output.frames
        XCTAssertEqual(snapshot.encodeDropCount, 0)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(try XCTUnwrap(frames.first).isKeyFrame)
    }

    func testExplicitDecoderRecoveryRequestForcesNextIDR() async throws {
        let encoder = FakeVideoEncoder(delayNanoseconds: 0, payloadBytes: 128)
        let pipeline = CaptureEncoderPipeline(videoEncoder: encoder)
        let output = EncodedFrameRecorder()
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .unbounded)

        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(width: 64, height: 64, bitrate: 8_000_000),
            generation: 11,
            isCurrentGeneration: { $0 == 11 },
            onEncodedFrame: { frame in await output.append(frame) }
        )
        pair.continuation.yield(try makeFrame(width: 64, height: 64, sequence: 0, generation: 11))
        for _ in 0..<100 where await output.frames.count < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await pipeline.requestKeyFrame()
        pair.continuation.yield(try makeFrame(width: 64, height: 64, sequence: 1, generation: 11))
        pair.continuation.finish()
        for _ in 0..<100 where await output.frames.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await pipeline.stop()

        let frames = await output.frames
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.first?.isKeyFrame == true)
        XCTAssertTrue(frames.last?.isKeyFrame == true)
    }

    func testSendQueueIsBoundedAndCountsDrops() async throws {
        let encoder = FakeVideoEncoder(delayNanoseconds: 0, payloadBytes: 3 * 1024 * 1024)
        let metrics = MediaPipelineMetrics()
        let pipeline = CaptureEncoderPipeline(videoEncoder: encoder, metrics: metrics)
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .unbounded)

        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(width: 64, height: 64, bitrate: 8_000_000),
            generation: 9,
            isCurrentGeneration: { $0 == 9 },
            onEncodedFrame: { _ in try await Task.sleep(nanoseconds: 100_000_000) }
        )
        for index in 0..<16 {
            pair.continuation.yield(try makeFrame(width: 64, height: 64, sequence: index, generation: 9))
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        pair.continuation.finish()
        try await Task.sleep(nanoseconds: 450_000_000)
        await pipeline.stop()
        let snapshot = await metrics.snapshot()
        XCTAssertGreaterThan(snapshot.sendDropCount, 0)
    }

    func testOldGenerationNeverReachesSink() async throws {
        let encoder = FakeVideoEncoder(delayNanoseconds: 0, payloadBytes: 64)
        let pipeline = CaptureEncoderPipeline(videoEncoder: encoder)
        let output = EncodedFrameRecorder()
        let pair = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .unbounded)
        try await pipeline.start(
            frames: pair.stream,
            encoderConfiguration: EncoderSpec(width: 64, height: 64, bitrate: 8_000_000),
            generation: 5,
            isCurrentGeneration: { _ in false },
            onEncodedFrame: { frame in await output.append(frame) }
        )
        pair.continuation.yield(try makeFrame(width: 64, height: 64, sequence: 0, generation: 5))
        pair.continuation.finish()
        try await Task.sleep(nanoseconds: 50_000_000)
        await pipeline.stop()
        let recordedFrames = await output.frames
        XCTAssertTrue(recordedFrames.isEmpty)
    }

    func testCommittedMediaVectorsMatchManifestAndContainDecodableHeaders() throws {
        let manifestData = try TestSupport.vector("media/media_vectors.json")
        let manifest = try JSONDecoder().decode([TestVectorMetadata].self, from: manifestData)
        XCTAssertEqual(Set(manifest.map { [$0.width, $0.height] }), Set([[1280, 800], [1920, 1200]]))
        for entry in manifest {
            let payload = try TestSupport.vector("media/\(entry.path)")
            XCTAssertEqual(payload.count, entry.bytes)
            XCTAssertLessThan(payload.count, 512 * 1024)
            let sha256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(sha256, entry.sha256)
            XCTAssertEqual(entry.codec, "h264")
            XCTAssertEqual(entry.profile, "high")
            XCTAssertEqual(entry.fps, 60)
            let types = H264AnnexB.nalUnitTypes(in: payload)
            XCTAssertTrue(types.contains(7))
            XCTAssertTrue(types.contains(8))
            XCTAssertTrue(types.contains(5))
        }
    }

    @MainActor
    func testRealVirtualDisplayCaptureProducesNV12Frame() async throws {
        guard ProcessInfo.processInfo.environment["RUN_CAPTURE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_CAPTURE_INTEGRATION=1 for ScreenCaptureKit integration")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("The test process does not have Screen Recording permission")
        }

        let provider = CGVirtualDisplayProvider()
        let spec = try VirtualDisplaySpec(
            name: "Second Display P2 Capture",
            deviceId: UUID(uuidString: "07E1F14E-E3EC-4F5E-B450-1B909180D492") ?? UUID(),
            orientation: .landscape
        )
        let handle = try provider.create(spec: spec)
        let capture = ScreenCaptureService()
        do {
            let display = try await capture.waitForDisplay(
                id: handle.displayID,
                generation: 1,
                timeoutNanoseconds: 15_000_000_000,
                isCurrentGeneration: { $0 == 1 }
            )
            let frames = try await capture.start(
                display: display,
                configuration: CaptureSpec(width: 1280, height: 800, showsCursor: false),
                generation: 1
            )
            let frame = try await firstFrame(from: frames, timeoutNanoseconds: 10_000_000_000)
            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 1280)
            XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), 800)
            let encoder = H264EncoderService()
            try await encoder.configure(EncoderSpec(width: 1280, height: 800, bitrate: 8_000_000))
            let encoded = try await encoder.encode(frame, forceKeyFrame: true)
            let accessUnit = try XCTUnwrap(encoded)
            XCTAssertTrue(accessUnit.isKeyFrame)
            XCTAssertTrue(H264AnnexB.nalUnitTypes(in: accessUnit.payload).contains(5))
            await encoder.invalidate()
            await capture.stop()
            await capture.stop()
            await provider.destroy(handle)
        } catch {
            await capture.stop()
            await provider.destroy(handle)
            throw error
        }
    }

    private func encodeWhenVideoToolboxIsAvailable(
        _ encoder: H264EncoderService,
        frame: CapturedFrame
    ) async throws -> EncodedFrame? {
        do {
            return try await encoder.encode(frame, forceKeyFrame: true)
        } catch let error as SessionError {
            let unavailableStatuses = [
                kVTCouldNotFindVideoEncoderErr,
                kVTVideoEncoderNotAvailableNowErr,
            ]
            guard unavailableStatuses.contains(where: {
                error.detail.contains("OSStatus \($0)")
            }) else {
                throw error
            }
            await encoder.invalidate()
            throw XCTSkip("VideoToolbox encoder is unavailable in this execution environment")
        }
    }

    private func percentile(_ sorted: [UInt64], percentile: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * percentile).rounded(.up))))
        return sorted[index]
    }

    private func formatMilliseconds(_ microseconds: UInt64) -> String {
        String(format: "%.2f", Double(microseconds) / 1_000)
    }
}

private struct TestVectorMetadata: Decodable {
    let path: String
    let codec: String
    let profile: String
    let width: Int
    let height: Int
    let fps: Int
    let sha256: String
    let bytes: Int
}

private struct FixedCapturePermission: ScreenCapturePermissionChecking {
    let isAuthorizedValue: Bool

    init(isAuthorized: Bool) {
        self.isAuthorizedValue = isAuthorized
    }

    func isAuthorized() -> Bool { isAuthorizedValue }
}

private struct FixedDisplayOnlineChecker: DisplayOnlineChecking {
    let isOnlineValue: Bool

    init(isOnline: Bool) {
        self.isOnlineValue = isOnline
    }

    func isOnline(_ displayID: CGDirectDisplayID) -> Bool { isOnlineValue }
}

private actor FakeShareableContentProvider: ShareableContentProviding {
    private var results: [[CaptureDisplay]]
    private var index = 0

    init(results: [[CaptureDisplay]]) {
        self.results = results
    }

    func displays() -> [CaptureDisplay] {
        guard !results.isEmpty else { return [] }
        let result = results[min(index, results.count - 1)]
        index += 1
        return result
    }
}

private actor EncodedFrameRecorder {
    private(set) var frames: [EncodedFrame] = []

    func append(_ frame: EncodedFrame) {
        frames.append(frame)
    }
}

private actor FakeVideoEncoder: VideoEncoding {
    private let delayNanoseconds: UInt64
    private let payloadBytes: Int
    private var sequence: UInt32 = 0
    private var concurrentEncodes = 0
    private(set) var maximumConcurrentEncodes = 0
    private(set) var forcedKeyFrameRequests = 0
    private(set) var bitrateUpdates: [Int] = []

    init(delayNanoseconds: UInt64, payloadBytes: Int) {
        self.delayNanoseconds = delayNanoseconds
        self.payloadBytes = payloadBytes
    }

    func configure(_ spec: EncoderSpec) {}

    func encode(_ frame: CapturedFrame, forceKeyFrame: Bool) async throws -> EncodedFrame? {
        concurrentEncodes += 1
        maximumConcurrentEncodes = max(maximumConcurrentEncodes, concurrentEncodes)
        defer { concurrentEncodes -= 1 }
        if forceKeyFrame { forcedKeyFrameRequests += 1 }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        let output = EncodedFrame(
            sequence: sequence,
            presentationTimeStampUs: MediaClock.microseconds(frame.presentationTimeStamp),
            isKeyFrame: forceKeyFrame,
            captureTimestampUs: frame.captureTimestampUs,
            encodeCompleteTimestampUs: MediaClock.monotonicMicroseconds(),
            payload: Data(repeating: forceKeyFrame ? 0x65 : 0x41, count: payloadBytes),
            generation: frame.generation
        )
        sequence &+= 1
        return output
    }

    func updateBitrate(_ bitsPerSecond: Int) {
        bitrateUpdates.append(bitsPerSecond)
    }
    func invalidate() {}
}

private func makeFrame(
    width: Int,
    height: Int,
    sequence: Int,
    generation: UInt64,
    callbackTimestampUs: UInt64? = nil,
    dirtyAreaRatio: Double = 1
) throws -> CapturedFrame {
    var optionalBuffer: CVPixelBuffer?
    let attributes =
        [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes,
        &optionalBuffer
    )
    guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
        throw SessionError(code: .encCreateFailed, detail: "Unable to allocate test pixel buffer: \(status)")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
        let value: Int32 = plane == 0 ? Int32((sequence * 13) & 0xff) : 128
        memset(
            base, value,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    let pts = CMTime(value: CMTimeValue(sequence), timescale: 60)
    let callbackTimestampUs = callbackTimestampUs ?? MediaClock.monotonicMicroseconds()
    return CapturedFrame(
        pixelBuffer: buffer,
        presentationTimeStamp: pts,
        captureTimestampUs: callbackTimestampUs,
        callbackTimestampUs: callbackTimestampUs,
        contentRect: CGRect(x: 0, y: 0, width: width, height: height),
        generation: generation,
        dirtyAreaRatio: dirtyAreaRatio
    )
}

private func waitForFrameCount(
    _ expectedCount: Int,
    recorder: EncodedFrameRecorder,
    timeout: Duration = .seconds(2)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await recorder.frames.count >= expectedCount { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw SessionError(
        code: .capStreamStopped,
        detail: "Timed out waiting for \(expectedCount) encoded frames"
    )
}

private func awaitValue(
    from stream: AsyncThrowingStream<CapturedFrame, Error>
) async throws -> CapturedFrame {
    var iterator = stream.makeAsyncIterator()
    guard let frame = try await iterator.next() else {
        throw SessionError(code: .capStreamStopped, detail: "Capture stream ended without a frame")
    }
    return frame
}

private func firstFrame(
    from frames: AsyncThrowingStream<CapturedFrame, Error>,
    timeoutNanoseconds: UInt64
) async throws -> CapturedFrame {
    try await withThrowingTaskGroup(of: CapturedFrame.self) { group in
        group.addTask {
            var iterator = frames.makeAsyncIterator()
            guard let frame = try await iterator.next() else {
                throw SessionError(
                    code: .capStreamStopped, detail: "Capture stream ended before the first frame")
            }
            return frame
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw SessionError(code: .capStreamStopped, detail: "Timed out waiting for a capture frame")
        }
        guard let frame = try await group.next() else {
            throw SessionError(code: .capStreamStopped, detail: "Capture frame task ended unexpectedly")
        }
        group.cancelAll()
        return frame
    }
}
