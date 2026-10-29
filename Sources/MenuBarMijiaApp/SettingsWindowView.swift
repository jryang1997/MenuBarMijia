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

    public init(store: HomeStore) {
        self.store = store
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        ZStack(alignment: .bottom) {
            TabView(selection: $tab) {
                GeneralSettingsTab(store: store)
                    .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                    .tag(SettingsTab.general)

                ConnectionSettingsTab(store: store)
                    .tabItem { Label(SettingsTab.connection.title, systemImage: SettingsTab.connection.symbol) }
                    .tag(SettingsTab.connection)

                AssistantSettingsTab(store: store)
                    .tabItem { Label(SettingsTab.assistant.title, systemImage: SettingsTab.assistant.symbol) }
                    .tag(SettingsTab.assistant)

                AppearanceSettingsTab(store: store)
                    .tabItem { Label(SettingsTab.appearance.title, systemImage: SettingsTab.appearance.symbol) }
                    .tag(SettingsTab.appearance)

                PrivacySettingsTab(store: store)
                    .tabItem { Label(SettingsTab.privacy.title, systemImage: SettingsTab.privacy.symbol) }
                    .tag(SettingsTab.privacy)

                AboutSettingsTab(store: store)
                    .tabItem { Label(SettingsTab.about.title, systemImage: SettingsTab.about.symbol) }
                    .tag(SettingsTab.about)
            }

            // Toasts are rendered by the panel; surface them here too while the panel is closed.
            if let toast = store.toastNotice {
                HStack(spacing: 6) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(toast.isError ? .orange : .green)
                    Text(toast.message)
                        .font(.system(size: 11.5, weight: .medium))
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
        .frame(width: 580, height: 640)
        .animation(AppleMotion.snappySpring, value: store.toastNotice)
        // Errors shown while the window is open still reach the diagnostics ring buffer (#45).
        .onChange(of: store.toastNotice?.id) { _, _ in
            AppDiagnosticsLog.shared.record(store.toastNotice)
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

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .connection: return "house.and.flag"
        case .assistant: return "sparkles"
        case .appearance: return "paintpalette"
        case .privacy: return "hand.raised"
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
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
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
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 11) {
                SettingsSection(title: L10n.tr("菜单栏与交互体验", "Menu Bar & Interface")) {
                    HStack {
                        Text(L10n.tr("界面语言 / Language", "Language / 界面语言"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { store.appLanguagePreference },
                                set: { store.appLanguagePreference = $0 }
                            )
                        ) {
                            ForEach(AppLanguagePreference.allCases) { pref in
                                Text(pref.label).tag(pref)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 176)
                        .controlSize(.small)
                    }

                    HStack {
                        Text(L10n.tr("温度单位", "Temperature Unit"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $temperatureUnitRaw) {
                            ForEach(TemperatureUnitPreference.allCases) { unit in
                                Text(unit.title).tag(unit.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 176)
                        .controlSize(.small)
                    }

                    Divider().overlay(Color.primary.opacity(0.06))

                    HStack {
                        Text(L10n.tr("面板标题", "Dashboard Title"))
                            .font(.system(size: 12))
                        Spacer()
                        TextField(
                            KeychainHelper.localizedDefaultHomeName,
                            text: Binding(
                                get: { store.homeName },
                                set: { store.homeName = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 170)
                    }

                    Divider().overlay(Color.primary.opacity(0.06))

                    HStack {
                        Text(L10n.tr("菜单栏旁显示", "Menu Bar Readout"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { store.menuBarTargetId },
                                set: { store.menuBarTargetId = $0 }
                            )
                        ) {
                            ForEach(store.availableMenuBarOptions) { option in
                                Text(option.title).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 176)
                        .controlSize(.small)
                    }

                    Divider().overlay(Color.primary.opacity(0.06))

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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Text(L10n.tr("登录 Mac 时自动启动", "Launch at Login"))
                            .font(.system(size: 12))
                        Spacer()
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
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
                    .font(.system(size: 10))
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
                            .font(.system(size: 11.5, weight: .semibold))

                            Text(L10n.tr(
                                "守护提醒（设备长时间开启、电量过低）和错过的定时任务要靠系统通知提醒你。通知只在本机显示，不会上传任何内容；不发通知时 App 其它功能照常使用。",
                                "Safety alerts (a device left on too long, low battery) and missed timers are delivered as local macOS notifications. They stay on this Mac; the rest of the app works without them."
                            ))
                            .font(.system(size: 10.5))
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
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }

                AutomationSettingsSection(store: store)
                EnergySettingsSection(store: store)

                if !store.hiddenDevices.isEmpty {
                    SettingsSection(title: L10n.tr("已隐藏的设备 (\(store.hiddenDevices.count))", "Hidden Devices (\(store.hiddenDevices.count))")) {
                        ForEach(store.hiddenDevices) { dev in
                            HStack(spacing: 8) {
                                Image(systemName: dev.sfSymbolName)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dev.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                    Text(L10n.displayRoomName(dev.roomName))
                                        .font(.system(size: 10))
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
                            .font(.system(size: 10.5))
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
                            .font(.system(size: 11, weight: .medium))
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
            VStack(alignment: .leading, spacing: 11) {
                SettingsSection(title: L10n.tr("连接配置", "Connection")) {
                    HStack {
                        Text(store.homeBackend == .demo
                             ? L10n.tr("当前为演示模式", "Demo mode is active")
                             : L10n.tr("选择数据源", "Data source"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(connectionBadgeText)
                            .font(.system(size: 10.5, weight: .medium))
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
                    .controlSize(.small)

                    if store.homeBackend == .demo {
                        Text(L10n.tr(
                            "演示模式使用内置虚拟设备，完全离线。选择「米家云端直连」或「Home Assistant」即可切回真实账号。",
                            "Demo mode uses built-in virtual devices and never touches the network. Choose Xiaomi Cloud or Home Assistant to switch back."
                        ))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if store.homeBackend == .homeAssistant {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L10n.tr("服务器地址", "Server URL"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let firstHA = store.discoveredHAInstances.first {
                                    if HAWebSocketProvider.normalizeBaseURL(urlDraft) == firstHA.baseURL {
                                        Label(
                                            L10n.tr("局域网已识别 · \(firstHA.locationName)", "LAN Detected · \(firstHA.locationName)"),
                                            systemImage: "checkmark.seal.fill"
                                        )
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.green)
                                    } else {
                                        Button(L10n.tr("填入已发现：\(firstHA.hostAndPort)", "Use Found: \(firstHA.hostAndPort)")) {
                                            urlDraft = firstHA.baseURL
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            TextField("https://your-home.ui.nabu.casa", text: $urlDraft)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .font(.system(size: 11.5, design: .monospaced))
                            if let address = URL(string: HAWebSocketProvider.normalizeBaseURL(urlDraft)),
                               address.scheme == "http",
                               let host = address.host,
                               !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
                                Label(L10n.tr("令牌将以明文在网络上传输，建议使用 HTTPS 或 Nabu Casa 地址。", "Your token will travel unencrypted. Use HTTPS or a Nabu Casa address."), systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L10n.tr("长期访问令牌 (安全存入钥匙串)", "Long-Lived Access Token (Stored in Keychain)"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let secURL = URL(string: "\(HAWebSocketProvider.normalizeBaseURL(urlDraft))/profile/security") {
                                    Button(L10n.tr("打开网页取令牌", "Open Security Page")) {
                                        NSWorkspace.shared.open(secURL)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                }
                            }
                            SecureField(L10n.tr("粘贴 HA 长期访问令牌", "Paste HA Long-Lived Access Token"), text: $tokenDraft)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .font(.system(size: 11.5, design: .monospaced))
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
            VStack(alignment: .leading, spacing: 11) {
                AssistantSettingsSection(store: store)
            }
            .padding(14)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    let store: HomeStore
    @AppStorage(AppSkin.storageKey) private var skinRaw: String = AppSkin.classic.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage(AppSkin.climatePanelKey) private var climatePanelModule: Bool = true
    @AppStorage(PanelHeight.storageKey) private var panelHeightRaw: String = PanelHeight.standard.rawValue

    var body: some View {
        let _ = store.effectiveLanguage
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 11) {
                SettingsSection(title: L10n.tr("外观模式", "Appearance")) {
                    Picker("", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)

                    Text(L10n.tr(
                        "跟随系统时，霜白、晨光、柔雾、便当格在深色系统下分别改用夜航、霓虹夜、胶囊、液态玻璃的配色；经典皮肤始终使用系统材质。",
                        "Following the system, Frost, Dawn, Soft Mist and Bento switch to the Night Flight, Neon, Capsule and Liquid Glass palettes in dark mode. Classic always uses system materials."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: L10n.tr("面板皮肤", "Panel Skin")) {
                    SkinPickerGrid(selection: Binding(
                        get: { AppSkin(rawValue: skinRaw) ?? .classic },
                        set: { skinRaw = $0.rawValue }
                    ))

                    Text(L10n.tr(
                        "经典之外的皮肤还带有：房间滑块、卡片依次入场、在灯上左右拖动调亮度、按住「全关」0.6 秒确认。",
                        "Skins other than Classic add a sliding room pill, staggered tiles, drag across a light to dim, and hold-to-confirm All Off."
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: L10n.tr("面板布局", "Panel Layout")) {
                    HStack {
                        Text(L10n.tr("面板高度", "Panel Height"))
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $panelHeightRaw) {
                            ForEach(PanelHeight.allCases) { h in
                                Text(h.title).tag(h.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                        .controlSize(.small)
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
            VStack(alignment: .leading, spacing: 11) {
                SettingsSection(title: L10n.tr("诊断信息", "Diagnostics")) {
                    Text(L10n.tr(
                        "复制一段 Markdown 粘贴到 GitHub issue。内容只有版本、系统、后端、型号与未识别设备，不含设备 ID、令牌、服务器地址或账号信息。",
                        "Copies Markdown for a GitHub issue: versions, OS, backend, models and skipped devices only. No device IDs, tokens, server addresses or account information."
                    ))
                    .font(.system(size: 10.5))
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
                                .font(.system(size: 10.5, weight: .medium))
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
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        if let scannedAt = scanner.lastScannedAt, !scanner.isScanning {
                            Text(L10n.tr("上次扫描：\(scannedAt.formatted(date: .abbreviated, time: .shortened))", "Last scan: \(scannedAt.formatted(date: .abbreviated, time: .shortened))"))
                                .font(.system(size: 10))
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
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !scanner.isScanning && scanner.lastScannedAt != nil && scanner.devices.isEmpty && scanner.errorMessage == nil {
                        Label(L10n.tr("没有发现被跳过的设备", "No skipped devices found"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.green)
                    }

                    ForEach(scanner.devices) { device in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "questionmark.square.dashed")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                Text("\(device.model.isEmpty ? L10n.tr("未知型号", "Unknown model") : device.model) · \(device.reasonText)")
                                    .font(.system(size: 10))
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
                                    .font(.system(size: 10.5, weight: .medium))
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
                .font(.system(size: 10))
                .foregroundStyle(.green)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 10.5))
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
                L10n.tr("皮肤", "Skin") + ": " + (AppSkin(rawValue: UserDefaults.standard.string(forKey: AppSkin.storageKey) ?? "") ?? .classic).title,
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
            VStack(alignment: .leading, spacing: 11) {
                SettingsSection(title: L10n.tr("关于 MenuBarMijia", "About MenuBarMijia")) {
                    HStack(spacing: 10) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                LinearGradient(
                                    colors: [Color.orange, Color(red: 0.92, green: 0.38, blue: 0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("MenuBarMijia")
                                .font(.system(size: 13, weight: .bold))
                            Text(L10n.tr("版本 \(appVersion) (\(buildNumber))", "Version \(appVersion) (\(buildNumber))"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Spacer()

                        if store.homeBackend == .demo {
                            Text(L10n.tr("演示模式", "Demo Mode"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack(spacing: 8) {
                        Link(L10n.tr("项目主页", "Repository"), destination: URL(string: "https://github.com/jryang1997/MenuBarMijia")!)
                        Link(L10n.tr("问题反馈", "Issues"), destination: URL(string: "https://github.com/jryang1997/MenuBarMijia/issues")!)
                        Link(L10n.tr("更新日志", "Releases"), destination: URL(string: "https://github.com/jryang1997/MenuBarMijia/releases")!)
                        Spacer()
                    }
                    .font(.system(size: 11, weight: .medium))
                }

                UpdateSection(store: store)

                SettingsSection(title: L10n.tr("退出", "Quit")) {
                    HStack {
                        Text(L10n.tr("完全退出后菜单栏图标与快捷键都会停止。", "Quitting stops the menu bar icon and the global shortcut."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "power")
                                Text(L10n.tr("退出 MenuBarMijia", "Quit MenuBarMijia"))
                            }
                            .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isPaired ? .green : (isEnabled ? .orange : .secondary))
            }

            HStack {
                Text(L10n.tr("启用 LG 电视局域网直连 (SSAP + WoL)", "Enable LG TV LAN Control (SSAP + WoL)"))
                    .font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField(L10n.tr("如 192.168.1.50", "e.g. 192.168.1.50"), text: $hostDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("MAC 地址 (Wake-on-LAN)", "MAC Address (Wake-on-LAN)"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField(L10n.tr("如 AA:BB:CC:DD:EE:FF", "e.g. AA:BB:CC:DD:EE:FF"), text: $macDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))
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
