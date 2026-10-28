import Foundation

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
            return L10n.tr("点「导入」读取 CodexBar/环境变量，或手动输入 sk-or-...", "Tap Import to read CodexBar/env, or enter sk-or-...")
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
        // A custom endpoint can be any server, so it never receives keys meant for a known provider.
        case .custom: return []
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

    /// Whether "从 CodexBar / 环境变量导入" applies: custom endpoints and keyless Ollama have nothing to import.
    public var supportsKeyImport: Bool {
        !envVarNames.isEmpty || !codexBarProviderIds.isEmpty
    }

    /// Maps an endpoint to the provider whose saved key it may use. Unknown or look-alike hosts are `.custom` (#19).
    public static func infer(baseURL: String) -> AssistantProviderPreset {
        guard let endpoint = AssistantEndpoint(baseURL) else { return .custom }
        let host = endpoint.host
        if endpoint.hostMatches(domain: "openrouter.ai") { return .openRouterJev }
        if endpoint.hostMatches(domain: "typesafe.ai") { return .nativeJev }
        if endpoint.hostMatches(domain: "deepseek.com") { return .deepSeek }
        if endpoint.hostMatches(domain: "siliconflow.cn") { return .siliconFlow }
        // aliyuncs.com and googleapis.com also serve customer-owned buckets, so only the API hosts count.
        if host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com" { return .dashScope }
        if endpoint.hostMatches(domain: "bigmodel.cn") { return .zhipuGLM }
        if endpoint.hostMatches(domain: "moonshot.cn") || endpoint.hostMatches(domain: "moonshot.ai") { return .moonshotKimi }
        if endpoint.hostMatches(domain: "openai.com") { return .openAI }
        if host == "generativelanguage.googleapis.com" { return .gemini }
        if endpoint.hostMatches(domain: "groq.com") { return .groq }
        if endpoint.port == 11434 && endpoint.isLocalNetwork { return .ollama }
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
    /// Every custom URL shares one Keychain slot, so this records which server (host:port) the saved custom key belongs to.
    static let customKeyEndpointKey = "assistant_custom_key_endpoint"

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

    /// The endpoint is on this computer or the local network, so it may run without an API key.
    public var isLoopbackEndpoint: Bool {
        AssistantEndpoint(baseURL)?.isLocalNetwork ?? false
    }

    /// False for plain http to a public host: the key and the user's words would cross the internet unencrypted.
    public var allowsSendingAPIKey: Bool {
        AssistantEndpoint(baseURL)?.allowsSendingSecrets ?? false
    }

    /// Ambient keys (CodexBar / environment variables) are never used implicitly; the user imports them explicitly (#20).
    public static func load(from defaults: UserDefaults, includeAmbientKey: Bool = false) -> AssistantConfig {
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
        let inferred = AssistantProviderPreset.infer(baseURL: trimmedBase)
        // A key typed by hand replaces an imported one, so the "imported from" label no longer applies.
        if Self.userStoredAPIKey(forBaseURL: trimmedBase, defaults: defaults) != trimmedKey {
            defaults.removeObject(forKey: Self.importedKeySourceKey(for: inferred))
        }
        defaults.set(trimmedBase, forKey: Self.baseURLKey)
        defaults.set(trimmedModel, forKey: Self.modelKey)
        Self.saveSecret(trimmedKey, for: inferred, defaults: defaults)
        if inferred == .custom {
            if trimmedKey.isEmpty {
                defaults.removeObject(forKey: Self.customKeyEndpointKey)
            } else {
                defaults.set(AssistantEndpoint(trimmedBase)?.identity, forKey: Self.customKeyEndpointKey)
            }
        }
    }

    /// Writes (or, with an empty key, deletes) the saved key for `preset`. The bundled OpenRouter/Jev preset also
    /// keeps the legacy `assistant_api_key` slot in sync because pre-v1.0.4 builds read the key from there.
    private static func saveSecret(_ key: String, for preset: AssistantProviderPreset, defaults: UserDefaults) {
        KeychainHelper.saveSecret(
            key,
            account: KeychainHelper.assistantProviderAPIKeyAccount(for: preset),
            defaults: defaults
        )
        if preset == .openRouterJev {
            KeychainHelper.saveSecret(key, account: KeychainHelper.assistantAPIKeyAccount, defaults: defaults)
        }
    }

    private static func clearSecret(for preset: AssistantProviderPreset, defaults: UserDefaults) {
        saveSecret("", for: preset, defaults: defaults)
    }

    /// Returns only the user's explicitly saved Keychain API key for the given endpoint (excluding ambient CodexBar/env keys).
    public static func userStoredAPIKey(forBaseURL baseURL: String, defaults: UserDefaults = .standard) -> String {
        let preset = AssistantProviderPreset.infer(baseURL: baseURL)
        let providerAccount = KeychainHelper.assistantProviderAPIKeyAccount(for: preset)
        let providerKey = KeychainHelper.loadSecret(account: providerAccount, defaults: defaults)
        if !providerKey.isEmpty {
            if preset == .custom {
                return customKeyBelongs(to: baseURL, defaults: defaults) ? providerKey : ""
            }
            return providerKey
        }
        // Pre-v1.0.4 versions stored the OpenRouter key in the generic `assistant_api_key` slot.
        if preset == .openRouterJev {
            return KeychainHelper.loadSecret(account: KeychainHelper.assistantAPIKeyAccount, defaults: defaults)
        }
        return ""
    }

    /// A custom key is only sent to the server it was saved for. Keys saved before this check existed
    /// belong to the custom URL that was saved alongside them.
    private static func customKeyBelongs(to baseURL: String, defaults: UserDefaults) -> Bool {
        guard let identity = AssistantEndpoint(baseURL)?.identity else { return false }
        if let bound = defaults.string(forKey: customKeyEndpointKey) {
            return bound == identity
        }
        guard let savedBase = defaults.string(forKey: baseURLKey),
              AssistantProviderPreset.infer(baseURL: savedBase) == .custom,
              let savedIdentity = AssistantEndpoint(savedBase)?.identity else {
            return false
        }
        defaults.set(savedIdentity, forKey: customKeyEndpointKey)
        return savedIdentity == identity
    }

    static func importedKeySourceKey(for preset: AssistantProviderPreset) -> String {
        "assistant_key_source_\(preset.rawValue)"
    }

    /// Copies a key from CodexBar or an environment variable into this app's Keychain, only when the user clicks
    /// "导入" (#20). CodexBar's file is not read before that. Returns where the key came from, or nil if none was found.
    @discardableResult
    public static func importAmbientAPIKey(
        forBaseURL baseURL: String,
        defaults: UserDefaults = .standard,
        configURL: URL? = nil
    ) -> String? {
        let preset = AssistantProviderPreset.infer(baseURL: baseURL)
        guard preset.supportsKeyImport,
              AssistantEndpoint(baseURL)?.allowsSendingSecrets == true,
              let label = ambientKeySourceLabel(forBaseURL: baseURL, configURL: configURL),
              let key = loadAmbientAPIKey(forBaseURL: baseURL, configURL: configURL) else {
            return nil
        }
        saveSecret(key, for: preset, defaults: defaults)
        defaults.set(label, forKey: importedKeySourceKey(for: preset))
        return label
    }

    /// Where the saved key for `baseURL` was imported from ("CodexBar", "OPENROUTER_API_KEY"), or nil if typed by hand.
    public static func importedKeySource(forBaseURL baseURL: String, defaults: UserDefaults = .standard) -> String? {
        let preset = AssistantProviderPreset.infer(baseURL: baseURL)
        guard !userStoredAPIKey(forBaseURL: baseURL, defaults: defaults).isEmpty else { return nil }
        return defaults.string(forKey: importedKeySourceKey(for: preset))
    }

    /// Forgets the saved key for `baseURL`'s provider (the "撤销" button next to an imported key).
    public static func removeStoredAPIKey(forBaseURL baseURL: String, defaults: UserDefaults = .standard) {
        let preset = AssistantProviderPreset.infer(baseURL: baseURL)
        clearSecret(for: preset, defaults: defaults)
        if preset == .custom {
            defaults.removeObject(forKey: customKeyEndpointKey)
        }
        defaults.removeObject(forKey: importedKeySourceKey(for: preset))
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

    /// Every account that may hold a saved assistant key: the per-provider slots plus the pre-v1.0.4 OpenRouter
    /// slot. Used by the plain-text migration (#16).
    static var assistantSecretAccounts: [String] {
        AssistantProviderPreset.allCases.map { assistantProviderAPIKeyAccount(for: $0) } + [assistantAPIKeyAccount]
    }

    /// `UserDefaults` key of the plain-text copy that ≤1.0.6 wrote (#16). Nothing writes it any more for
    /// `.standard`; a custom suite uses it as a test-only store so unit tests never touch the real Keychain.
    public static func secretFallbackKey(for account: String) -> String {
        "keychain_fallback_\(account)"
    }

    public static func loadSecret(
        account: String, defaults: UserDefaults = .standard, vault: CredentialVault = .shared
    ) -> String {
        guard defaults === UserDefaults.standard else {
            return defaults.string(forKey: secretFallbackKey(for: account))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return readKeychainSecret(account: account, vault: vault) ?? ""
    }

    /// Saving an empty value deletes the item.
    @discardableResult
    public static func saveSecret(
        _ value: String, account: String, defaults: UserDefaults = .standard, vault: CredentialVault = .shared
    ) -> Bool {
        guard defaults === UserDefaults.standard else {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: secretFallbackKey(for: account))
            } else {
                defaults.set(trimmed, forKey: secretFallbackKey(for: account))
            }
            return true
        }
        // Credentials live only in the Keychain (#16); drop any plain-text copy left behind by ≤1.0.6 once the
        // Keychain accepted the new value, so a failed write never loses the old secret.
        guard writeKeychainSecret(value, account: account, vault: vault) else { return false }
        defaults.removeObject(forKey: secretFallbackKey(for: account))
        return true
    }
}
