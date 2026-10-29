import Foundation
import Security
import Testing
@testable import MijiaCore

/// In-memory stand-in for the vault's single Keychain item; counts reads and writes so tests can prove how often
/// macOS would have been asked.
final class MemoryVaultStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var blob: Data?
    private var _readResult: CredentialVault.Storage.ReadResult?
    private var _writeSucceeds = true
    private var _reads = 0
    private var _writes = 0

    init(blob: Data? = nil) { self.blob = blob }

    /// Overrides what a read returns (e.g. `.unavailable` for a declined prompt).
    var readResult: CredentialVault.Storage.ReadResult? {
        get { locked { _readResult } }
        set { locked { _readResult = newValue } }
    }
    var writeSucceeds: Bool {
        get { locked { _writeSucceeds } }
        set { locked { _writeSucceeds = newValue } }
    }
    var reads: Int { locked { _reads } }
    var writes: Int { locked { _writes } }
    var rawBlob: Data? { locked { blob } }
    var storedItems: [String: Data]? { rawBlob.flatMap(CredentialVault.decode) }

    var storage: CredentialVault.Storage {
        CredentialVault.Storage(
            read: { [self] in
                locked {
                    _reads += 1
                    if let override = _readResult { return override }
                    return blob.map { .found($0) } ?? .notFound
                }
            },
            write: { [self] data in
                locked {
                    _writes += 1
                    guard _writeSucceeds else { return false }
                    blob = data
                    return true
                }
            }
        )
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// In-memory stand-in for the per-account Keychain items written by releases up to 1.1.0.
final class MemoryLegacyItems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]
    private var unreadable: Set<String>
    private(set) var deleted: [String] = []

    init(_ items: [String: Data], unreadable: Set<String> = []) {
        self.items = items
        self.unreadable = unreadable
    }

    var remaining: [String: Data] { lock.withLock { items } }
    var deletedAccounts: [String] { lock.withLock { deleted } }

    func allow(_ account: String) {
        lock.withLock { _ = unreadable.remove(account) }
    }

    var legacy: CredentialVault.LegacyItems {
        CredentialVault.LegacyItems(
            accounts: { [self] in lock.withLock { items.keys.sorted() } },
            read: { [self] account in lock.withLock { unreadable.contains(account) ? nil : items[account] } },
            delete: { [self] account in
                lock.withLock {
                    items[account] = nil
                    deleted.append(account)
                }
            }
        )
    }
}

/// #16: every credential sits in one Keychain item that is read once per process, so an upgrade signed with the
/// free self-signed certificate asks macOS at most once instead of once per read of every credential.
struct CredentialVaultTests {
    @Test("Credentials are read from the Keychain once per process, however often they are used")
    func readsTheKeychainOnce() throws {
        let seeded = try #require(CredentialVault.encode(["ha": Data("t".utf8), "mi": Data("s".utf8)]))
        let storage = MemoryVaultStorage(blob: seeded)
        let vault = CredentialVault(storage: storage.storage)

        for _ in 0..<20 {
            #expect(vault.data(for: "ha") == Data("t".utf8))
            #expect(vault.data(for: "mi") == Data("s".utf8))
            #expect(vault.lookup("absent") == .missing)
        }
        #expect(storage.reads == 1)
        #expect(vault.isLoaded)
    }

    @Test("Saving the value that is already stored does not touch the Keychain")
    func unchangedSaveSkipsWrite() throws {
        let storage = MemoryVaultStorage()
        let vault = CredentialVault(storage: storage.storage)
        try #require(vault.set(Data("v".utf8), for: "a"))
        #expect(storage.writes == 1)
        #expect(vault.set(Data("v".utf8), for: "a"))
        #expect(vault.set(nil, for: "never-saved"))
        #expect(storage.writes == 1)
    }

    @Test("All accounts share one item and survive each other's writes")
    func accountsShareOneItem() throws {
        let storage = MemoryVaultStorage()
        let vault = CredentialVault(storage: storage.storage)
        try #require(vault.set(Data("token".utf8), for: "ha_access_token"))
        try #require(vault.set(Data("key".utf8), for: "lg_webos_client_key"))
        try #require(vault.set(nil, for: "ha_access_token"))

        #expect(storage.storedItems == ["lg_webos_client_key": Data("key".utf8)])
        // A second process sees exactly what the first one stored.
        let relaunched = CredentialVault(storage: storage.storage)
        #expect(relaunched.data(for: "lg_webos_client_key") == Data("key".utf8))
        #expect(relaunched.lookup("ha_access_token") == .missing)
    }

    @Test("An unreadable vault reads as signed out, is not re-prompted on reads, and is never overwritten")
    func unreadableVaultIsNeverOverwritten() throws {
        let seeded = try #require(CredentialVault.encode(["ha": Data("t".utf8)]))
        let storage = MemoryVaultStorage(blob: seeded)
        storage.readResult = .unavailable
        let vault = CredentialVault(storage: storage.storage)

        #expect(vault.lookup("ha") == .unavailable)
        #expect(vault.data(for: "ha") == nil)
        #expect(storage.reads == 1, "a declined prompt must not be followed by another one on the next read")
        #expect(!vault.isLoaded)

        // A save retries the read once, and still refuses to replace credentials it could not read.
        #expect(!vault.set(Data("new".utf8), for: "other"))
        #expect(!vault.insertIfMissing(Data("legacy".utf8), for: "other"))
        #expect(storage.writes == 0)
        #expect(storage.rawBlob == seeded)

        // Once the user allows access, a save goes through and keeps the existing credentials.
        storage.readResult = nil
        #expect(vault.set(Data("new".utf8), for: "other"))
        #expect(storage.storedItems == ["ha": Data("t".utf8), "other": Data("new".utf8)])
    }

    @Test("A vault that cannot be decoded is treated as unreadable rather than replaced")
    func undecodableVaultIsKept() {
        let garbage = Data("not-a-vault".utf8)
        let storage = MemoryVaultStorage(blob: garbage)
        let vault = CredentialVault(storage: storage.storage)
        #expect(vault.lookup("ha") == .unavailable)
        #expect(!vault.set(Data("x".utf8), for: "ha"))
        #expect(storage.rawBlob == garbage)
    }

    @Test("1.1.0 per-account items move into the vault and are deleted only after it is written")
    func adoptsLegacyItems() {
        let storage = MemoryVaultStorage()
        let legacy = MemoryLegacyItems(["ha_access_token": Data("t".utf8), "mi_session": Data("s".utf8)])
        let vault = CredentialVault(storage: storage.storage, legacy: legacy.legacy)

        #expect(vault.data(for: "ha_access_token") == Data("t".utf8))
        #expect(storage.storedItems == ["ha_access_token": Data("t".utf8), "mi_session": Data("s".utf8)])
        #expect(legacy.remaining.isEmpty)

        // The next launch reads only the vault.
        let relaunched = CredentialVault(storage: storage.storage, legacy: MemoryLegacyItems([:]).legacy)
        #expect(relaunched.data(for: "mi_session") == Data("s".utf8))
    }

    @Test("Old items stay in place when the vault cannot be written")
    func legacyItemsSurviveFailedVaultWrite() {
        let storage = MemoryVaultStorage()
        storage.writeSucceeds = false
        let legacy = MemoryLegacyItems(["ha_access_token": Data("t".utf8)])
        let vault = CredentialVault(storage: storage.storage, legacy: legacy.legacy)

        #expect(vault.data(for: "ha_access_token") == Data("t".utf8), "the session still works from memory")
        #expect(legacy.deletedAccounts.isEmpty)
        #expect(legacy.remaining == ["ha_access_token": Data("t".utf8)])
    }

    @Test("When one old item cannot be read, it stays unavailable and blocks partial writes until readable")
    func partialLegacyReadRetriesLater() {
        let storage = MemoryVaultStorage()
        let legacy = MemoryLegacyItems(
            ["ha_access_token": Data("t".utf8), "mi_session": Data("s".utf8)],
            unreadable: ["mi_session"]
        )
        let vault = CredentialVault(storage: storage.storage, legacy: legacy.legacy)

        #expect(vault.data(for: "ha_access_token") == Data("t".utf8))
        #expect(vault.lookup("mi_session") == .unavailable)
        #expect(vault.lookup("absent") == .missing)
        #expect(!vault.isLoaded)
        #expect(!vault.set(Data("override".utf8), for: "mi_session"))
        #expect(!vault.set(Data("new".utf8), for: "other"))
        #expect(storage.rawBlob == nil)
        #expect(legacy.deletedAccounts.isEmpty)

        // Once the declined legacy item is allowed, a save completes migration and removes old items.
        legacy.allow("mi_session")
        #expect(vault.set(Data("new".utf8), for: "other"))
        #expect(vault.isLoaded)
        #expect(vault.data(for: "mi_session") == Data("s".utf8))
        #expect(storage.storedItems == [
            "ha_access_token": Data("t".utf8),
            "mi_session": Data("s".utf8),
            "other": Data("new".utf8)
        ])
        #expect(legacy.remaining.isEmpty)
    }

    @Test("Keychain storage updates in place and keeps the old value when the update is refused")
    func keychainStorageKeepsValueOnRefusedUpdate() throws {
        // A dedicated service keeps scratch items away from the app's own items and its legacy sweep.
        let service = "com.jryang1997.MenuBarMijia.tests"
        let account = "vault.\(UUID().uuidString)"
        defer {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
        let real = CredentialVault.Storage.keychainItem(service: service, account: account)
        #expect(real.read() == .notFound)
        try #require(real.write(Data("first".utf8)), "the Keychain must accept a scratch item")
        try #require(real.write(Data("second".utf8)))
        #expect(real.read() == .found(Data("second".utf8)))

        let refusing = CredentialVault.Storage.keychainItem(
            service: service, account: account,
            updateItem: { _, _ in errSecInteractionNotAllowed },
            addItem: { _ in errSecInteractionNotAllowed }
        )
        #expect(!refusing.write(Data("third".utf8)))
        #expect(real.read() == .found(Data("second".utf8)))
    }
}
