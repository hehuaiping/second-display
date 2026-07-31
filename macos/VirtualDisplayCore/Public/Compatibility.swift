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
    private static let resourceBundleName = "SecondDisplay_VirtualDisplayCore.bundle"
    private static let manifestName = "CompatibilityManifest.json"

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
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(resourceBundleName))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(resourceBundleName))
        candidates.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(resourceBundleName)
        )
        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(resourceBundleName)
            )
        }
        return loadManifest(from: candidates)
    }

    static func loadManifest(from resourceBundleURLs: [URL]) -> MacCompatibilityManifest {
        for resourceBundleURL in resourceBundleURLs {
            let manifestURL = resourceBundleURL.appendingPathComponent(manifestName)
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(MacCompatibilityManifest.self, from: data),
                manifest.schemaVersion == 1
            else {
                continue
            }
            return manifest
        }
        // 资源缺失或损坏时保持 unknown build 的实验状态，不允许打包错误让应用启动崩溃。
        return MacCompatibilityManifest(entries: [])
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
