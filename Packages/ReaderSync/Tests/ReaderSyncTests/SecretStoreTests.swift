import Foundation
import Security
import XCTest
import ReaderSync

/// A keychain stand-in that counts every call. Each read stands for one possible prompt.
final class FakeSecretBackend: SecretItemBackend, @unchecked Sendable {
    let service = "com.reader.Reader.tests"
    private let lock = NSLock()
    var items: [String: String] = [:]
    /// Accounts whose reads are refused (the user clicked Deny).
    var denied: [String: OSStatus] = [:]
    var writeStatus: OSStatus = errSecSuccess
    private(set) var reads: [String] = []
    private(set) var writes: [String] = []
    private(set) var removals: [String] = []

    func read(account: String) -> SecretLookup {
        lock.lock()
        defer { lock.unlock() }
        reads.append(account)
        if let status = denied[account] { return .unavailable(status) }
        return items[account].map(SecretLookup.found) ?? .notFound
    }

    func write(account: String, secret: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        writes.append(account)
        if writeStatus == errSecSuccess { items[account] = secret }
        return writeStatus
    }

    func remove(account: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        removals.append(account)
        items[account] = nil
        return errSecSuccess
    }

    var bundle: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let json = items[SecretStore.bundleAccount] else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    }

    func resetCounts() {
        lock.lock()
        reads = []
        writes = []
        removals = []
        lock.unlock()
    }
}

final class SecretStoreTests: XCTestCase {
    private func bundleJSON(_ values: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(values), as: UTF8.self)
    }

    func testRepeatedLoadsReadTheKeychainOnce() {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = bundleJSON(["openai": "sk-o", "anthropic": "sk-a", SyncKeychainAccount.credential: "cred"])
        let store = SecretStore(backend: backend)

        for _ in 0..<100 {
            XCTAssertEqual(store.load(account: "openai"), "sk-o")
            XCTAssertEqual(store.load(account: "anthropic"), "sk-a")
            XCTAssertEqual(store.load(account: SyncKeychainAccount.credential), "cred")
        }
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount], "every secret comes from one read of one item")
        XCTAssertEqual(backend.writes, [])
    }

    func testMissingSecretsAreCachedToo() {
        let backend = FakeSecretBackend()
        let store = SecretStore(backend: backend)

        for _ in 0..<50 {
            XCTAssertEqual(store.lookup(account: "openai"), .notFound)
            XCTAssertNil(store.load(account: SyncKeychainAccount.credential))
        }
        // The combined item and each old item are looked for once, and nothing is created.
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount] + SecretStore.legacyAccounts)
        XCTAssertEqual(backend.writes, [])
    }

    func testOldItemsAreCopiedIntoOneItemAndLeftInPlace() {
        let backend = FakeSecretBackend()
        backend.items["openai"] = "sk-o"
        backend.items[SyncKeychainAccount.credential] = "cred"
        backend.items[SyncKeychainAccount.deviceId] = "dev-1"
        let store = SecretStore(backend: backend)

        XCTAssertEqual(store.load(account: "openai"), "sk-o")
        XCTAssertEqual(store.load(account: SyncKeychainAccount.credential), "cred")
        XCTAssertNil(store.load(account: "anthropic"))
        XCTAssertEqual(backend.bundle, ["openai": "sk-o", SyncKeychainAccount.credential: "cred"])
        XCTAssertEqual(backend.items["openai"], "sk-o", "an older build can still read its own item")
        XCTAssertEqual(backend.removals, [])
        XCTAssertFalse(backend.reads.contains(SyncKeychainAccount.deviceId), "non-secrets are not migrated")

        // The next launch reads only the combined item.
        backend.resetCounts()
        let nextLaunch = SecretStore(backend: backend)
        XCTAssertEqual(nextLaunch.load(account: "openai"), "sk-o")
        XCTAssertEqual(nextLaunch.load(account: SyncKeychainAccount.credential), "cred")
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount])
    }

    func testDeniedPromptIsNotAskedAgainThisLaunch() {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = bundleJSON([SyncKeychainAccount.credential: "cred"])
        backend.denied[SecretStore.bundleAccount] = errSecUserCanceled
        let store = SecretStore(backend: backend)

        for _ in 0..<100 {
            XCTAssertEqual(store.lookup(account: SyncKeychainAccount.credential), .unavailable(errSecUserCanceled))
        }
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount])
    }

    func testDeniedOldItemBlocksMigrationSoNoKeyIsLost() {
        let backend = FakeSecretBackend()
        backend.items["openai"] = "sk-o"
        backend.items["anthropic"] = "sk-a"
        backend.denied["anthropic"] = errSecAuthFailed
        let store = SecretStore(backend: backend)

        XCTAssertEqual(store.load(account: "openai"), "sk-o")
        XCTAssertEqual(store.lookup(account: "anthropic"), .unavailable(errSecAuthFailed))
        XCTAssertNil(backend.items[SecretStore.bundleAccount], "writing now would hide the anthropic key from later launches")
        XCTAssertEqual(backend.writes, [])
        // Still one read of each item for the whole launch.
        _ = store.lookup(account: "anthropic")
        _ = store.lookup(account: "openai")
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount] + SecretStore.legacyAccounts)
    }

    func testSavingWhileAnOldItemIsUnreadableRefusesToWrite() {
        let backend = FakeSecretBackend()
        backend.items["anthropic"] = "sk-a"
        backend.denied["anthropic"] = errSecAuthFailed
        let store = SecretStore(backend: backend)

        XCTAssertThrowsError(try store.update(account: "openai", secret: "sk-new"))
        XCTAssertNil(backend.items[SecretStore.bundleAccount])

        // Once access is allowed, the save carries the old key along.
        backend.denied = [:]
        XCTAssertEqual(try store.update(account: "openai", secret: "sk-new"), .saved)
        XCTAssertEqual(backend.bundle, ["openai": "sk-new", "anthropic": "sk-a"])
    }

    func testSavingTheSameValueWritesNothing() throws {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = bundleJSON(["openai": "sk-o"])
        let store = SecretStore(backend: backend)

        XCTAssertEqual(try store.update(account: "openai", secret: "sk-o"), .unchanged)
        XCTAssertEqual(try store.remove(account: "anthropic"), .unchanged)
        XCTAssertEqual(backend.writes, [])

        XCTAssertEqual(try store.update(account: "anthropic", secret: "sk-a"), .saved)
        XCTAssertEqual(backend.bundle, ["openai": "sk-o", "anthropic": "sk-a"])
        XCTAssertEqual(store.load(account: "anthropic"), "sk-a")
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount], "a save does not re-read")
    }

    func testRemovingAKeyAlsoRemovesTheOldItem() throws {
        let backend = FakeSecretBackend()
        backend.items["openai"] = "sk-o"
        let store = SecretStore(backend: backend)

        XCTAssertEqual(try store.remove(account: "openai"), .removed)
        XCTAssertNil(store.load(account: "openai"))
        XCTAssertEqual(backend.bundle, [:])
        XCTAssertNil(backend.items["openai"])

        // With the combined item present, the old one is never read again.
        backend.resetCounts()
        XCTAssertNil(SecretStore(backend: backend).load(account: "openai"))
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount])
    }

    func testUnreadableKeychainIsNeverTreatedAsEmpty() throws {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = bundleJSON(["openai": "sk-o"])
        backend.denied[SecretStore.bundleAccount] = errSecUserCanceled
        let store = SecretStore(backend: backend)

        // Settings closing with an empty field must not delete the key it could not show.
        XCTAssertEqual(try store.remove(account: "openai"), .unchanged)
        XCTAssertEqual(backend.writes, [])
        XCTAssertEqual(backend.removals, [])
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount])
    }

    func testSavingAfterADenialAsksOnceMore() throws {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = bundleJSON(["anthropic": "sk-a"])
        backend.denied[SecretStore.bundleAccount] = errSecUserCanceled
        let store = SecretStore(backend: backend)
        XCTAssertEqual(store.lookup(account: "anthropic"), .unavailable(errSecUserCanceled))

        backend.denied = [:]
        XCTAssertEqual(try store.update(account: "openai", secret: "sk-o"), .saved)
        XCTAssertEqual(backend.bundle, ["openai": "sk-o", "anthropic": "sk-a"], "the other key survives")
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount, SecretStore.bundleAccount])
    }

    func testFirstSaveAfterADenialDoesNotAskTwiceInARow() {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = bundleJSON(["anthropic": "sk-a"])
        backend.denied[SecretStore.bundleAccount] = errSecUserCanceled
        let store = SecretStore(backend: backend)

        XCTAssertThrowsError(try store.update(account: "openai", secret: "sk-o"))
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount])
        XCTAssertEqual(backend.writes, [])
    }

    func testCorruptCombinedItemIsNotOverwritten() {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = "not json"
        backend.items["openai"] = "sk-o"
        let store = SecretStore(backend: backend)

        XCTAssertEqual(store.lookup(account: "openai"), .unavailable(errSecDecode))
        XCTAssertThrowsError(try store.update(account: "anthropic", secret: "sk-a"))
        XCTAssertEqual(backend.items[SecretStore.bundleAccount], "not json")
    }

    func testFailedWriteKeepsTheOldValue() {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = bundleJSON(["openai": "sk-o"])
        backend.writeStatus = errSecAuthFailed
        let store = SecretStore(backend: backend)

        XCTAssertThrowsError(try store.update(account: "openai", secret: "sk-new"))
        XCTAssertEqual(store.load(account: "openai"), "sk-o")
    }

    func testLegacyValuesAreReadAtMostOnce() {
        let backend = FakeSecretBackend()
        backend.items[SyncKeychainAccount.deviceId] = "dev-1"
        let store = SecretStore(backend: backend)

        for _ in 0..<10 {
            XCTAssertEqual(store.legacyValue(account: SyncKeychainAccount.deviceId), "dev-1")
            XCTAssertNil(store.legacyValue(account: SyncKeychainAccount.serverId))
        }
        XCTAssertEqual(backend.reads, [SyncKeychainAccount.deviceId, SyncKeychainAccount.serverId])
    }

    func testConcurrentFirstUseReadsOnce() {
        let backend = FakeSecretBackend()
        backend.items[SecretStore.bundleAccount] = bundleJSON(["openai": "sk-o"])
        let store = SecretStore(backend: backend)

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index.isMultiple(of: 2) {
                XCTAssertEqual(store.load(account: "openai"), "sk-o")
            } else {
                XCTAssertNil(store.load(account: "anthropic"))
            }
        }
        XCTAssertEqual(backend.reads, [SecretStore.bundleAccount])
    }
}

/// Exercises the real keychain calls under a throwaway service. Off by default: run with
/// READER_KEYCHAIN_LIVE=1 on a Mac whose login keychain is unlocked. The test process
/// creates the items, so it owns them and no prompt appears.
final class KeychainItemBackendLiveTests: XCTestCase {
    func testWriteReadUpdateRemoveAgainstTheLoginKeychain() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["READER_KEYCHAIN_LIVE"] == "1", "Set READER_KEYCHAIN_LIVE=1")
        let backend = KeychainItemBackend(service: "com.reader.Reader.livetest.\(UUID().uuidString)")
        defer {
            _ = backend.remove(account: SecretStore.bundleAccount)
            _ = backend.remove(account: "openai")
        }
        XCTAssertEqual(backend.read(account: SecretStore.bundleAccount), .notFound)
        XCTAssertEqual(backend.write(account: "openai", secret: "sk-old"), errSecSuccess)

        let store = SecretStore(backend: backend)
        XCTAssertEqual(store.load(account: "openai"), "sk-old")
        XCTAssertEqual(try store.update(account: "anthropic", secret: "sk-a"), .saved)
        XCTAssertEqual(try store.update(account: "anthropic", secret: "sk-a2"), .saved, "updates the item in place")

        let nextLaunch = SecretStore(backend: backend)
        XCTAssertEqual(nextLaunch.load(account: "openai"), "sk-old")
        XCTAssertEqual(nextLaunch.load(account: "anthropic"), "sk-a2")
        XCTAssertEqual(try nextLaunch.remove(account: "openai"), .removed)
        XCTAssertEqual(backend.read(account: "openai"), .notFound)
        XCTAssertNil(SecretStore(backend: backend).load(account: "openai"))
    }
}

/// Counts what the sync engine asks of its credential store.
final class CountingCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: String] = [:]
    var refusal: OSStatus?
    private(set) var lookups: [String] = []
    private(set) var legacyReads: [String] = []
    private(set) var saves: [String] = []

    func save(account: String, secret: String) throws {
        lock.lock()
        saves.append(account)
        values[account] = secret
        lock.unlock()
    }

    func load(account: String) -> String? {
        lookup(account: account).value
    }

    func delete(account: String) {
        lock.lock()
        values[account] = nil
        lock.unlock()
    }

    func lookup(account: String) -> SecretLookup {
        lock.lock()
        defer { lock.unlock() }
        lookups.append(account)
        if let refusal { return .unavailable(refusal) }
        return values[account].map(SecretLookup.found) ?? .notFound
    }

    func legacyValue(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        legacyReads.append(account)
        return values[account]
    }
}

final class SyncEngineKeychainTests: XCTestCase {
    private func makeEngine(
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("reader-sync-keychain-\(UUID().uuidString)", isDirectory: true),
        credentials: CountingCredentialStore,
        transport: MockTransport
    ) throws -> SyncEngine {
        let configuration = SyncClientConfiguration(
            baseURL: SyncClientConfiguration.loopbackTestURL,
            loopbackLogin: "arturo@local",
            deviceName: "Test Mac",
            appVersion: "test"
        )
        return try SyncEngine(directory: directory, configuration: configuration, credentials: credentials, transport: transport)
    }

    private func pairingTransport(onRequest: @escaping (String) -> Void = { _ in }) -> MockTransport {
        let transport = MockTransport()
        transport.handler = { request in
            let path = request.url?.path ?? ""
            onRequest(path)
            if path.hasSuffix("/v1/pairing/tokens") {
                return jsonResponse(200, [
                    "token": "MACTOKEN",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "qr": "readersync://pair?v=2&url=http://127.0.0.1:8789/v1/reader&token=MACTOKEN&server=srv_test",
                ])
            }
            if path.hasSuffix("/v1/pairing/redeem") {
                return jsonResponse(200, ["deviceId": "dev-mac", "credential": "secret-cred", "serverId": "srv_test", "kind": "mac"])
            }
            if path.hasSuffix("/v1/devices") {
                return jsonResponse(200, ["devices": []])
            }
            return jsonResponse(404, [:])
        }
        return transport
    }

    func testBuildingTheEngineAndRefreshingStatusNeverReadTheKeychain() throws {
        let credentials = CountingCredentialStore()
        credentials.values[SyncKeychainAccount.credential] = "cred"
        let engine = try makeEngine(credentials: credentials, transport: pairingTransport())

        for _ in 0..<100 {
            _ = engine.status()
            _ = engine.isPaired
        }
        XCTAssertEqual(credentials.lookups, [])
        XCTAssertEqual(credentials.legacyReads, [])
    }

    func testPairingSavesOnlyTheCredentialAndKeepsIdsInTheDatabase() async throws {
        let credentials = CountingCredentialStore()
        let engine = try makeEngine(credentials: credentials, transport: pairingTransport())
        XCTAssertFalse(engine.isPaired)

        let redeemed = try await engine.ensureMacPaired()
        XCTAssertEqual(redeemed.credential, "secret-cred")
        XCTAssertEqual(credentials.saves, [SyncKeychainAccount.credential])
        XCTAssertEqual(engine.store.meta("deviceId"), "dev-mac")
        XCTAssertEqual(engine.store.serverId, "srv_test")
        XCTAssertTrue(engine.isPaired)
    }

    func testCredentialIsReadOnceAcrossManyCalls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-sync-keychain-\(UUID().uuidString)", isDirectory: true)
        let first = CountingCredentialStore()
        let paired = try makeEngine(directory: directory, credentials: first, transport: pairingTransport())
        _ = try await paired.ensureMacPaired()

        // A later launch: same database, credential already in the keychain.
        let credentials = CountingCredentialStore()
        credentials.values[SyncKeychainAccount.credential] = "secret-cred"
        let engine = try makeEngine(directory: directory, credentials: credentials, transport: pairingTransport())
        XCTAssertTrue(engine.isPaired, "known from the database without asking the keychain")
        XCTAssertEqual(credentials.lookups, [])

        for _ in 0..<20 {
            let response = try await engine.ensureMacPaired()
            XCTAssertEqual(response.deviceId, "dev-mac")
            XCTAssertEqual(response.serverId, "srv_test")
            _ = engine.status()
        }
        XCTAssertEqual(credentials.lookups, [SyncKeychainAccount.credential])
        XCTAssertEqual(credentials.legacyReads, [], "ids come from the database")
        XCTAssertEqual(engine.http.credential, "secret-cred")
    }

    func testRefusedKeychainDoesNotPairAgain() async throws {
        let credentials = CountingCredentialStore()
        credentials.values[SyncKeychainAccount.credential] = "secret-cred"
        credentials.refusal = errSecUserCanceled
        var requests: [String] = []
        let engine = try makeEngine(credentials: credentials, transport: pairingTransport { requests.append($0) })

        do {
            _ = try await engine.ensureMacPaired()
            XCTFail("expected a keychain error")
        } catch let error as SyncAPIError {
            XCTAssertEqual(error.code, "keychain")
        }
        XCTAssertEqual(requests, [], "a denied prompt must not register this Mac as a new device")
        XCTAssertEqual(credentials.saves, [])
    }

    func testLostDatabaseRecoversDeviceIdFromTheOldKeychainItem() async throws {
        let credentials = CountingCredentialStore()
        credentials.values[SyncKeychainAccount.credential] = "secret-cred"
        credentials.values[SyncKeychainAccount.deviceId] = "dev-old"
        credentials.values[SyncKeychainAccount.serverId] = "srv_old"
        let engine = try makeEngine(credentials: credentials, transport: pairingTransport())

        let response = try await engine.ensureMacPaired()
        XCTAssertEqual(response.deviceId, "dev-old")
        XCTAssertEqual(response.serverId, "srv_old")
        XCTAssertEqual(credentials.legacyReads, [SyncKeychainAccount.deviceId, SyncKeychainAccount.serverId])
    }
}
