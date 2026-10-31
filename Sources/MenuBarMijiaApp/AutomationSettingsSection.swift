import SwiftUI
import MijiaCore

/// Settings → 通用 → 自动化与外部控制 (#57, #59).
///
/// Rules are stored in `UserDefaults` and start empty. `AutomationEngine` reads the same store on
/// every system event, so toggling a rule takes effect immediately without restarting the app.
struct AutomationSettingsSection: View {
    let store: HomeStore

    @AppStorage(URLDirectControl.allowDirectControlKey) private var allowDirectControl = false
    /// Loaded in `onAppear`; a `@State` initializer would re-decode `UserDefaults` on every render.
    @State private var rules: [AutomationRule] = []

    @State private var newTrigger: AutomationTrigger = .away
    @State private var newActionKind: AutomationActionKind = .quickAction
    @State private var newQuickAction: QuickAction = .lightsOff
    @State private var newSceneId: String?
    @State private var newDeviceIds: Set<String> = []
    @State private var newDeviceTurnOn = false

    private enum AutomationActionKind: String, CaseIterable, Identifiable {
        case quickAction, scene, devices

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quickAction: return L10n.tr("快捷动作", "Quick action")
            case .scene: return L10n.tr("场景", "Scene")
            case .devices: return L10n.tr("指定设备", "Devices")
            }
        }
    }

    var body: some View {
        let _ = store.effectiveLanguage
        SettingsSection(title: L10n.tr("自动化与外部控制", "Automation & External Control")) {
            Text(L10n.tr(
                "规则默认没有任何内容。锁屏、合盖、睡眠会合并成一个「离开」触发；解锁与唤醒合并成「回来」。同一触发一分钟内只执行一次。",
                "No rules exist by default. Lock, lid close and sleep are grouped as Away; unlock and wake as Back. The same trigger runs at most once per minute."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if rules.isEmpty {
                Text(L10n.tr(
                    "还没有规则。下面新建一条，例如「离开 → 关闭书房灯」。",
                    "No rules yet. Create one below, for example “Away → turn off the study light”."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            } else {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }

            Divider().overlay(Color.primary.opacity(0.06))
            newRuleBuilder

            Divider().overlay(Color.primary.opacity(0.06))

            SettingsToggleRow(
                title: L10n.tr("允许 URL 直控（跳过确认）", "Allow URL control without confirmation"),
                isOn: $allowDirectControl
            )
            Text(allowDirectControl
                ? L10n.tr(
                    "已关闭确认：任何网页或 App 只要打开 menumijia:// 链接就能立即控制设备。仅在你完全信任来源时使用。",
                    "Confirmation is off: any web page or app that opens a menumijia:// link can control devices immediately. Only use this with trusted sources."
                )
                : L10n.tr(
                    "默认每次都会先列出设备与动作，确认后才执行。链接格式：menumijia://toggle?device=<id>、menumijia://scene?name=<场景>、menumijia://ask?text=<一句话>。",
                    "By default every link lists the device and action and waits for confirmation. Formats: menumijia://toggle?device=<id>, menumijia://scene?name=<scene>, menumijia://ask?text=<sentence>."
                ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(allowDirectControl ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            rules = AutomationRuleStore().load()
        }
    }

    // MARK: - Existing Rules

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: rule.trigger.symbolName)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.trigger.title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                Text(rule.action.summary(devices: store.devices, scenes: store.scenes))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            Toggle("", isOn: enabledBinding(for: rule))
                .labelsHidden()
                .toggleStyle(.glass)
                .controlSize(.regular)

            Button {
                delete(rule)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: DesignTokens.TypeSize.caption))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.tr("删除这条规则", "Delete this rule"))
        }
        .padding(.vertical, 2)
    }

    private func enabledBinding(for rule: AutomationRule) -> Binding<Bool> {
        Binding(
            get: { rules.first(where: { $0.id == rule.id })?.isEnabled ?? rule.isEnabled },
            set: { enabled in
                guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
                rules[index].isEnabled = enabled
                persist()
            }
        )
    }

    private func delete(_ rule: AutomationRule) {
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    // MARK: - New Rule

    private var newRuleBuilder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("新建规则", "New Rule"))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text(L10n.tr("触发", "When"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                Picker(L10n.tr("触发", "When"), selection: $newTrigger) {
                    ForEach(AutomationTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 185)
                .controlSize(.regular)

                Text(L10n.tr("动作", "Then"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                Picker(L10n.tr("动作", "Then"), selection: $newActionKind) {
                    ForEach(AutomationActionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
                .controlSize(.regular)
            }

            actionEditor

            HStack {
                Spacer()
                Button {
                    addRule()
                } label: {
                    Label(L10n.tr("添加规则", "Add Rule"), systemImage: "plus")
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: canAdd))
                .disabled(!canAdd)
            }
        }
    }

    @ViewBuilder
    private var actionEditor: some View {
        switch newActionKind {
        case .quickAction:
            Picker("", selection: $newQuickAction) {
                ForEach(QuickAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)
            .controlSize(.regular)

        case .scene:
            if store.scenes.isEmpty {
                Text(L10n.tr(
                    "当前没有可用的场景。连接 Home Assistant 并同步场景后再试。",
                    "No scenes available. Connect Home Assistant and sync scenes first."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
            } else {
                Picker("", selection: sceneSelection) {
                    ForEach(store.scenes) { scene in
                        Text(scene.name).tag(Optional(scene.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240, alignment: .leading)
                .controlSize(.regular)
            }

        case .devices:
            // Same set App Intents offer: visible, online, and closable/openable with one click, so
            // a rule cannot be created for a hidden or offline device (#57 共用).
            let selectable = store.controllableDevices
            if selectable.isEmpty {
                Text(L10n.tr(
                    "当前没有可控设备（隐藏、离线或只能展开详情的设备不会列出）。连接数据源或取消隐藏后再试。",
                    "No controllable devices (hidden, offline, or detail-only devices are not listed). Connect a data source or unhide a device first."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(selectable) { device in
                            Toggle(isOn: deviceSelectionBinding(device.id)) {
                                Text("\(device.name) · \(L10n.displayRoomName(device.roomName))")
                                    .font(.system(size: DesignTokens.TypeSize.caption))
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.regular)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)

                Picker("", selection: $newDeviceTurnOn) {
                    Text(L10n.tr("打开", "Turn on")).tag(true)
                    Text(L10n.tr("关闭", "Turn off")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .controlSize(.regular)
            }
        }
    }

    private var sceneSelection: Binding<String?> {
        Binding(
            get: { newSceneId ?? store.scenes.first?.id },
            set: { newSceneId = $0 }
        )
    }

    private func deviceSelectionBinding(_ deviceId: String) -> Binding<Bool> {
        Binding(
            get: { newDeviceIds.contains(deviceId) },
            set: { selected in
                if selected {
                    newDeviceIds.insert(deviceId)
                } else {
                    newDeviceIds.remove(deviceId)
                }
            }
        )
    }

    private var canAdd: Bool {
        switch newActionKind {
        case .quickAction:
            return true
        case .scene:
            return !store.scenes.isEmpty
        case .devices:
            return !newDeviceIds.isEmpty
        }
    }

    private func addRule() {
        let action: AutomationAction
        switch newActionKind {
        case .quickAction:
            action = .quickAction(newQuickAction)
        case .scene:
            guard let sceneId = newSceneId ?? store.scenes.first?.id else { return }
            action = .scene(sceneId: sceneId)
        case .devices:
            guard !newDeviceIds.isEmpty else { return }
            action = .devices(ids: newDeviceIds.sorted(), isOn: newDeviceTurnOn)
        }
        rules.append(AutomationRule(trigger: newTrigger, action: action))
        newDeviceIds = []
        persist()
    }

    private func persist() {
        AutomationRuleStore().save(rules)
    }
}
