import Darwin
import Foundation
import SecondDisplayCore

public enum MacCompatibilityStatus: String, Codable, Sendable {
    case supported
    case experimental
    case blocked
}

public struct MacCompatibilityDecision: Equatable, Sendable {
    public let osBuild: String
    public let status: MacCompatibilityStatus
    public let reason: String

    public init(osBuild: String, status: MacCompatibilityStatus, reason: String) {
        self.osBuild = osBuild
        self.status = status
        self.reason = reason
    }

    public func requireCreationAllowed() throws {
        guard status != .blocked else {
            throw SessionError(
                code: .vdCapabilityMissing,
                detail: "macOS build \(osBuild) is blocked: \(reason)"
            )
        }
    }
}

public protocol MacCompatibilityChecking: Sendable {
    func decision() -> MacCompatibilityDecision
}

public struct MacCompatibilityManifest: Codable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let osBuild: String
        public let status: MacCompatibilityStatus
        public let reason: String

        public init(osBuild: String, status: MacCompatibilityStatus, reason: String) {
            self.osBuild = osBuild
            self.status = status
            self.reason = reason
        }
    }

    public let schemaVersion: Int
    public let entries: [Entry]
    public let unknownBuildStatus: MacCompatibilityStatus

    public init(
        schemaVersion: Int = 1,
        entries: [Entry],
        unknownBuildStatus: MacCompatibilityStatus = .experimental
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.unknownBuildStatus = unknownBuildStatus
    }

    public func decision(for osBuild: String) -> MacCompatibilityDecision {
        if let entry = entries.first(where: { $0.osBuild == osBuild }) {
            return MacCompatibilityDecision(
                osBuild: osBuild,
                status: entry.status,
                reason: entry.reason
            )
        }
        return MacCompatibilityDecision(
            osBuild: osBuild,
            status: unknownBuildStatus,
            reason: "Build is not present in the verified compatibility manifest"
        )
    }
}

public struct SystemMacCompatibilityChecker: MacCompatibilityChecking {
    private let manifest: MacCompatibilityManifest
    private let osBuild: String

    public init(
        manifest: MacCompatibilityManifest = Self.bundledManifest,
        osBuild: String = Self.currentOSBuild
    ) {
        self.manifest = manifest
        self.osBuild = osBuild
    }

    public func decision() -> MacCompatibilityDecision {
        manifest.decision(for: osBuild)
    }

    public static var bundledManifest: MacCompatibilityManifest {
        guard
            let url = Bundle.module.url(
                forResource: "CompatibilityManifest", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(MacCompatibilityManifest.self, from: data),
            manifest.schemaVersion == 1
        else {
            return MacCompatibilityManifest(entries: [])
        }
        return manifest
    }

    public static var currentOSBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }
}
