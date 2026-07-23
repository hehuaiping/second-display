import Foundation
import SecondDisplayCore
import SharedProtocol

public struct ServerHandshakeNegotiator: Sendable {
    public let preferredWidth: Int
    public let preferredHeight: Int
    public let preferredFramesPerSecond: Int
    public let bitrate: Int
    public let supportedCodecs: [VideoCodec]
    public let supportedTransports: [VideoTransport]

    public init(
        preferredWidth: Int = 1920,
        preferredHeight: Int = 1200,
        preferredFramesPerSecond: Int = 60,
        bitrate: Int = 12_000_000,
        supportedCodecs: [VideoCodec] = [.h264],
        supportedTransports: [VideoTransport] = [.tlsTCP]
    ) {
        self.preferredWidth = preferredWidth
        self.preferredHeight = preferredHeight
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.bitrate = bitrate
        self.supportedCodecs = supportedCodecs
        self.supportedTransports = supportedTransports
    }

    public func negotiate(
        _ hello: ClientHello,
        sessionId: String,
        serialNumber: UInt32
    ) throws -> ServerReady {
        guard hello.protocolVersion == ProtocolConstants.version else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unsupported protocol version \(hello.protocolVersion)"
            )
        }
        guard
            let codec = supportedCodecs.first(where: hello.codecs.contains),
            let transport = supportedTransports.first(where: hello.videoTransports.contains),
            hello.maxFps > 0,
            hello.maxDecodeWidth >= 800, hello.maxDecodeHeight >= 600,
            !sessionId.isEmpty
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Client capabilities are incompatible")
        }

        var width = min(preferredWidth, hello.maxDecodeWidth)
        var height = min(preferredHeight, hello.maxDecodeHeight)
        width -= width % 2
        height -= height % 2
        guard width >= 800, height >= 600 else {
            throw SessionError(code: .netProtocolMismatch, detail: "No compatible even stream size")
        }
        guard
            let framesPerSecond = [120, 90, 60].first(where: {
                $0 <= preferredFramesPerSecond && $0 <= hello.maxFps
            })
        else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Receiver does not support the minimum 60 fps stream")
        }
        let negotiatedBitrate = min(
            30_000_000,
            max(
                8_000_000,
                Int((Double(bitrate) * Double(framesPerSecond) / 60).rounded())
            )
        )
        let display = DisplayConfiguration(
            logicalWidth: width / 2,
            logicalHeight: height / 2,
            framebufferWidth: width,
            framebufferHeight: height,
            refreshRate: framesPerSecond,
            serialNumber: serialNumber
        )
        let stream = StreamConfiguration(
            codec: codec,
            width: width,
            height: height,
            fps: framesPerSecond,
            bitrate: negotiatedBitrate,
            transport: transport
        )
        return ServerReady(sessionId: sessionId, display: display, stream: stream)
    }

    public func protocolError(for error: SessionError, generation: UInt64) -> ErrorControlMessage {
        ErrorControlMessage(
            errorCode: error.code,
            message: error.detail,
            generation: generation
        )
    }
}
