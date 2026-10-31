import SwiftUI
import AppKit
import ServiceManagement
import MijiaCore

// MARK: - Settings Window (#42)

/// The ⌘, window. Everything that used to live in the menu-bar popover's long form is split into
/// tabs here so it survives switching to the browser to copy a token (audit #42).
public struct SettingsWindowView: View {
    public let store: HomeStore
    @State private var tab: SettingsTab = .general
    /// The ⌘, window is a separate scene, so it must apply the app's appearance itself.
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    public init(store: HomeStore) {
        self.store = store
    }

    init(store: HomeStore, selectedTab: SettingsTab) {
        self.store = store
        _tab = State(initialValue: selectedTab)
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        let opener = SettingsWindowOpener.shared
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                SettingsCategoryPicker(selection: $tab, hasUpdateBadge: store.updateState.badgeRelease != nil)
                    .frame(maxWidth: DesignTokens.Settings.navigationWidth)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 0) {
                    Text(tab.title)
                        .font(.system(size: DesignTokens.TypeSize.title, weight: .semibold))
                        .padding(.horizontal, 30)
                        .padding(.bottom, 4)
                    settingsPage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: DesignTokens.Settings.contentWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
            }

            // Toasts are rendered by the panel; surface them here too while the panel is closed.
            if let toast = store.toastNotice {
                HStack(spacing: 6) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(toast.isError ? .orange : .green)
                    Text(toast.message)
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .adaptiveGlass(in: Capsule(style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        .frame(minWidth: 740, idealWidth: 780, minHeight: 600, idealHeight: 680)
        .font(.system(size: DesignTokens.TypeSize.body))
        .controlSize(.regular)
        .animation(reduceMotion ? nil : AppleMotion.pressFeedback, value: store.toastNotice)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        // Errors shown while the window is open still reach the diagnostics ring buffer (#45).
        .onChange(of: store.toastNotice?.id) { _, _ in
            AppDiagnosticsLog.shared.record(store.toastNotice)
        }
        .onAppear {
            if let requested = opener.requestedTab {
                tab = requested
                opener.requestedTab = nil
            }
        }
        .onChange(of: opener.requestedTab) { _, requested in
            guard let requested else { return }
            tab = requested
            opener.requestedTab = nil
        }
        .task {
            await store.checkForUpdatesIfNeeded()
        }
    }
    @ViewBuilder
    private var settingsPage: some View {
        switch tab {
        case .general: GeneralSettingsTab(store: store)
        case .connection: ConnectionSettingsTab(store: store)
        case .assistant: AssistantSettingsTab(store: store)
        case .appearance: AppearanceSettingsTab(store: store)
        case .privacy: PrivacySettingsTab(store: store)
        case .about: AboutSettingsTab(store: store)
        }
    }

}

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case connection
    case assistant
    case appearance
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tr("通用", "General")
        case .connection: return L10n.tr("家居连接", "Connections")
        case .assistant: return L10n.tr("AI 助手", "AI Assistant")
        case .appearance: return L10n.tr("外观", "Appearance")
        case .privacy: return L10n.tr("隐私与诊断", "Privacy & Diagnostics")
        case .about: return L10n.tr("关于与更新", "About & Updates")
        }
    }

    var navigationTitle: String {
        switch self {
        case .general: return L10n.tr("通用", "General")
        case .connection: return L10n.tr("连接", "Connect")
        case .assistant: return L10n.tr("助手", "Assistant")
        case .appearance: return L10n.tr("外观", "Display")
        case .privacy: return L10n.tr("隐私", "Privacy")
        case .about: return L10n.tr("关于", "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .connection: return "link"
        case .assistant: return "sparkles"
        case .appearance: return "circle.lefthalf.filled"
        case .privacy: return "lock"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Shared Building Blocks

struct SettingsSection<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Settings.rowSpacing) {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                .foregroundStyle(.primary)
            content
        }
        .font(.system(size: DesignTokens.TypeSize.body))
        .controlSize(.regular)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(DesignTokens.separator.opacity(0.5), lineWidth: DesignTokens.hairline)
        }
    }
}

struct SettingsValueRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.body))
            Spacer(minLength: 12)
            content()
                .font(.system(size: DesignTokens.TypeSize.body))
                .controlSize(.regular)
                .frame(width: DesignTokens.Settings.fieldWidth, alignment: .trailing)
        }
        .frame(minHeight: DesignTokens.Settings.rowHeight)
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.body))
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.glass)
                .controlSize(.regular)
        }
        .frame(minHeight: DesignTokens.Settings.rowHeight)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    let store: HomeStore
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var showNotificationRationale = false
    @AppStorage(SoundFeedback.storageKey) private var soundFeedbackEnabled = false
    @AppStorage(TemperatureUnitPreference.storageKey) private var temperatureUnitRaw = TemperatureUnitPreference.system.rawValue

    private var notifications: NotificationPermissionState { .shared }
    private var hotkey: HotkeySettingsState { .shared }

    var body: some View {
        let _ = store.effectiveLanguage
        let hasActiveUpdate = store.updateState.badgeRelease != nil || store.updateState.isFailure
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                if hasActiveUpdate {
                    UpdateSection(store: store)
                }

                SettingsSection(title: L10n.tr("菜单栏与交互体验", "Menu Bar & Interface")) {
                    SettingsValueRow(title: L10n.tr("界面语言", "Language")) {
                        Picker(L10n.tr("界面语言", "Language"), selection: Binding(
                            get: { store.appLanguagePreference },
                            set: { store.appLanguagePreference = $0 }
                        )) {
                            ForEach(AppLanguagePreference.allCases) { pref in
                                Text(pref.label).tag(pref)
                            }
                        }
                        .labelsHidden()
                    }

                    SettingsValueRow(title: L10n.tr("温度单位", "Temperature Unit")) {
                        Picker(L10n.tr("温度单位", "Temperature Unit"), selection: $temperatureUnitRaw) {
                            ForEach(TemperatureUnitPreference.allCases) { unit in
                                Text(unit.title).tag(unit.rawValue)
                            }
                        }
                        .labelsHidden()
                    }

                    SettingsValueRow(title: L10n.tr("面板标题", "Dashboard Title")) {
                        TextField(KeychainHelper.localizedDefaultHomeName, text: Binding(
                            get: { store.homeName },
                            set: { store.homeName = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("面板标题", "Dashboard Title"))
                    }

                    SettingsValueRow(title: L10n.tr("菜单栏旁显示", "Menu Bar Readout")) {
                        Picker(L10n.tr("菜单栏旁显示", "Menu Bar Readout"), selection: Binding(
                            get: { store.menuBarTargetId },
                            set: { store.menuBarTargetId = $0 }
                        )) {
                            ForEach(store.availableMenuBarOptions) { option in
                                Text(option.title).tag(option.id)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider().padding(.vertical, 4)

                    SettingsToggleRow(
                        title: L10n.tr("显示顶部快捷场景栏", "Show Quick Scenes Bar"),
                        isOn: Binding(
                            get: { store.showQuickActionsBar },
                            set: { store.showQuickActionsBar = $0 }
                        )
                    )

                    SettingsToggleRow(
                        title: L10n.tr("双列紧凑磁贴视图", "2-Column Compact Grid"),
                        isOn: Binding(
                            get: { store.isCompactGridMode },
                            set: { store.isCompactGridMode = $0 }
                        )
                    )

                    SettingsToggleRow(
                        title: L10n.tr("隐藏离线/未通电的设备", "Hide Offline / Unpowered Devices"),
                        isOn: Binding(
                            get: { store.hideOfflineDevices },
                            set: { store.hideOfflineDevices = $0 }
                        )
                    )

                    SettingsToggleRow(
                        title: L10n.tr("操作声音反馈", "Play Feedback Sounds"),
                        isOn: $soundFeedbackEnabled
                    )

                    Text(L10n.tr(
                        "默认关闭。开启后，开关、全关和 AI 执行成功会播放轻提示音，失败会播放另一种提示音。",
                        "Off by default. When enabled, successful toggles, All Off and AI actions play a soft cue, and failures play a different one."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Text(L10n.tr("登录 Mac 时自动启动", "Launch at Login"))
                            .font(.system(size: DesignTokens.TypeSize.body))
                        Spacer()
                        Toggle(L10n.tr("登录 Mac 时自动启动", "Launch at Login"), isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.glass)
                            .controlSize(.regular)
                            .onChange(of: launchAtLogin) { _, newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    store.showToast(
                                        L10n.tr("开机自启需要在应用程序目录运行", "Launch at Login requires running from /Applications"),
                                        isError: true
                                    )
                                }
                            }
                    }
                    .frame(minHeight: DesignTokens.Settings.rowHeight)
                }

                SettingsSection(title: L10n.tr("全局快捷键", "Global Shortcut")) {
                    SettingsToggleRow(
                        title: L10n.tr(
                            "启用全局快捷键 \(hotkey.shortcut.displayString)（短按面板，长按语音）",
                            "Global shortcut \(hotkey.shortcut.displayString) (tap for dashboard, hold to speak)"
                        ),
                        isOn: Binding(
                            get: { store.enableGlobalHotkey },
                            set: { store.enableGlobalHotkey = $0 }
                        )
                    )

                    if store.enableGlobalHotkey {
                        HotkeyRecorderRow()
                    }

                    Text(L10n.tr(
                        "关闭开关会立即取消系统级注册，不会继续占用这个组合。",
                        "Turning this off unregisters the shortcut immediately so other apps can use it."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: L10n.tr("守护提醒与通知", "Safety Alerts & Notifications")) {
                    SettingsToggleRow(
                        title: L10n.tr("主动安全与低电量提醒", "Safety & Low Battery Alerts"),
                        isOn: Binding(
                            get: { store.enableSafetyAlerts },
                            set: { enabled in
                                store.enableSafetyAlerts = enabled
                                if enabled { askForNotificationsIfNeeded() }
                            }
                        )
                    )

                    NotificationPermissionRow()

                    if showNotificationRationale {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                L10n.tr("为什么需要通知权限？", "Why do notifications need permission?"),
                                systemImage: "bell.badge"
                            )
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))

                            Text(L10n.tr(
                                "守护提醒（设备长时间开启、电量过低）和错过的定时任务要靠系统通知提醒你。通知只在本机显示，不会上传任何内容；不发通知时 App 其它功能照常使用。",
                                "Safety alerts (a device left on too long, low battery) and missed timers are delivered as local macOS notifications. They stay on this Mac; the rest of the app works without them."
                            ))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                Spacer()
                                Button(L10n.tr("暂不", "Not Now")) {
                                    showNotificationRationale = false
                                }
                                .buttonStyle(PillActionButtonStyle())

                                Button(L10n.tr("允许通知", "Allow Notifications")) {
                                    showNotificationRationale = false
                                    Task {
                                        _ = await HotkeyAndNotificationManager.shared.requestNotificationAuthorization()
                                    }
                                }
                                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                            }
                        }
                        .padding(9)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous))
                    }
                }

                AutomationSettingsSection(store: store)
                EnergySettingsSection(store: store)

                if !store.hiddenDevices.isEmpty {
                    SettingsSection(title: L10n.tr("已隐藏的设备 (\(store.hiddenDevices.count))", "Hidden Devices (\(store.hiddenDevices.count))")) {
                        ForEach(store.hiddenDevices) { dev in
                            HStack(spacing: 8) {
                                Image(systemName: dev.sfSymbolName)
                                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dev.name)
                                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                    Text(L10n.displayRoomName(dev.roomName))
                                        .font(.system(size: DesignTokens.TypeSize.caption))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button(L10n.tr("恢复显示", "Unhide")) {
                                    withAnimation(AppleMotion.snappySpring) {
                                        store.unhideDevice(dev.id)
                                    }
                                }
                                .buttonStyle(PillActionButtonStyle())
                            }
                        }
                    }
                }

                SettingsSection(title: L10n.tr("首次设置", "Setup")) {
                    HStack {
                        Text(L10n.tr("重新打开新手引导，可再次查看连接、AI 与语音步骤。", "Reopen the setup guide to review connections, AI and voice."))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.reopenOnboarding()
                            NSApp.keyWindow?.orderOut(nil)
                            HotkeyAndNotificationManager.shared.ensureMenuBarExtraWindowVisible()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                Text(L10n.tr("打开新手引导", "Open Guide"))
                            }
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        }
                        .buttonStyle(PillActionButtonStyle())
                    }
                }
            }
            .padding(14)
        }
        .task {
            await HotkeyAndNotificationManager.shared.refreshNotificationPermission()
        }
    }

    /// In-app explanation first, system prompt second (#55).
    private func askForNotificationsIfNeeded() {
        if HotkeyAndNotificationManager.hasRequestedNotificationAuthorization {
            // Asked before: only show the system prompt when macOS can still present it.
            if notifications.canRequest {
                Task { _ = await HotkeyAndNotificationManager.shared.requestNotificationAuthorization() }
            }
            return
        }
        // A denial made in System Settings has nothing left to ask; the permission row offers the repair link.
        if notifications.isDenied { return }
        showNotificationRationale = true
    }
}

// MARK: - Connections

private struct ConnectionSettingsTab: View {
    let store: HomeStore
    @State private var urlDraft: String = ""
    @State private var tokenDraft: String = ""

    var body: some View {
        let _ = store.effectiveLanguage
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: L10n.tr("连接配置", "Connection")) {
                    HStack {
                        Text(store.homeBackend == .demo
                             ? L10n.tr("当前为演示模式", "Demo mode is active")
                             : L10n.tr("选择数据源", "Data source"))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(connectionBadgeText)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(connectionBadgeColor)
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
                    .controlSize(.regular)

                    if store.homeBackend == .demo {
                        Text(L10n.tr(
                            "演示模式使用内置虚拟设备，完全离线。选择「米家云端直连」或「Home Assistant」即可切回真实账号。",
                            "Demo mode uses built-in virtual devices and never touches the network. Choose Xiaomi Cloud or Home Assistant to switch back."
                        ))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if store.homeBackend == .homeAssistant {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L10n.tr("服务器地址", "Server URL"))
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let firstHA = store.discoveredHAInstances.first {
                                    if HAWebSocketProvider.normalizeBaseURL(urlDraft) == firstHA.baseURL {
                                        Label(
                                            L10n.tr("局域网已识别 · \(firstHA.locationName)", "LAN Detected · \(firstHA.locationName)"),
                                            systemImage: "checkmark.seal.fill"
                                        )
                                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                        .foregroundStyle(.green)
                                    } else {
                                        Button(L10n.tr("填入已发现：\(firstHA.hostAndPort)", "Use Found: \(firstHA.hostAndPort)")) {
                                            urlDraft = firstHA.baseURL
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            TextField("https://your-home.ui.nabu.casa", text: $urlDraft)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.regular)
                                .font(.system(size: DesignTokens.TypeSize.body, design: .monospaced))
                            if let address = URL(string: HAWebSocketProvider.normalizeBaseURL(urlDraft)),
                               address.scheme == "http",
                               let host = address.host,
                               !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
                                Label(L10n.tr("令牌将以明文在网络上传输，建议使用 HTTPS 或 Nabu Casa 地址。", "Your token will travel unencrypted. Use HTTPS or a Nabu Casa address."), systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L10n.tr("长期访问令牌 (安全存入钥匙串)", "Long-Lived Access Token (Stored in Keychain)"))
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let secURL = URL(string: "\(HAWebSocketProvider.normalizeBaseURL(urlDraft))/profile/security") {
                                    Button(L10n.tr("打开网页取令牌", "Open Security Page")) {
                                        NSWorkspace.shared.open(secURL)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                }
                            }
                            SecureField(L10n.tr("粘贴 HA 长期访问令牌", "Paste HA Long-Lived Access Token"), text: $tokenDraft)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.regular)
                                .font(.system(size: DesignTokens.TypeSize.body, design: .monospaced))
                        }

                        HStack {
                            Button(store.isDiscoveringHA ? L10n.tr("扫描中…", "Scanning…") : L10n.tr("扫描局域网 HA", "Scan LAN for HA")) {
                                Task {
                                    let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
                                    if let first = found.first {
                                        urlDraft = first.baseURL
                                        store.showToast(L10n.tr("已发现：\(first.displaySummary)", "Found: \(first.displaySummary)"))
                                    } else {
                                        store.showToast(L10n.tr("未在局域网扫描到 Home Assistant", "No Home Assistant found on LAN"), isError: true)
                                    }
                                }
                            }
                            .buttonStyle(PillActionButtonStyle())
                            .disabled(store.isDiscoveringHA)

                            Button(L10n.tr("默认地址", "Default URL")) {
                                urlDraft = KeychainHelper.defaultNASURL
                            }
                            .buttonStyle(PillActionButtonStyle())

                            Spacer()

                            Button(L10n.tr("保存并重新连接", "Save & Reconnect")) {
                                store.updateConnection(serverURL: urlDraft, token: tokenDraft)
                            }
                            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                        }
                        .padding(.top, 2)
                    } else if store.homeBackend == .xiaomiCloud {
                        MiAccountSection(store: store)
                    }
                }

                if store.homeBackend != .demo {
                    LGWebOSSettingsSection(store: store)
                }
            }
            .padding(14)
        }
        .onAppear {
            urlDraft = store.serverURLString
            tokenDraft = KeychainHelper.loadToken()
            if store.discoveredHAInstances.isEmpty {
                Task {
                    let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
                    if let first = found.first,
                       HAWebSocketProvider.normalizeBaseURL(urlDraft) == KeychainHelper.defaultNASURL {
                        urlDraft = first.baseURL
                    }
                }
            }
        }
    }

    private var connectionBadgeText: String {
        if store.homeBackend == .demo { return L10n.tr("● 离线演示", "● Offline Demo") }
        switch store.connectionStatus {
        case .connected: return L10n.tr("● 已连接", "● Connected")
        case .connecting: return L10n.tr("● 连接中…", "● Connecting…")
        case .disconnected: return L10n.tr("● 未连接", "● Disconnected")
        }
    }

    private var connectionBadgeColor: Color {
        if store.homeBackend == .demo { return .secondary }
        switch store.connectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }
}

// MARK: - AI Assistant

private struct AssistantSettingsTab: View {
    let store: HomeStore

    var body: some View {
        let _ = store.effectiveLanguage
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                AssistantSettingsSection(store: store)
            }
            .padding(14)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    let store: HomeStore
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(PanelPrefs.climatePanelKey) private var climatePanelModule: Bool = true
    @AppStorage(PanelHeight.storageKey) private var panelHeightRaw: String = PanelHeight.standard.rawValue

    var body: some View {
        let _ = store.effectiveLanguage
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: L10n.tr("外观模式", "Appearance")) {
                    GlassSegmentedControl(
                        selection: $appearanceRaw,
                        segments: AppAppearance.allCases.map {
                            GlassSegment(value: $0.rawValue, title: $0.title)
                        }
                    )

                    Text(L10n.tr(
                        "面板只有一套系统外观：跟随系统时会自动使用浅色或深色材质，开启的设备显示为亮色磁贴。",
                        "The panel has one system look: it follows light and dark automatically, and devices that are on use a bright platter."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: L10n.tr("面板布局", "Panel Layout")) {
                    HStack {
                        Text(L10n.tr("面板高度", "Panel Height"))
                            .font(.system(size: DesignTokens.TypeSize.body))
                        Spacer()
                        GlassSegmentedControl(
                            selection: $panelHeightRaw,
                            segments: PanelHeight.allCases.map {
                                GlassSegment(value: $0.rawValue, title: $0.title)
                            }
                        )
                        .frame(width: 210)
                    }

                    Divider().overlay(Color.primary.opacity(0.06))

                    SettingsToggleRow(
                        title: L10n.tr("空调使用整行面板模块", "Full-Width Climate Panel"),
                        isOn: $climatePanelModule
                    )
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Privacy & Diagnostics (#45, #50)

private struct PrivacySettingsTab: View {
    let store: HomeStore
    @State private var didCopy = false

    private var scanner: UnsupportedDeviceScanner { .shared }
    private var errorLog: AppDiagnosticsLog { .shared }

    var body: some View {
        let _ = store.effectiveLanguage
        let _ = errorLog.errorTimestamps
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: L10n.tr("诊断信息", "Diagnostics")) {
                    Text(L10n.tr(
                        "复制一段 Markdown 粘贴到 GitHub issue。内容只有版本、系统、后端、型号与未识别设备，不含设备 ID、令牌、服务器地址或账号信息。",
                        "Copies Markdown for a GitHub issue: versions, OS, backend, models and skipped devices only. No device IDs, tokens, server addresses or account information."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button {
                            copyDiagnostics()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text(L10n.tr("复制诊断信息", "Copy Diagnostics"))
                            }
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

                        if didCopy {
                            Label(L10n.tr("已复制", "Copied"), systemImage: "checkmark.circle.fill")
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                .foregroundStyle(.green)
                        }

                        Spacer()

                        Button(L10n.tr("打开 GitHub Issues", "Open GitHub Issues")) {
                            if let url = URL(string: "https://github.com/jryang1997/MenuBarMijia/issues") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(PillActionButtonStyle())
                    }
                }

                SettingsSection(title: L10n.tr("未能显示在面板的设备", "Devices Not Shown in the Panel")) {
                    Text(L10n.tr(
                        "扫描当前账号的原始设备列表，找出被跳过的设备与原因。米家首次扫描会按型号拉取规格，可能需要几十秒；演示模式没有跳过项。",
                        "Scans the raw device registry for devices the panel skipped, with the reason. The first Mi Cloud scan loads per-model specs and may take a while; demo mode has none."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        if let scannedAt = scanner.lastScannedAt, !scanner.isScanning {
                            Text(L10n.tr("上次扫描：\(scannedAt.formatted(date: .abbreviated, time: .shortened))", "Last scan: \(scannedAt.formatted(date: .abbreviated, time: .shortened))"))
                                .font(.system(size: DesignTokens.TypeSize.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(scanner.isScanning
                               ? L10n.tr("扫描中…", "Scanning…")
                               : L10n.tr("扫描不支持的设备", "Scan Skipped Devices")) {
                            Task { await scanner.scan(store: store) }
                        }
                        .buttonStyle(PillActionButtonStyle())
                        .disabled(scanner.isScanning)
                    }

                    if let error = scanner.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !scanner.isScanning && scanner.lastScannedAt != nil && scanner.devices.isEmpty && scanner.errorMessage == nil {
                        Label(L10n.tr("没有发现被跳过的设备", "No skipped devices found"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.green)
                    }

                    ForEach(scanner.devices) { device in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "questionmark.square.dashed")
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                Text("\(device.model.isEmpty ? L10n.tr("未知型号", "Unknown model") : device.model) · \(device.reasonText)")
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            if let url = feedbackURL(for: device) {
                                Link(destination: url) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.up.right.square")
                                        Text(L10n.tr("去 GitHub 反馈", "Report on GitHub"))
                                    }
                                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                                }
                            }
                        }
                    }
                }

                SettingsSection(title: L10n.tr("隐私", "Privacy")) {
                    privacyBullet(L10n.tr("语音只在本机识别时可完全离线；不支持的语种会提示改用苹果服务器。", "On-device speech stays on this Mac; unsupported languages say they fall back to Apple's servers."))
                    privacyBullet(L10n.tr("诊断报告不含设备 ID、令牌、服务器地址或账号信息。", "Diagnostics never include device IDs, tokens, server addresses or account info."))
                    privacyBullet(L10n.tr("演示模式完全离线，不发起任何网络请求。", "Demo mode is fully offline and sends no requests."))
                    privacyBullet(L10n.tr("最近错误只记录次数与时间，不保存错误原文。", "Recent errors are counted by time only; the raw text is not stored."))
                }
            }
            .padding(14)
        }
    }

    private func privacyBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.green)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyDiagnostics() {
        let info = Bundle.main.infoDictionary
        let models = Dictionary(grouping: store.devices, by: { $0.model })
            .map { DiagnosticsReportBuilder.ModelCount(model: $0.key, count: $0.value.count) }
        let input = DiagnosticsReportBuilder.Input(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            buildNumber: info?["CFBundleVersion"] as? String ?? "-",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            backendTitle: store.homeBackend.title,
            miCloudRegion: store.homeBackend == .xiaomiCloud ? store.miCloudRegion.title : "-",
            deviceCount: store.devices.count,
            onlineDeviceCount: store.onlineDeviceCount,
            hiddenDeviceCount: store.hiddenDevices.count,
            models: models,
            unsupported: scanner.devices,
            recentErrorCount: errorLog.errorTimestamps.count,
            lastErrorAt: errorLog.errorTimestamps.last,
            extraSettings: [
                L10n.tr("快捷键", "Shortcut") + ": " + HotkeyPreferences.load().displayString,
                L10n.tr("本机语音", "On-device speech") + ": " + (store.prefersOnDeviceSpeech ? "on" : "off"),
            ]
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DiagnosticsReportBuilder.markdown(input), forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func feedbackURL(for device: UnsupportedDevice) -> URL? {
        var components = URLComponents(string: "https://github.com/jryang1997/MenuBarMijia/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "template", value: "unsupported_device.yml"),
            URLQueryItem(name: "title", value: L10n.tr(
                "[设备不支持] \(device.name) (\(device.model))",
                "[Unsupported device] \(device.name) (\(device.model))"
            )),
        ]
        return components?.url
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    let store: HomeStore

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        let _ = store.effectiveLanguage
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: L10n.tr("关于 MenuBarMijia", "About MenuBarMijia")) {
                    HStack(spacing: 10) {
                        Image(systemName: "house.fill")
                            .font(.system(size: DesignTokens.TypeSize.title, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                LinearGradient(
                                    colors: [Color.orange, DesignTokens.active],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.inset, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("MenuBarMijia")
                                .font(.system(size: DesignTokens.TypeSize.body, weight: .bold))
                            Text(L10n.tr("版本 \(appVersion) (\(buildNumber))", "Version \(appVersion) (\(buildNumber))"))
                                .font(.system(size: DesignTokens.TypeSize.caption))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Spacer()

                        if store.homeBackend == .demo {
                            Text(L10n.tr("演示模式", "Demo Mode"))
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack(spacing: 8) {
                        Link(L10n.tr("项目主页", "Repository"), destination: URL(string: "https://github.com/jryang1997/MenuBarMijia")!)
                        Link(L10n.tr("问题反馈", "Issues"), destination: URL(string: "https://github.com/jryang1997/MenuBarMijia/issues")!)
                        Link(L10n.tr("更新日志", "Releases"), destination: URL(string: "https://github.com/jryang1997/MenuBarMijia/releases")!)
                        Spacer()
                    }
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                }

                UpdateSection(store: store)

                SettingsSection(title: L10n.tr("退出", "Quit")) {
                    HStack {
                        Text(L10n.tr("完全退出后菜单栏图标与快捷键都会停止。", "Quitting stops the menu bar icon and the global shortcut."))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "power")
                                Text(L10n.tr("退出 MenuBarMijia", "Quit MenuBarMijia"))
                            }
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - LG webOS

struct LGWebOSSettingsSection: View {
    let store: HomeStore
    @State private var isEnabled: Bool = false
    @State private var hostDraft: String = ""
    @State private var macDraft: String = ""
    @State private var isScanning: Bool = false
    @State private var confirmsTrustReset = false

    var body: some View {
        let _ = store.effectiveLanguage
        let isPaired = !store.lgConfig.clientKey.isEmpty
        let hasHost = !hostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        SettingsSection(title: L10n.tr("LG webOS 电视局域网直连", "LG webOS TV Direct LAN")) {
            HStack {
                Spacer()
                Text(isPaired
                     ? L10n.tr("● 已配对密钥", "● Paired")
                     : (isEnabled
                        ? (hasHost ? L10n.tr("● 待电视确认", "● Awaiting TV Prompt") : L10n.tr("● 待填电视 IP", "● Enter TV IP"))
                        : L10n.tr("● 已停用", "● Disabled")))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(isPaired ? .green : (isEnabled ? .orange : .secondary))
            }

            HStack {
                Text(L10n.tr("启用 LG 电视局域网直连 (SSAP + WoL)", "Enable LG TV LAN Control (SSAP + WoL)"))
                    .font(.system(size: DesignTokens.TypeSize.body))
                Spacer()
                Toggle(L10n.tr("启用 LG 电视局域网直连", "Enable LG TV Direct LAN"), isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.glass)
                    .controlSize(.regular)
                    .onChange(of: isEnabled) { _, newValue in
                        var next = store.lgConfig
                        next.isEnabled = newValue
                        next.host = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        next.macAddress = macDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.updateLGWebOSConfig(next)
                    }
            }

            if isEnabled {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("局域网 IP", "LAN IP"))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.secondary)
                        TextField(L10n.tr("如 192.168.1.50", "e.g. 192.168.1.50"), text: $hostDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .font(.system(size: DesignTokens.TypeSize.body, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("MAC 地址 (Wake-on-LAN)", "MAC Address (Wake-on-LAN)"))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.secondary)
                        TextField(L10n.tr("如 AA:BB:CC:DD:EE:FF", "e.g. AA:BB:CC:DD:EE:FF"), text: $macDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .font(.system(size: DesignTokens.TypeSize.body, design: .monospaced))
                    }
                }

                HStack {
                    Button(isScanning ? L10n.tr("扫描中…", "Scanning…") : L10n.tr("扫描局域网电视", "Scan LAN TV")) {
                        isScanning = true
                        Task {
                            let found = await store.discoverLGWebOSTVs(hostHint: hostDraft)
                            isScanning = false
                            if let first = found.first {
                                hostDraft = first.host
                                store.showToast(L10n.tr(
                                    "已发现：\(first.friendlyName) (\(first.host))",
                                    "Found: \(first.friendlyName) (\(first.host))"
                                ))
                            } else {
                                store.showToast(
                                    L10n.tr("未扫描到开机状态的 LG 电视", "No powered-on LG TV found on LAN"),
                                    isError: true
                                )
                            }
                        }
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .disabled(isScanning)

                    Button(L10n.tr("发起电视配对", "Pair TV")) {
                        saveDrafts()
                        store.triggerLGWebOSPairing()
                    }
                    .buttonStyle(PillActionButtonStyle())

                    Button(L10n.tr("重新信任电视", "Trust TV Again")) {
                        confirmsTrustReset = true
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .alert(L10n.tr("清除已保存的电视身份？", "Clear the saved TV identity?"), isPresented: $confirmsTrustReset) {
                        Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
                        Button(L10n.tr("重新配对", "Pair Again"), role: .destructive) {
                            saveDrafts()
                            store.resetLGWebOSTrustAndPair()
                        }
                    } message: {
                        Text(L10n.tr("请先核对电视 IP。确认后将清除旧证书和配对密钥，下次连接会信任新的证书，并要求在电视上重新确认。", "Verify the TV IP first. This clears the saved certificate and pairing key, trusts the certificate on the next connection, and requires confirmation on the TV."))
                    }

                    Spacer()

                    Button(L10n.tr("保存配置", "Save")) {
                        saveDrafts()
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                }
            }
        }
        .onAppear {
            isEnabled = store.lgConfig.isEnabled
            hostDraft = store.lgConfig.host
            macDraft = store.lgConfig.macAddress
        }
    }

    private func saveDrafts() {
        var next = store.lgConfig
        next.isEnabled = isEnabled
        next.host = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        next.macAddress = macDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateLGWebOSConfig(next)
    }
}
