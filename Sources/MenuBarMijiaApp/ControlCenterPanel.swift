import SwiftUI
import MijiaCore

public struct ControlCenterPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    public let store: HomeStore

    public init(store: HomeStore) {
        self.store = store
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            if store.isShowingSettings {
                SettingsSheetView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                mainDashboard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            overlayNotifications
        }
        .frame(width: 356, height: 460)
        .background(.ultraThinMaterial)
    }

    // MARK: - Main Dashboard

    private var mainDashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            topHeroHeader
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if store.isShowingAssistantBar {
                AssistantCommandBar(store: store)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(AppleMotion.drawerTransition)
            }

            if store.showQuickActionsBar {
                quickActionsAndScenesBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            roomFilterBar
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            ScrollView(.vertical, showsIndicators: false) {
                let quickIndexMap = Dictionary(
                    uniqueKeysWithValues: store.orderedVisibleDevices.prefix(9).enumerated().map { ($1.id, $0 + 1) }
                )

                VStack(alignment: .leading, spacing: 11) {
                    if store.filteredDevices.isEmpty {
                        emptyStateView
                    } else if store.selectedRoomId == nil {
                        if !store.favoriteDevices.isEmpty {
                            sectionHeader("常用控制", count: store.favoriteDevices.count)
                            deviceCollectionView(
                                devices: store.favoriteDevices,
                                showRoomBadge: true,
                                quickIndexMap: quickIndexMap
                            )
                        }

                        if !store.nonFavoriteDevices.isEmpty {
                            sectionHeader(
                                store.favoriteDevices.isEmpty ? "全屋设备" : "更多设备",
                                count: store.nonFavoriteDevices.count
                            )
                            deviceCollectionView(
                                devices: store.nonFavoriteDevices,
                                showRoomBadge: true,
                                quickIndexMap: quickIndexMap
                            )
                        }
                    } else {
                        deviceCollectionView(
                            devices: store.filteredDevices,
                            showRoomBadge: false,
                            quickIndexMap: quickIndexMap
                        )
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, 10)
                .padding(.bottom, store.undoBanner != nil || store.toastNotice != nil ? 48 : 12)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            footerBar
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .animation(AppleMotion.snappySpring, value: store.isShowingAssistantBar)
    }

    // MARK: - Adaptive Single-Column / 2-Column CompactTile Collection

    private enum DeviceRowItem: Identifiable {
        case single(SmartDevice)
        case pair(SmartDevice, SmartDevice?)

        var id: String {
            switch self {
            case .single(let d): return "single_\(d.id)"
            case .pair(let a, let b): return "pair_\(a.id)_\(b?.id ?? "none")"
            }
        }
    }

    private func buildRows(from devices: [SmartDevice]) -> [DeviceRowItem] {
        guard store.isCompactGridMode else {
            return devices.map { .single($0) }
        }
        var rows: [DeviceRowItem] = []
        var buffer: SmartDevice?

        for dev in devices {
            if store.expandedDeviceId == dev.id {
                if let pending = buffer {
                    rows.append(.pair(pending, nil))
                    buffer = nil
                }
                rows.append(.single(dev))
            } else if let pending = buffer {
                rows.append(.pair(pending, dev))
                buffer = nil
            } else {
                buffer = dev
            }
        }
        if let pending = buffer {
            rows.append(.pair(pending, nil))
        }
        return rows
    }

    @ViewBuilder
    private func deviceCollectionView(
        devices: [SmartDevice],
        showRoomBadge: Bool,
        quickIndexMap: [String: Int]
    ) -> some View {
        let rows = buildRows(from: devices)
        VStack(spacing: 7) {
            ForEach(rows) { row in
                switch row {
                case .single(let dev):
                    DeviceCardView(
                        device: dev,
                        store: store,
                        showRoomBadge: showRoomBadge,
                        isCompactTile: false,
                        quickIndex: quickIndexMap[dev.id]
                    )
                case .pair(let left, let right):
                    HStack(spacing: 7) {
                        DeviceCardView(
                            device: left,
                            store: store,
                            showRoomBadge: showRoomBadge,
                            isCompactTile: true,
                            quickIndex: quickIndexMap[left.id]
                        )
                        .frame(maxWidth: .infinity)

                        if let right {
                            DeviceCardView(
                                device: right,
                                store: store,
                                showRoomBadge: showRoomBadge,
                                isCompactTile: true,
                                quickIndex: quickIndexMap[right.id]
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 1. Hero Header & Live Environment Chips

    private var topHeroHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: store.activeDeviceCount > 0 ? "house.fill" : "house")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(
                                store.activeDeviceCount > 0
                                    ? (colorScheme == .dark ? Color.orange : Color(red: 0.86, green: 0.42, blue: 0.04))
                                    : Color.secondary
                            )

                        Text(store.homeName)
                            .font(.system(size: 15, weight: .bold))
                            .tracking(-0.2)
                    }

                    Text(statusSummaryText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        store.presentAssistantBar(startVoice: true)
                    }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .frame(width: 26, height: 24)
                        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("语音指令：点击直接说话控制设备（快捷键 V）")

                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        if store.isShowingAssistantBar {
                            store.dismissAssistantBar()
                        } else {
                            store.presentAssistantBar()
                        }
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(store.isShowingAssistantBar ? Color.white : Color.primary.opacity(0.78))
                        .frame(width: 26, height: 24)
                        .background {
                            if store.isShowingAssistantBar {
                                Capsule(style: .continuous).fill(Color.accentColor)
                            }
                        }
                        .glassEffect(
                            store.isShowingAssistantBar
                                ? .regular.tint(.accentColor.opacity(0.45)).interactive()
                                : .regular.interactive(),
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("AI 指令：用一句话控制设备（快捷键 /）")

                if store.activeDeviceCount > 0 {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.turnAllOff()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "power")
                                .font(.system(size: 10.5, weight: .bold))
                            Text("全关 (\(store.activeDeviceCount))")
                                .font(.system(size: 11.5, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(
                        PillActionButtonStyle(
                            isSelected: true,
                            tintColor: Color(red: 0.90, green: 0.44, blue: 0.08)
                        )
                    )
                }
            }

            if !store.environmentReadings.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(store.environmentReadings) { env in
                                environmentChip(env)
                            }
                            if store.totalPowerWatts >= 1 {
                                powerChip(watts: store.totalPowerWatts)
                            }
                        }
                    }
                }
            }
        }
    }

    private func powerChip(watts: Double) -> some View {
        let capsule = Capsule(style: .continuous)
        return HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.green : Color(red: 0.08, green: 0.54, blue: 0.22))

            Text(String(format: "%.0fW", watts))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .glassEffect(.regular, in: capsule)
        .overlay(
            capsule
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.48), lineWidth: 0.7)
        )
    }

    private func environmentChip(_ env: EnvironmentReading) -> some View {
        let capsule = Capsule(style: .continuous)
        return HStack(spacing: 5) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.teal : Color(red: 0.04, green: 0.48, blue: 0.52))

            Text(env.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))

            if let t = env.temperature {
                Text(String(format: "%.1f°", t))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }

            if let h = env.humidity {
                Text(String(format: "· %.0f%%", h))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.68))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 9.5)
        .padding(.vertical, 4.5)
        .glassEffect(.regular, in: capsule)
        .overlay(
            capsule
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.48), lineWidth: 0.7)
        )
    }

    private var statusSummaryText: String {
        if store.activeDeviceCount > 0 {
            return "\(store.activeDeviceCount) 台设备开启中 · 共 \(store.onlineDeviceCount) 台在线"
        }
        return "全屋设备待机 · \(store.onlineDeviceCount) 台实时在线"
    }

    // MARK: - 1B. Quick Actions & HA Scenes Strip

    private var quickActionsAndScenesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(QuickAction.allCases) { action in
                        Button {
                            withAnimation(AppleMotion.snappySpring) {
                                store.executeQuickAction(action)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: action.sfSymbolName)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(
                                        colorScheme == .dark
                                            ? Color.orange
                                            : Color(red: 0.82, green: 0.38, blue: 0.04)
                                    )
                                Text(action.title)
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .buttonStyle(PillActionButtonStyle())
                    }

                    if !store.scenes.isEmpty {
                        Divider()
                            .frame(height: 14)
                            .padding(.horizontal, 2)

                        ForEach(store.scenes) { scene in
                            Button {
                                withAnimation(AppleMotion.snappySpring) {
                                    store.triggerScene(scene)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: scene.iconName)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text(scene.name)
                                        .font(.system(size: 11, weight: .medium))
                                }
                            }
                            .buttonStyle(PillActionButtonStyle())
                        }
                    }
                }
            }
        }
    }

    // MARK: - 2. Room Filter Strip & Grid Toggle

    private var roomFilterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 5) {
                    HStack(spacing: 5) {
                        roomPill(title: "全部", roomId: nil)

                        ForEach(store.rooms) { room in
                            roomPill(title: room.name, roomId: room.id)
                        }
                    }
                    .padding(.trailing, 10)
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 0.91),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            GlassEffectContainer(spacing: 5) {
                HStack(spacing: 5) {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.isCompactGridMode.toggle()
                        }
                    } label: {
                        Image(systemName: store.isCompactGridMode ? "rectangle.grid.2x2.fill" : "rectangle.grid.1x2.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(store.isCompactGridMode ? Color.white : Color.primary.opacity(0.78))
                            .frame(width: 26, height: 24)
                            .background {
                                if store.isCompactGridMode {
                                    Capsule(style: .continuous).fill(Color.accentColor)
                                }
                            }
                            .glassEffect(
                                store.isCompactGridMode
                                    ? .regular.tint(.accentColor.opacity(0.45)).interactive()
                                    : .regular.interactive(),
                                in: Capsule(style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(store.isCompactGridMode ? "当前：双列紧凑磁贴（点击切换单列）" : "点击切换双列紧凑磁贴视图")

                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.hideOfflineDevices.toggle()
                        }
                    } label: {
                        Image(systemName: store.hideOfflineDevices ? "wifi" : "wifi.slash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(store.hideOfflineDevices ? Color.white : Color.primary.opacity(0.78))
                            .frame(width: 26, height: 24)
                            .background {
                                if store.hideOfflineDevices {
                                    Capsule(style: .continuous).fill(Color.accentColor)
                                }
                            }
                            .glassEffect(
                                store.hideOfflineDevices
                                    ? .regular.tint(.accentColor.opacity(0.45)).interactive()
                                    : .regular.interactive(),
                                in: Capsule(style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(store.hideOfflineDevices ? "当前只显示在线设备（点击显示全部）" : "点击隐藏未通电/离线设备")
                }
            }
        }
    }

    private func roomPill(title: String, roomId: String?) -> some View {
        let isSelected = (store.selectedRoomId == roomId)
        return Button(title) {
            withAnimation(AppleMotion.snappySpring) {
                store.selectedRoomId = roomId
            }
        }
        .buttonStyle(PillActionButtonStyle(isSelected: isSelected, tintColor: .accentColor))
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.80))
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 3)
        .padding(.bottom, -3)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            if case .disconnected = store.connectionStatus {
                Text("尚未连接到 Home Assistant")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("点击下方按钮配置你的服务器地址与访问令牌")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("前往连接配置") {
                    withAnimation(AppleMotion.snappySpring) {
                        store.isShowingSettings = true
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                .padding(.top, 2)
            } else {
                Text(store.hideOfflineDevices ? "该房间暂无通电在线的设备" : "正在同步设备列表…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if store.hideOfflineDevices {
                    Button("显示离线设备") {
                        withAnimation(AppleMotion.snappySpring) {
                            store.hideOfflineDevices = false
                        }
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - 3. Floating Undo & Toast Banner

    @ViewBuilder
    private var overlayNotifications: some View {
        if let banner = store.undoBanner {
            let bannerShape = RoundedRectangle(cornerRadius: 13, style: .continuous)
            HStack(spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))

                Text(banner.title)
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                Button("撤销") {
                    withAnimation(AppleMotion.snappySpring) {
                        store.undoTurnAllOff()
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: Color(red: 0.90, green: 0.44, blue: 0.08)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: bannerShape)
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 14)
            .padding(.bottom, 42)
            .transition(AppleMotion.drawerTransition)
        } else if let toast = store.toastNotice {
            let toastShape = Capsule(style: .continuous)
            HStack(spacing: 6) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? .orange : .green)
                    .font(.system(size: 11.5))

                Text(toast.message)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: toastShape)
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
            .padding(.bottom, 42)
            .transition(AppleMotion.drawerTransition)
        }
    }

    // MARK: - 4. Footer Status Bar

    private var footerBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)

            Text(statusFooterLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("立即同步最新状态")

            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.isShowingSettings = true
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("偏好设置与连接配置")
        }
    }

    private var statusDotColor: Color {
        switch store.connectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }

    private var statusFooterLabel: String {
        switch store.connectionStatus {
        case .connected:
            if store.homeBackend == .xiaomiCloud {
                return "\(store.serverHostSummary) · Miot 直连"
            }
            return "HA 实时连接 (\(store.serverHostSummary))"
        case .connecting:
            return "正在连接 (\(store.serverHostSummary))…"
        case .disconnected(let reason):
            return "未连接：\(reason)"
        }
    }
}
