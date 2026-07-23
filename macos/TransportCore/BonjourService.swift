import Foundation
@preconcurrency import Network
import SecondDisplayCore

/// Second Display 在局域网中使用的 DNS-SD 服务描述。
///
/// TXT 记录只用于能力筛选和定位候选端点，不能替代配对证书校验。
public struct SecondDisplayBonjourService: Equatable, Sendable {
    public static let serviceType = "_seconddisplay._tcp"
    public static let protocolVersion = 1

    public let name: String
    public let controlPort: UInt16
    public let videoPort: UInt16
    public let certificateFingerprint: String
    public let capabilities: [String]

    public init(
        name: String,
        controlPort: UInt16,
        videoPort: UInt16,
        certificateFingerprint: String,
        capabilities: [String]
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, controlPort > 0, videoPort > 0 else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Bonjour service name and ports must be valid"
            )
        }
        guard let fingerprint = Self.normalizeFingerprint(certificateFingerprint) else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Bonjour certificate fingerprint must be SHA-256"
            )
        }
        let normalizedCapabilities = Array(
            Set(
                capabilities
                    .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.count <= 32 }
            )
        ).sorted()
        guard !normalizedCapabilities.isEmpty else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Bonjour service must publish at least one codec capability"
            )
        }
        self.name = String(trimmedName.prefix(63))
        self.controlPort = controlPort
        self.videoPort = videoPort
        self.certificateFingerprint = fingerprint
        self.capabilities = normalizedCapabilities
    }

    public var textRecord: [String: String] {
        [
            "pv": String(Self.protocolVersion),
            "vp": String(videoPort),
            "tls": "1",
            "fp": certificateFingerprint,
            "state": "ready",
            "caps": capabilities.joined(separator: ","),
        ]
    }

    public var networkService: NWListener.Service {
        NWListener.Service(
            name: name,
            type: Self.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(textRecord)
        )
    }

    public static func normalizeFingerprint(_ value: String) -> String? {
        let normalized =
            value
            .filter { $0.isHexDigit }
            .lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else { return nil }
        return normalized
    }
}
