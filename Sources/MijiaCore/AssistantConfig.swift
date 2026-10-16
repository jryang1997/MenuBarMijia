import Foundation
import Security

// MARK: - Assistant (LLM Fallback) Configuration

public struct AssistantConfig: Equatable, Sendable {
    public static let defaultBaseURL = "http://localhost:3425/v1"
    public static let defaultModel = "antigravity/gemini-3.5-flash-lite"

    static let baseURLKey = "assistant_base_url"
    static let modelKey = "assistant_model"

    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(baseURL: String = defaultBaseURL, model: String = defaultModel, apiKey: String = "") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public static func load(from defaults: UserDefaults) -> AssistantConfig {
        let nonEmpty = { (key: String) -> String? in
            guard let v = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { return nil }
            return v
        }
        return AssistantConfig(
            baseURL: nonEmpty(baseURLKey) ?? defaultBaseURL,
            model: nonEmpty(modelKey) ?? defaultModel,
            apiKey: KeychainHelper.loadSecret(account: KeychainHelper.assistantAPIKeyAccount)
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.baseURLKey)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelKey)
        KeychainHelper.saveSecret(apiKey, account: KeychainHelper.assistantAPIKeyAccount)
    }
}

// MARK: - Generic Keychain Secrets

extension KeychainHelper {
    public static let assistantAPIKeyAccount = "assistant_api_key"

    public static func loadSecret(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saving an empty value deletes the item.
    public static func saveSecret(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
