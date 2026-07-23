import Foundation
import SecondDisplayCore

public enum ProtocolConstants {
    public static let version = 1
    public static let maximumControlMessageBytes = 64 * 1024
}

public enum VideoCodec: String, Codable, Sendable {
    case h264
    case hevc
}

public enum VideoTransport: String, Codable, Sendable {
    case tlsTCP = "tlsTcp"
    case quicDatagram
}

public enum DisplayOrientation: String, Codable, Sendable {
    case landscape
    case portrait
}

public enum ClientFeature: String, Codable, Sendable {
    case cursorSideChannelV1
    case dynamicStreamV1
    case networkMigrationV1
    case multiDisplayV1
    case quicDatagramV1
}

public struct ClientHello: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let deviceId: String
    public let deviceName: String
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let deviceScale: Double
    public let maxFps: Int
    public let codecs: [VideoCodec]
    public let maxDecodeWidth: Int
    public let maxDecodeHeight: Int
    public let orientation: DisplayOrientation
    public let features: [ClientFeature]
    public let videoTransports: [VideoTransport]

    public init(
        deviceId: String,
        deviceName: String = "Unknown Device",
        nativeWidth: Int,
        nativeHeight: Int,
        deviceScale: Double = 2,
        maxFps: Int = 60,
        codecs: [VideoCodec] = [.h264],
        maxDecodeWidth: Int? = nil,
        maxDecodeHeight: Int? = nil,
        orientation: DisplayOrientation = .landscape,
        features: [ClientFeature] = [],
        videoTransports: [VideoTransport] = [.tlsTCP]
    ) {
        self.type = "clientHello"
        self.protocolVersion = ProtocolConstants.version
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.deviceScale = deviceScale
        self.maxFps = maxFps
        self.codecs = codecs
        self.maxDecodeWidth = maxDecodeWidth ?? nativeWidth
        self.maxDecodeHeight = maxDecodeHeight ?? nativeHeight
        self.orientation = orientation
        self.features = features
        self.videoTransports = videoTransports
    }

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, deviceId, deviceName, nativeWidth, nativeHeight
        case deviceScale, maxFps, codecs, maxDecodeWidth, maxDecodeHeight, orientation, features
        case videoTransports
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        deviceName = try values.decodeIfPresent(String.self, forKey: .deviceName) ?? "Unknown Device"
        nativeWidth = try values.decode(Int.self, forKey: .nativeWidth)
        nativeHeight = try values.decode(Int.self, forKey: .nativeHeight)
        deviceScale = try values.decodeIfPresent(Double.self, forKey: .deviceScale) ?? 2
        maxFps = try values.decodeIfPresent(Int.self, forKey: .maxFps) ?? 60
        codecs = try values.decodeIfPresent([VideoCodec].self, forKey: .codecs) ?? [.h264]
        maxDecodeWidth = try values.decodeIfPresent(Int.self, forKey: .maxDecodeWidth) ?? nativeWidth
        maxDecodeHeight = try values.decodeIfPresent(Int.self, forKey: .maxDecodeHeight) ?? nativeHeight
        orientation = try values.decodeIfPresent(DisplayOrientation.self, forKey: .orientation) ?? .landscape
        features = try values.decodeIfPresent([ClientFeature].self, forKey: .features) ?? []
        videoTransports =
            try values.decodeIfPresent([VideoTransport].self, forKey: .videoTransports) ?? [.tlsTCP]
    }
}

public struct DisplayConfiguration: Codable, Equatable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let framebufferWidth: Int
    public let framebufferHeight: Int
    public let refreshRate: Int
    public let serialNumber: UInt32

    public init(
        logicalWidth: Int,
        logicalHeight: Int,
        framebufferWidth: Int,
        framebufferHeight: Int,
        refreshRate: Int,
        serialNumber: UInt32
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.framebufferWidth = framebufferWidth
        self.framebufferHeight = framebufferHeight
        self.refreshRate = refreshRate
        self.serialNumber = serialNumber
    }
}

public struct StreamConfiguration: Codable, Equatable, Sendable {
    public let codec: VideoCodec
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrate: Int
    public let transport: VideoTransport

    public init(
        codec: VideoCodec,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        transport: VideoTransport = .tlsTCP
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey {
        case codec, width, height, fps, bitrate, transport
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codec = try values.decode(VideoCodec.self, forKey: .codec)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        fps = try values.decode(Int.self, forKey: .fps)
        bitrate = try values.decode(Int.self, forKey: .bitrate)
        transport =
            try values.decodeIfPresent(VideoTransport.self, forKey: .transport) ?? .tlsTCP
    }
}

public struct ServerReady: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let sessionId: String
    public let display: DisplayConfiguration
    public let stream: StreamConfiguration

    public init(sessionId: String, display: DisplayConfiguration, stream: StreamConfiguration) {
        self.type = "serverReady"
        self.protocolVersion = ProtocolConstants.version
        self.sessionId = sessionId
        self.display = display
        self.stream = stream
    }
}

public struct ErrorControlMessage: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let errorCode: SessionErrorCode
    public let message: String
    public let sessionId: String?
    public let generation: UInt64

    public init(
        errorCode: SessionErrorCode,
        message: String = "",
        sessionId: String? = nil,
        generation: UInt64 = 0
    ) {
        self.type = "error"
        self.protocolVersion = ProtocolConstants.version
        self.errorCode = errorCode
        self.message = message
        self.sessionId = sessionId
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, errorCode, message, sessionId, generation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        protocolVersion =
            try values.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? ProtocolConstants.version
        errorCode = try values.decode(SessionErrorCode.self, forKey: .errorCode)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? ""
        sessionId = try values.decodeIfPresent(String.self, forKey: .sessionId)
        generation = try values.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
    }
}

public enum InputEventKind: String, Codable, Sendable {
    case move
    case leftDown
    case leftUp
    case drag
    case scroll
}

public struct InputEventMessage: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let sessionId: String
    public let sequence: UInt64
    public let eventType: InputEventKind
    public let normalizedX: Double?
    public let normalizedY: Double?
    public let deltaX: Double
    public let deltaY: Double

    public init(
        sessionId: String,
        sequence: UInt64,
        eventType: InputEventKind,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        deltaX: Double = 0,
        deltaY: Double = 0
    ) {
        self.type = "inputEvent"
        self.protocolVersion = ProtocolConstants.version
        self.sessionId = sessionId
        self.sequence = sequence
        self.eventType = eventType
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.deltaX = deltaX
        self.deltaY = deltaY
    }

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, sessionId, sequence, eventType
        case normalizedX, normalizedY, deltaX, deltaY
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        protocolVersion =
            try values.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? ProtocolConstants.version
        sessionId = try values.decode(String.self, forKey: .sessionId)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        eventType = try values.decode(InputEventKind.self, forKey: .eventType)
        normalizedX = try values.decodeIfPresent(Double.self, forKey: .normalizedX)
        normalizedY = try values.decodeIfPresent(Double.self, forKey: .normalizedY)
        deltaX = try values.decodeIfPresent(Double.self, forKey: .deltaX) ?? 0
        deltaY = try values.decodeIfPresent(Double.self, forKey: .deltaY) ?? 0
    }
}

public enum GestureType: String, Codable, Sendable {
    case swipe
    case pinch
}

public enum GestureDirection: String, Codable, Sendable {
    case up
    case down
    case left
    case right
    case inward = "in"
    case outward = "out"
}

public struct GestureEventMessage: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let sessionId: String
    public let sequence: UInt64
    public let fingerCount: Int
    public let gestureType: GestureType
    public let direction: GestureDirection
    public let magnitude: Double

    public init(
        sessionId: String,
        sequence: UInt64,
        fingerCount: Int,
        gestureType: GestureType,
        direction: GestureDirection,
        magnitude: Double
    ) {
        self.type = "gestureEvent"
        self.protocolVersion = ProtocolConstants.version
        self.sessionId = sessionId
        self.sequence = sequence
        self.fingerCount = fingerCount
        self.gestureType = gestureType
        self.direction = direction
        self.magnitude = magnitude
    }
}

public struct RequestKeyFrame: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let sessionId: String
    public let sequence: UInt64
    public let reason: String

    public init(sessionId: String, sequence: UInt64, reason: String = "decoderRecovery") {
        self.type = "requestKeyFrame"
        self.protocolVersion = ProtocolConstants.version
        self.sessionId = sessionId
        self.sequence = sequence
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, sessionId, sequence, reason
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        protocolVersion =
            try values.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? ProtocolConstants.version
        sessionId = try values.decode(String.self, forKey: .sessionId)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? "decoderRecovery"
    }
}

public struct CursorPositionMessage: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let sessionId: String
    public let sequence: UInt64
    public let normalizedX: Double
    public let normalizedY: Double
    public let visible: Bool

    public init(
        sessionId: String,
        sequence: UInt64,
        normalizedX: Double,
        normalizedY: Double,
        visible: Bool
    ) {
        self.type = "cursorPosition"
        self.protocolVersion = ProtocolConstants.version
        self.sessionId = sessionId
        self.sequence = sequence
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.visible = visible
    }
}

public struct Heartbeat: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let sessionId: String
    public let sequence: UInt64
    public let sentAtUs: UInt64

    public init(sessionId: String, sequence: UInt64, sentAtUs: UInt64) {
        self.type = "heartbeat"
        self.protocolVersion = ProtocolConstants.version
        self.sessionId = sessionId
        self.sequence = sequence
        self.sentAtUs = sentAtUs
    }
}

public struct HeartbeatAck: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let sessionId: String
    public let sequence: UInt64
    public let sentAtUs: UInt64
    public let receivedAtUs: UInt64

    public init(
        sessionId: String,
        sequence: UInt64,
        sentAtUs: UInt64,
        receivedAtUs: UInt64
    ) {
        self.type = "heartbeatAck"
        self.protocolVersion = ProtocolConstants.version
        self.sessionId = sessionId
        self.sequence = sequence
        self.sentAtUs = sentAtUs
        self.receivedAtUs = receivedAtUs
    }
}

public struct ReceiverFeedback: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let sessionId: String
    public let sequence: UInt64
    public let decoderQueueDepth: Int
    public let droppedFrames: UInt64
    public let renderedFramesPerSecond: Double
    public let networkType: String

    public init(
        sessionId: String,
        sequence: UInt64,
        decoderQueueDepth: Int,
        droppedFrames: UInt64,
        renderedFramesPerSecond: Double,
        networkType: String
    ) {
        self.type = "receiverFeedback"
        self.protocolVersion = ProtocolConstants.version
        self.sessionId = sessionId
        self.sequence = sequence
        self.decoderQueueDepth = decoderQueueDepth
        self.droppedFrames = droppedFrames
        self.renderedFramesPerSecond = renderedFramesPerSecond
        self.networkType = networkType
    }

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, sessionId, sequence, decoderQueueDepth
        case droppedFrames, renderedFramesPerSecond, networkType
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        protocolVersion =
            try values.decodeIfPresent(Int.self, forKey: .protocolVersion)
            ?? ProtocolConstants.version
        sessionId = try values.decode(String.self, forKey: .sessionId)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        decoderQueueDepth = try values.decode(Int.self, forKey: .decoderQueueDepth)
        droppedFrames = try values.decode(UInt64.self, forKey: .droppedFrames)
        renderedFramesPerSecond = try values.decode(
            Double.self, forKey: .renderedFramesPerSecond)
        networkType = try values.decode(String.self, forKey: .networkType)
        guard !sessionId.isEmpty, sessionId.count <= 128,
            (0...64).contains(decoderQueueDepth),
            renderedFramesPerSecond.isFinite,
            (0...240).contains(renderedFramesPerSecond),
            !networkType.isEmpty,
            networkType.utf8.count <= 32
        else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Invalid receiver feedback"
            )
        }
    }
}

public enum ControlMessage: Equatable, Sendable {
    case clientHello(ClientHello)
    case serverReady(ServerReady)
    case error(ErrorControlMessage)
    case inputEvent(InputEventMessage)
    case gestureEvent(GestureEventMessage)
    case cursorPosition(CursorPositionMessage)
    case requestKeyFrame(RequestKeyFrame)
    case heartbeat(Heartbeat)
    case heartbeatAck(HeartbeatAck)
    case receiverFeedback(ReceiverFeedback)
}

public struct ControlMessageCodec: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> ControlMessage? {
        guard data.count <= ProtocolConstants.maximumControlMessageBytes else {
            throw SessionError(code: .netProtocolMismatch, detail: "Control message exceeds 64 KiB")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SessionError(code: .netProtocolMismatch, detail: "Invalid control JSON")
        }
        guard
            let dictionary = object as? [String: Any],
            let type = dictionary["type"] as? String
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Control message type is missing")
        }
        guard
            type == "clientHello" || type == "serverReady" || type == "error"
                || type == "inputEvent" || type == "gestureEvent" || type == "cursorPosition"
                || type == "requestKeyFrame" || type == "heartbeat"
                || type == "heartbeatAck" || type == "receiverFeedback"
        else {
            return nil
        }
        let decoder = JSONDecoder()
        let message: ControlMessage
        do {
            switch type {
            case "clientHello": message = .clientHello(try decoder.decode(ClientHello.self, from: data))
            case "serverReady": message = .serverReady(try decoder.decode(ServerReady.self, from: data))
            case "error": message = .error(try decoder.decode(ErrorControlMessage.self, from: data))
            case "inputEvent": message = .inputEvent(try decoder.decode(InputEventMessage.self, from: data))
            case "gestureEvent":
                message = .gestureEvent(try decoder.decode(GestureEventMessage.self, from: data))
            case "cursorPosition":
                message = .cursorPosition(try decoder.decode(CursorPositionMessage.self, from: data))
            case "requestKeyFrame":
                message = .requestKeyFrame(try decoder.decode(RequestKeyFrame.self, from: data))
            case "heartbeat": message = .heartbeat(try decoder.decode(Heartbeat.self, from: data))
            case "heartbeatAck": message = .heartbeatAck(try decoder.decode(HeartbeatAck.self, from: data))
            case "receiverFeedback":
                message = .receiverFeedback(try decoder.decode(ReceiverFeedback.self, from: data))
            default: return nil
            }
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError(code: .netProtocolMismatch, detail: "Invalid \(type) message")
        }
        try validateVersion(message)
        return message
    }

    public func encode<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(message)
            guard data.count <= ProtocolConstants.maximumControlMessageBytes else {
                throw SessionError(code: .netProtocolMismatch, detail: "Control message exceeds 64 KiB")
            }
            return data
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError(code: .netProtocolMismatch, detail: "Unable to encode control message")
        }
    }

    private func validateVersion(_ message: ControlMessage) throws {
        let version: Int
        switch message {
        case .clientHello(let value): version = value.protocolVersion
        case .serverReady(let value): version = value.protocolVersion
        case .error(let value): version = value.protocolVersion
        case .inputEvent(let value): version = value.protocolVersion
        case .gestureEvent(let value): version = value.protocolVersion
        case .cursorPosition(let value): version = value.protocolVersion
        case .requestKeyFrame(let value): version = value.protocolVersion
        case .heartbeat(let value): version = value.protocolVersion
        case .heartbeatAck(let value): version = value.protocolVersion
        case .receiverFeedback(let value): version = value.protocolVersion
        }
        guard version == ProtocolConstants.version else {
            throw SessionError(code: .netProtocolMismatch, detail: "Unsupported protocol version \(version)")
        }
    }
}
