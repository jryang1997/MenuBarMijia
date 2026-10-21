import SwiftUI
import AppKit
import MijiaCore

public struct OnboardingGuideView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let store: HomeStore

    @State private var haURLDraft: String = ""
    @State private var haTokenDraft: String = ""
    @State private var apiKeyDraft: String = ""
    @State private var voiceAuthorized: Bool = false
    @State private var isRequestingVoice: Bool = false

    public init(store: HomeStore) {
        self.store = store
    }

    public var body: some View {
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
            apiKeyDraft = store.assistantConfig.apiKey
            voiceAuthorized = SpeechInputController.shared.hasVoicePermissions
            if store.miSessionMaskedUserId == nil,
               haTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               store.homeBackend != .xiaomiCloud {
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
                Text("欢迎使用 MenuBarMijia")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(-0.2)

                Text("30 秒完成配置 · 菜单栏一秒掌控米家")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("跳过") {
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
                Text("连接你的米家设备")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if isBackendConnected {
                    Label("已连接", systemImage: "checkmark.circle.fill")
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
                        Label("已发现局域网 HA · \(firstHA.hostAndPort)", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("推荐手机扫码")
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

            if store.homeBackend == .xiaomiCloud {
                MiAccountSection(store: store)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("http://homeassistant.local:8123", text: $haURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))

                        Button(store.isDiscoveringHA ? "扫描中…" : "自动扫描") {
                            Task {
                                let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
                                if let first = found.first {
                                    haURLDraft = first.baseURL
                                    store.applyDiscoveredHAInstance(first, reconnectProvider: false)
                                    store.showToast("已发现：\(first.displaySummary)")
                                } else {
                                    store.showToast("未在局域网扫描到 Home Assistant", isError: true)
                                }
                            }
                        }
                        .buttonStyle(PillActionButtonStyle())
                        .disabled(store.isDiscoveringHA)
                    }

                    if let firstHA = store.discoveredHAInstances.first {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Text("已自动识别局域网 HA：\(firstHA.displaySummary)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if let secURL = URL(string: "\(HAWebSocketProvider.normalizeBaseURL(haURLDraft))/profile/security") {
                                Button("打开网页取令牌") {
                                    NSWorkspace.shared.open(secURL)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        SecureField("粘贴 HA 长期访问令牌", text: $haTokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))

                        Button("连接") {
                            store.updateConnection(serverURL: haURLDraft, token: haTokenDraft)
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                    }
                }
            }
        }
        .padding(11)
        .glassTile(isActive: isBackendConnected, accent: .green, cornerRadius: 12)
    }

    // MARK: - Step 2: Jev Decision Model

    private var step2JevModelCard: some View {
        let hasCodexBarKey = (AssistantConfig.loadCodexBarOpenRouterKey() != nil)
        let hasSavedKey = !store.assistantConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isReady = hasCodexBarKey || hasSavedKey

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                stepBadge("2", isDone: isReady)
                Text("Jev 极速决策模型（可选）")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if hasCodexBarKey {
                    Label("已自动接入 CodexBar", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if hasSavedKey {
                    Label("已配置密钥", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Text("不填也可用本机 0ms 规则")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text("常规指令本机 0ms 直接执行；配置 OpenRouter Key 后，复杂场景口语（如「准备写代码，有点热」）由 Jev 决策模型约 280ms 一次统筹多台设备。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !hasCodexBarKey {
                HStack(spacing: 6) {
                    SecureField("粘贴 OpenRouter API Key (sk-or-...)", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11, design: .monospaced))

                    Button("保存") {
                        var cfg = store.assistantConfig
                        cfg.apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.assistantConfig = cfg
                        store.showToast("已保存 OpenRouter 密钥")
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: !apiKeyDraft.isEmpty, tintColor: .accentColor))
                }
            }
        }
        .padding(11)
        .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)
    }

    // MARK: - Step 3: Hold-to-Talk & Shortcuts

    private var step3VoiceAndShortcutsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                stepBadge("3", isDone: voiceAuthorized)
                Text("解锁「按住菜单栏直接说话」")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if voiceAuthorized {
                    Label("语音已授权", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                shortcutTipRow(
                    icon: "waveform.badge.mic",
                    title: "长按顶部菜单栏温度/图标",
                    detail: "按住直接说出指令（如「书房灯月光模式」「10分钟后关灯」），松手即执行"
                )
                shortcutTipRow(
                    icon: "command",
                    title: "全局快捷键 ⌥M 与数字键 1–9",
                    detail: "随时按 ⌥M 呼出面板，按 1–9 瞬间开关对应常用设备，说「撤销」可回退操作"
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
                                store.showToast("已开启麦克风与语音识别权限")
                            } else {
                                store.showToast("可在「系统设置 → 隐私与安全性」中开启权限", isError: true)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                            Text(isRequestingVoice ? "正在请求系统授权…" : "一键授权麦克风与语音")
                        }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                    .disabled(isRequestingVoice)
                }
                .padding(.top, 2)
            }
        }
        .padding(11)
        .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)
    }

    // MARK: - Footer

    private var bottomActionRow: some View {
        HStack {
            Text("随时可在「偏好设置 → 新手引导」重新打开")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.completeOnboarding()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("开始使用")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
        }
    }

    // MARK: - Subviews

    private var isBackendConnected: Bool {
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
