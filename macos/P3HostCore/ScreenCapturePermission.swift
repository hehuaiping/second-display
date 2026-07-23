import CoreGraphics
import Foundation

public protocol ScreenCaptureAuthorizing: Sendable {
    func isAuthorized() -> Bool
    func requestAuthorization() -> Bool
}

public struct SystemScreenCaptureAuthorization: ScreenCaptureAuthorizing {
    public init() {}

    public func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func requestAuthorization() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

/// 将系统授权弹窗限制为每个控制器实例最多请求一次。
///
/// macOS 会记住用户的授权选择；重复调用请求 API 只会制造连续弹窗或无效操作。
/// 后续授权变更应通过 `preflight()` 检测，并引导用户前往系统设置。
private final class ScreenCapturePermissionRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requestStarted = false

    func beginRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !requestStarted else { return false }
        requestStarted = true
        return true
    }
}

public struct ScreenCapturePermissionController: Sendable {
    private let authorization: any ScreenCaptureAuthorizing
    private let requestGate: ScreenCapturePermissionRequestGate

    public init(authorization: any ScreenCaptureAuthorizing = SystemScreenCaptureAuthorization()) {
        self.authorization = authorization
        requestGate = ScreenCapturePermissionRequestGate()
    }

    public func preflight() -> Bool {
        authorization.isAuthorized()
    }

    public func requestFromUserAction() -> Bool {
        if authorization.isAuthorized() { return true }
        guard requestGate.beginRequest() else { return false }
        return authorization.requestAuthorization()
    }
}
