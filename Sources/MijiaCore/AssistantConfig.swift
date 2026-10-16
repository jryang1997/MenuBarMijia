import Foundation
import Security

// MARK: - Assistant (LLM Fallback) Configuration

public struct AssistantConfig: Equatable, Sendable {
    public static let defaultBaseURL = "https://openrouter.ai/api/v1"
    public static let defaultModel = "~typesafe/jev-latest"
    public static let localRouterBaseURL = "http://localhost:3425/v1"
    private static let legacyDefaultModels: Set<String> = [
        "antigravity/gemini-3.5-flash-lite",
        "glm-5.1"
    ]

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
        let keychainKey = KeychainHelper.loadSecret(account: KeychainHelper.assistantAPIKeyAccount)
        let codexBarKey = loadCodexBarOpenRouterKey() ?? ""
        let effectiveKey = keychainKey.isEmpty ? codexBarKey : keychainKey

        let savedBase = nonEmpty(baseURLKey)
        let savedModel = nonEmpty(modelKey)

        // Upgrade legacy local defaults to OpenRouter Jev when a CodexBar OpenRouter key is present.
        if !effectiveKey.isEmpty,
           (savedModel == nil || legacyDefaultModels.contains(savedModel!)),
           (savedBase == nil || savedBase == localRouterBaseURL) {
            return AssistantConfig(
                baseURL: defaultBaseURL,
                model: defaultModel,
                apiKey: effectiveKey
            )
        }

        return AssistantConfig(
            baseURL: savedBase ?? (effectiveKey.isEmpty ? localRouterBaseURL : defaultBaseURL),
            model: savedModel ?? (effectiveKey.isEmpty ? "glm-5.1" : defaultModel),
            apiKey: effectiveKey
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.baseURLKey)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelKey)
        KeychainHelper.saveSecret(apiKey, account: KeychainHelper.assistantAPIKeyAccount)
    }

    private static let cachedDefaultCodexBarKey: String? = readCodexBarOpenRouterKey(configURL: nil)

    /// Reads the OpenRouter API key from `OPENROUTER_API_KEY` or CodexBar's `~/.config/codexbar/config.json`.
    public static func loadCodexBarOpenRouterKey(configURL: URL? = nil) -> String? {
        if configURL == nil {
            return cachedDefaultCodexBarKey
        }
        return readCodexBarOpenRouterKey(configURL: configURL)
    }

    private static func readCodexBarOpenRouterKey(configURL: URL?) -> String? {
        if configURL == nil,
           let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envKey.isEmpty {
            return envKey
        }
        let url = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codexbar/config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]] else {
            return nil
        }
        for provider in providers where (provider["id"] as? String) == "openrouter" {
            if let key = (provider["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
        }
        return nil
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
