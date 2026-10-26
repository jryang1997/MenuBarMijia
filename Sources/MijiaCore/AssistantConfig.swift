import Foundation
import Security

// MARK: - AI Provider Presets

public enum AssistantProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case openRouterJev = "openrouter_jev"
    case nativeJev = "native_jev"
    case deepSeek = "deepseek"
    case siliconFlow = "siliconflow"
    case dashScope = "dashscope"
    case zhipuGLM = "zhipu_glm"
    case moonshotKimi = "moonshot_kimi"
    case openAI = "openai"
    case gemini = "gemini"
    case groq = "groq"
    case ollama = "ollama"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openRouterJev:
            return L10n.tr("OpenRouter · Jev (默认)", "OpenRouter · Jev (Default)")
        case .nativeJev:
            return L10n.tr("TypeSafe · 原生 Jev", "TypeSafe · Native Jev")
        case .deepSeek:
            return L10n.tr("DeepSeek 官方", "DeepSeek Official")
        case .siliconFlow:
            return L10n.tr("硅基流动 SiliconFlow", "SiliconFlow")
        case .dashScope:
            return L10n.tr("通义千问 / 阿里云百炼", "Qwen / Alibaba DashScope")
        case .zhipuGLM:
            return L10n.tr("智谱 GLM (BigModel)", "Zhipu GLM (BigModel)")
        case .moonshotKimi:
            return L10n.tr("Moonshot Kimi (月之暗面)", "Moonshot Kimi")
        case .openAI:
            return "OpenAI"
        case .gemini:
            return "Google Gemini"
        case .groq:
            return "Groq"
        case .ollama:
            return L10n.tr("Ollama 本地模型", "Ollama (Local)")
        case .custom:
            return L10n.tr("自定义兼容接口", "Custom Compatible Endpoint")
        }
    }

    public var shortTitle: String {
        switch self {
        case .openRouterJev: return "OpenRouter"
        case .nativeJev: return L10n.tr("原生 Jev", "Native Jev")
        case .deepSeek: return "DeepSeek"
        case .siliconFlow: return L10n.tr("硅基流动", "SiliconFlow")
        case .dashScope: return L10n.tr("通义千问", "Qwen")
        case .zhipuGLM: return L10n.tr("智谱 GLM", "Zhipu GLM")
        case .moonshotKimi: return "Kimi"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        case .ollama: return "Ollama"
        case .custom: return L10n.tr("自定义", "Custom")
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openRouterJev: return "https://openrouter.ai/api/v1"
        case .nativeJev: return "https://api.typesafe.ai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .siliconFlow: return "https://api.siliconflow.cn/v1"
        case .dashScope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .zhipuGLM: return "https://open.bigmodel.cn/api/paas/v4"
        case .moonshotKimi: return "https://api.moonshot.cn/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: return "https://api.groq.com/openai/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .openRouterJev: return "~typesafe/jev-latest"
        case .nativeJev: return "jev-latest"
        case .deepSeek: return "deepseek-chat"
        case .siliconFlow: return "deepseek-ai/DeepSeek-V3"
        case .dashScope: return "qwen-plus"
        case .zhipuGLM: return "glm-4-flash"
        case .moonshotKimi: return "kimi-k2-0711-preview"
        case .openAI: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        case .groq: return "llama-3.3-70b-versatile"
        case .ollama: return "qwen2.5:7b"
        case .custom: return ""
        }
    }

    public var recommendedModels: [String] {
        switch self {
        case .openRouterJev:
            return ["~typesafe/jev-latest", "deepseek/deepseek-chat", "google/gemini-2.5-flash"]
        case .nativeJev:
            return ["jev-latest", "jev-router-latest"]
        case .deepSeek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .siliconFlow:
            return ["deepseek-ai/DeepSeek-V3", "Qwen/Qwen2.5-72B-Instruct"]
        case .dashScope:
            return ["qwen-plus", "qwen-turbo", "qwen-max"]
        case .zhipuGLM:
            return ["glm-4-flash", "glm-4-plus"]
        case .moonshotKimi:
            return ["kimi-k2-0711-preview", "moonshot-v1-8k"]
        case .openAI:
            return ["gpt-4o-mini", "gpt-4.1-mini"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .groq:
            return ["llama-3.3-70b-versatile", "deepseek-r1-distill-llama-70b"]
        case .ollama:
            return ["qwen2.5:7b", "deepseek-r1:8b"]
        case .custom:
            return []
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .openRouterJev:
            return L10n.tr("留空自动读取 CodexBar，或手动输入 sk-or-...", "Auto-read CodexBar or enter sk-or-...")
        case .nativeJev:
            return L10n.tr("粘贴 TypeSafe 原生 Jev API Key", "Paste TypeSafe Native Jev API Key")
        case .deepSeek:
            return L10n.tr("粘贴 DeepSeek API Key (sk-...)", "Paste DeepSeek API Key (sk-...)")
        case .siliconFlow:
            return L10n.tr("粘贴硅基流动 API Key (sk-...)", "Paste SiliconFlow API Key (sk-...)")
        case .dashScope:
            return L10n.tr("粘贴阿里云百炼 API Key (sk-...)", "Paste DashScope API Key (sk-...)")
        case .zhipuGLM:
            return L10n.tr("粘贴智谱开放平台 API Key", "Paste Zhipu BigModel API Key")
        case .moonshotKimi:
            return L10n.tr("粘贴 Moonshot Kimi API Key (sk-...)", "Paste Moonshot Kimi API Key (sk-...)")
        case .openAI:
            return L10n.tr("粘贴 OpenAI API Key (sk-...)", "Paste OpenAI API Key (sk-...)")
        case .gemini:
            return L10n.tr("粘贴 Google Gemini API Key (AIza...)", "Paste Gemini API Key (AIza...)")
        case .groq:
            return L10n.tr("粘贴 Groq API Key (gsk_...)", "Paste Groq API Key (gsk_...)")
        case .ollama:
            return L10n.tr("Ollama 本地接口免密（可留空）", "Ollama local endpoint requires no key")
        case .custom:
            return L10n.tr("粘贴 API Key (本机接口可留空)", "Paste API Key (optional for localhost)")
        }
    }

    public var envVarNames: [String] {
        switch self {
        case .openRouterJev: return ["OPENROUTER_API_KEY"]
        case .nativeJev: return ["TYPESAFE_API_KEY", "JEV_API_KEY"]
        case .deepSeek: return ["DEEPSEEK_API_KEY"]
        case .siliconFlow: return ["SILICONFLOW_API_KEY"]
        case .dashScope: return ["DASHSCOPE_API_KEY"]
        case .zhipuGLM: return ["ZHIPU_API_KEY", "GLM_API_KEY"]
        case .moonshotKimi: return ["MOONSHOT_API_KEY", "KIMI_API_KEY"]
        case .openAI: return ["OPENAI_API_KEY"]
        case .gemini: return ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .groq: return ["GROQ_API_KEY"]
        case .ollama: return []
        case .custom: return ["OPENAI_API_KEY"]
        }
    }

    public var codexBarProviderIds: [String] {
        switch self {
        case .openRouterJev: return ["openrouter"]
        case .nativeJev: return ["typesafe", "jev"]
        case .deepSeek: return ["deepseek"]
        case .siliconFlow: return ["siliconflow"]
        case .dashScope: return ["dashscope", "qwen", "bailian"]
        case .zhipuGLM: return ["zhipu", "glm", "bigmodel"]
        case .moonshotKimi: return ["moonshot", "kimi"]
        case .openAI: return ["openai", "codex"]
        case .gemini: return ["gemini", "google"]
        case .groq: return ["groq"]
        case .ollama: return ["ollama"]
        case .custom: return []
        }
    }

    public static func infer(baseURL: String) -> AssistantProviderPreset {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsed = URL(string: trimmed)
        let host = parsed?.host?.lowercased() ?? trimmed
        if host.contains("openrouter.ai") { return .openRouterJev }
        if host.contains("typesafe.ai") { return .nativeJev }
        if host.contains("deepseek.com") { return .deepSeek }
        if host.contains("siliconflow.cn") { return .siliconFlow }
        if host.contains("aliyuncs.com") { return .dashScope }
        if host.contains("bigmodel.cn") { return .zhipuGLM }
        if host.contains("moonshot.cn") || host.contains("moonshot.ai") { return .moonshotKimi }
        if host.contains("openai.com") { return .openAI }
        if host.contains("googleapis.com") { return .gemini }
        if host.contains("groq.com") { return .groq }
        if parsed?.port == 11434 || trimmed.contains(":11434") { return .ollama }
        return .custom
    }
}

// MARK: - Assistant (LLM Fallback) Configuration

public struct AssistantConfig: Equatable, Sendable {
    public static let defaultBaseURL = "https://openrouter.ai/api/v1"
    public static let defaultModel = "~typesafe/jev-latest"
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

    public var preset: AssistantProviderPreset {
        AssistantProviderPreset.infer(baseURL: baseURL)
    }

    public var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isLoopbackEndpoint: Bool {
        guard let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".local")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
    }

    public static func load(from defaults: UserDefaults, includeAmbientKey: Bool = true) -> AssistantConfig {
        let nonEmpty = { (key: String) -> String? in
            guard let v = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { return nil }
            return v
        }

        let savedBase = nonEmpty(baseURLKey)
        let savedModel = nonEmpty(modelKey)

        let resolvedBase = savedBase ?? defaultBaseURL

        let resolvedModel: String
        if let savedModel, !legacyDefaultModels.contains(savedModel) {
            resolvedModel = savedModel
        } else {
            let inferredPreset = AssistantProviderPreset.infer(baseURL: resolvedBase)
            resolvedModel = inferredPreset.defaultModel.isEmpty ? "gpt-4o-mini" : inferredPreset.defaultModel
        }

        let explicitKey = userStoredAPIKey(forBaseURL: resolvedBase, defaults: defaults)
        let effectiveKey: String
        if !explicitKey.isEmpty {
            effectiveKey = explicitKey
        } else if includeAmbientKey {
            effectiveKey = loadAmbientAPIKey(forBaseURL: resolvedBase) ?? ""
        } else {
            effectiveKey = ""
        }

        return AssistantConfig(
            baseURL: resolvedBase,
            model: resolvedModel,
            apiKey: effectiveKey
        )
    }

    public func save(to defaults: UserDefaults) {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmedBase, forKey: Self.baseURLKey)
        defaults.set(trimmedModel, forKey: Self.modelKey)
        let inferred = AssistantProviderPreset.infer(baseURL: trimmedBase)
        let providerAccount = KeychainHelper.assistantProviderAPIKeyAccount(for: inferred)
        KeychainHelper.saveSecret(trimmedKey, account: providerAccount, defaults: defaults)
        if inferred == .openRouterJev {
            KeychainHelper.saveSecret(trimmedKey, account: KeychainHelper.assistantAPIKeyAccount, defaults: defaults)
        }
    }

    /// Returns only the user's explicitly saved Keychain API key for the given endpoint (excluding ambient CodexBar/env keys).
    public static func userStoredAPIKey(forBaseURL baseURL: String, defaults: UserDefaults = .standard) -> String {
        let preset = AssistantProviderPreset.infer(baseURL: baseURL)
        let providerAccount = KeychainHelper.assistantProviderAPIKeyAccount(for: preset)
        let providerKey = KeychainHelper.loadSecret(account: providerAccount, defaults: defaults)
        if !providerKey.isEmpty {
            return providerKey
        }
        // Pre-v1.0.4 versions stored the OpenRouter key in the generic `assistant_api_key` slot.
        if preset == .openRouterJev {
            return KeychainHelper.loadSecret(account: KeychainHelper.assistantAPIKeyAccount, defaults: defaults)
        }
        return ""
    }

    /// Reads an ambient API key from environment variables or `~/.config/codexbar/config.json` matching the provider for `baseURL`.
    public static func loadAmbientAPIKey(forBaseURL baseURL: String, configURL: URL? = nil) -> String? {
        let preset = AssistantProviderPreset.infer(baseURL: baseURL)
        if configURL == nil {
            for envName in preset.envVarNames {
                if let envKey = ProcessInfo.processInfo.environment[envName]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !envKey.isEmpty {
                    return envKey
                }
            }
        }
        guard !preset.codexBarProviderIds.isEmpty else { return nil }
        return readCodexBarProviderKey(providerIds: preset.codexBarProviderIds, configURL: configURL)
    }

    /// Human-readable label when an ambient key is available for `baseURL` (e.g., `"CodexBar"` or `"OPENROUTER_API_KEY"`).
    public static func ambientKeySourceLabel(forBaseURL baseURL: String, configURL: URL? = nil) -> String? {
        let preset = AssistantProviderPreset.infer(baseURL: baseURL)
        if configURL == nil {
            for envName in preset.envVarNames {
                if let envKey = ProcessInfo.processInfo.environment[envName]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !envKey.isEmpty {
                    return envName
                }
            }
        }
        if !preset.codexBarProviderIds.isEmpty,
           readCodexBarProviderKey(providerIds: preset.codexBarProviderIds, configURL: configURL) != nil {
            return "CodexBar"
        }
        return nil
    }

    /// Reads the OpenRouter API key from `OPENROUTER_API_KEY` or CodexBar's `~/.config/codexbar/config.json`.
    public static func loadCodexBarOpenRouterKey(configURL: URL? = nil) -> String? {
        loadAmbientAPIKey(forBaseURL: defaultBaseURL, configURL: configURL)
    }

    private static func readCodexBarProviderKey(providerIds: [String], configURL: URL?) -> String? {
        let wanted = Set(providerIds.map { $0.lowercased() })
        let url = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codexbar/config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]] else {
            return nil
        }
        for provider in providers {
            guard let id = (provider["id"] as? String)?.lowercased(),
                  wanted.contains(id),
                  let key = (provider["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                continue
            }
            return key
        }
        return nil
    }
}

// MARK: - Generic Keychain Secrets

extension KeychainHelper {
    public static let assistantAPIKeyAccount = "assistant_api_key"

    public static func assistantProviderAPIKeyAccount(for preset: AssistantProviderPreset) -> String {
        "assistant_api_key_\(preset.rawValue)"
    }

    public static func secretFallbackKey(for account: String) -> String {
        "keychain_fallback_\(account)"
    }

    public static func loadSecret(account: String, defaults: UserDefaults = .standard) -> String {
        let fallbackKey = secretFallbackKey(for: account)
        if let fallback = defaults.string(forKey: fallbackKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return fallback
        }
        guard defaults === UserDefaults.standard else {
            return ""
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let str = String(data: data, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                defaults.set(trimmed, forKey: fallbackKey)
                return trimmed
            }
        }
        return ""
    }

    /// Saving an empty value deletes the item.
    public static func saveSecret(_ value: String, account: String, defaults: UserDefaults = .standard) {
        let fallbackKey = secretFallbackKey(for: account)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: fallbackKey)
        } else {
            defaults.set(trimmed, forKey: fallbackKey)
        }
        guard defaults === UserDefaults.standard else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
