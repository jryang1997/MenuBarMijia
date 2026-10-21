import SwiftUI
import AppKit
import ServiceManagement
import MijiaCore

public struct SettingsSheetView: View {
    public let store: HomeStore

    @State private var urlDraft: String = ""
    @State private var tokenDraft: String = ""
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    public init(store: HomeStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned Header
            HStack {
                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        store.isShowingSettings = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("返回面板")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(PillActionButtonStyle())

                Spacer()

                Text("偏好设置")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        store.reopenOnboarding()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                        Text("新手引导")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(PillActionButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            // Scrollable Settings Body
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 11) {
                    // 1. Menu Bar & Interface Options
                    VStack(alignment: .leading, spacing: 10) {
                        Text("菜单栏与交互体验")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("面板标题")
                                .font(.system(size: 12))
                            Spacer()
                            TextField(
                                "我的家",
                                text: Binding(
                                    get: { store.homeName },
                                    set: { store.homeName = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 140)
                        }

                        Divider().overlay(Color.primary.opacity(0.06))

                        HStack {
                            Text("菜单栏旁显示")
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

                        settingsToggleRow(
                            title: "显示顶部快捷场景栏",
                            isOn: Binding(
                                get: { store.showQuickActionsBar },
                                set: { store.showQuickActionsBar = $0 }
                            )
                        )

                        settingsToggleRow(
                            title: "双列紧凑磁贴视图",
                            isOn: Binding(
                                get: { store.isCompactGridMode },
                                set: { store.isCompactGridMode = $0 }
                            )
                        )

                        settingsToggleRow(
                            title: "全局快捷键 ⌥M 呼出面板",
                            isOn: Binding(
                                get: { store.enableGlobalHotkey },
                                set: { store.enableGlobalHotkey = $0 }
                            )
                        )

                        settingsToggleRow(
                            title: "主动安全与低电量提醒",
                            isOn: Binding(
                                get: { store.enableSafetyAlerts },
                                set: { store.enableSafetyAlerts = $0 }
                            )
                        )

                        settingsToggleRow(
                            title: "隐藏离线/未通电的设备",
                            isOn: Binding(
                                get: { store.hideOfflineDevices },
                                set: { store.hideOfflineDevices = $0 }
                            )
                        )

                        HStack {
                            Text("登录 Mac 时自动启动")
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
                                        store.showToast("开机自启需要在应用程序目录运行", isError: true)
                                    }
                                }
                        }
                    }
                    .padding(12)
                    .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)

                    // 2. Hidden Devices Management (if any)
                    if !store.hiddenDevices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("已隐藏的设备 (\(store.hiddenDevices.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(store.hiddenDevices) { dev in
                                HStack(spacing: 8) {
                                    Image(systemName: dev.sfSymbolName)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(dev.name)
                                            .font(.system(size: 11.5, weight: .medium))
                                        Text(dev.roomName)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button("恢复显示") {
                                        withAnimation(AppleMotion.snappySpring) {
                                            store.unhideDevice(dev.id)
                                        }
                                    }
                                    .buttonStyle(PillActionButtonStyle())
                                }
                            }
                        }
                        .padding(12)
                        .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)
                    }

                    // 3. Connection Configuration (Home Assistant / Xiaomi Cloud)
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("连接配置")
                                .font(.system(size: 11, weight: .semibold))
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

                        if store.homeBackend == .homeAssistant {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("服务器地址")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let firstHA = store.discoveredHAInstances.first {
                                        if HAWebSocketProvider.normalizeBaseURL(urlDraft) == firstHA.baseURL {
                                            Label("局域网已识别 · \(firstHA.locationName)", systemImage: "checkmark.seal.fill")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.green)
                                        } else {
                                            Button("填入已发现：\(firstHA.hostAndPort)") {
                                                urlDraft = firstHA.baseURL
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                TextField("http://homeassistant.local:8123", text: $urlDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("长期访问令牌 (安全存入钥匙串)")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let secURL = URL(string: "\(HAWebSocketProvider.normalizeBaseURL(urlDraft))/profile/security") {
                                        Button("打开网页取令牌") {
                                            NSWorkspace.shared.open(secURL)
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                    }
                                }
                                SecureField("粘贴 HA 长期访问令牌", text: $tokenDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }

                            HStack {
                                Button(store.isDiscoveringHA ? "扫描中…" : "扫描局域网 HA") {
                                    Task {
                                        let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
                                        if let first = found.first {
                                            urlDraft = first.baseURL
                                            store.applyDiscoveredHAInstance(first, reconnectProvider: false)
                                            store.showToast("已发现：\(first.displaySummary)")
                                        } else {
                                            store.showToast("未在局域网扫描到 Home Assistant", isError: true)
                                        }
                                    }
                                }
                                .buttonStyle(PillActionButtonStyle())
                                .disabled(store.isDiscoveringHA)

                                Button("默认地址") {
                                    urlDraft = KeychainHelper.defaultNASURL
                                }
                                .buttonStyle(PillActionButtonStyle())

                                Spacer()

                                Button("保存并重新连接") {
                                    store.updateConnection(serverURL: urlDraft, token: tokenDraft)
                                    withAnimation(AppleMotion.snappySpring) {
                                        store.isShowingSettings = false
                                    }
                                }
                                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                            }
                            .padding(.top, 2)
                        } else {
                            MiAccountSection(store: store)
                        }
                    }
                    .padding(12)
                    .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)

                    LGWebOSSettingsSection(store: store)

                    AssistantSettingsSection(store: store)

                    UpdateSection(store: store)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            // Pinned Bottom Quit Row
            HStack {
                Text("\(store.homeName) · 在线 \(store.onlineDeviceCount)/\(store.devices.count) 台")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("退出 MenuBarMijia")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
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

    private func settingsToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var connectionBadgeText: String {
        switch store.connectionStatus {
        case .connected: return "● 已连接"
        case .connecting: return "● 连接中…"
        case .disconnected: return "● 未连接"
        }
    }

    private var connectionBadgeColor: Color {
        switch store.connectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }
}

private struct LGWebOSSettingsSection: View {
    let store: HomeStore
    @State private var isEnabled: Bool = false
    @State private var hostDraft: String = ""
    @State private var macDraft: String = ""
    @State private var nameDraft: String = ""
    @State private var isScanning: Bool = false

    var body: some View {
        let isPaired = !store.lgConfig.clientKey.isEmpty
        let hasHost = !hostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("LG webOS 电视局域网直连")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isPaired ? "● 已配对密钥" : (isEnabled ? (hasHost ? "● 待电视确认" : "● 待填电视 IP") : "● 已停用"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isPaired ? .green : (isEnabled ? .orange : .secondary))
            }

            HStack {
                Text("启用 LG 电视局域网直连 (SSAP + WoL)")
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
                        Text("局域网 IP")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("如 192.168.1.50", text: $hostDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("MAC 地址 (Wake-on-LAN)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("如 AA:BB:CC:DD:EE:FF", text: $macDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }

                HStack {
                    Button(isScanning ? "扫描中…" : "扫描局域网电视") {
                        isScanning = true
                        Task {
                            let found = await store.discoverLGWebOSTVs(hostHint: hostDraft)
                            isScanning = false
                            if let first = found.first {
                                hostDraft = first.host
                                store.showToast("已发现：\(first.friendlyName) (\(first.host))")
                            } else {
                                store.showToast("未扫描到开机状态的 LG 电视", isError: true)
                            }
                        }
                    }
                    .buttonStyle(PillActionButtonStyle())
                    .disabled(isScanning)

                    Button("发起电视配对") {
                        saveDrafts()
                        store.triggerLGWebOSPairing()
                    }
                    .buttonStyle(PillActionButtonStyle())

                    Spacer()

                    Button("保存配置") {
                        saveDrafts()
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                }
            }
        }
        .padding(12)
        .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)
        .onAppear {
            isEnabled = store.lgConfig.isEnabled
            hostDraft = store.lgConfig.host
            macDraft = store.lgConfig.macAddress
            nameDraft = store.lgConfig.name
        }
    }

    private func saveDrafts() {
        var next = store.lgConfig
        next.isEnabled = isEnabled
        next.host = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        next.macAddress = macDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next.name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        store.updateLGWebOSConfig(next)
    }
}

