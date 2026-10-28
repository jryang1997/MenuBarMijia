import Foundation
import Security

/// Every credential lives in **one** Keychain item, read once per process (#16).
///
/// Releases are signed with a free self-signed certificate. macOS stamps each Keychain item with the creating
/// build's `cdhash:` partition ID, so after every upgrade it asks again — for every item, on every read, because
/// `kSecUseAuthenticationUISkip` does not suppress that prompt on the file-based login keychain. Keeping all
/// credentials in a single item that is read once turns "a prompt per read of every credential" into one prompt per
/// upgrade; answering it with "Always Allow" also covers the writes that follow.
///
/// Failure rules: a vault that cannot be read reads as "not signed in" and is never overwritten (that would wipe the
/// other credentials); a failed write leaves the previous value in place.
public final class CredentialVault: @unchecked Sendable {
    public enum Lookup: Equatable, Sendable {
        case value(Data)
        case missing
        case unavailable
    }

    /// The single Keychain item that holds the encoded vault.
    struct Storage: Sendable {
        enum ReadResult: Equatable, Sendable {
            case found(Data)
            case notFound
            case unavailable
        }

        var read: @Sendable () -> ReadResult
        /// Replaces the item's data in place (keeping its access control), adding the item only when it is missing.
        var write: @Sendable (Data) -> Bool
    }

    /// Per-account items written by releases up to 1.1.0. Adopted once, when no vault exists yet.
    struct LegacyItems: Sendable {
        var accounts: @Sendable () -> [String]
        var read: @Sendable (String) -> Data?
        var delete: @Sendable (String) -> Void

        static let none = LegacyItems(accounts: { [] }, read: { _ in nil }, delete: { _ in })
    }

    static let vaultAccount = "credential_vault_v1"

    public static let shared = CredentialVault(
        storage: .keychainItem(account: vaultAccount),
        legacy: .keychainItems(excluding: vaultAccount)
    )

    private enum State {
        case unloaded
        case loaded([String: Data])
        case unavailable
    }

    private let storage: Storage
    private let legacy: LegacyItems
    private let lock = NSLock()
    private var state = State.unloaded

    init(storage: Storage, legacy: LegacyItems = .none) {
        self.storage = storage
        self.legacy = legacy
    }

    /// Reads go to memory after the first successful load. An unreadable vault is not retried on reads, so a
    /// declined prompt is not followed by another one on the next read.
    public func lookup(_ account: String) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        guard let items = loadedItems(retryingUnavailable: false) else { return .unavailable }
        return items[account].map(Lookup.value) ?? .missing
    }

    func data(for account: String) -> Data? {
        if case .value(let data) = lookup(account) { return data }
        return nil
    }

    /// `nil` removes the account. Writes retry an unreadable vault once: they follow a user action, and the vault
    /// has to be readable before any of it is rewritten.
    @discardableResult
    func set(_ data: Data?, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var items = loadedItems(retryingUnavailable: true) else { return false }
        guard items[account] != data else { return true }
        items[account] = data
        return persist(items)
    }

    /// Adds the value only when the account is empty; an existing credential always wins over a migrated one.
    func insertIfMissing(_ data: Data, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var items = loadedItems(retryingUnavailable: false) else { return false }
        guard items[account] == nil else { return true }
        items[account] = data
        return persist(items)
    }

    /// True once this process has read the vault (or found there is nothing to read).
    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .loaded = state { return true }
        return false
    }

    // MARK: - Loading

    private func loadedItems(retryingUnavailable: Bool) -> [String: Data]? {
        switch state {
        case .loaded(let items):
            return items
        case .unavailable where !retryingUnavailable:
            return nil
        case .unavailable, .unloaded:
            break
        }
        switch storage.read() {
        case .found(let blob):
            // An undecodable vault is never rewritten: that would drop every credential in it.
            guard let items = Self.decode(blob) else {
                state = .unavailable
                return nil
            }
            state = .loaded(items)
            return items
        case .notFound:
            return adoptLegacyItems()
        case .unavailable:
            state = .unavailable
            return nil
        }
    }

    /// Moves the 1.1.0 per-account items into a new vault. The old items are deleted only after the vault was
    /// written. When any of them cannot be read (a declined prompt), nothing is written or deleted here, so the next
    /// launch retries the whole move; the readable ones still serve this session. A credential saved before that
    /// retry creates the vault, after which an unread old item is left in place untouched rather than adopted.
    private func adoptLegacyItems() -> [String: Data] {
        var items: [String: Data] = [:]
        var complete = true
        for account in legacy.accounts() {
            if let data = legacy.read(account) {
                items[account] = data
            } else {
                complete = false
            }
        }
        state = .loaded(items)
        guard complete, !items.isEmpty, persist(items) else { return items }
        for account in items.keys {
            legacy.delete(account)
        }
        return items
    }

    private func persist(_ items: [String: Data]) -> Bool {
        guard let blob = Self.encode(items), storage.write(blob) else { return false }
        state = .loaded(items)
        return true
    }

    // MARK: - Encoding

    private struct File: Codable {
        var version: Int
        var items: [String: Data]
    }

    static func encode(_ items: [String: Data]) -> Data? {
        try? JSONEncoder().encode(File(version: 1, items: items))
    }

    static func decode(_ blob: Data) -> [String: Data]? {
        guard let file = try? JSONDecoder().decode(File.self, from: blob), file.version == 1 else { return nil }
        return file.items
    }
}

// MARK: - Keychain Backing

private func keychainQuery(service: String, account: String?) -> [String: Any] {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service
    ]
    if let account {
        query[kSecAttrAccount as String] = account
    }
    return query
}

extension CredentialVault.Storage {
    static func keychainItem(
        service: String = KeychainHelper.service,
        account: String,
        updateItem: @escaping @Sendable (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
        addItem: @escaping @Sendable (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    ) -> Self {
        return Self(
            read: {
                var query = keychainQuery(service: service, account: account)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
                var item: CFTypeRef?
                switch SecItemCopyMatching(query as CFDictionary, &item) {
                case errSecSuccess:
                    guard let data = item as? Data else { return .unavailable }
                    return .found(data)
                case errSecItemNotFound:
                    return .notFound
                default:
                    return .unavailable
                }
            },
            write: { data in
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                ]
                // Update in place: delete-then-add would lose the credentials when the add is refused.
                let query = keychainQuery(service: service, account: account)
                let status = updateItem(query as CFDictionary, attributes as CFDictionary)
                if status == errSecSuccess { return true }
                guard status == errSecItemNotFound else { return false }
                let addQuery = query.merging(attributes) { _, new in new }
                return addItem(addQuery as CFDictionary) == errSecSuccess
            }
        )
    }
}

extension CredentialVault.LegacyItems {
    static func keychainItems(service: String = KeychainHelper.service, excluding vaultAccount: String) -> Self {
        #if os(macOS)
        return Self(
            accounts: {
                // Attributes only: listing items never needs their secret, so it never prompts.
                var query = keychainQuery(service: service, account: nil)
                query[kSecReturnAttributes as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitAll
                var result: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                      let rows = result as? [[String: Any]] else { return [] }
                return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0 != vaultAccount }
            },
            read: { account in
                var query = keychainQuery(service: service, account: account)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
                return item as? Data
            },
            delete: { account in
                let query = keychainQuery(service: service, account: account)
                SecItemDelete(query as CFDictionary)
            }
        )
        #else
        return .none
        #endif
    }
}

extension CredentialVault {
    /// Whether the app has stored any credential on this Mac, judged from item attributes only (never prompts).
    public static func hasStoredCredentials(service: String = KeychainHelper.service) -> Bool {
        itemExists(service: service, account: nil)
    }

    /// Whether the single-item vault exists yet (as opposed to only the 1.1.0 per-account items).
    public static func hasVaultItem(service: String = KeychainHelper.service) -> Bool {
        itemExists(service: service, account: vaultAccount)
    }

    private static func itemExists(service: String, account: String?) -> Bool {
        #if os(macOS)
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        #else
        return false
        #endif
    }
}
