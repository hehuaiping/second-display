import Foundation
import PrivateAPIShim
import SecondDisplayCore

public enum VirtualDisplayPrivateClassRole: String, CaseIterable, Sendable {
    case display
    case descriptor
    case settings
    case mode
}

public enum VirtualDisplayPrivateSelectorRole: String, CaseIterable, Sendable {
    case displayInitializer
    case applySettings
    case displayIdentifier
    case modeInitializer
}

public protocol VirtualDisplayRuntimeChecking: Sendable {
    func hasClass(_ role: VirtualDisplayPrivateClassRole) -> Bool
    func hasSelector(_ role: VirtualDisplayPrivateSelectorRole) -> Bool
}

public struct VirtualDisplayCapabilityReport: Sendable {
    public let supported: Bool
    public let osVersion: OperatingSystemVersion
    public let architecture: String
    public let missingClasses: [String]
    public let missingSelectors: [String]
    public let probeVersion: Int

    public init(
        supported: Bool,
        osVersion: OperatingSystemVersion,
        architecture: String,
        missingClasses: [String],
        missingSelectors: [String],
        probeVersion: Int
    ) {
        self.supported = supported
        self.osVersion = osVersion
        self.architecture = architecture
        self.missingClasses = missingClasses
        self.missingSelectors = missingSelectors
        self.probeVersion = probeVersion
    }

    public func requireSupport() throws {
        guard supported else {
            throw SessionError(code: .vdCapabilityMissing, detail: "Required virtual display runtime capability is missing")
        }
    }
}

public struct VirtualDisplayCapabilityProbe: Sendable {
    private let checker: any VirtualDisplayRuntimeChecking

    public init(checker: any VirtualDisplayRuntimeChecking = SystemVirtualDisplayRuntimeChecker()) {
        self.checker = checker
    }

    public func report(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        architecture: String = SystemVirtualDisplayRuntimeChecker.architecture
    ) -> VirtualDisplayCapabilityReport {
        let missingClasses = VirtualDisplayPrivateClassRole.allCases
            .filter { !checker.hasClass($0) }
            .map(\.rawValue)
        let missingSelectors = VirtualDisplayPrivateSelectorRole.allCases
            .filter { !checker.hasSelector($0) }
            .map(\.rawValue)
        return VirtualDisplayCapabilityReport(
            supported: missingClasses.isEmpty && missingSelectors.isEmpty,
            osVersion: osVersion,
            architecture: architecture,
            missingClasses: missingClasses,
            missingSelectors: missingSelectors,
            probeVersion: 1
        )
    }
}

public struct SystemVirtualDisplayRuntimeChecker: VirtualDisplayRuntimeChecking {
    private let missingClassMask: UInt32
    private let missingSelectorMask: UInt32

    public init() {
        let result = SDVDProbeCapabilities()
        self.missingClassMask = result.missingClassRoles
        self.missingSelectorMask = result.missingSelectorRoles
    }

    public func hasClass(_ role: VirtualDisplayPrivateClassRole) -> Bool {
        missingClassMask & classMask(for: role) == 0
    }

    public func hasSelector(_ role: VirtualDisplayPrivateSelectorRole) -> Bool {
        missingSelectorMask & selectorMask(for: role) == 0
    }

    public static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    private func classMask(for role: VirtualDisplayPrivateClassRole) -> UInt32 {
        switch role {
        case .display: return UInt32(SDVDClassRoleDisplay)
        case .descriptor: return UInt32(SDVDClassRoleDescriptor)
        case .settings: return UInt32(SDVDClassRoleSettings)
        case .mode: return UInt32(SDVDClassRoleMode)
        }
    }

    private func selectorMask(for role: VirtualDisplayPrivateSelectorRole) -> UInt32 {
        switch role {
        case .displayInitializer: return UInt32(SDVDSelectorRoleDisplayInitializer)
        case .applySettings: return UInt32(SDVDSelectorRoleApplySettings)
        case .displayIdentifier: return UInt32(SDVDSelectorRoleDisplayIdentifier)
        case .modeInitializer: return UInt32(SDVDSelectorRoleModeInitializer)
        }
    }
}
