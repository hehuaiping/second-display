import Foundation
import Network
import SecondDisplayCore
import SharedProtocol
import XCTest

@testable import TransportCore

final class TransportTests: XCTestCase {
    func testControlParserHandlesPartialAndStickyFramesAndIgnoresUnknown() throws {
        let codec = LengthPrefixedControlCodec()
        let first = try codec.encode(Heartbeat(sessionId: "session", sequence: 1, sentAtUs: 10))
        let unknownPayload = Data(#"{"type":"future","protocolVersion":1}"#.utf8)
        var unknown = Data()
        var unknownLength = UInt32(unknownPayload.count).bigEndian
        unknown.append(Data(bytes: &unknownLength, count: 4))
        unknown.append(unknownPayload)
        let second = try codec.encode(
            HeartbeatAck(sessionId: "session", sequence: 1, sentAtUs: 10, receivedAtUs: 12)
        )
        let combined = first + unknown + second

        var parser = IncrementalControlFrameParser()
        XCTAssertTrue(try parser.append(Data(combined.prefix(3))).isEmpty)
        XCTAssertTrue(try parser.append(Data(combined[3..<9])).isEmpty)
        let messages = try parser.append(Data(combined.dropFirst(9)))
        XCTAssertEqual(messages.count, 2)
        guard case .heartbeat(let heartbeat) = messages[0] else {
            return XCTFail("Expected heartbeat")
        }
        XCTAssertEqual(heartbeat.sequence, 1)
        guard case .heartbeatAck(let acknowledgement) = messages[1] else {
            return XCTFail("Expected heartbeat acknowledgement")
        }
        XCTAssertEqual(acknowledgement.receivedAtUs, 12)
        try parser.finish()
    }

    func testControlParserRejectsOversizedAndPartialFrames() throws {
        var parser = IncrementalControlFrameParser()
        var oversized = UInt32(ProtocolConstants.maximumControlMessageBytes + 1).bigEndian
        XCTAssertThrowsError(try parser.append(Data(bytes: &oversized, count: 4))) { error in
            XCTAssertEqual((error as? SessionError)?.code, .netProtocolMismatch)
        }

        let framed = try LengthPrefixedControlCodec().encode(
            Heartbeat(sessionId: "session", sequence: 0, sentAtUs: 0)
        )
        XCTAssertTrue(try parser.append(Data(framed.dropLast())).isEmpty)
        XCTAssertThrowsError(try parser.finish())
    }

    func testVideoParserHandlesPartialAndContinuousFrames() throws {
        let codec = VideoFrameCodec()
        let first = VideoFrame(
            frameType: .video,
            flags: [.keyframe],
            sequence: 1,
            ptsUs: 10,
            captureUs: 9,
            payload: Data([0, 0, 0, 1, 0x65])
        )
        let second = VideoFrame(
            frameType: .video,
            flags: [],
            sequence: 2,
            ptsUs: 20,
            captureUs: 19,
            payload: Data([0, 0, 0, 1, 0x41])
        )
        let bytes = try codec.encode(first) + codec.encode(second)
        var parser = IncrementalVideoFrameParser()
        XCTAssertTrue(try parser.append(Data(bytes.prefix(31))).isEmpty)
        XCTAssertEqual(try parser.append(Data(bytes.dropFirst(31))), [first, second])
        try parser.finish()
    }

    func testVideoSendQueueIsLimitedByFramesAndBytes() async {
        let queue = BoundedVideoSendQueue()
        let key = makeVideoFrame(sequence: 1, bytes: 3 * 1024 * 1024, keyframe: true)
        let delta = makeVideoFrame(sequence: 2, bytes: 3 * 1024 * 1024, keyframe: false)
        let replacement = makeVideoFrame(sequence: 3, bytes: 3 * 1024 * 1024, keyframe: false)
        let keyResult = await queue.enqueue(key)
        let deltaResult = await queue.enqueue(delta)
        XCTAssertTrue(keyResult.accepted)
        XCTAssertTrue(deltaResult.accepted)
        let result = await queue.enqueue(replacement)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.droppedFrames, 1)
        XCTAssertTrue(result.requiresKeyFrame)
        let depth = await queue.depth
        let bytes = await queue.bytes
        XCTAssertEqual(depth, 2)
        XCTAssertLessThanOrEqual(bytes, 8 * 1024 * 1024)
        await queue.finish()
    }

    func testHeartbeatTimeoutChangesStateAndOldGenerationAckIsIgnored() async throws {
        let clock = AdvancingTransportClock()
        let monitor = HeartbeatMonitor(
            clock: clock,
            intervalNanoseconds: 1_000_000,
            timeoutMicroseconds: 2_000
        )
        let failures = SessionErrorRecorder()
        await monitor.start(
            sessionId: "session",
            generation: 8,
            send: { _ in },
            onTimeout: { await failures.append($0) }
        )
        for _ in 0..<50 where await failures.errors.isEmpty {
            await Task.yield()
        }
        let errors = await failures.errors
        XCTAssertEqual(errors.first?.code, .netProtocolMismatch)
        await monitor.acknowledge(
            HeartbeatAck(sessionId: "session", sequence: 1, sentAtUs: 1, receivedAtUs: 2),
            generation: 7
        )
        await monitor.stop()
    }

    func testControlChannelReceivesChunksWithoutBlockingSender() async throws {
        let heartbeat = try LengthPrefixedControlCodec().encode(
            Heartbeat(sessionId: "session", sequence: 4, sentAtUs: 100)
        )
        let connection = FakeByteConnection(inbound: [
            Data(heartbeat.prefix(2)), Data(heartbeat.dropFirst(2)), nil,
        ])
        let channel = ControlChannel(connection: connection)
        let recorder = ControlMessageRecorder()
        let failures = SessionErrorRecorder()
        try await channel.start(
            generation: 3,
            onMessage: { await recorder.append($0) },
            onFailure: { await failures.append($0) }
        )
        for _ in 0..<50 {
            let receivedMessage = !(await recorder.messages).isEmpty
            let receivedFailure = !(await failures.errors).isEmpty
            if receivedMessage, receivedFailure { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let messages = await recorder.messages
        let receivedErrors = await failures.errors
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(receivedErrors.first?.code, .netProtocolMismatch)
        try await channel.send(Heartbeat(sessionId: "session", sequence: 5, sentAtUs: 110))
        let sent = await connection.sent
        XCTAssertEqual(sent.count, 1)
        await channel.stop()
        await channel.stop()
    }

    func testTLSParametersUseTCPNoDelay() {
        let parameters = TLSNetworkParameters.client()
        let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        XCTAssertEqual(options?.noDelay, true)
    }

    func testHandshakeNegotiatesCompatibleH264Configuration() throws {
        let hello = ClientHello(
            deviceId: "tablet",
            nativeWidth: 2560,
            nativeHeight: 1600,
            maxFps: 60,
            maxDecodeWidth: 1920,
            maxDecodeHeight: 1200
        )
        let ready = try ServerHandshakeNegotiator().negotiate(
            hello,
            sessionId: "session",
            serialNumber: 42
        )
        XCTAssertEqual(ready.protocolVersion, ProtocolConstants.version)
        XCTAssertEqual(ready.display.logicalWidth, 960)
        XCTAssertEqual(ready.stream.width, 1920)
        XCTAssertEqual(ready.stream.height, 1200)
        XCTAssertEqual(ready.stream.fps, 60)
    }

    func testHandshakeUsesReceiverSystemResolutionWhenPreferred() throws {
        let hello = ClientHello(
            deviceId: "harmony-system-display",
            nativeWidth: 2720,
            nativeHeight: 1260,
            maxFps: 60,
            maxDecodeWidth: 2720,
            maxDecodeHeight: 1260
        )
        let ready = try ServerHandshakeNegotiator(
            preferredWidth: hello.nativeWidth,
            preferredHeight: hello.nativeHeight
        ).negotiate(hello, sessionId: "dynamic-resolution", serialNumber: 43)

        XCTAssertEqual(ready.display.framebufferWidth, 2720)
        XCTAssertEqual(ready.display.framebufferHeight, 1260)
        XCTAssertEqual(ready.display.logicalWidth, 1360)
        XCTAssertEqual(ready.display.logicalHeight, 630)
        XCTAssertEqual(ready.stream.width, 2720)
        XCTAssertEqual(ready.stream.height, 1260)
    }

    func testHandshakeNegotiatesStandardHighRefreshRateAndScalesBitrate() throws {
        let hello = ClientHello(
            deviceId: "high-refresh-tablet",
            nativeWidth: 2720,
            nativeHeight: 1260,
            maxFps: 120
        )
        let oneTwenty = try ServerHandshakeNegotiator(
            preferredWidth: 2720,
            preferredHeight: 1260,
            preferredFramesPerSecond: 120,
            bitrate: 12_000_000
        ).negotiate(hello, sessionId: "120-fps", serialNumber: 44)
        XCTAssertEqual(oneTwenty.stream.fps, 120)
        XCTAssertEqual(oneTwenty.display.refreshRate, 120)
        XCTAssertEqual(oneTwenty.stream.bitrate, 24_000_000)

        let ninety = try ServerHandshakeNegotiator(
            preferredWidth: 2720,
            preferredHeight: 1260,
            preferredFramesPerSecond: 90,
            bitrate: 12_000_000
        ).negotiate(hello, sessionId: "90-fps", serialNumber: 45)
        XCTAssertEqual(ninety.stream.fps, 90)
        XCTAssertEqual(ninety.stream.bitrate, 18_000_000)
    }

    func testHandshakeRejectsReceiverBelowSixtyFps() {
        let hello = ClientHello(
            deviceId: "slow-tablet",
            nativeWidth: 1920,
            nativeHeight: 1200,
            maxFps: 30
        )
        XCTAssertThrowsError(
            try ServerHandshakeNegotiator(preferredFramesPerSecond: 120)
                .negotiate(hello, sessionId: "slow", serialNumber: 46))
    }

    func testHandshakeNegotiatesHEVCAndQUICOnlyWhenBothPeersAdvertiseThem() throws {
        let capable = ClientHello(
            deviceId: "capable",
            nativeWidth: 1920,
            nativeHeight: 1200,
            codecs: [.hevc, .h264],
            videoTransports: [.quicDatagram, .tlsTCP]
        )
        let ready = try ServerHandshakeNegotiator(
            supportedCodecs: [.hevc, .h264],
            supportedTransports: [.quicDatagram, .tlsTCP]
        ).negotiate(capable, sessionId: "new", serialNumber: 50)
        XCTAssertEqual(ready.stream.codec, .hevc)
        XCTAssertEqual(ready.stream.transport, .quicDatagram)

        let legacy = ClientHello(
            deviceId: "legacy",
            nativeWidth: 1920,
            nativeHeight: 1200
        )
        let fallback = try ServerHandshakeNegotiator(
            supportedCodecs: [.hevc, .h264],
            supportedTransports: [.quicDatagram, .tlsTCP]
        ).negotiate(legacy, sessionId: "legacy", serialNumber: 51)
        XCTAssertEqual(fallback.stream.codec, .h264)
        XCTAssertEqual(fallback.stream.transport, .tlsTCP)
    }

    func testVideoDatagramReassemblyHandlesOutOfOrderAndOldGeneration() async throws {
        let frame = Data((0..<7_000).map { UInt8($0 % 251) })
        let datagrams = try VideoDatagramPacketizer(maximumDatagramBytes: 1_200)
            .packetize(frame, sequence: 7)
        XCTAssertGreaterThan(datagrams.count, 1)
        XCTAssertTrue(datagrams.allSatisfy { $0.count <= 1_200 })

        let reassembler = VideoDatagramReassembler()
        await reassembler.begin(generation: 9)
        var completed: Data?
        for datagram in datagrams.reversed() {
            let result = try await reassembler.append(
                datagram,
                generation: 9,
                receivedAtUs: 10
            )
            completed = result.frame ?? completed
        }
        XCTAssertEqual(completed, frame)
        let stale = try await reassembler.append(
            datagrams[0],
            generation: 8,
            receivedAtUs: 20
        )
        XCTAssertNil(stale.frame)
    }

    func testVideoDatagramTimeoutDropsIncompleteFrameAndRequestsKeyFrame() async throws {
        let packetizer = VideoDatagramPacketizer(maximumDatagramBytes: 100)
        let first = try packetizer.packetize(Data(repeating: 1, count: 200), sequence: 1)
        let second = try packetizer.packetize(Data(repeating: 2, count: 200), sequence: 2)
        let reassembler = VideoDatagramReassembler(timeoutMicroseconds: 100)
        await reassembler.begin(generation: 3)
        _ = try await reassembler.append(first[0], generation: 3, receivedAtUs: 0)
        let result = try await reassembler.append(second[0], generation: 3, receivedAtUs: 101)
        XCTAssertEqual(result.droppedFrames, 1)
        XCTAssertTrue(result.requiresKeyFrame)
    }

    func testNetworkAdaptationUsesHysteresisForBitrateAndResolution() {
        var controller = NetworkAdaptiveController(baseBitrate: 20_000_000)
        let severe = NetworkAdaptationSample(
            roundTripMilliseconds: 130,
            senderQueueDepth: 2,
            receiverQueueDepth: 4,
            droppedFramesDelta: 4,
            renderedFramesPerSecond: 30,
            targetFramesPerSecond: 60
        )
        XCTAssertNil(controller.observe(severe))
        XCTAssertEqual(controller.observe(severe)?.bitrateCeiling, 16_000_000)
        var rebuild: NetworkAdaptationDecision?
        for _ in 0..<20 {
            if let decision = controller.observe(severe), decision.requiresStreamRebuild {
                rebuild = decision
                break
            }
        }
        XCTAssertNotNil(rebuild)
        XCTAssertLessThan(rebuild?.resolutionScale ?? 1, 1)
    }

    func testNetworkInterfaceClassificationPrefersUSBOrEthernet() {
        XCTAssertEqual(
            NetworkPathObserver.classify(
                statusSatisfied: true,
                usesWiFi: true,
                usesWiredEthernet: true,
                usesCellular: false
            ),
            .wiredOrUSB
        )
        XCTAssertEqual(
            NetworkPathObserver.classify(
                statusSatisfied: false,
                usesWiFi: true,
                usesWiredEthernet: false,
                usesCellular: false
            ),
            .unavailable
        )
    }

    func testProtocolMismatchSendsStructuredErrorBeforeFailure() async throws {
        let payload = Data(
            #"{"type":"clientHello","protocolVersion":2,"deviceId":"tablet","nativeWidth":1920,"nativeHeight":1200}"#
                .utf8
        )
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        let connection = FakeByteConnection(inbound: [framed])
        let channel = ControlChannel(connection: connection)
        let failures = SessionErrorRecorder()
        try await channel.start(
            generation: 9,
            onMessage: { _ in },
            onFailure: { await failures.append($0) }
        )
        for _ in 0..<50 where await connection.sent.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let sent = await connection.sent
        XCTAssertEqual(sent.count, 1)
        var parser = IncrementalControlFrameParser()
        let messages = try parser.append(sent[0])
        guard case .error(let response) = messages.first else {
            return XCTFail("Expected structured protocol error")
        }
        XCTAssertEqual(response.errorCode, .netProtocolMismatch)
        XCTAssertEqual(response.generation, 9)
        await channel.stop()
    }
}

private func makeVideoFrame(sequence: UInt32, bytes: Int, keyframe: Bool) -> VideoFrame {
    VideoFrame(
        frameType: .video,
        flags: keyframe ? [.keyframe] : [],
        sequence: sequence,
        ptsUs: UInt64(sequence),
        captureUs: UInt64(sequence),
        payload: Data(repeating: keyframe ? 0x65 : 0x41, count: bytes)
    )
}

private final class AdvancingTransportClock: TransportClock, @unchecked Sendable {
    private let lock = NSLock()
    private var nowUs: UInt64 = 0

    func nowMicroseconds() -> UInt64 {
        lock.withLock { nowUs }
    }

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        lock.withLock { nowUs &+= nanoseconds / 1_000 }
        await Task.yield()
    }
}

private actor SessionErrorRecorder {
    private(set) var errors: [SessionError] = []
    func append(_ error: SessionError) { errors.append(error) }
}

private actor ControlMessageRecorder {
    private(set) var messages: [ControlMessage] = []
    func append(_ message: ControlMessage) { messages.append(message) }
}

private actor FakeByteConnection: ByteTransportConnection {
    private var inbound: [Data?]
    private(set) var sent: [Data] = []
    private(set) var cancelled = false

    init(inbound: [Data?]) {
        self.inbound = inbound
    }

    func start() {}

    func send(_ data: Data) {
        sent.append(data)
    }

    func receive(maximumLength: Int) -> Data? {
        guard !inbound.isEmpty else { return nil }
        return inbound.removeFirst()
    }

    func cancel() {
        cancelled = true
    }
}
