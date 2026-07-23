import CoreGraphics
import CryptoKit
import Foundation
import SecondDisplayCore

public enum VirtualDisplayOrientation: String, Codable, Sendable, CaseIterable {
    case landscape
    case portrait
}

public struct VirtualDisplaySpec: Sendable, Equatable {
    public let name: String
    public let deviceId: UUID
    public let orientation: VirtualDisplayOrientation
    public let framebufferWidth: Int
    public let framebufferHeight: Int
    public let scaleFactor: Int
    public let refreshRate: Double
    public let physicalWidthMM: Double
    public let physicalHeightMM: Double

    public init(
        name: String,
        deviceId: UUID,
        orientation: VirtualDisplayOrientation,
        framebufferWidth: Int = 2560,
        framebufferHeight: Int = 1600,
        scaleFactor: Int = 2,
        refreshRate: Double = 60,
        physicalWidthMM: Double = 260,
        physicalHeightMM: Double = 162.5
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !name.contains("\0")
        else {
            throw SessionError(code: .vdApplyFailed, detail: "Display name is empty")
        }
        guard framebufferWidth > 0, framebufferHeight > 0,
            framebufferWidth.isMultiple(of: 2), framebufferHeight.isMultiple(of: 2),
            framebufferWidth <= Int(UInt32.max), framebufferHeight <= Int(UInt32.max)
        else {
            throw SessionError(
                code: .vdApplyFailed, detail: "Framebuffer dimensions must be positive and even")
        }
        guard scaleFactor == 2 else {
            throw SessionError(code: .vdApplyFailed, detail: "MVP scale factor must be 2")
        }
        guard [60.0, 90.0, 120.0].contains(refreshRate) else {
            throw SessionError(code: .vdApplyFailed, detail: "Refresh rate must be 60, 90, or 120 Hz")
        }
        let logicalWidth = framebufferWidth / scaleFactor
        let logicalHeight = framebufferHeight / scaleFactor
        guard min(logicalWidth, logicalHeight) >= 600, max(logicalWidth, logicalHeight) >= 800 else {
            throw SessionError(code: .vdApplyFailed, detail: "Logical display must be at least 800 x 600")
        }
        guard physicalWidthMM.isFinite, physicalHeightMM.isFinite,
            physicalWidthMM > 0, physicalHeightMM > 0
        else {
            throw SessionError(
                code: .vdApplyFailed, detail: "Physical dimensions must be positive and finite")
        }
        self.name = name
        self.deviceId = deviceId
        self.orientation = orientation
        self.framebufferWidth = framebufferWidth
        self.framebufferHeight = framebufferHeight
        self.scaleFactor = scaleFactor
        self.refreshRate = refreshRate
        self.physicalWidthMM = physicalWidthMM
        self.physicalHeightMM = physicalHeightMM
    }

    public var logicalSize: CGSize {
        CGSize(width: framebufferWidth / scaleFactor, height: framebufferHeight / scaleFactor)
    }

    public var framebufferSize: CGSize {
        CGSize(width: framebufferWidth, height: framebufferHeight)
    }
}

public struct DisplayIdentity: Sendable, Equatable, Hashable {
    public static let vendorId: UInt32 = 0x4857
    public static let productId: UInt32 = 0x5344

    public let vendorId: UInt32
    public let productId: UInt32
    public let serialNumber: UInt32

    public init(vendorId: UInt32, productId: UInt32, serialNumber: UInt32) {
        self.vendorId = vendorId
        self.productId = productId
        self.serialNumber = serialNumber
    }
}

public struct DisplayIdentityGenerator: Sendable {
    public init() {}

    public func identity(deviceId: UUID, orientation: VirtualDisplayOrientation) -> DisplayIdentity {
        var uuid = deviceId.uuid
        let data = withUnsafeBytes(of: &uuid) { Data($0) }
        let digest = SHA256.hash(data: data)
        let prefix = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var serial = prefix & 0x7fff_ffff
        if serial == 0 {
            serial = 1
        }
        // 最高位编码方向：同一设备旋转后获得不同 serial，macOS 才会重新枚举正确的显示模式。
        if orientation == .portrait {
            serial |= 0x8000_0000
        }
        return DisplayIdentity(
            vendorId: DisplayIdentity.vendorId,
            productId: DisplayIdentity.productId,
            serialNumber: serial
        )
    }
}

public final class DisplayIdentityRegistry: @unchecked Sendable {
    // CGVirtualDisplay 要求进程内 serial 唯一；注册表覆盖多个 Provider，不能只做实例内检查。
    public static let shared = DisplayIdentityRegistry()

    private let lock = NSLock()
    private var ownersBySerial: [UInt32: UUID] = [:]

    public init() {}

    public func claim(_ identity: DisplayIdentity, deviceId: UUID) throws {
        try lock.withLock {
            if ownersBySerial[identity.serialNumber] != nil {
                throw SessionError(code: .vdApplyFailed, detail: "Virtual display serial collision")
            }
            ownersBySerial[identity.serialNumber] = deviceId
        }
    }

    public func release(_ identity: DisplayIdentity, deviceId: UUID) {
        lock.withLock {
            guard ownersBySerial[identity.serialNumber] == deviceId else { return }
            ownersBySerial.removeValue(forKey: identity.serialNumber)
        }
    }
}
