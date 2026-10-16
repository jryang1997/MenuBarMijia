import SwiftUI
import MijiaCore

public struct DeviceCardView: View {
    @Environment(\.colorScheme) private var colorScheme

    public let device: SmartDevice
    public let store: HomeStore
    public let showRoomBadge: Bool
    public let isCompactTile: Bool
    public let quickIndex: Int?

    @State private var isHovered: Bool = false
    @State private var speakerInputText: String = ""

    public init(
        device: SmartDevice,
        store: HomeStore,
        showRoomBadge: Bool = false,
        isCompactTile: Bool = false,
        quickIndex: Int? = nil
    ) {
        self.device = device
        self.store = store
        self.showRoomBadge = showRoomBadge
        self.isCompactTile = isCompactTile
        self.quickIndex = quickIndex
    }

    private var isExpanded: Bool {
        store.expandedDeviceId == device.id
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
        DevicePalette.accentColor(for: device)
    }

    private var statusColor: Color {
        DevicePalette.statusTextColor(for: device, colorScheme: colorScheme)
    }

    private var favoriteStarColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.82, blue: 0.24)
            : Color(red: 0.90, green: 0.56, blue: 0.02)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCompactTile {
                compactHeaderRow
            } else {
                headerRow
            }

            if isExpanded && device.hasDetailDrawer {
                Divider()
                    .overlay(Color.primary.opacity(0.08))
                    .padding(.horizontal, 12)

                detailDrawer
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(AppleMotion.drawerTransition)
            }
        }
        .glassTile(isActive: device.isActiveOn, accent: accent, cornerRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isKeyboardFocused ? accent.opacity(0.85) : Color.clear, lineWidth: 1.6)
        )
        .opacity(device.isOnline ? 1.0 : 0.58)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button {
                store.toggleFavorite(device.id)
            } label: {
                Label(isFavorite ? "取消常用星标" : "设为常用星标", systemImage: isFavorite ? "star.slash" : "star.fill")
            }

            if isFavorite {
                Button {
                    store.moveFavorite(deviceId: device.id, direction: -1)
                } label: {
                    Label("常用排序上移", systemImage: "arrow.up")
                }

                Button {
                    store.moveFavorite(deviceId: device.id, direction: 1)
                } label: {
                    Label("常用排序下移", systemImage: "arrow.down")
                }
            }

            if device.hasDetailDrawer {
                Button {
                    withAnimation(AppleMotion.snappySpring) {
                        store.toggleExpanded(device.id)
                    }
                } label: {
                    Label(isExpanded ? "收起详细控制" : "展开详细控制", systemImage: "slider.horizontal.3")
                }
            }

            Divider()

            Button(role: .destructive) {
                withAnimation(AppleMotion.snappySpring) {
                    store.hideDevice(device.id)
                }
            } label: {
                Label("隐藏此设备", systemImage: "eye.slash")
            }
        }
    }

    // MARK: - Compact 2-Column Header (Left Icon Toggles, Right Area Expands)

    private var compactHeaderRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.togglePrimary(device)
                }
            } label: {
                iconBadge
            }
            .buttonStyle(PressableCardButtonStyle())
            .help("点击直接切换开关")

            Button {
                withAnimation(AppleMotion.snappySpring) {
                    if device.hasDetailDrawer {
                        store.toggleExpanded(device.id)
                    } else {
                        store.togglePrimary(device)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(device.statusSubtitle)
                            .font(.system(size: 10.5, weight: device.isActiveOn ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    if let quickIndex, shouldShowQuickBadge {
                        quickIndexPill(quickIndex)
                    } else if device.hasDetailDrawer {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(device.hasDetailDrawer ? "点击展开详细控制" : device.name)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8.5)
    }

    // MARK: - Standard Single-Column Row (1-Click Toggle + Expand Trigger)

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.togglePrimary(device)
                }
            } label: {
                HStack(spacing: 10) {
                    iconBadge

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 5) {
                            Text(device.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if showRoomBadge {
                                Text(device.roomName)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.primary.opacity(0.68))
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.075))
                                            .overlay(
                                                Capsule(style: .continuous)
                                                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.36), lineWidth: 0.6)
                                            )
                                    )
                            }
                        }

                        Text(device.statusSubtitle)
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
                            .foregroundStyle(isFavorite ? favoriteStarColor : Color.secondary.opacity(0.65))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "从常用中移除" : "加入常用")
                }

                if device.hasDetailDrawer {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.toggleExpanded(device.id)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.68))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 24, height: 24)
                            .background {
                                if isExpanded {
                                    Circle()
                                        .fill(Color.primary.opacity(0.08))
                                        .glassEffect(.regular, in: Circle())
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "收起控制面板" : "展开详细控制")
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9.5)
    }

    private func quickIndexPill(_ index: Int) -> some View {
        Text("\(index)")
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }

    private var iconBadge: some View {
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
                    .glassEffect(.regular.tint(accent.opacity(0.55)), in: Circle())
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
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
                    .frame(width: 33, height: 33)
                    .glassEffect(.regular, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.22 : 0.50),
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
                    GlassEffectContainer(spacing: 6) {
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
                }
            }
        }
    }

    // MARK: - 2. Climate (AC / Heater) Detail Controls

    private func climateDrawer(_ spec: ClimateSpec) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    store.stepClimateTemperature(device.id, delta: -spec.step)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 28)
                        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                }
                .buttonStyle(PressableCardButtonStyle())
                .disabled(!device.isOnline)

                Spacer()

                VStack(spacing: 1) {
                    Text(String(format: "%.0f°C", spec.targetTemperature))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if let cur = spec.currentTemperature {
                        Text(String(format: "当前室温 %.1f°C", cur))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("设定温度")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    store.stepClimateTemperature(device.id, delta: spec.step)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 28)
                        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                }
                .buttonStyle(PressableCardButtonStyle())
                .disabled(!device.isOnline)
            }
            .padding(.horizontal, 8)

            // HVAC Modes
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 6) {
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
            }
        }
    }

    // MARK: - 3. Fan Detail Controls

    private func fanDrawer(_ spec: FanSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !spec.availablePresetModes.isEmpty {
                GlassEffectContainer(spacing: 6) {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时功率")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f W", spec.powerWatts ?? 0))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                Divider().frame(height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text("今日用电")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f kWh", spec.energyKwh ?? 0))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                Spacer()

                if spec.childLockEntityId != nil {
                    Toggle(
                        "按键锁",
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
                    title: "冷藏室",
                    actual: spec.fridgeCurrentTemp,
                    target: spec.fridgeTargetTemp,
                    onStep: { store.stepFridgeTargetTemp(device.id, isFreezer: false, delta: $0) }
                )

                fridgeZoneBox(
                    title: "冷冻室",
                    actual: spec.freezerCurrentTemp,
                    target: spec.freezerTargetTemp,
                    onStep: { store.stepFridgeTargetTemp(device.id, isFreezer: true, delta: $0) }
                )
            }

            if !spec.availableModes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(spec.availableModes, id: \.self) { mode in
                                Button(mode) {
                                    store.setFridgeMode(device.id, mode: mode)
                                }
                                .buttonStyle(PillActionButtonStyle(isSelected: spec.currentMode == mode, tintColor: accent))
                            }
                        }
                    }
                }
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
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let actual {
                    Text(String(format: "实测 %.0f°C", actual))
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

                Spacer()

                Text(String(format: "%.0f°C", target))
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
            }
        }
        .padding(8)
        .glassEffect(.regular, in: shape)
    }

    // MARK: - 6. Vacuum Controls

    private func vacuumDrawer(_ spec: VacuumSpec) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.performVacuumAction(device.id, action: .start)
                } label: {
                    Label("开始清扫", systemImage: "play.fill")
                }
                .buttonStyle(PillActionButtonStyle(isSelected: spec.status == "cleaning", tintColor: accent))

                Button {
                    store.performVacuumAction(device.id, action: .pause)
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                .buttonStyle(PillActionButtonStyle(isSelected: spec.status == "paused", tintColor: accent))

                Button {
                    store.performVacuumAction(device.id, action: .returnToBase)
                } label: {
                    Label("回充", systemImage: "bolt.house.fill")
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
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .help("切换麦克风/扬声器静音")

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

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if let musicBtn = spec.playMusicButtonId {
                        Button {
                            store.pressDeviceButton(musicBtn, label: "播放音乐")
                        } label: {
                            Label("放歌", systemImage: "music.note")
                        }
                        .buttonStyle(PillActionButtonStyle(tintColor: accent))
                    }

                    if let stopAlarmBtn = spec.stopAlarmButtonId {
                        Button {
                            store.pressDeviceButton(stopAlarmBtn, label: "停止闹钟")
                        } label: {
                            Label("停闹钟", systemImage: "bell.slash.fill")
                        }
                        .buttonStyle(PillActionButtonStyle(tintColor: accent))
                    }
                }
            }

            if spec.directiveNotifyEntityId != nil || spec.ttsNotifyEntityId != nil {
                HStack(spacing: 6) {
                    TextField("输入小爱指令或播报文字…", text: $speakerInputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5.5)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onSubmit {
                            guard !speakerInputText.isEmpty else { return }
                            store.sendSpeakerText(device.id, text: speakerInputText, asDirective: true)
                            speakerInputText = ""
                        }

                    if spec.ttsNotifyEntityId != nil {
                        Button("播报") {
                            store.sendSpeakerText(device.id, text: speakerInputText, asDirective: false)
                            speakerInputText = ""
                        }
                        .buttonStyle(PillActionButtonStyle(tintColor: accent))
                        .disabled(speakerInputText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if spec.directiveNotifyEntityId != nil {
                        Button("执行") {
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
        VStack(alignment: .leading, spacing: 8) {
            LiquidGlassSlider(
                value: Binding(
                    get: { Double(spec.volumePercent) },
                    set: { store.setSpeakerVolume(device.id, percent: Int($0.rounded())) }
                ),
                in: 0...100,
                step: 1,
                iconName: "speaker.wave.2.fill",
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

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if let wakeBtn = spec.turnOnButtonId {
                        Button {
                            store.pressDeviceButton(wakeBtn, label: "蓝牙唤醒开机")
                        } label: {
                            Label("唤醒开机", systemImage: "power")
                        }
                        .buttonStyle(PillActionButtonStyle(tintColor: accent))
                    }

                    ForEach(spec.availableSources, id: \.self) { src in
                        Button(src) {
                            Task {
                                try? await Task.sleep(for: .milliseconds(10))
                            }
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: spec.currentSource == src, tintColor: accent))
                    }
                }
            }
        }
    }
}
