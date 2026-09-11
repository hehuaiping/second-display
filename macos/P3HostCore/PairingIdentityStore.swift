import CryptoKit
import Foundation
import SecondDisplayCore
import Security
import TransportCore

/// macOS 服务端使用的 TLS 身份数据。保留 PKCS#12 形态，兼容现有 Host 配置和开发工具。
public struct PairingIdentityCredentials: Sendable {
    public let identityData: Data
    public let password: String
    public let fingerprint: String
    public let directory: URL

    public init(identityData: Data, password: String, fingerprint: String, directory: URL) {
        self.identityData = identityData
        self.password = password
        self.fingerprint = fingerprint
        self.directory = directory
    }
}

protocol PairingIdentityGenerating: Sendable {
    func generateIdentity(in directory: URL, password: String) async throws
}

protocol PairingPasswordStoring: Sendable {
    func readPassword() throws -> String?
    func writePassword(_ password: String) throws
    func deletePassword() throws
}

protocol PairingIdentityValidating: Sendable {
    func validate(identityData: Data, password: String, certificateData: Data) throws -> String
}

protocol PairingRandomPasswordGenerating: Sendable {
    func makePassword() throws -> String
}

protocol PairingProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        operation: String
    ) async throws
}

/// 串行化身份创建，并通过 operation generation 阻止旧异步结果恢复已经被替换的状态。
public actor PairingIdentityStore {
    private struct InFlight {
        let identifier: UInt64
        let generation: UInt64
        let resetsExistingIdentity: Bool
        let task: Task<PairingIdentityCredentials, Error>
    }

    private let worker: PairingIdentityWorker
    private var latestGeneration: UInt64 = 0
    private var nextIdentifier: UInt64 = 0
    private var inFlight: InFlight?

    init(worker: PairingIdentityWorker) {
        self.worker = worker
    }

    init(
        directory: URL,
        passwordStore: any PairingPasswordStoring,
        legacyPasswordURL: URL?,
        removesLegacyPasswordAfterMigration: Bool,
        generator: any PairingIdentityGenerating,
        validator: any PairingIdentityValidating,
        passwordGenerator: any PairingRandomPasswordGenerating
    ) {
        worker = PairingIdentityWorker(
            directory: directory,
            passwordStore: passwordStore,
            legacyPasswordURL: legacyPasswordURL,
            removesLegacyPasswordAfterMigration: removesLegacyPasswordAfterMigration,
            generator: generator,
            validator: validator,
            passwordGenerator: passwordGenerator
        )
    }

    /// 发行应用默认把密码迁移到 Keychain；显式开发目录继续使用密码文件以保持工具兼容。
    public static func applicationDefault() throws -> PairingIdentityStore {
        let fileManager = FileManager.default
        let processInfo = ProcessInfo.processInfo
        let generator = OpenSSLPairingIdentityGenerator()
        let validator = SecurityPairingIdentityValidator()
        let passwordGenerator = SecurePairingPasswordGenerator()

        if let configured = processInfo.environment["P3_POC_TLS_DIRECTORY"],
            !configured.isEmpty
        {
            let directory = URL(fileURLWithPath: configured, isDirectory: true)
            return PairingIdentityStore(
                directory: directory,
                passwordStore: FilePairingPasswordStore(
                    passwordURL: directory.appending(path: "password")
                ),
                legacyPasswordURL: nil,
                removesLegacyPasswordAfterMigration: false,
                generator: generator,
                validator: validator,
                passwordGenerator: passwordGenerator
            )
        }

        guard
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Application Support directory is unavailable"
            )
        }
        let installed =
            applicationSupport
            .appending(path: "Second Display", directoryHint: .isDirectory)
            .appending(path: "Pairing", directoryHint: .isDirectory)
        let development = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appending(path: ".build/p3-poc-tls", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: installed.path),
            fileManager.fileExists(atPath: development.path)
        {
            return PairingIdentityStore(
                directory: development,
                passwordStore: FilePairingPasswordStore(
                    passwordURL: development.appending(path: "password")
                ),
                legacyPasswordURL: nil,
                removesLegacyPasswordAfterMigration: false,
                generator: generator,
                validator: validator,
                passwordGenerator: passwordGenerator
            )
        }

        return PairingIdentityStore(
            directory: installed,
            passwordStore: KeychainPairingPasswordStore(
                service: "com.cuihua.cloud.display.macos.pairing-password",
                account: "default"
            ),
            legacyPasswordURL: installed.appending(path: "password"),
            removesLegacyPasswordAfterMigration: true,
            generator: generator,
            validator: validator,
            passwordGenerator: passwordGenerator
        )
    }

    public func loadOrCreate(generation: UInt64) async throws -> PairingIdentityCredentials {
        try await perform(generation: generation, resetsExistingIdentity: false)
    }

    /// 用户确认后才删除旧身份；新证书会使已配对设备需要重新确认信任。
    public func resetAndCreate(generation: UInt64) async throws -> PairingIdentityCredentials {
        try await perform(generation: generation, resetsExistingIdentity: true)
    }

    public func cancel() {
        latestGeneration &+= 1
        inFlight?.task.cancel()
        inFlight = nil
    }

    public nonisolated static func requiresExplicitReset(_ error: SessionError) -> Bool {
        error.code == .netProtocolMismatch
            && error.detail.hasPrefix(PairingIdentityWorker.resetRequiredPrefix)
    }

    private func perform(
        generation: UInt64,
        resetsExistingIdentity: Bool
    ) async throws -> PairingIdentityCredentials {
        guard generation >= latestGeneration else { throw CancellationError() }
        if generation > latestGeneration {
            latestGeneration = generation
            inFlight?.task.cancel()
            inFlight = nil
        }

        if let inFlight,
            inFlight.generation == generation,
            inFlight.resetsExistingIdentity == resetsExistingIdentity
        {
            do {
                let credentials = try await inFlight.task.value
                guard
                    latestGeneration == generation,
                    self.inFlight?.identifier == inFlight.identifier,
                    !Task.isCancelled
                else {
                    throw CancellationError()
                }
                return credentials
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SessionError {
                throw error
            } catch {
                throw SessionError(
                    code: .netProtocolMismatch,
                    detail: "Pairing identity operation failed"
                )
            }
        }

        inFlight?.task.cancel()
        nextIdentifier &+= 1
        let identifier = nextIdentifier
        let worker = worker
        let task = Task.detached(priority: .userInitiated) {
            if resetsExistingIdentity {
                try await worker.resetIdentity()
            }
            return try await worker.loadOrCreate()
        }
        inFlight = InFlight(
            identifier: identifier,
            generation: generation,
            resetsExistingIdentity: resetsExistingIdentity,
            task: task
        )

        do {
            let credentials = try await task.value
            guard
                latestGeneration == generation,
                inFlight?.identifier == identifier,
                !Task.isCancelled
            else {
                throw CancellationError()
            }
            inFlight = nil
            return credentials
        } catch is CancellationError {
            if inFlight?.identifier == identifier { inFlight = nil }
            throw CancellationError()
        } catch let error as SessionError {
            if inFlight?.identifier == identifier { inFlight = nil }
            throw error
        } catch {
            if inFlight?.identifier == identifier { inFlight = nil }
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Pairing identity operation failed"
            )
        }
    }
}

struct PairingIdentityWorker: Sendable {
    static let resetRequiredPrefix = "PAIRING_RESET_REQUIRED:"

    let directory: URL
    let passwordStore: any PairingPasswordStoring
    let legacyPasswordURL: URL?
    let removesLegacyPasswordAfterMigration: Bool
    let generator: any PairingIdentityGenerating
    let validator: any PairingIdentityValidating
    let passwordGenerator: any PairingRandomPasswordGenerating

    func loadOrCreate() async throws -> PairingIdentityCredentials {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let identityURL = directory.appending(path: "identity.p12")
        let certificateURL = directory.appending(path: "cert.pem")
        let identityExists = fileManager.fileExists(atPath: identityURL.path)
        let certificateExists = fileManager.fileExists(atPath: certificateURL.path)
        let storedPassword = try passwordStore.readPassword()
        let legacyPassword = try readLegacyPasswordIfPresent()
        let passwordCandidates = [storedPassword, legacyPassword]
            .compactMap { $0 }
            .reduce(into: [String]()) { result, password in
                if !result.contains(password) { result.append(password) }
            }
        let hasAnyMaterial = identityExists || certificateExists || !passwordCandidates.isEmpty

        if hasAnyMaterial {
            guard identityExists, certificateExists, !passwordCandidates.isEmpty else {
                throw resetRequired("Pairing identity is incomplete")
            }
            var validatedCredentials: PairingIdentityCredentials?
            for password in passwordCandidates {
                if let credentials = try? loadExisting(
                    identityURL: identityURL,
                    certificateURL: certificateURL,
                    password: password
                ) {
                    validatedCredentials = credentials
                    break
                }
            }
            guard let credentials = validatedCredentials else {
                throw resetRequired("Pairing identity validation failed")
            }
            if storedPassword != credentials.password {
                try Task.checkCancellation()
                try passwordStore.writePassword(credentials.password)
            }
            if removesLegacyPasswordAfterMigration,
                let legacyPasswordURL,
                fileManager.fileExists(atPath: legacyPasswordURL.path)
            {
                do {
                    try fileManager.removeItem(at: legacyPasswordURL)
                } catch {
                    throw SessionError(
                        code: .netProtocolMismatch,
                        detail: "Unable to remove migrated pairing password"
                    )
                }
            }
            return credentials
        }

        return try await createIdentity()
    }

    func resetIdentity() async throws {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let quarantine = parent.appending(
            path: ".second-display-pairing-reset-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let directoryExists = fileManager.fileExists(atPath: directory.path)
        if directoryExists {
            do {
                try fileManager.moveItem(at: directory, to: quarantine)
            } catch {
                throw SessionError(
                    code: .netProtocolMismatch,
                    detail: "Unable to isolate the previous pairing identity"
                )
            }
        }
        do {
            try passwordStore.deletePassword()
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: quarantine.path) {
                try fileManager.removeItem(at: quarantine)
            }
        } catch {
            if directoryExists,
                fileManager.fileExists(atPath: quarantine.path),
                !fileManager.fileExists(atPath: directory.path)
            {
                try? fileManager.moveItem(at: quarantine, to: directory)
            }
            throw error
        }
    }

    private func createIdentity() async throws -> PairingIdentityCredentials {
        let fileManager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryDirectory = parent.appending(
            path: ".second-display-pairing-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var didPublish = false
        defer {
            if fileManager.fileExists(atPath: temporaryDirectory.path) {
                try? fileManager.removeItem(at: temporaryDirectory)
            }
        }

        do {
            let password = try passwordGenerator.makePassword()
            try await generator.generateIdentity(in: temporaryDirectory, password: password)
            try Task.checkCancellation()
            let credentials = try loadExisting(
                identityURL: temporaryDirectory.appending(path: "identity.p12"),
                certificateURL: temporaryDirectory.appending(path: "cert.pem"),
                password: password,
                reportedDirectory: directory
            )
            for fileName in ["cert.pem", "identity.p12"] {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: temporaryDirectory.appending(path: fileName).path
                )
            }
            if fileManager.fileExists(atPath: directory.path) {
                let contents = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
                guard contents.isEmpty else {
                    throw resetRequired("Pairing directory contains unexpected files")
                }
                try fileManager.removeItem(at: directory)
            }
            try Task.checkCancellation()
            try fileManager.moveItem(at: temporaryDirectory, to: directory)
            didPublish = true
            try Task.checkCancellation()
            try passwordStore.writePassword(password)
            try Task.checkCancellation()
            return credentials
        } catch {
            if didPublish, fileManager.fileExists(atPath: directory.path) {
                try? fileManager.removeItem(at: directory)
            }
            if didPublish { try? passwordStore.deletePassword() }
            throw error
        }
    }

    private func loadExisting(
        identityURL: URL,
        certificateURL: URL,
        password: String,
        reportedDirectory: URL? = nil
    ) throws -> PairingIdentityCredentials {
        let identityData: Data
        let certificateData: Data
        do {
            identityData = try Data(contentsOf: identityURL)
            certificateData = try Data(contentsOf: certificateURL)
        } catch {
            throw resetRequired("Pairing files cannot be read")
        }
        guard !password.isEmpty, !identityData.isEmpty, !certificateData.isEmpty else {
            throw resetRequired("Pairing files are empty")
        }
        let fingerprint: String
        do {
            fingerprint = try validator.validate(
                identityData: identityData,
                password: password,
                certificateData: certificateData
            )
        } catch {
            throw resetRequired("Pairing identity validation failed")
        }
        return PairingIdentityCredentials(
            identityData: identityData,
            password: password,
            fingerprint: fingerprint,
            directory: reportedDirectory ?? directory
        )
    }

    private func readLegacyPasswordIfPresent() throws -> String? {
        guard let legacyPasswordURL,
            FileManager.default.fileExists(atPath: legacyPasswordURL.path)
        else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: legacyPasswordURL)
        } catch {
            throw resetRequired("Legacy pairing password cannot be read")
        }
        guard
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            throw resetRequired("Legacy pairing password is invalid")
        }
        return value
    }

    private func resetRequired(_ detail: String) -> SessionError {
        SessionError(
            code: .netProtocolMismatch,
            detail: "\(Self.resetRequiredPrefix) \(detail)"
        )
    }
}

struct FilePairingPasswordStore: PairingPasswordStoring {
    let passwordURL: URL

    func readPassword() throws -> String? {
        guard FileManager.default.fileExists(atPath: passwordURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: passwordURL)
        } catch {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to read pairing password"
            )
        }
        guard
            let password = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !password.isEmpty
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Pairing password is invalid")
        }
        return password
    }

    func writePassword(_ password: String) throws {
        do {
            try Data(password.utf8).write(to: passwordURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: passwordURL.path
            )
        } catch {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to persist pairing password"
            )
        }
    }

    func deletePassword() throws {
        guard FileManager.default.fileExists(atPath: passwordURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: passwordURL)
        } catch {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to remove pairing password"
            )
        }
    }
}

struct KeychainPairingPasswordStore: PairingPasswordStoring {
    let service: String
    let account: String

    func readPassword() throws -> String? {
        var result: CFTypeRef?
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else {
            throw keychainError("Unable to read pairing password", status: status)
        }
        return password
    }

    func writePassword(_ password: String) throws {
        guard !password.isEmpty else {
            throw SessionError(code: .netProtocolMismatch, detail: "Pairing password is empty")
        }
        let data = Data(password.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError("Unable to update pairing password", status: updateStatus)
        }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError("Unable to store pairing password", status: addStatus)
        }
    }

    func deletePassword() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError("Unable to delete pairing password", status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainError(_ detail: String, status: OSStatus) -> SessionError {
        SessionError(
            code: .netProtocolMismatch,
            detail: "\(detail) (Security status \(status))"
        )
    }
}

struct SecurePairingPasswordGenerator: PairingRandomPasswordGenerating {
    func makePassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to generate a secure TLS password"
            )
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct SecurityPairingIdentityValidator: PairingIdentityValidating {
    func validate(identityData: Data, password: String, certificateData: Data) throws -> String {
        guard
            let certificatePEM = String(data: certificateData, encoding: .utf8),
            let certificateDER = decodeCertificatePEM(certificatePEM)
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Certificate PEM is invalid")
        }
        let identity = try TLSIdentityLoader.loadPKCS12(data: identityData, password: password)
        let identityFingerprint = try TLSIdentityLoader.certificateSHA256Fingerprint(
            identity: identity
        )
        let digest = SHA256.hash(data: certificateDER)
        let fileFingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        guard normalize(fileFingerprint) == normalize(identityFingerprint) else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Certificate does not match the PKCS#12 identity"
            )
        }
        return fileFingerprint
    }

    private func normalize(_ fingerprint: String) -> String {
        fingerprint.replacingOccurrences(of: ":", with: "").lowercased()
    }

    private func decodeCertificatePEM(_ value: String) -> Data? {
        let base64 =
            value
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: base64)
    }
}

struct OpenSSLPairingIdentityGenerator: PairingIdentityGenerating {
    private let processRunner: any PairingProcessRunning
    private let executableCandidates: [URL]
    private let timeout: Duration

    init(
        processRunner: any PairingProcessRunning = OpenSSLProcessRunner(),
        executableCandidates: [URL] = [
            URL(fileURLWithPath: "/usr/bin/openssl"),
            URL(fileURLWithPath: "/opt/homebrew/bin/openssl"),
            URL(fileURLWithPath: "/usr/local/bin/openssl"),
        ],
        timeout: Duration = .seconds(15)
    ) {
        self.processRunner = processRunner
        self.executableCandidates = executableCandidates
        self.timeout = timeout
    }

    func generateIdentity(in directory: URL, password: String) async throws {
        guard
            let executable = executableCandidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            })
        else {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "OpenSSL is unavailable; install it before starting the service"
            )
        }
        let passwordURL = directory.appending(path: ".password")
        let keyURL = directory.appending(path: ".key.pem")
        let certificateURL = directory.appending(path: "cert.pem")
        let identityURL = directory.appending(path: "identity.p12")
        do {
            try Data(password.utf8).write(to: passwordURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: passwordURL.path
            )
        } catch {
            throw SessionError(
                code: .netProtocolMismatch,
                detail: "Unable to prepare pairing identity generation"
            )
        }
        defer {
            try? FileManager.default.removeItem(at: passwordURL)
            try? FileManager.default.removeItem(at: keyURL)
        }

        try await processRunner.run(
            executable: executable,
            arguments: [
                "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
                "-days", "3650", "-subj", "/CN=Second Display Mac",
                "-keyout", keyURL.path, "-out", certificateURL.path,
            ],
            timeout: timeout,
            operation: "Unable to generate TLS certificate"
        )
        try Task.checkCancellation()
        try await processRunner.run(
            executable: executable,
            arguments: [
                "pkcs12", "-export", "-out", identityURL.path,
                "-inkey", keyURL.path, "-in", certificateURL.path,
                "-passout", "file:\(passwordURL.path)",
            ],
            timeout: timeout,
            operation: "Unable to package TLS identity"
        )
        try Task.checkCancellation()
    }
}

struct OpenSSLProcessRunner: PairingProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        operation: String
    ) async throws {
        let processBox = PairingProcessBox()
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await launch(
                        executable: executable,
                        arguments: arguments,
                        operation: operation,
                        processBox: processBox
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw SessionError(
                        code: .netProtocolMismatch,
                        detail: "\(operation): timed out"
                    )
                }
                defer {
                    group.cancelAll()
                    processBox.terminate()
                }
                guard try await group.next() != nil else {
                    throw SessionError(code: .netProtocolMismatch, detail: operation)
                }
                try Task.checkCancellation()
            }
        } onCancel: {
            processBox.cancel()
        }
    }

    private func launch(
        executable: URL,
        arguments: [String],
        operation: String,
        processBox: PairingProcessBox
    ) async throws {
        let completionGate = PairingProcessCompletionGate()
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finishedProcess in
                processBox.clear(finishedProcess)
                if processBox.isCancellationRequested {
                    completionGate.resume(continuation, with: .failure(CancellationError()))
                } else if finishedProcess.terminationStatus == 0 {
                    completionGate.resume(continuation, with: .success(()))
                } else {
                    completionGate.resume(
                        continuation,
                        with: .failure(
                            SessionError(code: .netProtocolMismatch, detail: operation)
                        )
                    )
                }
            }
            guard processBox.register(process) else {
                completionGate.resume(continuation, with: .failure(CancellationError()))
                return
            }
            do {
                try process.run()
                processBox.didStart(process)
            } catch {
                processBox.clear(process)
                completionGate.resume(
                    continuation,
                    with: .failure(
                        SessionError(code: .netProtocolMismatch, detail: operation)
                    )
                )
            }
        }
    }
}

private final class PairingProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    var isCancellationRequested: Bool {
        lock.withLock { cancellationRequested }
    }

    func register(_ process: Process) -> Bool {
        lock.withLock {
            guard !cancellationRequested else { return false }
            self.process = process
            return true
        }
    }

    func didStart(_ process: Process) {
        let shouldTerminate = lock.withLock {
            cancellationRequested && self.process === process
        }
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process { self.process = nil }
        }
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancellationRequested = true
            return self.process
        }
        if let process, process.isRunning { process.terminate() }
    }

    func terminate() {
        let process = lock.withLock { self.process }
        if let process, process.isRunning { process.terminate() }
    }
}

private final class PairingProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) {
        let shouldResume = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldResume else { return }
        continuation.resume(with: result)
    }
}
