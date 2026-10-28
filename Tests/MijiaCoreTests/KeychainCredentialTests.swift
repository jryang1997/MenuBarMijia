import Foundation
import Testing
@testable import MijiaCore

/// 审计 #16 / #27：凭证只存钥匙串，不再明文镜像到 `UserDefaults`；旧明文键在启动时迁入钥匙串并删除；
/// 米家会话不再持久化 `passToken`（见 `docs/adr/0004-no-pass-token-storage.md`）。
struct KeychainCredentialTests {
    /// Keychain writes in tests use a scratch account so a developer's real credentials are never touched.
    private func scratchAccount(_ label: String) -> String { "test.\(label).\(UUID().uuidString)" }

    @Test("Saving a secret writes only the Keychain, never a plain UserDefaults copy")
    func secretIsNeverMirroredAsPlaintext() {
        let account = scratchAccount("secret")
        let plaintextKey = KeychainHelper.secretFallbackKey(for: account)
        UserDefaults.standard.removeObject(forKey: plaintextKey)
        defer {
            KeychainHelper.saveSecret("", account: account)
            UserDefaults.standard.removeObject(forKey: plaintextKey)
        }

        #expect(KeychainHelper.saveSecret("sk-test-value", account: account), "the Keychain must accept a scratch item")
        #expect(UserDefaults.standard.string(forKey: plaintextKey) == nil)
        #expect(KeychainHelper.readKeychainSecret(account: account) == "sk-test-value")
        #expect(KeychainHelper.loadSecret(account: account) == "sk-test-value")

        // Saving an empty value deletes the item instead of leaving an empty secret behind.
        #expect(KeychainHelper.saveSecret("", account: account), "an empty value deletes the item")
        #expect(KeychainHelper.loadSecret(account: account).isEmpty)
        #expect(UserDefaults.standard.string(forKey: plaintextKey) == nil)
    }

    @Test("Migration moves a plaintext credential into the Keychain and deletes the plaintext key")
    func migrationMovesSecretAndDeletesPlaintext() throws {
        let suite = "test.keychain-migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let account = scratchAccount("migrate")
        let plaintextKey = "test_plaintext_\(UUID().uuidString)"
        defer {
            KeychainHelper.saveSecret("", account: account)
            defaults.removePersistentDomain(forName: suite)
        }

        defaults.set("legacy-secret", forKey: plaintextKey)
        KeychainHelper.migratePlaintextSecret(defaults: defaults, plaintextKey: plaintextKey, account: account)
        #expect(KeychainHelper.readKeychainSecret(account: account) == "legacy-secret", "the plaintext value must land in the Keychain")
        #expect(defaults.string(forKey: plaintextKey) == nil)

        // Idempotent: a second launch has nothing left to migrate.
        KeychainHelper.migratePlaintextSecret(defaults: defaults, plaintextKey: plaintextKey, account: account)
        #expect(defaults.string(forKey: plaintextKey) == nil)
        #expect(KeychainHelper.readKeychainSecret(account: account) == "legacy-secret")

        // Whitespace-only leftovers are dropped without writing an empty secret.
        let blankAccount = scratchAccount("blank")
        defer { KeychainHelper.saveSecret("", account: blankAccount) }
        defaults.set("  \n", forKey: plaintextKey)
        KeychainHelper.migratePlaintextSecret(defaults: defaults, plaintextKey: plaintextKey, account: blankAccount)
        #expect(defaults.string(forKey: plaintextKey) == nil)
        #expect(KeychainHelper.loadSecret(account: blankAccount).isEmpty)
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

        let account = scratchAccount("suite")
        #expect(KeychainHelper.saveSecret("suite-value", account: account, defaults: defaults))
        #expect(defaults.string(forKey: KeychainHelper.secretFallbackKey(for: account)) == "suite-value")
        #expect(KeychainHelper.readKeychainSecret(account: account) == nil)
        #expect(KeychainHelper.loadSecret(account: account, defaults: defaults) == "suite-value")
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
