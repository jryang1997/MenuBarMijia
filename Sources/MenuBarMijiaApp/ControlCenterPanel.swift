import SwiftUI
import MijiaCore

public struct ControlCenterPanel: View {
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
                .padding(.top, 13)
                .padding(.bottom, 10)

            roomFilterBar
                .padding(.horizontal, 14)
                .padding(.bottom, 9)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 11) {
                    if store.filteredDevices.isEmpty {
                        emptyStateView
                    } else if store.selectedRoomId == nil {
                        if !store.favoriteDevices.isEmpty {
                            sectionHeader("常用控制", count: store.favoriteDevices.count)
                            VStack(spacing: 7) {
                                ForEach(store.favoriteDevices) { dev in
                                    DeviceCardView(device: dev, store: store, showRoomBadge: true)
                                }
                            }
                        }

                        if !store.nonFavoriteDevices.isEmpty {
                            sectionHeader(
                                store.favoriteDevices.isEmpty ? "全屋设备" : "更多设备",
                                count: store.nonFavoriteDevices.count
                            )
                            VStack(spacing: 7) {
                                ForEach(store.nonFavoriteDevices) { dev in
                                    DeviceCardView(device: dev, store: store, showRoomBadge: true)
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 7) {
                            ForEach(store.filteredDevices) { dev in
                                DeviceCardView(device: dev, store: store, showRoomBadge: false)
                            }
                        }
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
    }

    // MARK: - 1. Hero Header & Live Environment Chips

    private var topHeroHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: store.activeDeviceCount > 0 ? "house.fill" : "house")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(store.activeDeviceCount > 0 ? Color.orange : Color.secondary)

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
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.orange.opacity(0.14))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.8)
                                )
                        )
                    }
                    .buttonStyle(PressableCardButtonStyle())
                }
            }

            if !store.environmentReadings.isEmpty {
                HStack(spacing: 7) {
                    ForEach(store.environmentReadings) { env in
                        environmentChip(env)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func environmentChip(_ env: EnvironmentReading) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.teal)

            Text(env.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))

            if let t = env.temperature {
                Text(String(format: "%.1f°", t))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            if let h = env.humidity {
                Text(String(format: "· %.0f%%", h))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
                )
        )
    }

    private var statusSummaryText: String {
        if store.activeDeviceCount > 0 {
            return "\(store.activeDeviceCount) 台设备开启中 · 共 \(store.onlineDeviceCount) 台在线"
        }
        return "全屋设备待机 · \(store.onlineDeviceCount) 台实时在线"
    }

    // MARK: - 2. Room Filter Strip

    private var roomFilterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    roomPill(title: "全部", roomId: nil)

                    ForEach(store.rooms) { room in
                        roomPill(title: room.name, roomId: room.id)
                    }
                }
            }

            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.hideOfflineDevices.toggle()
                }
            } label: {
                Image(systemName: store.hideOfflineDevices ? "wifi" : "wifi.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.hideOfflineDevices ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 24)
                    .background(
                        Capsule(style: .continuous)
                            .fill(store.hideOfflineDevices ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help(store.hideOfflineDevices ? "当前只显示在线设备（点击显示全部）" : "点击隐藏未通电/离线设备")
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
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.75))
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
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 42)
            .transition(AppleMotion.drawerTransition)
        } else if let toast = store.toastNotice {
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
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
            )
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
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
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
            return "HA 实时连接 (\(store.serverHostSummary))"
        case .connecting:
            return "正在连接 (\(store.serverHostSummary))…"
        case .disconnected(let reason):
            return "未连接：\(reason)"
        }
    }
}
