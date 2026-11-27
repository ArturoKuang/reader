import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func save(account: String, secret: String) throws
    func load(account: String) -> String?
    func delete(account: String)
}

/// In-memory store that tests can inject. The struct wrapper above is unused; this is the real one.
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

public struct KeychainCredentialStore: CredentialStoring, Sendable {
    public var service: String

    public init(service: String = "com.reader.Reader") {
        self.service = service
    }

    public func save(account: String, secret: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            throw SyncAPIError(status: 0, code: "keychain", message: "could not save the device token in Keychain (\(status))")
        }
    }

    public func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    public func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum SyncKeychainAccount {
    public static let credential = "taildrive.credential"
    public static let deviceId = "taildrive.deviceId"
    public static let serverId = "taildrive.serverId"
}
