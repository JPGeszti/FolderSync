import CryptoKit
import Foundation
import Security

/// Supplies the symmetric key protecting the version store.
public protocol KeyProvider: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

/// Used by tests; the key never leaves memory.
public struct InMemoryKeyProvider: KeyProvider {
    private let keyData: Data
    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        keyData = key.withUnsafeBytes { Data($0) }
    }
    public func loadOrCreateKey() throws -> SymmetricKey { SymmetricKey(data: keyData) }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
    }
}

/// Stores a random 256-bit key as a generic password in the user's keychain. The item is
/// device-bound (`ThisDeviceOnly`) so it is never migrated through backups to another Mac,
/// and it never leaves the machine (no iCloud Keychain sync).
public struct KeychainKeyProvider: KeyProvider {
    public let service: String
    public let account: String

    public init(service: String = "FolderSync Version Store", account: String = "store-key-v1") {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try load() { return existing }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem, let raced = try load() { return raced }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }

    private func load() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data, data.count == 32 else {
            throw KeychainError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return SymmetricKey(data: data)
    }
}

/// Uses the Keychain when available and otherwise a key file (mode 0600) inside the sandboxed
/// application container. The fallback is weaker (the key sits next to the data, protected by the
/// sandbox, file permissions and FileVault) and is reported to the user in Settings.
public final class PreferredKeyProvider: KeyProvider, @unchecked Sendable {
    public enum Source: String, Sendable { case keychain, localFile }
    public private(set) var source: Source = .keychain
    let keychain: KeychainKeyProvider
    let fileURL: URL
    let allowCreatingFallback: Bool

    /// `allowCreatingFallback` must be false once a store exists: a transient Keychain failure
    /// must never cause a new key to be generated for an existing store.
    public init(keychain: KeychainKeyProvider = KeychainKeyProvider(), fallbackFile: URL, allowCreatingFallback: Bool) {
        self.keychain = keychain
        fileURL = fallbackFile
        self.allowCreatingFallback = allowCreatingFallback
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        // A key file that already exists means the store was created with it: keep using it.
        if let data = try? Data(contentsOf: fileURL), data.count == 32 {
            source = .localFile
            return SymmetricKey(data: data)
        }
        do {
            source = .keychain
            return try keychain.loadOrCreateKey()
        } catch {
            guard allowCreatingFallback else { throw error }
            source = .localFile
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            let oldMask = umask(0o077)
            defer { umask(oldMask) }
            try data.write(to: fileURL, options: [.atomic, .withoutOverwriting])
            chmod(fileURL.path, 0o600)
            return key
        }
    }
}
