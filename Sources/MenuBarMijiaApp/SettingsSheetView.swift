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
                    if let url = URL(string: store.serverURLString) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("HA 网页")
                        Image(systemName: "arrow.up.right.square")
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
                                Text("服务器地址")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                TextField("http://homeassistant.local:8123", text: $urlDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("长期访问令牌 (安全存入钥匙串)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                SecureField("粘贴 HA 长期访问令牌", text: $tokenDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }

                            HStack {
                                Button("恢复默认地址") {
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
                        Text("退出 MenuMijia")
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
