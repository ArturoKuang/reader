import Foundation
import Security

/// What a secret lookup found.
public enum SecretLookup: Equatable, Sendable {
    case found(String)
    case notFound
    /// The keychain refused: the user denied or cancelled the prompt, the keychain is locked,
    /// or the item could not be decoded. Reader must not treat this as "no secret".
    case unavailable(OSStatus)

    public var value: String? {
        if case .found(let value) = self { return value }
        return nil
    }
}

public struct SecretStoreError: Error, Equatable, Sendable {
    public var status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var message: String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Keychain: \(detail)"
    }
}

public protocol CredentialStoring: Sendable {
    func save(account: String, secret: String) throws
    func load(account: String) -> String?
    func delete(account: String)
    /// Like `load`, but says whether the keychain refused instead of folding that into nil.
    func lookup(account: String) -> SecretLookup
    /// Reads a value Reader used to keep in its own keychain item (device id, server id).
    /// Only for recovery when the sync database lost its copy.
    func legacyValue(account: String) -> String?
}

public extension CredentialStoring {
    func lookup(account: String) -> SecretLookup {
        load(account: account).map(SecretLookup.found) ?? .notFound
    }

    func legacyValue(account: String) -> String? {
        load(account: account)
    }
}

/// In-memory store that tests can inject.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func save(account: String, secret: String) throws {
        lock.lock()
        values[account] = secret
        lock.unlock()
    }

    public func load(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    public func delete(account: String) {
        lock.lock()
        values[account] = nil
        lock.unlock()
    }
}

// MARK: - Keychain items

/// One generic-password item per account. `SecretStore` is the only caller in the app.
public protocol SecretItemBackend: Sendable {
    var service: String { get }
    func read(account: String) -> SecretLookup
    /// Updates the item in place, or adds it when it does not exist yet.
    func write(account: String, secret: String) -> OSStatus
    func remove(account: String) -> OSStatus
}

public struct KeychainItemBackend: SecretItemBackend {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) -> SecretLookup {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                return .unavailable(errSecDecode)
            }
            return .found(string)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    public func write(account: String, secret: String) -> OSStatus {
        let data = Data(secret.utf8)
        // Update in place: deleting and re-adding would ask the user once more for the delete.
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }

    public func remove(account: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

// MARK: - The one store the app uses

/// Every secret Reader keeps (API keys, the sync credential) in one keychain item,
/// read at most once per launch.
///
/// The release app is ad-hoc signed, so each build is a new code identity and the keychain
/// asks again before the first read of each item. One item means one prompt per build, and
/// the cache means "Allow" (as opposed to "Always Allow") is not asked again on the next read.
/// A refusal is remembered for the launch so a background loop cannot re-prompt.
///
/// Older builds kept one item per account. When the combined item is missing, those are read
/// once and copied into it. They are left in place (an older build can still read them) and
/// only removed when the user deletes that key.
public final class SecretStore: CredentialStoring, @unchecked Sendable {
    /// Account of the combined item: a JSON object `{account: secret}`.
    public static let bundleAccount = "reader.secrets"
    /// Accounts older builds stored as their own items.
    public static let legacyAccounts = ["openai", "anthropic", SyncKeychainAccount.credential]

    public static let shared = SecretStore(
        backend: KeychainItemBackend(service: Bundle.main.bundleIdentifier ?? "com.reader.Reader")
    )

    public enum WriteResult: Equatable, Sendable {
        case unchanged
        case saved
        case removed
    }

    private enum State {
        case unloaded
        case loaded([String: String])
        case unavailable(OSStatus)
    }

    private let backend: SecretItemBackend
    private let legacyAccounts: [String]
    private let lock = NSRecursiveLock()
    private var state: State = .unloaded
    /// Legacy accounts whose old item could not be read this launch.
    private var blocked: [String: OSStatus] = [:]
    /// Raw reads of other legacy items (device id, server id), at most one per account.
    private var legacyCache: [String: SecretLookup] = [:]

    public init(backend: SecretItemBackend, legacyAccounts: [String] = SecretStore.legacyAccounts) {
        self.backend = backend
        self.legacyAccounts = legacyAccounts
    }

    public var service: String { backend.service }

    // MARK: Reading

    public func lookup(account: String) -> SecretLookup {
        lock.lock()
        defer { lock.unlock() }
        switch loadedState() {
        case .loaded(let values):
            if let value = values[account] { return .found(value) }
            if let status = blocked[account] { return .unavailable(status) }
            return .notFound
        case .unavailable(let status):
            return .unavailable(status)
        case .unloaded:
            return .notFound
        }
    }

    public func load(account: String) -> String? {
        lookup(account: account).value
    }

    public func legacyValue(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = legacyCache[account] { return cached.value }
        let result = backend.read(account: account)
        legacyCache[account] = result
        return result.value
    }

    /// Reads the combined item (or migrates the old ones) the first time anything asks.
    private func loadedState() -> State {
        if case .unloaded = state {
            state = readFromKeychain()
        }
        return state
    }

    private func readFromKeychain() -> State {
        switch backend.read(account: Self.bundleAccount) {
        case .found(let json):
            guard let values = Self.decode(json) else { return .unavailable(errSecDecode) }
            return .loaded(values)
        case .unavailable(let status):
            return .unavailable(status)
        case .notFound:
            return .loaded(migrateLegacyItems())
        }
    }

    private func migrateLegacyItems() -> [String: String] {
        var values: [String: String] = [:]
        blocked = [:]
        for account in legacyAccounts {
            switch backend.read(account: account) {
            case .found(let value): values[account] = value
            case .notFound: break
            case .unavailable(let status): blocked[account] = status
            }
        }
        // Writing the combined item while an old one is unreadable would hide that key from
        // every later launch, so leave everything as it is and try again next launch.
        if !values.isEmpty, blocked.isEmpty {
            _ = backend.write(account: Self.bundleAccount, secret: Self.encode(values))
        }
        return values
    }

    // MARK: Writing

    public func save(account: String, secret: String) throws {
        try update(account: account, secret: secret)
    }

    public func delete(account: String) {
        _ = try? remove(account: account)
    }

    /// Stores `secret`. Does nothing when the keychain already holds that value.
    @discardableResult
    public func update(account: String, secret: String) throws -> WriteResult {
        lock.lock()
        defer { lock.unlock() }
        if case .unavailable = state {
            // An earlier read was refused. The user is saving on purpose, so ask once more.
            state = .unloaded
        }
        guard case .loaded(let current) = loadedState() else {
            if case .unavailable(let status) = state { throw SecretStoreError(status: status) }
            throw SecretStoreError(status: errSecInternalError)
        }
        if current[account] == secret, blocked[account] == nil { return .unchanged }
        var values = try unblockLegacyItems(except: account)
        values[account] = secret
        let status = backend.write(account: Self.bundleAccount, secret: Self.encode(values))
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        state = .loaded(values)
        return .saved
    }

    /// Removes the secret, including the item an older build kept for it.
    /// Does nothing when the keychain could not be read: an empty field the user never saw
    /// filled is not a request to delete their key.
    @discardableResult
    public func remove(account: String) throws -> WriteResult {
        lock.lock()
        defer { lock.unlock() }
        guard case .loaded(let current) = loadedState() else { return .unchanged }
        guard blocked[account] == nil, current[account] != nil else { return .unchanged }
        var values = try unblockLegacyItems(except: account)
        values[account] = nil
        let status = backend.write(account: Self.bundleAccount, secret: Self.encode(values))
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        state = .loaded(values)
        if legacyAccounts.contains(account) {
            _ = backend.remove(account: account)
        }
        return .removed
    }

    /// Writing the combined item makes later launches skip the old items, so every old item
    /// has to be read first. The user is changing a key on purpose, so asking again is fine.
    /// Returns the loaded values, including any old items it could now read.
    private func unblockLegacyItems(except account: String) throws -> [String: String] {
        guard case .loaded(var values) = state else { return [:] }
        // Keep what was read even when a later item throws.
        defer { state = .loaded(values) }
        for blockedAccount in blocked.keys.sorted() where blockedAccount != account {
            switch backend.read(account: blockedAccount) {
            case .found(let value):
                values[blockedAccount] = value
                blocked[blockedAccount] = nil
            case .notFound:
                blocked[blockedAccount] = nil
            case .unavailable(let status):
                blocked[blockedAccount] = status
                throw SecretStoreError(status: status)
            }
        }
        blocked[account] = nil
        return values
    }

    // MARK: Encoding

    static func encode(_ values: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(values)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> [String: String]? {
        try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    }
}

public enum SyncKeychainAccount {
    public static let credential = "taildrive.credential"
    /// No longer written: the sync database keeps it. Read only to recover a lost database.
    public static let deviceId = "taildrive.deviceId"
    /// No longer written: the sync database keeps it. Read only to recover a lost database.
    public static let serverId = "taildrive.serverId"
}
