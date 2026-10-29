import SwiftUI
import MijiaCore

public struct DeviceCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appSkin) private var skin
    @Environment(\.skinPalette) private var palette
    @Environment(\.isEditingLayout) private var isEditingLayout
    @AppStorage(AppSkin.climatePanelKey) private var climatePanelModule: Bool = true
    @AppStorage(DeviceLayoutPrefs.storageKey) private var tileSizesRaw: String = "{}"
    @AppStorage(GroupPrefs.groupsKey) private var groupsRaw: String = "[]"
    @AppStorage(GroupPrefs.mapKey) private var groupMapRaw: String = "{}"
    /// Observed so a temperature-unit change in Settings re-renders open cards (#52).
    @AppStorage(TemperatureUnitPreference.storageKey) private var temperatureUnitRaw = TemperatureUnitPreference.system.rawValue

    public let device: SmartDevice
    public let store: HomeStore
    public let showRoomBadge: Bool
    public let isCompactTile: Bool
    public let quickIndex: Int?
    public let isBentoTile: Bool

    @State private var isHovered: Bool = false
    @State private var speakerInputText: String = ""
    @State private var dragBrightness: Double?
    @State private var cardWidth: CGFloat = 1

    public init(
        device: SmartDevice,
        store: HomeStore,
        showRoomBadge: Bool = false,
        isCompactTile: Bool = false,
        quickIndex: Int? = nil,
        isBentoTile: Bool = false
    ) {
        self.isBentoTile = isBentoTile
        self.device = device
        self.store = store
        self.showRoomBadge = showRoomBadge
        self.isCompactTile = isCompactTile
        self.quickIndex = quickIndex
    }

    private var layoutScope: String { store.selectedRoomId ?? "all" }

    private var chosenSize: TileSize { DeviceLayoutPrefs.cachedSize(raw: tileSizesRaw, id: device.id, scope: layoutScope) }

    private var resolvedSize: TileSize {
        DeviceLayoutPrefs.resolved(chosenSize, device: device, compactGrid: store.isCompactGridMode, climatePanel: climatePanelModule)
    }

    private func setSize(_ size: TileSize) {
        var sizes = DeviceLayoutPrefs.decode(tileSizesRaw)
        sizes[DeviceLayoutPrefs.scopedKey(id: device.id, scope: layoutScope)] = size
        withAnimation(AppleMotion.snappySpring) { tileSizesRaw = DeviceLayoutPrefs.encode(sizes) }
    }

    private func assignGroup(_ groupId: String?) {
        var map = GroupPrefs.map(groupMapRaw)
        map[device.id] = groupId
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { groupMapRaw = GroupPrefs.encode(map) }
    }

    private var isExpanded: Bool {
        if resolvedSize == .panel { return true }
        return store.expandedDeviceId == device.id
    }

    private var isFavorite: Bool {
        store.favoriteDeviceIds.contains(device.id)
    }

    private var isKeyboardFocused: Bool {
        store.focusedDeviceId == device.id
    }

    private var shouldShowQuickBadge: Bool {
        quickIndex != nil && (store.isOptionKeyPressed || store.focusedDeviceId != nil)
    }

    private var accent: Color {
        skin.isClassic ? DevicePalette.accentColor(for: device) : palette.accent
    }

    private var statusColor: Color {
        guard !skin.isClassic else { return DevicePalette.statusTextColor(for: device, colorScheme: colorScheme) }
        if skin == .glass || skin == .capsule {
            return device.isOnline && device.isActiveOn ? palette.activeText.opacity(0.7) : palette.muted
        }
        return palette.muted
    }

    private var nameColor: Color {
        guard !skin.isClassic else { return .primary }
        return device.isActiveOn && device.isOnline && (skin == .glass || skin == .capsule) ? palette.activeText : palette.fg
    }

    private var nameGlow: Color {
        guard palette.glow, device.isActiveOn, device.isOnline else { return .clear }
        return palette.accent.opacity(0.85)
    }

    /// One spoken sentence for the whole card: name, power state and the detail subtitle (#41).
    private var accessibilitySummary: String {
        guard device.isOnline else {
            return L10n.tr("\(device.name)，离线", "\(device.name), offline")
        }
        let state = device.isActiveOn ? L10n.tr("已开启", "on") : L10n.tr("已关闭", "off")
        let subtitle = device.statusSubtitle
        let off = L10n.tr("已关闭", "Off")
        let on = L10n.tr("已开启", "On")
        if subtitle == off || subtitle == on || subtitle.isEmpty {
            return L10n.tr("\(device.name)，\(state)", "\(device.name), \(state)")
        }
        return L10n.tr("\(device.name)，\(state)，\(subtitle)", "\(device.name), \(state), \(subtitle)")
    }

    /// Current brightness 0...1 for lights (live while dragging), nil for other kinds.
    private var lightLevel: Double? {
        guard case .light(let spec) = device.kind else { return nil }
        if let dragBrightness { return dragBrightness }
        guard spec.isOn else { return 0 }
        return Double(spec.brightnessPercent ?? 100) / 100
    }

    private var favoriteStarColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.82, blue: 0.24)
            : Color(red: 0.90, green: 0.56, blue: 0.02)
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        if !isCompactTile, resolvedSize != .half, case .climate(let spec) = device.kind,
           climatePanelModule || chosenSize != .auto {
            ClimatePanelModule(device: device, spec: spec, store: store, showRoomBadge: showRoomBadge, forceExpanded: resolvedSize == .panel)
                .contextMenu { contextMenuItems }
        } else if case .sensor(let spec) = device.kind, !isBentoTile {
            SensorCardView(device: device, spec: spec, isCompact: isCompactTile, showRoomBadge: showRoomBadge)
                .contextMenu { contextMenuItems }
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isBentoTile {
                bentoBody
            } else if isCompactTile {
                compactHeaderRow
                    .frame(minHeight: skin.isClassic ? 50 : 60, maxHeight: isExpanded ? nil : .infinity)
            } else {
                headerRow
                    .frame(maxHeight: isExpanded ? nil : .infinity)
            }

            if isExpanded && device.hasDetailDrawer {
                if skin == .capsule && device.isActiveOn && device.isOnline {
                    detailDrawer
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(palette.tile)
                        )
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .transition(AppleMotion.drawerTransition)
                } else {
                    Rectangle()
                        .fill(skin.isClassic ? Color.primary.opacity(0.08) : palette.line)
                        .frame(height: 1)
                        .padding(.horizontal, 12)

                    detailDrawer
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .transition(AppleMotion.drawerTransition)
                }
            }
        }
        .background(alignment: .leading) { brightnessFill }
        .glassTile(isActive: device.isActiveOn, accent: accent, cornerRadius: 14)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in cardWidth = w }
            }
        }
        .simultaneousGesture(dimGesture)
        .overlay(
            RoundedRectangle(cornerRadius: skin.isClassic ? 14 : (palette.capsuleTiles ? 26 : palette.tileRadius), style: .continuous)
                .strokeBorder(isKeyboardFocused ? accent.opacity(0.85) : Color.clear, lineWidth: 1.6)
        )
        .opacity(device.isOnline ? 1.0 : 0.58)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu { contextMenuItems }
    }

    // MARK: - Drag-to-Dim (skins only)

    /// Horizontal drag across a light card sets brightness; committed once on release.
    private var dimGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag in
                guard !skin.isClassic, !isEditingLayout, !isExpanded, device.isOnline, lightLevel != nil,
                      abs(drag.translation.width) > abs(drag.translation.height) else { return }
                dragBrightness = min(max(drag.location.x / max(cardWidth, 1), 0.01), 1)
            }
            .onEnded { _ in
                guard let level = dragBrightness else { return }
                store.setLightBrightness(device.id, percent: max(1, Int((level * 100).rounded())))
                withAnimation(.easeOut(duration: 0.3)) { dragBrightness = nil }
            }
    }

    @ViewBuilder
    private var brightnessFill: some View {
        if !skin.isClassic, !isExpanded, let level = lightLevel, level > 0 {
            GeometryReader { geo in
                Rectangle()
                    .fill(palette.fill)
                    .frame(width: geo.size.width * level)
                    .animation(dragBrightness == nil ? .easeOut(duration: 0.3) : nil, value: level)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
            Menu {
                ForEach(TileSize.allCases) { size in
                    Button {
                        setSize(size)
                    } label: {
                        Label(size.title, systemImage: chosenSize == size ? "checkmark" : size.symbol)
                    }
                }
            } label: {
                Label(L10n.tr("卡片大小（本页）", "Card Size (this page)"), systemImage: "square.resize")
            }

            Button {
                LayoutUIState.shared.renamingDeviceId = device.id
            } label: {
                Label(L10n.tr("重命名…", "Rename…"), systemImage: "pencil")
            }

            Button {
                LayoutUIState.shared.isEditingLayoutRequested = true
            } label: {
                Label(L10n.tr("编辑布局…", "Edit Layout…"), systemImage: "rectangle.3.group")
            }

            Menu {
                let groups = GroupPrefs.groups(groupsRaw)
                let current = GroupPrefs.map(groupMapRaw)[device.id]
                ForEach(groups) { group in
                    Button {
                        assignGroup(group.id)
                    } label: {
                        Label(group.name, systemImage: current == group.id ? "checkmark" : "folder")
                    }
                }
                if current != nil {
                    Button {
                        assignGroup(nil)
                    } label: {
                        Label(L10n.tr("不分组", "No Group"), systemImage: "tray")
                    }
                }
                if !groups.isEmpty { Divider() }
                Button {
                    LayoutUIState.shared.newGroupForDevice = device.id
                } label: {
                    Label(L10n.tr("新建分组…", "New Group…"), systemImage: "folder.badge.plus")
                }
            } label: {
                Label(L10n.tr("移到分组", "Move to Group"), systemImage: "folder")
            }

            Divider()

            Button {
                store.toggleFavorite(device.id)
            } label: {
                Label(
                    isFavorite ? L10n.tr("取消常用星标", "Remove from Favorites") : L10n.tr("设为常用星标", "Add to Favorites"),
                    systemImage: isFavorite ? "star.slash" : "star.fill"
                )
            }

            if isFavorite {
                Button {
                    store.moveFavorite(deviceId: device.id, direction: -1)
                } label: {
                    Label(L10n.tr("常用排序上移", "Move Up in Favorites"), systemImage: "arrow.up")
                }

                Button {
                    store.moveFavorite(deviceId: device.id, direction: 1)
                } label: {
                    Label(L10n.tr("常用排序下移", "Move Down in Favorites"), systemImage: "arrow.down")
                }
            }

            if device.hasDetailDrawer {
                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        store.toggleExpanded(device.id)
                    }
                } label: {
                    Label(
                        isExpanded ? L10n.tr("收起详细控制", "Collapse Controls") : L10n.tr("展开详细控制", "Expand Controls"),
                        systemImage: "slider.horizontal.3"
                    )
                }
            }

            Button {
                store.setJoinsAllOff(!store.joinsAllOff(device), deviceId: device.id)
            } label: {
                if store.joinsAllOff(device) {
                    Label(L10n.tr("不参与「全关」", "Leave Out of All Off"), systemImage: "power.circle")
                } else {
                    Label(L10n.tr("参与「全关」", "Include in All Off"), systemImage: "power.circle.fill")
                }
            }

            Divider()

            Button(role: .destructive) {
                withAnimation(AppleMotion.snappySpring) {
                    store.hideDevice(device.id)
                }
            } label: {
                Label(L10n.tr("隐藏此设备", "Hide Device"), systemImage: "eye.slash")
            }
    }

    // MARK: - Bento Tile (icon on top, text below; tap toggles, chevron expands)

    private var bentoBody: some View {
        Button {
            withAnimation(AppleMotion.snappySpring) { _ = store.togglePrimary(device) }
            if device.isOnline { SoundFeedback.playSuccess() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    iconBadge
                    Spacer(minLength: 0)
                    if device.hasDetailDrawer {
                        Button {
                            withAnimation(AppleMotion.snappySpring) { store.toggleExpanded(device.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(statusColor)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(L10n.tr("更多 \(device.name) 操作", "More actions for \(device.name)")))
                    }
                }
                Spacer(minLength: 6)
                Text(device.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                Text(dragBrightness.map { L10n.tr("亮度 \(Int($0 * 100))%", "Brightness \(Int($0 * 100))%") } ?? device.statusSubtitle)
                    .font(.system(size: 11, weight: device.isActiveOn ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardButtonStyle(scaleAmount: 0.95))
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text(L10n.tr("切换开关", "Toggle power")))
    }

    // MARK: - Compact 2-Column Header (Left Icon Toggles, Right Area Expands)

    private var compactHeaderRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(AppleMotion.snappySpring) {
                    _ = store.togglePrimary(device)
                }
                if device.isOnline { SoundFeedback.playSuccess() }
            } label: {
                iconBadge
            }
            .buttonStyle(PressableCardButtonStyle())
            .accessibilityLabel(Text(L10n.tr("\(device.name) 开关", "\(device.name) power")))
            .skinHelp(L10n.tr("点击直接切换开关", "Click to toggle power"))

            Button {
                withAnimation(AppleMotion.snappySpring) {
                    if device.hasDetailDrawer {
                        store.toggleExpanded(device.id)
                    } else {
                        _ = store.togglePrimary(device)
                        if device.isOnline { SoundFeedback.playSuccess() }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: skin.isClassic ? 12 : 13.5, weight: .semibold))
                            .foregroundStyle(nameColor)
                            .shadowIf(nameGlow != .clear, color: nameGlow, radius: 6)
                            .lineLimit(1)

                        Text(dragBrightness.map { L10n.tr("亮度 \(Int($0 * 100))%", "Brightness \(Int($0 * 100))%") } ?? device.statusSubtitle)
                            .font(.system(size: skin.isClassic ? 10.5 : 11.5, weight: device.isActiveOn && skin.isClassic ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    if let quickIndex, shouldShowQuickBadge {
                        quickIndexPill(quickIndex)
                    } else if device.hasDetailDrawer && skin.isClassic {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(device.hasDetailDrawer
                ? L10n.tr("\(device.name)，详细控制", "\(device.name), controls")
                : accessibilitySummary))
            .skinHelp(device.hasDetailDrawer ? L10n.tr("点击展开详细控制", "Click to expand controls") : device.name)
        }
        .padding(.horizontal, skin.isClassic ? 9 : 11)
        .padding(.vertical, skin.isClassic ? 8.5 : 12)
    }

    // MARK: - Standard Single-Column Row (1-Click Toggle + Expand Trigger)

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(AppleMotion.snappySpring) {
                    _ = store.togglePrimary(device)
                }
                if device.isOnline { SoundFeedback.playSuccess() }
            } label: {
                HStack(spacing: 10) {
                    iconBadge

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 5) {
                            Text(device.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(nameColor)
                                .lineLimit(1)

                            if showRoomBadge {
                                Text(L10n.displayRoomName(device.roomName))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(nameColor.opacity(0.68))
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(nameColor.opacity(colorScheme == .dark ? 0.12 : 0.075))
                                            .overlay(
                                                Capsule(style: .continuous)
                                                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.36), lineWidth: 0.6)
                                            )
                                    )
                            }
                        }

                        Text(dragBrightness.map { L10n.tr("亮度 \(Int($0 * 100))%", "Brightness \(Int($0 * 100))%") } ?? device.statusSubtitle)
                            .font(.system(size: 11, weight: device.isActiveOn ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableCardButtonStyle())
            .accessibilityLabel(Text(accessibilitySummary))
            .accessibilityHint(Text(L10n.tr("切换开关", "Toggle power")))

            // Quick Index Pill + Favorite Star + Drawer Chevron
            HStack(spacing: 4) {
                if let quickIndex, shouldShowQuickBadge {
                    quickIndexPill(quickIndex)
                }

                if isHovered || isExpanded || isFavorite {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.toggleFavorite(device.id)
                        }
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(isFavorite ? favoriteStarColor : statusColor.opacity(0.75))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isFavorite
                        ? L10n.tr("取消常用星标 \(device.name)", "Remove \(device.name) from favorites")
                        : L10n.tr("设为常用星标 \(device.name)", "Add \(device.name) to favorites")))
                    .skinHelp(isFavorite ? L10n.tr("从常用中移除", "Remove from Favorites") : L10n.tr("加入常用", "Add to Favorites"))
                }

                if device.hasDetailDrawer {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.toggleExpanded(device.id)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(nameColor.opacity(0.68))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 24, height: 24)
                            .background {
                                if isExpanded {
                                    Circle()
                                        .fill(nameColor.opacity(0.08))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isExpanded
                        ? L10n.tr("收起 \(device.name) 详细控制", "Collapse \(device.name) controls")
                        : L10n.tr("展开 \(device.name) 详细控制", "Expand \(device.name) controls")))
                    .skinHelp(isExpanded ? L10n.tr("收起控制面板", "Collapse controls") : L10n.tr("展开详细控制", "Expand controls"))
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9.5)
    }

    private func quickIndexPill(_ index: Int) -> some View {
        Text("\(index)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }

    @ViewBuilder
    private var iconBadge: some View {
        if skin.isClassic {
            classicIconBadge
        } else {
            skinIconBadge
        }
    }

    private var skinIconBadge: some View {
        let p = palette
        let on = device.isActiveOn && device.isOnline
        let glow = lightLevel ?? (on ? 0.6 : 0)
        let lightOn = on && lightLevel != nil
        return ZStack {
            Circle()
                .fill(on ? (skin == .capsule && lightOn ? Color(red: 1, green: 0.84, blue: 0.04) : p.accent) : p.chip)
                .frame(width: 36, height: 36)
                .overlay {
                    if !on {
                        Circle()
                            .strokeBorder(p.neumorphic ? Color.white.opacity(0.65) : p.line.opacity(0.6), lineWidth: 0.7)
                    }
                }
                .shadowIf(on, color: p.accent.opacity(0.22 + glow * 0.35), radius: 3 + glow * 6)
            Image(systemName: resolvedSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? (skin == .capsule && lightOn ? Color(red: 0.23, green: 0.18, blue: 0) : p.onAccent) : p.muted)
                .rotationEffect(.degrees(on ? -8 : 0))
                .scaleEffect(on ? 1.06 : 1)
                .symbolEffect(.bounce, value: on)
        }
        .toggleRipple(isOn: on, color: p.accent)
        .animation(.spring(response: 0.45, dampingFraction: 0.55), value: on)
    }

    private var classicIconBadge: some View {
        ZStack {
            if device.isActiveOn {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.90),
                                accent
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 33, height: 33)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.58),
                                        Color.white.opacity(0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                    }
                    .shadow(color: accent.opacity(0.30), radius: 5, x: 0, y: 2)
            } else {
                Circle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
                    .frame(width: 33, height: 33)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.22 : 0.55),
                                        Color.primary.opacity(0.06)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.75
                            )
                    }
            }

            Image(systemName: resolvedSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    device.isActiveOn
                        ? Color.white
                        : (device.isOnline ? Color.primary.opacity(0.76) : Color.secondary)
                )
        }
    }

    private var resolvedSymbolName: String {
        if case .vacuum = device.kind {
            return "circle.dotted.circle.fill"
        }
        return device.sfSymbolName
    }

    // MARK: - Expandable Detail Drawer

    @ViewBuilder
    private var detailDrawer: some View {
        switch device.kind {
        case .light(let spec):
            lightDrawer(spec)
        case .climate(let spec):
            climateDrawer(spec)
        case .fan(let spec):
            fanDrawer(spec)
        case .plug(let spec):
            plugDrawer(spec)
        case .fridge(let spec):
            fridgeDrawer(spec)
        case .vacuum(let spec):
            vacuumDrawer(spec)
        case .speaker(let spec):
            speakerDrawer(spec)
        case .tv(let spec):
            tvDrawer(spec)
        case .sensor:
            EmptyView()
        }
    }

    // MARK: - 1. Light Detail Controls

    private func lightDrawer(_ spec: LightSpec) -> some View {
        let brightnessVal = Double(spec.brightnessPercent ?? (spec.isOn ? 80 : 0))
        let kelvinVal = Double(spec.colorTempKelvin ?? 4000)

        return VStack(alignment: .leading, spacing: 10) {
            // Liquid Glass Brightness Slider
            LiquidGlassSlider(
                value: Binding(
                    get: { brightnessVal },
                    set: { store.setLightBrightness(device.id, percent: Int($0.rounded())) }
                ),
                in: 1...100,
                step: 1,
                iconName: "sun.max.fill",
                iconColor: statusColor,
                trackFill: LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.72, blue: 0.18).opacity(0.62),
                        Color(red: 0.96, green: 0.56, blue: 0.06).opacity(0.92)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                formattedValue: "\(Int(brightnessVal))%"
            )
            .disabled(!device.isOnline)

            // Liquid Glass Color Temperature Slider (Physical Kelvin Spectrum)
            LiquidGlassSlider(
                value: Binding(
                    get: { kelvinVal },
                    set: { store.setLightColorTemp(device.id, kelvin: Int($0.rounded())) }
                ),
                in: Double(spec.minKelvin)...Double(spec.maxKelvin),
                step: 100,
                iconName: "thermometer.sun.fill",
                iconColor: Color.orange,
                trackFill: LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.62, blue: 0.16).opacity(0.85),
                        Color(red: 1.0, green: 0.90, blue: 0.74).opacity(0.80),
                        Color(red: 0.56, green: 0.82, blue: 1.0).opacity(0.88)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                isSpectrumTrack: true,
                formattedValue: "\(Int(kelvinVal))K"
            )
            .disabled(!device.isOnline)

            // Scene Effect Presets (Day / Night / TV / Hospitality)
            if !spec.availableEffects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    AdaptiveGlassContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(spec.availableEffects, id: \.self) { effect in
                                let selected = (spec.currentEffect == effect)
                                Button(SmartDevice.localizeEffect(effect)) {
                                    store.setLightEffect(device.id, effect: effect)
                                }
                                .buttonStyle(PillActionButtonStyle(isSelected: selected, tintColor: accent))
                                .disabled(!device.isOnline)
                            }
                        }
                    }
                    .padding(6)
                }
                .padding(-6)
            }
        }
    }

    // MARK: - 2. Climate (AC / Heater) Detail Controls

    private func climateDrawer(_ spec: ClimateSpec) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    store.stepClimateTemperature(device.id, delta: -L10n.celsiusStep(spec.step))
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 28)
                        .adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(PressableCardButtonStyle())
                .accessibilityLabel(Text(L10n.tr("降低目标温度", "Lower target temperature")))
                .disabled(!device.isOnline)

                Spacer()

                VStack(spacing: 1) {
                    Text(L10n.temperature(spec.targetTemperature))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if let cur = spec.currentTemperature {
                        Text(L10n.format("当前室温 %@", "Room %@", L10n.temperature(cur, fractionDigits: 1)))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("设定温度", "Target Temp"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    store.stepClimateTemperature(device.id, delta: L10n.celsiusStep(spec.step))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 28)
                        .adaptiveGlass(in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(PressableCardButtonStyle())
                .accessibilityLabel(Text(L10n.tr("升高目标温度", "Raise target temperature")))
                .disabled(!device.isOnline)
            }
            .padding(.horizontal, 8)

            // HVAC Modes
            ScrollView(.horizontal, showsIndicators: false) {
                AdaptiveGlassContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(spec.availableModes, id: \.self) { mode in
                            let selected = (spec.hvacMode == mode)
                            Button(SmartDevice.localizeHVACMode(mode)) {
                                store.setClimateMode(device.id, mode: mode)
                            }
                            .buttonStyle(PillActionButtonStyle(isSelected: selected, tintColor: accent))
                            .disabled(!device.isOnline)
                        }
                    }
                }
                .padding(6)
            }
            .padding(-6)
        }
    }

    // MARK: - 3. Fan Detail Controls

    private func fanDrawer(_ spec: FanSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !spec.availablePresetModes.isEmpty {
                AdaptiveGlassContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(spec.availablePresetModes, id: \.self) { mode in
                            let selected = (spec.presetMode == mode)
                            Button(mode) {
                                store.setFanPresetMode(device.id, preset: mode)
                            }
                            .buttonStyle(PillActionButtonStyle(isSelected: selected, tintColor: accent))
                            .disabled(!device.isOnline)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. Smart Plug (Coffee Machine) Controls

    private func plugDrawer(_ spec: PlugSpec) -> some View {
        let todayKwh = store.energyHistory.todayKwh(forDevice: device.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("实时功率", "Live Power"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f W", spec.powerWatts ?? 0))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                Divider().frame(height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("今日用电", "Today"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(todayKwh.map { String(format: "%.2f kWh", $0) } ?? "—")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                if let totalKwh = spec.energyKwh, totalKwh.isFinite, totalKwh >= 0 {
                    Divider().frame(height: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("累计电量", "Total"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f kWh", totalKwh))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }

                Spacer()

                if spec.childLockEntityId != nil {
                    Toggle(
                        L10n.tr("按键锁", "Child Lock"),
                        isOn: Binding(
                            get: { spec.isChildLocked },
                            set: { store.setPlugChildLock(device.id, locked: $0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11, weight: .medium))
                }
            }
        }
    }

    // MARK: - 5. Smart Refrigerator Controls

    private func fridgeDrawer(_ spec: FridgeSpec) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Fridge & Freezer Target Steppers
            HStack(spacing: 10) {
                fridgeZoneBox(
                    title: L10n.tr("冷藏室", "Fridge"),
                    actual: spec.fridgeCurrentTemp,
                    target: spec.fridgeTargetTemp,
                    onStep: { store.stepFridgeTargetTemp(device.id, isFreezer: false, delta: $0) }
                )

                fridgeZoneBox(
                    title: L10n.tr("冷冻室", "Freezer"),
                    actual: spec.freezerCurrentTemp,
                    target: spec.freezerTargetTemp,
                    onStep: { store.stepFridgeTargetTemp(device.id, isFreezer: true, delta: $0) }
                )
            }

            if !spec.availableModes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    AdaptiveGlassContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(spec.availableModes, id: \.self) { mode in
                                Button(mode) {
                                    store.setFridgeMode(device.id, mode: mode)
                                }
                                .buttonStyle(PillActionButtonStyle(isSelected: spec.currentMode == mode, tintColor: accent))
                            }
                        }
                    }
                    .padding(6)
                }
                .padding(-6)
            }
        }
    }

    private func fridgeZoneBox(
        title: String,
        actual: Double?,
        target: Double,
        onStep: @escaping (Double) -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let actual {
                    Text(L10n.format("实测 %@", "Actual %@", L10n.temperature(actual)))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    onStep(-1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("降低\(title)温度", "Lower \(title) temperature")))

                Spacer()

                Text(L10n.temperature(target))
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Spacer()

                Button {
                    onStep(1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("升高\(title)温度", "Raise \(title) temperature")))
            }
        }
        .padding(8)
        .adaptiveGlass(in: shape)
    }

    // MARK: - 6. Vacuum Controls

    private func vacuumDrawer(_ spec: VacuumSpec) -> some View {
        AdaptiveGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.performVacuumAction(device.id, action: .start)
                } label: {
                    Label(L10n.tr("开始清扫", "Clean"), systemImage: "play.fill")
                }
                .buttonStyle(PillActionButtonStyle(isSelected: spec.status == "cleaning", tintColor: accent))

                Button {
                    store.performVacuumAction(device.id, action: .pause)
                } label: {
                    Label(L10n.tr("暂停", "Pause"), systemImage: "pause.fill")
                }
                .buttonStyle(PillActionButtonStyle(isSelected: spec.status == "paused", tintColor: accent))

                Button {
                    store.performVacuumAction(device.id, action: .returnToBase)
                } label: {
                    Label(L10n.tr("回充", "Dock"), systemImage: "bolt.house.fill")
                }
                .buttonStyle(PillActionButtonStyle(isSelected: spec.status == "returning", tintColor: accent))
            }
        }
    }

    // MARK: - 7. Xiaomi Smart Speaker Controls + XiaoAi Command Bar

    private func speakerDrawer(_ spec: SpeakerSpec) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Button {
                    store.toggleSpeakerMute(device.id)
                } label: {
                    Image(systemName: spec.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(spec.isMuted ? .red : statusColor)
                        .frame(width: 24, height: 22)
                        .adaptiveGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(spec.isMuted
                    ? L10n.tr("取消静音 \(device.name)", "Unmute \(device.name)")
                    : L10n.tr("静音 \(device.name)", "Mute \(device.name)")))
                .skinHelp(L10n.tr("切换麦克风/扬声器静音", "Toggle speaker mute"))

                LiquidGlassSlider(
                    value: Binding(
                        get: { Double(spec.volumePercent) },
                        set: { store.setSpeakerVolume(device.id, percent: Int($0.rounded())) }
                    ),
                    in: 0...100,
                    step: 1,
                    iconName: "waveform",
                    iconColor: statusColor,
                    trackFill: LinearGradient(
                        colors: [
                            accent.opacity(0.60),
                            accent.opacity(0.92)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    formattedValue: "\(spec.volumePercent)%"
                )
            }

            AdaptiveGlassContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if let musicBtn = spec.playMusicButtonId {
                        Button {
                            store.pressDeviceButton(musicBtn, label: L10n.tr("播放音乐", "Play Music"))
                        } label: {
                            Label(L10n.tr("放歌", "Music"), systemImage: "music.note")
                        }
                        .buttonStyle(PillActionButtonStyle(tintColor: accent))
                    }

                    if let stopAlarmBtn = spec.stopAlarmButtonId {
                        Button {
                            store.pressDeviceButton(stopAlarmBtn, label: L10n.tr("停止闹钟", "Stop Alarm"))
                        } label: {
                            Label(L10n.tr("停闹钟", "Stop Alarm"), systemImage: "bell.slash.fill")
                        }
                        .buttonStyle(PillActionButtonStyle(tintColor: accent))
                    }
                }
            }

            if spec.directiveNotifyEntityId != nil || spec.ttsNotifyEntityId != nil {
                HStack(spacing: 6) {
                    TextField(L10n.tr("输入小爱指令或播报文字…", "Enter XiaoAi command or TTS text…"), text: $speakerInputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .adaptiveGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onSubmit {
                            guard !speakerInputText.isEmpty else { return }
                            store.sendSpeakerText(device.id, text: speakerInputText, asDirective: true)
                            speakerInputText = ""
                        }

                    if spec.ttsNotifyEntityId != nil {
                        Button(L10n.tr("播报", "Speak")) {
                            store.sendSpeakerText(device.id, text: speakerInputText, asDirective: false)
                            speakerInputText = ""
                        }
                        .buttonStyle(PillActionButtonStyle(tintColor: accent))
                        .disabled(speakerInputText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if spec.directiveNotifyEntityId != nil {
                        Button(L10n.tr("执行", "Run")) {
                            store.sendSpeakerText(device.id, text: speakerInputText, asDirective: true)
                            speakerInputText = ""
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: accent))
                        .disabled(speakerInputText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - 8. TV / Monitor Controls

    private func tvDrawer(_ spec: TVSpec) -> some View {
        let isLG = LGWebOSProtocol.isLGEntity(spec.mediaEntityId)
        return VStack(alignment: .leading, spacing: 8) {
            if spec.isPairingPromptActive {
                HStack(spacing: 8) {
                    Image(systemName: "tv.badge.wifi")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(L10n.tr("电视已弹出配对提示，请用遥控器点击「接受」", "Pairing prompt shown on TV; accept with your remote"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button(L10n.tr("重发请求", "Retry")) {
                        store.triggerLGWebOSPairing()
                    }
                    .buttonStyle(PillActionButtonStyle(tintColor: accent))
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.toggleTVMute(device.id)
                } label: {
                    Image(systemName: spec.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: spec.isMuted, tintColor: accent))
                .accessibilityLabel(Text(spec.isMuted
                    ? L10n.tr("取消静音 \(device.name)", "Unmute \(device.name)")
                    : L10n.tr("静音 \(device.name)", "Mute \(device.name)")))
                .skinHelp(spec.isMuted ? L10n.tr("取消静音", "Unmute") : L10n.tr("静音", "Mute"))

                LiquidGlassSlider(
                    value: Binding(
                        get: { Double(spec.volumePercent) },
                        set: { store.setSpeakerVolume(device.id, percent: Int($0.rounded())) }
                    ),
                    in: 0...100,
                    step: 1,
                    iconName: "waveform",
                    iconColor: statusColor,
                    trackFill: LinearGradient(
                        colors: [
                            accent.opacity(0.60),
                            accent.opacity(0.92)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    formattedValue: "\(spec.volumePercent)%"
                )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                AdaptiveGlassContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            _ = store.togglePrimary(device)
                            if device.isOnline { SoundFeedback.playSuccess() }
                        } label: {
                            Label(device.isActiveOn ? L10n.tr("关机待机", "Standby") : L10n.tr("唤醒开机", "Wake"), systemImage: "power")
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: device.isActiveOn, tintColor: accent))

                        if isLG {
                            Button {
                                store.toggleTVScreenOff(device.id)
                            } label: {
                                Label(spec.isScreenOff ? L10n.tr("点亮屏幕", "Screen On") : L10n.tr("OLED 熄屏", "Screen Off"), systemImage: "moon.fill")
                            }
                            .buttonStyle(PillActionButtonStyle(isSelected: spec.isScreenOff, tintColor: accent))
                        }

                        ForEach(spec.availableSources, id: \.self) { src in
                            Button(src) {
                                store.selectTVSource(device.id, source: src)
                            }
                            .buttonStyle(PillActionButtonStyle(isSelected: spec.currentSource == src, tintColor: accent))
                        }
                    }
                }
                .padding(6)
            }
            .padding(-6)
        }
    }
}
