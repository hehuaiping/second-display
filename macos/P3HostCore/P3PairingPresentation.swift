import Foundation
import SecondDisplayCore
import TransportCore

/// 供接收端首次建立证书固定所需的公开配对信息。
///
/// 二维码包含完整 SHA-256 指纹，校验码用于无法扫码时的人工核对；两者都不包含私钥。
public struct P3PairingPresentation: Codable, Equatable, Sendable {
    public static let payloadType = "second-display-pairing"
    public static let currentVersion = 1

    public let type: String
    public let version: Int
    public let fingerprint: String
    public let name: String

    public init(fingerprint: String, name: String) throws {
        guard let normalized = SecondDisplayBonjourService.normalizeFingerprint(fingerprint) else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Pairing fingerprint must be SHA-256"
            )
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SessionError(code: .netProtocolMismatch, detail: "Pairing name is empty")
        }
        type = Self.payloadType
        version = Self.currentVersion
        self.fingerprint = normalized
        self.name = String(trimmedName.prefix(63))
    }

    public var verificationCode: String {
        let prefix = fingerprint.prefix(12).uppercased()
        return stride(from: 0, to: prefix.count, by: 4)
            .map { offset in
                let start = prefix.index(prefix.startIndex, offsetBy: offset)
                let end = prefix.index(start, offsetBy: min(4, prefix.count - offset))
                return String(prefix[start..<end])
            }
            .joined(separator: "-")
    }

    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(self)
        } catch {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to encode pairing payload"
            )
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Pairing payload is not UTF-8"
            )
        }
        return value
    }
}
