import CoreGraphics
import Foundation
import SecondDisplayCore

public struct DisplayOriginRecord: Codable, Sendable, Equatable {
    public let deviceId: UUID
    public let orientation: VirtualDisplayOrientation
    public let logicalWidth: Double
    public let logicalHeight: Double
    public let originX: Double
    public let originY: Double

    public init(
        deviceId: UUID,
        orientation: VirtualDisplayOrientation,
        logicalWidth: Double,
        logicalHeight: Double,
        originX: Double,
        originY: Double
    ) {
        self.deviceId = deviceId
        self.orientation = orientation
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.originX = originX
        self.originY = originY
    }

    fileprivate var key: String {
        "\(deviceId.uuidString.lowercased())|\(orientation.rawValue)"
    }
}

@MainActor
public protocol DisplayOriginStoring: AnyObject {
    func record(deviceId: UUID, orientation: VirtualDisplayOrientation) -> DisplayOriginRecord?
    func save(_ record: DisplayOriginRecord) throws
}

@MainActor
public final class UserDefaultsDisplayOriginStore: DisplayOriginStoring {
    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "second-display.virtual-display-origins"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func record(deviceId: UUID, orientation: VirtualDisplayOrientation) -> DisplayOriginRecord? {
        records()[recordKey(deviceId: deviceId, orientation: orientation)]
    }

    public func save(_ record: DisplayOriginRecord) throws {
        var values = records()
        values[record.key] = record
        do {
            let data = try JSONEncoder().encode(values)
            defaults.set(data, forKey: storageKey)
        } catch {
            throw SessionError(code: .vdApplyFailed, detail: "Unable to persist virtual display origin")
        }
    }

    private func records() -> [String: DisplayOriginRecord] {
        guard let data = defaults.data(forKey: storageKey),
            let values = try? JSONDecoder().decode([String: DisplayOriginRecord].self, from: data)
        else {
            return [:]
        }
        return values
    }

    private func recordKey(deviceId: UUID, orientation: VirtualDisplayOrientation) -> String {
        "\(deviceId.uuidString.lowercased())|\(orientation.rawValue)"
    }
}

@MainActor
public protocol DisplayOriginControlling: AnyObject {
    func bounds(displayID: CGDirectDisplayID) -> CGRect
    func applyOrigin(displayID: CGDirectDisplayID, origin: CGPoint) -> CGError
}

@MainActor
public final class CoreGraphicsDisplayOriginController: DisplayOriginControlling {
    public init() {}

    public func bounds(displayID: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(displayID)
    }

    public func applyOrigin(displayID: CGDirectDisplayID, origin: CGPoint) -> CGError {
        guard origin.x.isFinite, origin.y.isFinite,
            origin.x >= Double(Int32.min), origin.x <= Double(Int32.max),
            origin.y >= Double(Int32.min), origin.y <= Double(Int32.max)
        else {
            return .illegalArgument
        }
        var configuration: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&configuration)
        guard beginError == .success, let configuration else { return beginError }
        let configureError = CGConfigureDisplayOrigin(
            configuration,
            displayID,
            Int32(origin.x.rounded()),
            Int32(origin.y.rounded())
        )
        guard configureError == .success else {
            CGCancelDisplayConfiguration(configuration)
            return configureError
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession)
    }
}

@MainActor
public final class DisplayArrangementManager {
    private let store: any DisplayOriginStoring
    private let controller: any DisplayOriginControlling

    public init(
        store: any DisplayOriginStoring = UserDefaultsDisplayOriginStore(),
        controller: any DisplayOriginControlling = CoreGraphicsDisplayOriginController()
    ) {
        self.store = store
        self.controller = controller
    }

    @discardableResult
    public func saveActualOrigin(
        displayID: CGDirectDisplayID,
        deviceId: UUID,
        orientation: VirtualDisplayOrientation
    ) throws -> DisplayOriginRecord {
        let bounds = controller.bounds(displayID: displayID)
        guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else {
            throw SessionError(code: .vdApplyFailed, detail: "Unable to read virtual display bounds")
        }
        let record = DisplayOriginRecord(
            deviceId: deviceId,
            orientation: orientation,
            logicalWidth: bounds.width,
            logicalHeight: bounds.height,
            originX: bounds.origin.x,
            originY: bounds.origin.y
        )
        try store.save(record)
        return record
    }

    @discardableResult
    public func restoreOrigin(
        displayID: CGDirectDisplayID,
        deviceId: UUID,
        orientation: VirtualDisplayOrientation,
        newLogicalSize: CGSize
    ) throws -> DisplayOriginRecord? {
        guard let saved = store.record(deviceId: deviceId, orientation: orientation) else { return nil }
        guard newLogicalSize.width > 0, newLogicalSize.height > 0 else {
            throw SessionError(code: .vdApplyFailed, detail: "Invalid logical size for origin restore")
        }
        let oldCenter = CGPoint(
            x: saved.originX + saved.logicalWidth / 2,
            y: saved.originY + saved.logicalHeight / 2
        )
        let requestedOrigin = CGPoint(
            x: oldCenter.x - newLogicalSize.width / 2,
            y: oldCenter.y - newLogicalSize.height / 2
        )
        let error = controller.applyOrigin(displayID: displayID, origin: requestedOrigin)
        guard error == .success else {
            throw SessionError(code: .vdApplyFailed, detail: "Unable to restore virtual display origin")
        }
        return try saveActualOrigin(
            displayID: displayID,
            deviceId: deviceId,
            orientation: orientation
        )
    }
}

