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

public struct ScreenCapturePermissionController: Sendable {
    private let authorization: any ScreenCaptureAuthorizing

    public init(authorization: any ScreenCaptureAuthorizing = SystemScreenCaptureAuthorization()) {
        self.authorization = authorization
    }

    public func preflight() -> Bool {
        authorization.isAuthorized()
    }

    public func requestFromUserAction() -> Bool {
        authorization.isAuthorized() || authorization.requestAuthorization()
    }
}
