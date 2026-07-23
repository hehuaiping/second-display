import Foundation
import CryptoKit
@preconcurrency import Network
import SecondDisplayCore
@preconcurrency import Security

public enum TLSNetworkParameters {
    public static func client() -> NWParameters {
        makeParameters(identity: nil)
    }

    public static func server(identity: SecIdentity) throws -> NWParameters {
        guard let protocolIdentity = sec_identity_create(identity) else {
            throw SessionError(code: .netProtocolMismatch, detail: "Unable to create TLS server identity")
        }
        return makeParameters(identity: protocolIdentity)
    }

    private static func makeParameters(identity: sec_identity_t?) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        if let identity {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

public enum QUICNetworkParameters {
    public static let applicationProtocol = "second-display-video-v1"

    public static func client() -> NWParameters {
        makeParameters(identity: nil)
    }

    public static func server(identity: SecIdentity) throws -> NWParameters {
        guard let protocolIdentity = sec_identity_create(identity) else {
            throw SessionError(code: .netProtocolMismatch, detail: "Unable to create QUIC identity")
        }
        return makeParameters(identity: protocolIdentity)
    }

    private static func makeParameters(identity: sec_identity_t?) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [applicationProtocol])
        quic.isDatagram = true
        quic.maxDatagramFrameSize = 1_200
        quic.maxUDPPayloadSize = 1_200
        quic.idleTimeout = 15_000
        sec_protocol_options_set_min_tls_protocol_version(
            quic.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(
            quic.securityProtocolOptions, .TLSv13)
        if let identity {
            sec_protocol_options_set_local_identity(quic.securityProtocolOptions, identity)
            sec_protocol_options_set_peer_authentication_required(
                quic.securityProtocolOptions, false)
        }
        let parameters = NWParameters(quic: quic)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

public enum TLSIdentityLoader {
    public static func loadPKCS12(data: Data, password: String) throws -> SecIdentity {
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &imported)
        guard status == errSecSuccess,
            let items = imported as? [[String: Any]],
            let first = items.first,
            let identityValue = first[kSecImportItemIdentity as String],
            CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID()
        else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to load TLS identity (Security status \(status))"
            )
        }
        return Unmanaged<SecIdentity>.fromOpaque(
            Unmanaged.passUnretained(identityValue as AnyObject).toOpaque()
        ).takeUnretainedValue()
    }

    public static func certificateSHA256Fingerprint(identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to read TLS certificate from server identity"
            )
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public final class NWTransportListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let readyGate = ListenerGate<Void>()
    private let connectionGate = ListenerGate<NWConnection>()
    private let registrationGate = ListenerGate<Void>()
    private let stateLock = NSLock()
    private var started = false
    private var ready = false
    private var cancelled = false

    public init(port: NWEndpoint.Port, parameters: NWParameters) throws {
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw SessionError(code: .netProtocolMismatch, detail: "Unable to create TLS listener")
        }
        queue = DispatchQueue(
            label: "second-display.transport.listener.\(port.rawValue)", qos: .userInitiated)
    }

    /// 启动监听但不等待客户端连接，供上层在广播服务前确认所有端口均已 ready。
    public func start() async throws {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard !cancelled, !started else { return false }
            started = true
            return true
        }
        if shouldStart {
            listener.stateUpdateHandler = { [readyGate, stateLock] state in
                switch state {
                case .ready:
                    stateLock.withLock { self.ready = true }
                    readyGate.complete(.success(()))
                case .failed(let error):
                    readyGate.complete(.failure(Self.map(error)))
                case .cancelled:
                    readyGate.complete(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [connectionGate] connection in
                connectionGate.complete(.success(connection))
            }
            listener.start(queue: queue)
        }
        let isReady = stateLock.withLock { ready }
        if isReady { return }
        try await withTaskCancellationHandler {
            try await readyGate.value()
        } onCancel: {
            self.cancel()
        }
    }

    /// 在已启动的 listener 上发布 Bonjour；注册完成前不会返回。
    public func advertise(_ service: SecondDisplayBonjourService) async throws {
        try await start()
        listener.serviceRegistrationUpdateHandler = { [registrationGate] change in
            if case .add = change {
                registrationGate.complete(.success(()))
            }
        }
        listener.service = service.networkService
        let timeoutTask = Task { [registrationGate] in
            do {
                try await Task.sleep(for: .seconds(5))
                registrationGate.complete(
                    .failure(
                        SessionError(
                            code: .netProtocolMismatch,
                            detail: "Bonjour service registration timed out"
                        )
                    )
                )
            } catch {
                return
            }
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try await registrationGate.value()
        } onCancel: {
            self.cancel()
        }
    }

    public func stopAdvertising() {
        listener.service = nil
        listener.serviceRegistrationUpdateHandler = nil
    }

    /// 保持旧调用兼容：未显式 start 时，accept 仍会自动启动 listener。
    public func accept() async throws -> NWByteTransportConnection {
        try await start()
        return try await withTaskCancellationHandler {
            let connection = try await connectionGate.value()
            return NWByteTransportConnection(connection: connection)
        } onCancel: {
            self.cancel()
        }
    }

    public func cancel() {
        stateLock.withLock { cancelled = true }
        stopAdvertising()
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        readyGate.complete(.failure(CancellationError()))
        connectionGate.complete(.failure(CancellationError()))
        registrationGate.complete(.failure(CancellationError()))
    }

    private static func map(_ error: NWError) -> SessionError {
        SessionError(code: .netProtocolMismatch, detail: "TLS listener failed: \(error)")
    }
}

public final class NWQUICDatagramListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let readyGate = ListenerGate<Void>()
    private let connectionGate = ListenerGate<NWConnection>()

    public init(port: NWEndpoint.Port, parameters: NWParameters) throws {
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw SessionError(code: .netProtocolMismatch, detail: "Unable to create QUIC listener")
        }
        queue = DispatchQueue(
            label: "second-display.transport.quic-listener.\(port.rawValue)",
            qos: .userInitiated
        )
    }

    public func accept() async throws -> NWQUICDatagramConnection {
        listener.stateUpdateHandler = { [readyGate] state in
            switch state {
            case .ready:
                readyGate.complete(.success(()))
            case .failed(let error):
                readyGate.complete(.failure(Self.map(error)))
            case .cancelled:
                readyGate.complete(.failure(CancellationError()))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [connectionGate] connection in
            connectionGate.complete(.success(connection))
        }
        listener.start(queue: queue)
        return try await withTaskCancellationHandler {
            try await readyGate.value()
            return NWQUICDatagramConnection(connection: try await connectionGate.value())
        } onCancel: {
            self.cancel()
        }
    }

    public func cancel() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        readyGate.complete(.failure(CancellationError()))
        connectionGate.complete(.failure(CancellationError()))
    }

    private static func map(_ error: NWError) -> SessionError {
        SessionError(code: .netProtocolMismatch, detail: "QUIC listener failed: \(error)")
    }
}

public final class NWQUICDatagramConnection: ByteTransportConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let startGate = OneShotGate<Void>()
    private let packetizer = VideoDatagramPacketizer()
    private let reassembler = VideoDatagramReassembler()
    private let lock = NSLock()
    private var sendSequence: UInt32 = 0
    private var generation: UInt64 = 0

    public init(connection: NWConnection) {
        self.connection = connection
        queue = DispatchQueue(
            label: "second-display.transport.quic-datagram",
            qos: .userInitiated
        )
    }

    public convenience init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        self.init(connection: NWConnection(host: host, port: port, using: QUICNetworkParameters.client()))
    }

    public func start() async throws {
        let activeGeneration = lock.withLock { () -> UInt64 in
            generation &+= 1
            return generation
        }
        await reassembler.begin(generation: activeGeneration)
        connection.stateUpdateHandler = { [startGate] state in
            switch state {
            case .ready:
                startGate.complete(.success(()))
            case .failed(let error):
                startGate.complete(.failure(Self.map(error)))
            case .cancelled:
                startGate.complete(.failure(CancellationError()))
            default:
                break
            }
        }
        connection.start(queue: queue)
        try await withTaskCancellationHandler {
            try await startGate.value()
        } onCancel: {
            self.connection.cancel()
            self.startGate.complete(.failure(CancellationError()))
        }
    }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        let sequence = lock.withLock { () -> UInt32 in
            defer { sendSequence &+= 1 }
            return sendSequence
        }
        for packet in try packetizer.packetize(data, sequence: sequence) {
            try Task.checkCancellation()
            let gate = OneShotGate<Void>()
            connection.send(
                content: packet,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        gate.complete(.failure(Self.map(error)))
                    } else {
                        gate.complete(.success(()))
                    }
                }
            )
            try await withTaskCancellationHandler {
                try await gate.value()
            } onCancel: {
                gate.complete(.failure(CancellationError()))
            }
        }
    }

    public func receive(maximumLength: Int) async throws -> Data? {
        let activeGeneration = lock.withLock { generation }
        while !Task.isCancelled {
            let gate = OneShotGate<(Data?, Bool)>()
            connection.receiveMessage { data, _, isComplete, error in
                if let error {
                    gate.complete(.failure(Self.map(error)))
                } else {
                    gate.complete(.success((data, isComplete)))
                }
            }
            let (datagram, isComplete) = try await withTaskCancellationHandler {
                try await gate.value()
            } onCancel: {
                gate.complete(.failure(CancellationError()))
            }
            guard let datagram, !datagram.isEmpty else {
                if isComplete { return nil }
                continue
            }
            let result = try await reassembler.append(
                datagram,
                generation: activeGeneration,
                receivedAtUs: DispatchTime.now().uptimeNanoseconds / 1_000
            )
            if let frame = result.frame {
                guard frame.count <= maximumLength else {
                    throw SessionError(
                        code: .netProtocolMismatch,
                        detail: "Reassembled QUIC frame exceeds receive limit"
                    )
                }
                return frame
            }
        }
        throw CancellationError()
    }

    public func cancel() async {
        lock.withLock { generation &+= 1 }
        await reassembler.stop()
        connection.stateUpdateHandler = nil
        connection.cancel()
        startGate.complete(.failure(CancellationError()))
    }

    private static func map(_ error: NWError) -> SessionError {
        SessionError(code: .netProtocolMismatch, detail: "QUIC connection failed: \(error)")
    }
}

public final class NWByteTransportConnection: ByteTransportConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let startGate = OneShotGate<Void>()

    public init(connection: NWConnection, queueLabel: String = "second-display.transport.connection") {
        self.connection = connection
        self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    public convenience init(host: NWEndpoint.Host, port: NWEndpoint.Port, parameters: NWParameters) {
        self.init(connection: NWConnection(host: host, port: port, using: parameters))
    }

    public func start() async throws {
        connection.stateUpdateHandler = { [startGate] state in
            switch state {
            case .ready:
                startGate.complete(.success(()))
            case .failed(let error):
                startGate.complete(.failure(Self.map(error)))
            case .cancelled:
                startGate.complete(.failure(CancellationError()))
            default:
                break
            }
        }
        connection.start(queue: queue)
        try await startGate.value()
    }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        let gate = OneShotGate<Void>()
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                if let error {
                    gate.complete(.failure(Self.map(error)))
                } else {
                    gate.complete(.success(()))
                }
            })
        try await withTaskCancellationHandler {
            try await gate.value()
        } onCancel: {
            gate.complete(.failure(CancellationError()))
        }
    }

    public func receive(maximumLength: Int = 64 * 1024) async throws -> Data? {
        try Task.checkCancellation()
        let gate = OneShotGate<Data?>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
            data, _, isComplete, error in
            if let error {
                gate.complete(.failure(Self.map(error)))
            } else if let data, !data.isEmpty {
                gate.complete(.success(data))
            } else if isComplete {
                gate.complete(.success(nil))
            } else {
                gate.complete(.success(Data()))
            }
        }
        return try await withTaskCancellationHandler {
            try await gate.value()
        } onCancel: {
            gate.complete(.failure(CancellationError()))
        }
    }

    public func cancel() async {
        connection.stateUpdateHandler = nil
        connection.cancel()
        startGate.complete(.failure(CancellationError()))
    }

    private static func map(_ error: NWError) -> SessionError {
        SessionError(code: .netProtocolMismatch, detail: "Network connection failed: \(error)")
    }
}

private final class OneShotGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed = false

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Value, Error>? in
                if let result {
                    self.result = nil
                    return result
                }
                if completed {
                    return .failure(CancellationError())
                }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func complete(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard !completed else { return nil }
            completed = true
            guard let continuation = self.continuation else {
                self.result = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class ListenerGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed = false

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = lock.withLock { () -> Result<Value, Error>? in
                if let result {
                    self.result = nil
                    return result
                }
                if completed { return .failure(CancellationError()) }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func complete(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard !completed else { return nil }
            completed = true
            guard let continuation = self.continuation else {
                self.result = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
