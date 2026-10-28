import Foundation
import Security
import Testing
@testable import MijiaCore

/// 审计 #16 / #27：凭证只存钥匙串，不再明文镜像到 `UserDefaults`；旧明文键在启动时迁入钥匙串并删除；
/// 米家会话不再持久化 `passToken`（见 `docs/adr/0004-no-pass-token-storage.md`）。
struct KeychainCredentialTests {
    /// Each test gets its own in-memory vault, so a developer's real credentials are never touched.
    private func memoryVault(_ storage: MemoryVaultStorage = MemoryVaultStorage()) -> CredentialVault {
        CredentialVault(storage: storage.storage)
    }

    @Test("A rejected vault write preserves the previous credential")
    func rejectedReplacementPreservesPreviousCredential() throws {
        let storage = MemoryVaultStorage()
        let vault = memoryVault(storage)
        try #require(KeychainHelper.writeKeychainSecret("previous-value", account: "a", vault: vault))

        storage.writeSucceeds = false
        #expect(!KeychainHelper.writeKeychainData(Data("replacement-value".utf8), account: "a", vault: vault))
        #expect(KeychainHelper.readKeychainSecret(account: "a", vault: vault) == "previous-value")
        #expect(storage.storedItems?["a"] == Data("previous-value".utf8))
    }

    @Test("Saving a secret writes only the Keychain, never a plain UserDefaults copy")
    func secretIsNeverMirroredAsPlaintext() {
        let vault = memoryVault()
        let account = "test.secret.\(UUID().uuidString)"
        let plaintextKey = KeychainHelper.secretFallbackKey(for: account)
        UserDefaults.standard.removeObject(forKey: plaintextKey)
        defer { UserDefaults.standard.removeObject(forKey: plaintextKey) }

        #expect(KeychainHelper.saveSecret("sk-test-value", account: account, vault: vault))
        #expect(UserDefaults.standard.string(forKey: plaintextKey) == nil)
        #expect(KeychainHelper.loadSecret(account: account, vault: vault) == "sk-test-value")

        #expect(KeychainHelper.saveSecret("replacement-value", account: account, vault: vault))
        #expect(KeychainHelper.readKeychainSecret(account: account, vault: vault) == "replacement-value")
        #expect(UserDefaults.standard.string(forKey: plaintextKey) == nil)

        // Saving an empty value deletes the entry instead of leaving an empty secret behind.
        #expect(KeychainHelper.saveSecret("", account: account, vault: vault), "an empty value deletes the item")
        #expect(KeychainHelper.loadSecret(account: account, vault: vault).isEmpty)
        #expect(vault.lookup(account) == .missing)
    }

    @Test("Migration moves a plaintext credential into the Keychain and deletes the plaintext key")
    func migrationMovesSecretAndDeletesPlaintext() throws {
        let suite = "test.keychain-migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = memoryVault()
        let plaintextKey = "test_plaintext"

        defaults.set("legacy-secret", forKey: plaintextKey)
        KeychainHelper.migratePlaintextSecret(defaults: defaults, plaintextKey: plaintextKey, account: "m", vault: vault)
        #expect(KeychainHelper.readKeychainSecret(account: "m", vault: vault) == "legacy-secret")
        #expect(defaults.string(forKey: plaintextKey) == nil)

        // Idempotent: a second launch has nothing left to migrate.
        KeychainHelper.migratePlaintextSecret(defaults: defaults, plaintextKey: plaintextKey, account: "m", vault: vault)
        #expect(defaults.string(forKey: plaintextKey) == nil)
        #expect(KeychainHelper.readKeychainSecret(account: "m", vault: vault) == "legacy-secret")

        // Whitespace-only leftovers are dropped without writing an empty secret.
        defaults.set("  \n", forKey: plaintextKey)
        KeychainHelper.migratePlaintextSecret(defaults: defaults, plaintextKey: plaintextKey, account: "blank", vault: vault)
        #expect(defaults.string(forKey: plaintextKey) == nil)
        #expect(vault.lookup("blank") == .missing)
    }

    @Test("Legacy plaintext cannot replace an existing Keychain credential")
    func migrationPreservesExistingCredential() throws {
        let suite = "test.keychain-existing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = memoryVault()

        try #require(KeychainHelper.writeKeychainSecret("current-secure-value", account: "e", vault: vault))
        defaults.set("stale-plaintext-value", forKey: "legacy-secret")
        KeychainHelper.migratePlaintextSecret(defaults: defaults, plaintextKey: "legacy-secret", account: "e", vault: vault)

        #expect(KeychainHelper.readKeychainSecret(account: "e", vault: vault) == "current-secure-value")
        #expect(defaults.object(forKey: "legacy-secret") == nil)
    }

    @Test("Migration cannot overwrite a credential saved concurrently")
    func migrationPreservesConcurrentLogin() {
        // Whichever runs first, the new login must survive: an insert after it is ignored, a save after the insert
        // replaces it.
        for _ in 0..<50 {
            let vault = memoryVault()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    _ = vault.insertIfMissing(Data("legacy-value".utf8), for: "c")
                } else {
                    _ = vault.set(Data("new-login".utf8), for: "c")
                }
            }
            #expect(vault.data(for: "c") == Data("new-login".utf8))
        }
    }

    @Test("A failed migration keeps the plaintext and cannot replace a protected credential")
    func migrationFailurePreservesCredential() throws {
        let suite = "test.keychain-denied.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // The vault accepts nothing: the plaintext stays for the next launch, the existing credential stays too.
        let refusing = MemoryVaultStorage()
        let vault = memoryVault(refusing)
        try #require(vault.set(Data("protected-value".utf8), for: "p"))
        refusing.writeSucceeds = false
        defaults.set("legacy-value", forKey: "legacy")
        KeychainHelper.migratePlaintextSecret(defaults: defaults, plaintextKey: "legacy", account: "q", vault: vault)
        #expect(defaults.string(forKey: "legacy") == "legacy-value")
        #expect(vault.data(for: "p") == Data("protected-value".utf8))

        // The vault cannot be read (a declined prompt): migration must not write over it.
        let unreadable = MemoryVaultStorage()
        unreadable.readResult = .unavailable
        KeychainHelper.migratePlaintextSecret(
            defaults: defaults, plaintextKey: "legacy", account: "q", vault: memoryVault(unreadable)
        )
        #expect(defaults.string(forKey: "legacy") == "legacy-value")
        #expect(unreadable.writes == 0)
    }

    @Test("Legacy session migration preserves an existing login or inserts a sanitized session")
    func sessionMigrationPreservesExistingLogin() throws {
        let suite = "test.session-existing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = memoryVault()
        let current = MiSession(userId: "current", cUserId: "c", ssecurity: "secure", serviceToken: "current-token")
        let currentData = try JSONEncoder().encode(current)
        let legacy = Data(#"{"userId":"old","cUserId":"c","ssecurity":"legacy","serviceToken":"old-token","passToken":"discard-me","region":"cn"}"#.utf8)
        try #require(KeychainHelper.writeKeychainData(currentData, account: "s", vault: vault))
        defaults.set(legacy, forKey: MiSessionStore.fallbackDefaultsKey)

        KeychainHelper.migratePlaintextSession(defaults: defaults, account: "s", vault: vault)
        #expect(KeychainHelper.readKeychainData(account: "s", vault: vault) == currentData)
        #expect(defaults.object(forKey: MiSessionStore.fallbackDefaultsKey) == nil)

        KeychainHelper.deleteKeychainItem(account: "s", vault: vault)
        defaults.set(legacy, forKey: MiSessionStore.fallbackDefaultsKey)
        KeychainHelper.migratePlaintextSession(defaults: defaults, account: "s", vault: vault)
        let migrated = try #require(KeychainHelper.readKeychainData(account: "s", vault: vault))
        let object = try #require(try JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(object["serviceToken"] as? String == "old-token")
        #expect(object["passToken"] == nil)
        #expect(defaults.object(forKey: MiSessionStore.fallbackDefaultsKey) == nil)
    }

    @Test("Startup migration reads exactly the plaintext keys that ≤1.0.6 wrote")
    func migrationCoversLegacyKeys() {
        #expect(KeychainHelper.legacyPlaintextTokenKey == "ha_fallback_token")
        #expect(MiSessionStore.fallbackDefaultsKey == "mi_session_fallback_v1")
        #expect(LGWebOSConfig.clientKeyDefaultsKey == "lg_webos_client_key")
        #expect(LGWebOSConfig.clientKeyAccount == "lg_webos_client_key")
        #expect(KeychainHelper.secretFallbackKey(for: "assistant_api_key_openrouter_jev")
            == "keychain_fallback_assistant_api_key_openrouter_jev")

        // The assistant sweep covers every provider slot plus the pre-v1.0.4 OpenRouter slot.
        #expect(KeychainHelper.assistantSecretAccounts.contains(KeychainHelper.assistantAPIKeyAccount))
        for preset in AssistantProviderPreset.allCases {
            #expect(KeychainHelper.assistantSecretAccounts.contains(KeychainHelper.assistantProviderAPIKeyAccount(for: preset)))
        }
    }

    @Test("A custom suite keeps the test store in UserDefaults and leaves the Keychain alone")
    func suiteSeamStaysOutOfTheKeychain() throws {
        let suite = "com.jryang1997.MenuBarMijia.keychain-seam.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let account = "test.suite"
        let untouched = MemoryVaultStorage()
        let vault = memoryVault(untouched)
        #expect(KeychainHelper.saveSecret("suite-value", account: account, defaults: defaults, vault: vault))
        #expect(defaults.string(forKey: KeychainHelper.secretFallbackKey(for: account)) == "suite-value")
        #expect(KeychainHelper.loadSecret(account: account, defaults: defaults, vault: vault) == "suite-value")
        #expect(untouched.reads == 0 && untouched.writes == 0, "a suite must never reach the vault")
        #expect(KeychainHelper.saveSecret("suite-ha-token", account: "ha_access_token", defaults: defaults))
        #expect(KeychainHelper.loadToken(defaults: defaults) == "suite-ha-token")

        #expect(KeychainHelper.saveSecret("", account: account, defaults: defaults))
        #expect(defaults.string(forKey: KeychainHelper.secretFallbackKey(for: account)) == nil)
    }

    @Test("Suite sessions round-trip through the test store and are stored without passToken")
    func suiteSessionRoundTrip() throws {
        let suite = "com.jryang1997.MenuBarMijia.session-seam.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let session = MiSession(userId: "987654321", cUserId: "cid", ssecurity: "ssec", serviceToken: "stoken")
        #expect(MiSessionStore.save(session, defaults: defaults))
        let data = try #require(defaults.data(forKey: MiSessionStore.fallbackDefaultsKey))
        let stored = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(stored["passToken"] == nil)
        #expect(MiSessionStore.load(defaults: defaults) == session)

        MiSessionStore.clear(defaults: defaults)
        #expect(MiSessionStore.load(defaults: defaults) == nil)
    }

    @Test("Loading a ≤1.0.6 session rewrites it without passToken, once (#27)")
    func legacySessionIsRewrittenOnLoad() throws {
        let suite = "com.jryang1997.MenuBarMijia.session-rewrite.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = Data(#"{"userId":"42","cUserId":"c","ssecurity":"c2VjcmV0","serviceToken":"tok","passToken":"pt","region":"cn"}"#.utf8)
        defaults.set(legacy, forKey: MiSessionStore.fallbackDefaultsKey)

        let loaded = try #require(MiSessionStore.load(defaults: defaults))
        #expect(loaded.serviceToken == "tok")
        let rewritten = try #require(defaults.data(forKey: MiSessionStore.fallbackDefaultsKey))
        #expect(rewritten != legacy)
        let object = try #require(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        #expect(object["passToken"] == nil)

        // A second read is stable: the stripped session is not rewritten again.
        #expect(MiSessionStore.load(defaults: defaults) == loaded)
        #expect(defaults.data(forKey: MiSessionStore.fallbackDefaultsKey) == rewritten)
    }

    @Test("A ≤1.0.6 session JSON still decodes, and re-encoding drops its passToken (#27)")
    func legacySessionJSONDropsPassToken() throws {
        let legacy = Data(#"{"userId":"42","cUserId":"c","ssecurity":"c2VjcmV0","serviceToken":"tok","passToken":"pt","region":"cn"}"#.utf8)
        let session = try #require(try? JSONDecoder().decode(MiSession.self, from: legacy))
        #expect(session.userId == "42")
        #expect(session.cUserId == "c")
        #expect(session.serviceToken == "tok")
        #expect(session.region == "cn")

        let migrated = try #require(MiSessionStore.migratedData(fromLegacyDefaults: legacy))
        let object = try #require(try JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(object["passToken"] == nil)
        #expect(object["serviceToken"] as? String == "tok")

        // Undecodable legacy data is reported instead of being written to the Keychain.
        #expect(MiSessionStore.migratedData(fromLegacyDefaults: Data("not-json".utf8)) == nil)
    }

    @Test("A session created by a new login never encodes a passToken")
    func newSessionHasNoPassToken() throws {
        let session = MiSession(userId: "42", cUserId: "c", ssecurity: "c2VjcmV0", serviceToken: "tok")
        let data = try JSONEncoder().encode(session)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["passToken"] == nil)
        let decoded = try JSONDecoder().decode(MiSession.self, from: data)
        #expect(decoded == session)
    }
}
