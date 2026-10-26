import Foundation
import Security

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case primaryTemp = "primaryTemp"
    case balconyTemp = "balconyTemp"
    case activeCount = "activeCount"
    case iconOnly = "iconOnly"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .primaryTemp: return L10n.tr("主卧温度 (如 26.6°)", "Bedroom Temp (e.g. 26.6°)")
        case .balconyTemp: return L10n.tr("阳台温度 (如 28.1°)", "Balcony Temp (e.g. 28.1°)")
        case .activeCount: return L10n.tr("开启设备数", "Active Devices")
        case .iconOnly: return L10n.tr("仅显示图标", "Icon Only")
        }
    }
}

public enum KeychainHelper {
    public static let service = "com.jryang1997.MenuBarMijia"
    private static let account = "ha_access_token"

    public static let defaultHomeName = "我的家"
    public static var localizedDefaultHomeName: String {
        L10n.tr("我的家", "My Home")
    }
    public static let defaultNASURL = "http://homeassistant.local:8123"
    public static let defaultSeededToken = ""

    public static func loadToken() -> String {
        if let envToken = ProcessInfo.processInfo.environment["HA_ACCESS_TOKEN"],
           !envToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let ud = UserDefaults.standard.string(forKey: "ha_fallback_token"),
           !ud.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ud.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let keychainToken = loadTokenFromKeychain() {
            UserDefaults.standard.set(keychainToken, forKey: "ha_fallback_token")
            return keychainToken
        }
        return defaultSeededToken
    }

    private static func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let str = String(data: data, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    public static func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "ha_fallback_token")
        guard let data = trimmed.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Snapshots readable Keychain credentials into `UserDefaults` fallback keys while the running
    /// binary's CDHash matches the Keychain item ACL, preventing loss across ad-hoc signed updates.
    public static func synchronizeFallbackCredentialsBeforeUpdate(defaults: UserDefaults = .standard) {
        if defaults === UserDefaults.standard {
            let existingFallback = defaults.string(forKey: "ha_fallback_token")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingFallback.isEmpty, let keychainToken = loadTokenFromKeychain() {
                defaults.set(keychainToken, forKey: "ha_fallback_token")
            }
        }
        if let session = MiSessionStore.load(defaults: defaults),
           let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: MiSessionStore.fallbackDefaultsKey)
        }
        let accounts = AssistantProviderPreset.allCases.map { assistantProviderAPIKeyAccount(for: $0) }
            + [assistantAPIKeyAccount]
        for accountName in accounts {
            let secret = loadSecret(account: accountName, defaults: defaults)
            if !secret.isEmpty {
                defaults.set(secret, forKey: secretFallbackKey(for: accountName))
            }
        }
    }
}
