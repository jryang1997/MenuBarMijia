import SwiftUI
import MijiaCore

public struct DeviceCardView: View {
    public let device: SmartDevice
    public let store: HomeStore
    public let showRoomBadge: Bool

    @State private var isHovered: Bool = false
    @State private var speakerInputText: String = ""

    public init(device: SmartDevice, store: HomeStore, showRoomBadge: Bool = false) {
        self.device = device
        self.store = store
        self.showRoomBadge = showRoomBadge
    }

    private var isExpanded: Bool {
        store.expandedDeviceId == device.id
    }

    private var isFavorite: Bool {
        store.favoriteDeviceIds.contains(device.id)
    }

    private var accent: Color {
        DevicePalette.accentColor(for: device)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

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
        .glassTile(isActive: device.isActiveOn, accent: accent, cornerRadius: 13)
        .opacity(device.isOnline ? 1.0 : 0.56)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Top Row (1-Click Toggle + Expand Trigger)

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(AppleMotion.snappySpring) {
                    store.togglePrimary(device)
                }
            } label: {
                HStack(spacing: 10) {
                    iconBadge

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(device.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if showRoomBadge {
                                Text(device.roomName)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.primary.opacity(0.07))
                                    )
                            }
                        }

                        Text(device.statusSubtitle)
                            .font(.system(size: 11, weight: .regular))
                            .monospacedDigit()
                            .foregroundStyle(device.isActiveOn ? accent : .secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableCardButtonStyle())

            // Favorite Star + Drawer Chevron
            HStack(spacing: 4) {
                if isHovered || isExpanded || isFavorite {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.toggleFavorite(device.id)
                        }
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isFavorite ? Color.yellow : Color.secondary.opacity(0.55))
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
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 24, height: 26)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(isExpanded ? 0.10 : 0.0))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "收起控制面板" : "展开详细控制")
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(
                    device.isActiveOn
                        ? accent
                        : Color.primary.opacity(0.08)
                )
                .frame(width: 32, height: 32)

            Image(systemName: resolvedSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(device.isActiveOn ? Color.white : (device.isOnline ? accent : Color.secondary))
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
        VStack(alignment: .leading, spacing: 10) {
            // Brightness Slider
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(spec.brightnessPercent ?? (spec.isOn ? 80 : 0)) },
                        set: { store.setLightBrightness(device.id, percent: Int($0.rounded())) }
                    ),
                    in: 1...100
                )
                .tint(accent)
                .disabled(!device.isOnline)

                Text("\(spec.brightnessPercent ?? (spec.isOn ? 80 : 0))%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            // Color Temperature Slider
            HStack(spacing: 8) {
                Image(systemName: "thermometer.sun.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)

                Slider(
                    value: Binding(
                        get: { Double(spec.colorTempKelvin ?? 4000) },
                        set: { store.setLightColorTemp(device.id, kelvin: Int($0.rounded())) }
                    ),
                    in: Double(spec.minKelvin)...Double(spec.maxKelvin),
                    step: 100
                )
                .tint(Color(red: 0.98, green: 0.75, blue: 0.32))
                .disabled(!device.isOnline)

                Text("\(spec.colorTempKelvin ?? 4000)K")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            // Scene Effect Presets (Day / Night / TV / Hospitality)
            if !spec.availableEffects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
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
                        .background(Circle().fill(Color.primary.opacity(0.08)))
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
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("设定温度")
                            .font(.system(size: 10.5))
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
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(PressableCardButtonStyle())
                .disabled(!device.isOnline)
            }
            .padding(.horizontal, 8)

            // HVAC Modes
            ScrollView(.horizontal, showsIndicators: false) {
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

    // MARK: - 3. Fan Detail Controls

    private func fanDrawer(_ spec: FanSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !spec.availablePresetModes.isEmpty {
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

    // MARK: - 4. Smart Plug (Coffee Machine) Controls

    private func plugDrawer(_ spec: PlugSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时功率")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f W", spec.powerWatts ?? 0))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                Divider().frame(height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text("今日用电")
                        .font(.system(size: 10))
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
                    .font(.system(size: 11))
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

    private func fridgeZoneBox(
        title: String,
        actual: Double?,
        target: Double,
        onStep: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let actual {
                    Text(String(format: "实测 %.0f°C", actual))
                        .font(.system(size: 10))
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
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - 6. Vacuum Controls

    private func vacuumDrawer(_ spec: VacuumSpec) -> some View {
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

    // MARK: - 7. Xiaomi Smart Speaker Controls + XiaoAi Command Bar

    private func speakerDrawer(_ spec: SpeakerSpec) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    store.toggleSpeakerMute(device.id)
                } label: {
                    Image(systemName: spec.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(spec.isMuted ? .red : .secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("切换麦克风/扬声器静音")

                Slider(
                    value: Binding(
                        get: { Double(spec.volumePercent) },
                        set: { store.setSpeakerVolume(device.id, percent: Int($0.rounded())) }
                    ),
                    in: 0...100
                )
                .tint(accent)

                Text("\(spec.volumePercent)%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

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

            if spec.directiveNotifyEntityId != nil || spec.ttsNotifyEntityId != nil {
                HStack(spacing: 6) {
                    TextField("输入小爱指令或播报文字…", text: $speakerInputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
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
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { Double(spec.volumePercent) },
                        set: { store.setSpeakerVolume(device.id, percent: Int($0.rounded())) }
                    ),
                    in: 0...100
                )
                .tint(accent)

                Text("\(spec.volumePercent)%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

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
