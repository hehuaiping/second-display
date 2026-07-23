import Foundation
@preconcurrency import Network

public enum NetworkInterfaceKind: String, Codable, Sendable {
    case wifi
    case wiredOrUSB
    case cellular
    case other
    case unavailable
}

public struct NetworkPathSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let kind: NetworkInterfaceKind
    public let interfaceNames: [String]
    public let isExpensive: Bool
    public let isConstrained: Bool

    public init(
        generation: UInt64,
        kind: NetworkInterfaceKind,
        interfaceNames: [String],
        isExpensive: Bool,
        isConstrained: Bool
    ) {
        self.generation = generation
        self.kind = kind
        self.interfaceNames = interfaceNames
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

public final class NetworkPathObserver: @unchecked Sendable {
    public typealias Handler = @Sendable (NetworkPathSnapshot) -> Void

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(
        label: "second-display.transport.path-monitor",
        qos: .utility
    )
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var isRunning = false

    public init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    public func start(onChange: @escaping Handler) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let nextGeneration = lock.withLock { () -> UInt64 in
                guard isRunning else { return 0 }
                generation &+= 1
                return generation
            }
            guard nextGeneration > 0 else { return }
            onChange(Self.snapshot(path: path, generation: nextGeneration))
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard isRunning else { return false }
            isRunning = false
            generation &+= 1
            return true
        }
        guard shouldStop else { return }
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    public static func classify(
        statusSatisfied: Bool,
        usesWiFi: Bool,
        usesWiredEthernet: Bool,
        usesCellular: Bool
    ) -> NetworkInterfaceKind {
        guard statusSatisfied else { return .unavailable }
        if usesWiredEthernet { return .wiredOrUSB }
        if usesWiFi { return .wifi }
        if usesCellular { return .cellular }
        return .other
    }

    private static func snapshot(path: NWPath, generation: UInt64) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            generation: generation,
            kind: classify(
                statusSatisfied: path.status == .satisfied,
                usesWiFi: path.usesInterfaceType(.wifi),
                usesWiredEthernet: path.usesInterfaceType(.wiredEthernet),
                usesCellular: path.usesInterfaceType(.cellular)
            ),
            interfaceNames: path.availableInterfaces.map(\.name).sorted(),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
