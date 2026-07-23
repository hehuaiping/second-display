import Foundation

public enum SessionErrorCode: String, Codable, CaseIterable, Sendable {
    case vdCapabilityMissing = "VD_CAPABILITY_MISSING"
    case vdApplyFailed = "VD_APPLY_FAILED"
    case vdEnumerationTimeout = "VD_ENUMERATION_TIMEOUT"
    case vdHiDPIModeMissing = "VD_HIDPI_MODE_MISSING"
    case vdMirrorDetachFailed = "VD_MIRROR_DETACH_FAILED"
    case vdTerminatedBySystem = "VD_TERMINATED_BY_SYSTEM"
    case capPermissionDenied = "CAP_PERMISSION_DENIED"
    case capStreamStopped = "CAP_STREAM_STOPPED"
    case encCreateFailed = "ENC_CREATE_FAILED"
    case encBackpressure = "ENC_BACKPRESSURE"
    case netProtocolMismatch = "NET_PROTOCOL_MISMATCH"
    case decoderFatal = "DECODER_FATAL"
    case inputPermissionDenied = "INPUT_PERMISSION_DENIED"
}

public struct SessionError: Error, Equatable, Sendable {
    public let code: SessionErrorCode
    public let detail: String

    public init(code: SessionErrorCode, detail: String = "") {
        self.code = code
        self.detail = detail
    }
}

extension SessionError: LocalizedError {
    public var errorDescription: String? {
        detail.isEmpty ? code.rawValue : "\(code.rawValue): \(detail)"
    }
}

