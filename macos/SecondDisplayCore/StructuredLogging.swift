import CryptoKit
import Foundation

public enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct LogEvent: Sendable, Equatable {
    public let timestamp: Date
    public let level: LogLevel
    public let sessionId: String
    public let generation: UInt64
    public let component: String
    public let event: String
    public let errorCode: SessionErrorCode?
    public let fields: [String: String]
    public let isFrameLevel: Bool

    public init(
        timestamp: Date = Date(),
        level: LogLevel,
        sessionId: String,
        generation: UInt64,
        component: String,
        event: String,
        errorCode: SessionErrorCode? = nil,
        fields: [String: String] = [:],
        isFrameLevel: Bool = false
    ) {
        self.timestamp = timestamp
        self.level = level
        self.sessionId = sessionId
        self.generation = generation
        self.component = component
        self.event = event
        self.errorCode = errorCode
        self.fields = fields
        self.isFrameLevel = isFrameLevel
    }
}

public enum BuildLogPolicy {
    #if DEBUG
        public static let frameDebugEnabled = true
    #else
        public static let frameDebugEnabled = false
    #endif
}

public struct LogRedactor: Sendable {
    private static let sensitiveKeys: Set<String> = [
        "deviceId", "deviceName", "ip", "ipAddress", "path", "userPath", "uuid",
    ]

    public init() {}

    public func redactSessionId(_ value: String) -> String {
        token(for: value)
    }

    public func redact(fields: [String: String]) -> [String: String] {
        fields.reduce(into: [:]) { result, item in
            if Self.sensitiveKeys.contains(item.key) {
                result[item.key] = token(for: item.value)
            } else {
                result[item.key] = redactEmbeddedValues(in: item.value)
            }
        }
    }

    private func token(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let prefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "hash:\(prefix)"
    }

    private func redactEmbeddedValues(in value: String) -> String {
        let patterns = [
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
            #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"#,
            #"(?:/Users|/home)/[^\s\"']+"#,
        ]
        return patterns.reduce(value) { current, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return current }
            let range = NSRange(current.startIndex..., in: current)
            let matches = expression.matches(in: current, range: range).reversed()
            return matches.reduce(current) { partial, match in
                guard let swiftRange = Range(match.range, in: partial) else { return partial }
                return partial.replacingCharacters(in: swiftRange, with: token(for: String(partial[swiftRange])))
            }
        }
    }
}

public struct JSONLinesLogEncoder: Sendable {
    private let redactor: LogRedactor
    private let frameDebugEnabled: Bool

    public init(
        redactor: LogRedactor = LogRedactor(),
        frameDebugEnabled: Bool = BuildLogPolicy.frameDebugEnabled
    ) {
        self.redactor = redactor
        self.frameDebugEnabled = frameDebugEnabled
    }

    public func encode(_ event: LogEvent) throws -> String? {
        guard frameDebugEnabled || !event.isFrameLevel else { return nil }
        let payload = Payload(
            timestamp: event.timestamp,
            level: event.level,
            sessionId: redactor.redactSessionId(event.sessionId),
            generation: event.generation,
            component: event.component,
            event: event.event,
            errorCode: event.errorCode?.rawValue,
            fields: redactor.redact(fields: event.fields)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw SessionError(code: .netProtocolMismatch, detail: "Unable to encode log event")
        }
        guard let line = String(data: data, encoding: .utf8) else {
            throw SessionError(code: .netProtocolMismatch, detail: "Log event is not UTF-8")
        }
        return line + "\n"
    }
}

private struct Payload: Codable {
    let timestamp: Date
    let level: LogLevel
    let sessionId: String
    let generation: UInt64
    let component: String
    let event: String
    let errorCode: String?
    let fields: [String: String]
}

