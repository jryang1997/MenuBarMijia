import Foundation
import Security

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Shows the sensor picked through `HomeStore.menuBarTargetId` (first temperature sensor when unset).
    case sensorTemperature = "sensorTemperature"
    case activeCount = "activeCount"
    case iconOnly = "iconOnly"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sensorTemperature: return L10n.tr("传感器温度 (如 26.6°)", "Sensor Temp (e.g. 26.6°)")
        case .activeCount: return L10n.tr("开启设备数", "Active Devices")
        case .iconOnly: return L10n.tr("仅显示图标", "Icon Only")
        }
    }

    /// Raw values written by ≤1.0.x that hardcoded the author's 主卧/阳台 rooms. Read once on launch
    /// and migrated to `.sensorTemperature` plus the first available temperature sensor (#36).
    public static let legacyTemperatureRawValues: Set<String> = ["primaryTemp", "balconyTemp"]
}

public enum KeychainHelper {
    public static let service = "com.jryang1997.MenuBarMijia"
    private static let account = "ha_access_token"
    /// `UserDefaults` key where ≤1.0.6 mirrored the HA token in plain text. Only read by
    /// `migratePlaintextCredentialsToKeychain`; nothing writes it any more (#16).
    static let legacyPlaintextTokenKey = "ha_fallback_token"

    public static let defaultHomeName = "我的家"
    public static var localizedDefaultHomeName: String {
        L10n.tr("我的家", "My Home")
    }
    public static let defaultNASURL = "http://homeassistant.local:8123"
    public static let defaultSeededToken = ""

    public static func loadToken(defaults: UserDefaults = .standard) -> String {
        guard defaults === UserDefaults.standard else {
            return loadSecret(account: account, defaults: defaults)
        }
        if let envToken = ProcessInfo.processInfo.environment["HA_ACCESS_TOKEN"],
           !envToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Credentials live only in the Keychain (#16). An unreadable item reads as "not signed in" instead of
        // looping on the Keychain authorization prompt.
        return readKeychainSecret(account: account) ?? defaultSeededToken
    }

    public static func saveToken(_ token: String) {
        guard writeKeychainSecret(token, account: account) else { return }
        UserDefaults.standard.removeObject(forKey: legacyPlaintextTokenKey)
    }

    // MARK: - Keychain Primitives

    static func readKeychainSecret(account: String) -> String? {
        guard let data = readKeychainData(account: account),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func readKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Saving an empty value deletes the item.
    @discardableResult
    static func writeKeychainSecret(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return writeKeychainData(trimmed.isEmpty ? nil : trimmed.data(using: .utf8), account: account)
    }

    /// Passing `nil` deletes the item.
    @discardableResult
    static func writeKeychainData(
        _ data: Data?, account: String, accessibility: String? = nil,
        updateItem: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
        addItem: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let accessibility {
            attributes[kSecAttrAccessible as String] = accessibility
        }
        let status = updateItem(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let addQuery = query.merging(attributes) { _, newValue in newValue }
        return addItem(addQuery as CFDictionary) == errSecSuccess
    }

    static func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Plaintext Migration (#16, #27)

    /// Moves every credential that ≤1.0.6 mirrored into plain `UserDefaults` into the Keychain, then deletes the
    /// plaintext copies. Idempotent: with no plaintext key left it does nothing. Call once at launch, before
    /// anything reads a credential.
    public static func migratePlaintextCredentialsToKeychain(defaults: UserDefaults = .standard) {
        // Only the app's own domain ever held these keys; a test suite must never write production accounts.
        guard defaults === UserDefaults.standard else { return }
        migratePlaintextSecret(defaults: defaults, plaintextKey: legacyPlaintextTokenKey, account: account)
        for accountName in assistantSecretAccounts {
            migratePlaintextSecret(defaults: defaults, plaintextKey: secretFallbackKey(for: accountName), account: accountName)
        }
        migratePlaintextSecret(
            defaults: defaults,
            plaintextKey: LGWebOSConfig.clientKeyDefaultsKey,
            account: LGWebOSConfig.clientKeyAccount
        )
        migratePlaintextSession(defaults: defaults)
    }

    /// Legacy plaintext must never replace a credential already protected by Keychain. Keep the plaintext
    /// for retry when neither insertion nor reading an existing item succeeds.
    static func migratePlaintextSecret(defaults: UserDefaults, plaintextKey: String, account: String) {
        guard let raw = defaults.string(forKey: plaintextKey) else { return }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || insertMigratedKeychainData(Data(value.utf8), account: account) else { return }
        defaults.removeObject(forKey: plaintextKey)
    }

    /// Add atomically: a read-then-update could overwrite a login saved between those operations.
    @discardableResult
    static func insertMigratedKeychainData(
        _ data: Data, account: String, accessibility: String? = nil,
        addItem: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    ) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        if let accessibility {
            query[kSecAttrAccessible as String] = accessibility
        }
        let status = addItem(query as CFDictionary)
        if status == errSecSuccess { return true }
        return status == errSecDuplicateItem && readKeychainData(account: account) != nil
    }

    static func migratePlaintextSession(defaults: UserDefaults, account: String = MiSessionStore.keychainAccount) {
        guard let legacy = defaults.data(forKey: MiSessionStore.fallbackDefaultsKey) else { return }
        // Re-encoding through `MiSession` drops the `passToken` that ≤1.0.6 also persisted (#27, ADR-0004).
        if let data = MiSessionStore.migratedData(fromLegacyDefaults: legacy) {
            let written = insertMigratedKeychainData(
                data,
                account: account,
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
            guard written else { return }
        }
        defaults.removeObject(forKey: MiSessionStore.fallbackDefaultsKey)
    }
}
