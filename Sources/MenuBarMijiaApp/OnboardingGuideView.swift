import SwiftUI
import AppKit
import MijiaCore

public struct OnboardingGuideView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let store: HomeStore

    @State private var haURLDraft: String = ""
    @State private var haTokenDraft: String = ""
    @State private var selectedPreset: AssistantProviderPreset = .openRouterJev
    @State private var apiKeyDraft: String = ""
    @State private var voiceAuthorized: Bool = false
    @State private var isRequestingVoice: Bool = false

    public init(store: HomeStore) {
        self.store = store
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    step1ConnectionCard
                    step2JevModelCard
                    step3VoiceAndShortcutsCard
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            bottomActionRow
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .onAppear {
            haURLDraft = store.serverURLString
            haTokenDraft = KeychainHelper.loadToken()
            let currentBase = store.assistantConfig.baseURL
            selectedPreset = AssistantProviderPreset.infer(baseURL: currentBase)
            apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: currentBase)
            voiceAuthorized = SpeechInputController.shared.hasVoicePermissions
            if store.miSessionMaskedUserId == nil,
               haTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               store.homeBackend == .homeAssistant {
                // Never pull a user who chose the offline demo back into a cloud login (#47).
                store.switchBackend(.xiaomiCloud)
            }
            Task {
                let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
                if let first = found.first {
                    let normDraft = HAWebSocketProvider.normalizeBaseURL(haURLDraft)
                    if haURLDraft.isEmpty || normDraft == KeychainHelper.defaultNASURL {
                        haURLDraft = first.baseURL
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color(red: 0.92, green: 0.38, blue: 0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "house.fill")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1.5) {
                Text(L10n.tr("欢迎使用 MenuBarMijia", "Welcome to MenuBarMijia"))
                    .font(.system(size: 14, weight: .bold))
                    .tracking(-0.2)

                Text(L10n.tr("30 秒完成配置 · 菜单栏一秒掌控米家", "30-second setup · Control Xiaomi Home from your menu bar"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(store.effectiveLanguage == .en ? "中文" : "EN") {
                withAnimation(AppleMotion.snappySpring) {
                    store.appLanguagePreference = (store.effectiveLanguage == .en) ? .zhHans : .en
                }
            }
            .buttonStyle(PillActionButtonStyle())
            .help(L10n.tr("切换为英文界面 / Switch to English", "Switch to Chinese / 切换为中文界面"))

            Button(L10n.tr("跳过", "Skip")) {
                withAnimation(AppleMotion.snappySpring) {
                    store.completeOnboarding()
                }
            }
            .buttonStyle(PillActionButtonStyle())
        }
    }

    // MARK: - Step 1: Connect Devices

    private var step1ConnectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                stepBadge("1", isDone: isBackendConnected)
                Text(L10n.tr("连接你的米家设备", "Connect Your Devices"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if isBackendConnected {
                    Label(L10n.tr("已连接", "Connected"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if let firstHA = store.discoveredHAInstances.first {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            haURLDraft = firstHA.baseURL
                            store.applyDiscoveredHAInstance(firstHA, reconnectProvider: false)
                            store.switchBackend(.homeAssistant)
                        }
                    } label: {
                        Label(
                            L10n.tr("已发现局域网 HA · \(firstHA.hostAndPort)", "Found LAN HA · \(firstHA.hostAndPort)"),
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(L10n.tr("推荐手机扫码", "QR Login Recommended"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            Picker(
                "",
                selection: Binding(
                    get: { store.homeBackend },
                    set: { newBackend in
                        withAnimation(AppleMotion.snappySpring) {
                            store.switchBackend(newBackend)
                        }
                    }
                )
            ) {
                ForEach(HomeBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            // #47: let people try the panel before signing any account in.
            if store.homeBackend == .demo {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(L10n.tr(
                        "演示模式已开启：内置虚拟家庭，完全离线，不发起任何网络请求。选择上方「米家云端直连」或「Home Assistant」即可切回真实账号。",
                        "Demo mode is on: a built-in virtual home, fully offline, no network requests. Pick Xiaomi Cloud or Home Assistant above to switch back to a real account."
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.switchBackend(.demo)
                            // No `completeOnboarding()`: once demo devices arrive the guide hides by
                            // itself, and switching to an account without credentials shows it again.
                            store.showToast(L10n.tr("已进入演示模式，可随时在设置里切回真实账号", "Demo mode on; switch back anytime in Settings"))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.rectangle")
                            Text(L10n.tr("先看看演示（无需账号）", "Try the Demo (No Account)"))
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))

                    Text(L10n.tr("用虚拟设备体验面板与皮肤", "Explore the dashboard with virtual devices"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if store.homeBackend == .xiaomiCloud {
                MiAccountSection(store: store)
            } else if store.homeBackend == .homeAssistant {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("https://your-home.ui.nabu.casa", text: $haURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))

                        Button(store.isDiscoveringHA ? L10n.tr("扫描中…", "Scanning…") : L10n.tr("自动扫描", "Auto Scan")) {
                            Task {
                                let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
                                if let first = found.first {
                                    haURLDraft = first.baseURL
                                    store.showToast(L10n.tr("已发现：\(first.displaySummary)", "Found: \(first.displaySummary)"))
                                } else {
                                    store.showToast(L10n.tr("未在局域网扫描到 Home Assistant", "No Home Assistant found on LAN"), isError: true)
                                }
                            }
                        }
                        .buttonStyle(PillActionButtonStyle())
                        .disabled(store.isDiscoveringHA)
                    }

                    if let address = URL(string: HAWebSocketProvider.normalizeBaseURL(haURLDraft)),
                       address.scheme == "http",
                       let host = address.host,
                       !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
                        Label(L10n.tr("令牌将以明文在网络上传输，建议使用 HTTPS 或 Nabu Casa 地址。", "Your token will travel unencrypted. Use HTTPS or a Nabu Casa address."), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let firstHA = store.discoveredHAInstances.first {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Text(L10n.tr("已自动识别局域网 HA：\(firstHA.displaySummary)", "Detected LAN HA: \(firstHA.displaySummary)"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if let secURL = URL(string: "\(HAWebSocketProvider.normalizeBaseURL(haURLDraft))/profile/security") {
                                Button(L10n.tr("打开网页取令牌", "Open Security Page")) {
                                    NSWorkspace.shared.open(secURL)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        SecureField(L10n.tr("粘贴 HA 长期访问令牌", "Paste HA Long-Lived Access Token"), text: $haTokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))

                        Button(L10n.tr("连接", "Connect")) {
                            store.updateConnection(serverURL: haURLDraft, token: haTokenDraft)
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                    }
                }
            }
        }
        .padding(11)
        .glassTile(isActive: isBackendConnected, cornerRadius: 12)
    }

    // MARK: - Step 2: AI Decision Model

    private var step2JevModelCard: some View {
        let effectiveBase = selectedPreset.defaultBaseURL.isEmpty ? store.assistantConfig.baseURL : selectedPreset.defaultBaseURL
        let hasCustomKey = !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let importedSource = hasCustomKey ? AssistantConfig.importedKeySource(forBaseURL: effectiveBase) : nil
        let isLoopback = AssistantConfig(baseURL: effectiveBase, model: selectedPreset.defaultModel, apiKey: "").isLoopbackEndpoint
        let isReady = hasCustomKey || isLoopback

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                stepBadge("2", isDone: isReady)
                Text(L10n.tr("AI 决策模型（支持 Jev / DeepSeek / 自定义 Key）", "AI Decision Model (Jev / DeepSeek / Custom Key)"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let importedSource {
                    Label(L10n.tr("已从 \(importedSource) 导入", "Imported from \(importedSource)"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if hasCustomKey {
                    Label(L10n.tr("已配置密钥", "Key Configured"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if isLoopback {
                    Label(L10n.tr("本机免密接口", "Local Endpoint"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(L10n.tr("不填也可用本机 0ms 规则", "0ms Local Rules Work Without Key"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text(L10n.tr(
                "常规指令本机 0ms 直接执行；支持 OpenRouter Jev、TypeSafe 原生 Jev、DeepSeek、通义千问、智谱 GLM 等，复杂场景口语一次统筹多台设备。",
                "Standard commands run locally in 0ms. Configure OpenRouter Jev, Native Jev, DeepSeek, Qwen, GLM, or OpenAI to coordinate complex natural phrases."
            ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Picker(
                    "",
                    selection: Binding(
                        get: { selectedPreset },
                        set: { newPreset in
                            selectedPreset = newPreset
                            if newPreset != .custom {
                                apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: newPreset.defaultBaseURL)
                            } else {
                                apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: store.assistantConfig.baseURL)
                            }
                        }
                    )
                ) {
                    ForEach(AssistantProviderPreset.allCases) { preset in
                        Text(preset.shortTitle).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                .controlSize(.small)

                SecureField(selectedPreset.keyPlaceholder, text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11, design: .monospaced))

                Button(L10n.tr("保存", "Save")) {
                    persistOnboardingAssistantDraft()
                    store.showToast(L10n.tr("已保存 \(selectedPreset.shortTitle) 配置", "Saved \(selectedPreset.shortTitle) config"))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: !apiKeyDraft.isEmpty, tintColor: .accentColor))
            }

            if selectedPreset.supportsKeyImport && !hasCustomKey {
                Button(L10n.tr("已在 CodexBar 或环境变量里配过？点此导入 Key", "Already set up in CodexBar or env vars? Import the key")) {
                    if let label = AssistantConfig.importAmbientAPIKey(forBaseURL: effectiveBase) {
                        apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: effectiveBase)
                        store.showToast(L10n.tr("已从 \(label) 导入 \(selectedPreset.shortTitle) 的 Key", "Imported the \(selectedPreset.shortTitle) key from \(label)"))
                    } else {
                        store.showToast(
                            L10n.tr("CodexBar 和环境变量里都没有 \(selectedPreset.shortTitle) 的 Key", "No \(selectedPreset.shortTitle) key in CodexBar or environment variables"),
                            isError: true
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(11)
        .glassTile(isActive: false, cornerRadius: 12)
    }

    private func persistOnboardingAssistantDraft() {
        let base = selectedPreset.defaultBaseURL.isEmpty ? store.assistantConfig.baseURL : selectedPreset.defaultBaseURL
        let model = selectedPreset.defaultModel.isEmpty ? store.assistantConfig.model : selectedPreset.defaultModel
        store.assistantConfig = AssistantConfig(
            baseURL: base,
            model: model,
            apiKey: apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Step 3: Hold-to-Talk & Shortcuts

    private var step3VoiceAndShortcutsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                stepBadge("3", isDone: voiceAuthorized)
                Text(L10n.tr("解锁「按住菜单栏直接说话」", "Unlock Hold-to-Talk & Shortcuts"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if voiceAuthorized {
                    Label(L10n.tr("语音已授权", "Voice Authorized"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                shortcutTipRow(
                    icon: "waveform.badge.mic",
                    title: L10n.tr("长按顶部菜单栏温度/图标", "Long-Press Menu Bar Icon"),
                    detail: L10n.tr(
                        "按住直接说出指令（如「书房灯月光模式」「10分钟后关灯」），松手即执行",
                        "Hold and speak a command (e.g. \"study light moonlight mode\", \"in 10 minutes turn off lights\"), release to run"
                    )
                )
                shortcutTipRow(
                    icon: "command",
                    title: L10n.tr("全局快捷键 ⌥M 与数字键 1–9", "Global Hotkey ⌥M & Keys 1–9"),
                    detail: L10n.tr(
                        "短按 ⌥M 呼出面板，长按 ⌥M 直接说话，按 1–9 瞬间开关常用设备，说「撤销」可回退",
                        "Tap ⌥M to toggle the dashboard, hold ⌥M to speak, 1–9 to toggle top devices, or say \"undo\" to revert"
                    )
                )
            }

            if !voiceAuthorized {
                HStack {
                    Spacer()
                    Button {
                        isRequestingVoice = true
                        Task { @MainActor in
                            let granted = await SpeechInputController.shared.requestPermissions()
                            voiceAuthorized = granted
                            isRequestingVoice = false
                            if granted {
                                store.showToast(L10n.tr("已开启麦克风与语音识别权限", "Microphone & Speech Recognition enabled"))
                            } else {
                                store.showToast(
                                    L10n.tr("可在「系统设置 → 隐私与安全性」中开启权限", "Enable permissions in System Settings → Privacy & Security"),
                                    isError: true
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                            Text(isRequestingVoice
                                 ? L10n.tr("正在请求系统授权…", "Requesting Authorization…")
                                 : L10n.tr("一键授权麦克风与语音", "Authorize Microphone & Speech"))
                        }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                    .disabled(isRequestingVoice)
                }
                .padding(.top, 2)
            }
        }
        .padding(11)
        .glassTile(isActive: false, cornerRadius: 12)
    }

    // MARK: - Footer

    private var bottomActionRow: some View {
        HStack {
            Text(L10n.tr("随时可在「偏好设置 → 新手引导」重新打开", "Reopen anytime in Settings → Guide"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentPreset = AssistantProviderPreset.infer(baseURL: store.assistantConfig.baseURL)
                if !trimmedKey.isEmpty || selectedPreset != currentPreset {
                    persistOnboardingAssistantDraft()
                }
                withAnimation(AppleMotion.snappySpring) {
                    store.completeOnboarding()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.tr("开始使用", "Get Started"))
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
        }
    }

    // MARK: - Subviews

    private var isBackendConnected: Bool {
        if store.homeBackend == .demo { return true }
        if case .connected = store.connectionStatus { return true }
        if store.homeBackend == .xiaomiCloud && store.miSessionMaskedUserId != nil { return true }
        return false
    }

    private func stepBadge(_ number: String, isDone: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isDone ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.18))
                .frame(width: 18, height: 18)
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                Text(number)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func shortcutTipRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
