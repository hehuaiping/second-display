import Foundation
import SecondDisplayCore
import XCTest

@testable import P3HostCore

final class PairingIdentityStoreTests: XCTestCase {
    private var temporaryRoot: URL?

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "second-display-pairing-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        temporaryRoot = root
    }

    override func tearDownWithError() throws {
        if let temporaryRoot,
            FileManager.default.fileExists(atPath: temporaryRoot.path)
        {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testConcurrentLoadCreatesOneIdentityAndKeepsPasswordOffDisk() async throws {
        let directory = try pairingDirectory()
        let passwordStore = LockedPairingPasswordStore()
        let generator = FakePairingIdentityGenerator(delay: .milliseconds(40))
        let store = makeStore(
            directory: directory,
            passwordStore: passwordStore,
            generator: generator
        )

        async let first = store.loadOrCreate(generation: 1)
        async let second = store.loadOrCreate(generation: 1)
        let credentials = try await [first, second]

        XCTAssertEqual(generator.generateCount, 1)
        XCTAssertEqual(credentials.count, 2)
        XCTAssertEqual(credentials[0].identityData, credentials[1].identityData)
        XCTAssertEqual(passwordStore.password, "fixed-password")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "password").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "identity.p12").path
            )
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: "identity.p12").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExistingIdentityIsPreservedAcrossGenerations() async throws {
        let directory = try pairingDirectory()
        try writeIdentity(directory: directory, identity: "existing")
        let passwordStore = LockedPairingPasswordStore(password: "existing-password")
        let generator = FakePairingIdentityGenerator()
        let store = makeStore(
            directory: directory,
            passwordStore: passwordStore,
            generator: generator
        )

        let first = try await store.loadOrCreate(generation: 1)
        let second = try await store.loadOrCreate(generation: 2)

        XCTAssertEqual(String(data: first.identityData, encoding: .utf8), "existing")
        XCTAssertEqual(first.identityData, second.identityData)
        XCTAssertEqual(generator.generateCount, 0)
    }

    func testLegacyPasswordMigratesToStoreAndIsRemoved() async throws {
        let directory = try pairingDirectory()
        try writeIdentity(directory: directory, identity: "legacy")
        let legacyPasswordURL = directory.appending(path: "password")
        try Data("legacy-password\n".utf8).write(to: legacyPasswordURL)
        let passwordStore = LockedPairingPasswordStore()
        let generator = FakePairingIdentityGenerator()
        let store = PairingIdentityStore(
            directory: directory,
            passwordStore: passwordStore,
            legacyPasswordURL: legacyPasswordURL,
            removesLegacyPasswordAfterMigration: true,
            generator: generator,
            validator: FakePairingIdentityValidator(),
            passwordGenerator: FixedPairingPasswordGenerator(value: "unused")
        )

        let credentials = try await store.loadOrCreate(generation: 1)

        XCTAssertEqual(credentials.password, "legacy-password")
        XCTAssertEqual(passwordStore.password, "legacy-password")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPasswordURL.path))
        XCTAssertEqual(generator.generateCount, 0)
    }

    func testValidLegacyPasswordReplacesStaleStoredPassword() async throws {
        let directory = try pairingDirectory()
        try writeIdentity(directory: directory, identity: "legacy")
        let legacyPasswordURL = directory.appending(path: "password")
        try Data("correct-password".utf8).write(to: legacyPasswordURL)
        let passwordStore = LockedPairingPasswordStore(password: "stale-password")
        let store = PairingIdentityStore(
            directory: directory,
            passwordStore: passwordStore,
            legacyPasswordURL: legacyPasswordURL,
            removesLegacyPasswordAfterMigration: true,
            generator: FakePairingIdentityGenerator(),
            validator: PasswordCheckingPairingIdentityValidator(expected: "correct-password"),
            passwordGenerator: FixedPairingPasswordGenerator(value: "unused")
        )

        let credentials = try await store.loadOrCreate(generation: 1)

        XCTAssertEqual(credentials.password, "correct-password")
        XCTAssertEqual(passwordStore.password, "correct-password")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPasswordURL.path))
    }

    func testIncompleteIdentityRequiresExplicitReset() async throws {
        let directory = try pairingDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("certificate".utf8).write(to: directory.appending(path: "cert.pem"))
        let passwordStore = LockedPairingPasswordStore(password: "existing-password")
        let generator = FakePairingIdentityGenerator()
        let store = makeStore(
            directory: directory,
            passwordStore: passwordStore,
            generator: generator
        )

        do {
            _ = try await store.loadOrCreate(generation: 1)
            XCTFail("Expected incomplete identity failure")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .netProtocolMismatch)
            XCTAssertTrue(PairingIdentityStore.requiresExplicitReset(error))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(generator.generateCount, 0)
    }

    func testResetReplacesIdentityOnlyAfterExplicitRequest() async throws {
        let directory = try pairingDirectory()
        try writeIdentity(directory: directory, identity: "old")
        let passwordStore = LockedPairingPasswordStore(password: "old-password")
        let generator = FakePairingIdentityGenerator()
        let store = makeStore(
            directory: directory,
            passwordStore: passwordStore,
            generator: generator
        )

        let credentials = try await store.resetAndCreate(generation: 1)

        XCTAssertEqual(String(data: credentials.identityData, encoding: .utf8), "generated-1")
        XCTAssertEqual(passwordStore.password, "fixed-password")
        XCTAssertEqual(generator.generateCount, 1)
    }

    func testNewGenerationCancelsOldGenerationAndOldResultCannotReturn() async throws {
        let directory = try pairingDirectory()
        let passwordStore = LockedPairingPasswordStore()
        let generator = FakePairingIdentityGenerator(delay: .milliseconds(200))
        let store = makeStore(
            directory: directory,
            passwordStore: passwordStore,
            generator: generator
        )

        let oldTask = Task { try await store.loadOrCreate(generation: 1) }
        try await waitForGenerationStart(generator)
        let current = try await store.loadOrCreate(generation: 2)

        do {
            _ = try await oldTask.value
            XCTFail("Expected old generation cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected old-generation error: \(error)")
        }
        XCTAssertEqual(String(data: current.identityData, encoding: .utf8), "generated-2")
        XCTAssertEqual(generator.generateCount, 2)
    }

    func testCancelledGenerationDoesNotPublishPartialDirectory() async throws {
        let directory = try pairingDirectory()
        let generator = FakePairingIdentityGenerator(delay: .seconds(2))
        let store = makeStore(
            directory: directory,
            passwordStore: LockedPairingPasswordStore(),
            generator: generator
        )
        let task = Task { try await store.loadOrCreate(generation: 1) }
        try await waitForGenerationStart(generator)

        await store.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testProcessRunnerTimesOutAndTerminatesProcess() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await OpenSSLProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: .milliseconds(40),
                operation: "test operation"
            )
            XCTFail("Expected timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, .netProtocolMismatch)
            XCTAssertTrue(error.detail.contains("timed out"))
        } catch {
            XCTFail("Unexpected timeout error: \(error)")
        }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testProcessRunnerCancellationTerminatesProcess() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            try await OpenSSLProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: .seconds(5),
                operation: "test operation"
            )
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected process cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected process cancellation error: \(error)")
        }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testOpenSSLGeneratorProducesFilesAndRemovesTemporarySecrets() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else {
            throw XCTSkip("System OpenSSL is unavailable")
        }
        guard let temporaryRoot else {
            throw SessionError(code: .netProtocolMismatch, detail: "Test root is unavailable")
        }
        let output = temporaryRoot.appending(path: "generated", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

        try await OpenSSLPairingIdentityGenerator().generateIdentity(
            in: output,
            password: "test-password"
        )

        XCTAssertGreaterThan(
            try Data(contentsOf: output.appending(path: "identity.p12")).count,
            0
        )
        XCTAssertGreaterThan(
            try Data(contentsOf: output.appending(path: "cert.pem")).count,
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appending(path: ".key.pem").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appending(path: ".password").path))
    }

    func testKeychainPasswordStoreRoundTrip() throws {
        let store = KeychainPairingPasswordStore(
            service: "com.cuihua.cloud.display.tests.\(UUID().uuidString)",
            account: "pairing"
        )
        defer { try? store.deletePassword() }

        XCTAssertNil(try store.readPassword())
        try store.writePassword("first")
        XCTAssertEqual(try store.readPassword(), "first")
        try store.writePassword("second")
        XCTAssertEqual(try store.readPassword(), "second")
        try store.deletePassword()
        XCTAssertNil(try store.readPassword())
    }

    private func makeStore(
        directory: URL,
        passwordStore: LockedPairingPasswordStore,
        generator: FakePairingIdentityGenerator
    ) -> PairingIdentityStore {
        PairingIdentityStore(
            directory: directory,
            passwordStore: passwordStore,
            legacyPasswordURL: directory.appending(path: "password"),
            removesLegacyPasswordAfterMigration: true,
            generator: generator,
            validator: FakePairingIdentityValidator(),
            passwordGenerator: FixedPairingPasswordGenerator(value: "fixed-password")
        )
    }

    private func pairingDirectory() throws -> URL {
        guard let temporaryRoot else {
            throw SessionError(code: .netProtocolMismatch, detail: "Test root is unavailable")
        }
        return temporaryRoot.appending(path: "Pairing", directoryHint: .isDirectory)
    }

    private func writeIdentity(directory: URL, identity: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(identity.utf8).write(to: directory.appending(path: "identity.p12"))
        try Data("certificate".utf8).write(to: directory.appending(path: "cert.pem"))
    }

    private func waitForGenerationStart(
        _ generator: FakePairingIdentityGenerator,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while generator.generateCount == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(generator.generateCount, 0)
    }
}

private final class LockedPairingPasswordStore: PairingPasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPassword: String?

    init(password: String? = nil) {
        storedPassword = password
    }

    var password: String? {
        lock.withLock { storedPassword }
    }

    func readPassword() throws -> String? {
        lock.withLock { storedPassword }
    }

    func writePassword(_ password: String) throws {
        lock.withLock { storedPassword = password }
    }

    func deletePassword() throws {
        lock.withLock { storedPassword = nil }
    }
}

private final class FakePairingIdentityGenerator: PairingIdentityGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private var generationCount = 0

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    var generateCount: Int {
        lock.withLock { generationCount }
    }

    func generateIdentity(in directory: URL, password: String) async throws {
        let count = lock.withLock { () -> Int in
            generationCount += 1
            return generationCount
        }
        if delay != .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        try Data("generated-\(count)".utf8).write(
            to: directory.appending(path: "identity.p12")
        )
        try Data("certificate".utf8).write(to: directory.appending(path: "cert.pem"))
    }
}

private struct FakePairingIdentityValidator: PairingIdentityValidating {
    func validate(identityData: Data, password: String, certificateData: Data) throws -> String {
        guard
            !password.isEmpty,
            !certificateData.isEmpty,
            let identity = String(data: identityData, encoding: .utf8)
        else {
            throw SessionError(code: .netProtocolMismatch, detail: "Invalid test identity")
        }
        return "FP-\(identity)"
    }
}

private struct PasswordCheckingPairingIdentityValidator: PairingIdentityValidating {
    let expected: String

    func validate(identityData: Data, password: String, certificateData: Data) throws -> String {
        guard password == expected else {
            throw SessionError(code: .netProtocolMismatch, detail: "Wrong test password")
        }
        return "FP-valid"
    }
}

private struct FixedPairingPasswordGenerator: PairingRandomPasswordGenerating {
    let value: String

    func makePassword() throws -> String { value }
}
