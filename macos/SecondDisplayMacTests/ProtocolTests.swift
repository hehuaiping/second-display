import Foundation
import SecondDisplayCore
import SharedProtocol
import XCTest

final class ProtocolTests: XCTestCase {
    private let codec = ControlMessageCodec()

    func testSwiftReadsAllControlVectors() throws {
        let hello = try XCTUnwrap(codec.decode(TestSupport.vector("control/client_hello_full.json")))
        let ready = try XCTUnwrap(codec.decode(TestSupport.vector("control/server_ready.json")))
        let error = try XCTUnwrap(codec.decode(TestSupport.vector("control/error_minimal.json")))
        let input = try XCTUnwrap(codec.decode(TestSupport.vector("control/input_scroll.json")))
        let gesture = try XCTUnwrap(codec.decode(TestSupport.vector("control/gesture_swipe.json")))
        let cursor = try XCTUnwrap(codec.decode(TestSupport.vector("control/cursor_position.json")))
        let keyFrame = try XCTUnwrap(codec.decode(TestSupport.vector("control/request_key_frame.json")))
        let heartbeat = try XCTUnwrap(codec.decode(TestSupport.vector("control/heartbeat.json")))
        let heartbeatAck = try XCTUnwrap(codec.decode(TestSupport.vector("control/heartbeat_ack.json")))
        let feedback = try XCTUnwrap(
            codec.decode(TestSupport.vector("control/receiver_feedback.json")))

        guard case .clientHello = hello, case .serverReady = ready, case .error = error,
            case .inputEvent = input, case .gestureEvent = gesture, case .cursorPosition = cursor,
            case .requestKeyFrame = keyFrame,
            case .heartbeat = heartbeat, case .heartbeatAck = heartbeatAck,
            case .receiverFeedback = feedback
        else {
            XCTFail("Unexpected decoded control message")
            return
        }
    }

    func testGestureMessageRoundTrip() throws {
        let gesture = GestureEventMessage(
            sessionId: "gesture-session",
            sequence: 12,
            fingerCount: 5,
            gestureType: .pinch,
            direction: .outward,
            magnitude: 0.4
        )
        let decoded = try XCTUnwrap(codec.decode(try codec.encode(gesture)))
        guard case .gestureEvent(let value) = decoded else {
            return XCTFail("Expected gestureEvent")
        }
        XCTAssertEqual(value, gesture)
    }

    func testClientHelloUsesExplicitDefaults() throws {
        let decoded = try XCTUnwrap(codec.decode(TestSupport.vector("control/client_hello_minimal.json")))
        guard case .clientHello(let hello) = decoded else {
            XCTFail("Expected clientHello")
            return
        }
        XCTAssertEqual(hello.deviceName, "Unknown Device")
        XCTAssertEqual(hello.deviceScale, 2)
        XCTAssertEqual(hello.maxFps, 60)
        XCTAssertEqual(hello.codecs, [.h264])
        XCTAssertEqual(hello.maxDecodeWidth, hello.nativeWidth)
        XCTAssertEqual(hello.maxDecodeHeight, hello.nativeHeight)
        XCTAssertEqual(hello.orientation, .landscape)
        XCTAssertEqual(hello.features, [])
        XCTAssertEqual(hello.videoTransports, [.tlsTCP])
    }

    func testReceiverFeedbackRoundTripAndBoundsValidation() throws {
        let feedback = ReceiverFeedback(
            sessionId: "session",
            sequence: 4,
            decoderQueueDepth: 2,
            droppedFrames: 3,
            renderedFramesPerSecond: 59.5,
            networkType: "wifi"
        )
        let decoded = try XCTUnwrap(codec.decode(try codec.encode(feedback)))
        guard case .receiverFeedback(let value) = decoded else {
            return XCTFail("Expected receiverFeedback")
        }
        XCTAssertEqual(value, feedback)

        let invalid = Data(
            #"{"type":"receiverFeedback","protocolVersion":1,"sessionId":"s","sequence":1,"decoderQueueDepth":65,"droppedFrames":0,"renderedFramesPerSecond":60,"networkType":"wifi"}"#
                .utf8
        )
        XCTAssertThrowsError(try codec.decode(invalid)) { error in
            XCTAssertEqual((error as? SessionError)?.code, .netProtocolMismatch)
        }
    }

    func testCursorSideChannelCapabilityAndMessageRoundTrip() throws {
        let hello = ClientHello(
            deviceId: "cursor-client",
            nativeWidth: 1920,
            nativeHeight: 1200,
            features: [.cursorSideChannelV1]
        )
        let decodedHello = try XCTUnwrap(codec.decode(try codec.encode(hello)))
        guard case .clientHello(let value) = decodedHello else {
            return XCTFail("Expected clientHello")
        }
        XCTAssertEqual(value.features, [.cursorSideChannelV1])

        let cursor = CursorPositionMessage(
            sessionId: "session",
            sequence: 7,
            normalizedX: 0.25,
            normalizedY: 0.75,
            visible: true
        )
        let decodedCursor = try XCTUnwrap(codec.decode(try codec.encode(cursor)))
        guard case .cursorPosition(let value) = decodedCursor else {
            return XCTFail("Expected cursorPosition")
        }
        XCTAssertEqual(value, cursor)
    }

    func testOtherMessagesUseExplicitDefaults() throws {
        let errorMessage = try XCTUnwrap(codec.decode(TestSupport.vector("control/error_minimal.json")))
        guard case .error(let error) = errorMessage else {
            XCTFail("Expected error")
            return
        }
        XCTAssertEqual(error.protocolVersion, 1)
        XCTAssertEqual(error.message, "")
        XCTAssertEqual(error.generation, 0)

        let request = try XCTUnwrap(codec.decode(TestSupport.vector("control/request_key_frame.json")))
        guard case .requestKeyFrame(let keyFrame) = request else {
            XCTFail("Expected requestKeyFrame")
            return
        }
        XCTAssertEqual(keyFrame.reason, "decoderRecovery")
    }

    func testUnknownControlMessageIsIgnored() throws {
        XCTAssertNil(try codec.decode(TestSupport.vector("control/unknown.json")))
    }

    func testOversizedControlMessageIsRejectedWithProjectError() {
        XCTAssertThrowsError(try codec.decode(Data(repeating: 0x20, count: 65 * 1024))) { error in
            XCTAssertEqual((error as? SessionError)?.code, .netProtocolMismatch)
        }
    }

    func testVideoFrameGoldenVectorAndRoundTrip() throws {
        let vectorData = try TestSupport.vector("video/frame_golden.json")
        let object = try JSONSerialization.jsonObject(with: vectorData)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let payloadHex = try XCTUnwrap(dictionary["payloadHex"] as? String)
        let encodedHex = try XCTUnwrap(dictionary["encodedHex"] as? String)
        let frame = VideoFrame(
            frameType: .video,
            flags: [.keyframe],
            sequence: 42,
            ptsUs: 1_000_000,
            captureUs: 900_000,
            payload: try TestSupport.data(hex: payloadHex)
        )
        let encoded = try VideoFrameCodec().encode(frame)
        XCTAssertEqual(encoded, try TestSupport.data(hex: encodedHex))
        XCTAssertEqual(try VideoFrameCodec().decode(encoded), frame)
    }

    func testVideoFrameRejectsBadMagicTruncationAndOversizedPayload() throws {
        let valid = try TestSupport.data(
            hex: "53445331010100010000002a00000000000f424000000000000dbba0000000050000000165"
        )
        var badMagic = valid
        badMagic[0] = 0
        assertProtocolError { _ = try VideoFrameCodec().decode(badMagic) }
        assertProtocolError { _ = try VideoFrameCodec().decode(valid.prefix(31)) }

        var oversized = Data(valid.prefix(VideoFrame.headerSize))
        oversized.replaceSubrange(28..<32, with: [0x01, 0x00, 0x00, 0x01])
        assertProtocolError { _ = try VideoFrameCodec().decode(oversized) }
    }

    private func assertProtocolError(_ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual((error as? SessionError)?.code, .netProtocolMismatch)
        }
    }
}
