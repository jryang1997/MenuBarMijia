import AppIntents
import Foundation
import MijiaCore

// MARK: - App Intents (#57)
//
// Every intent executes through the same HomeStore entry points as the panel, so optimistic
// updates, optimistic locking, habit recording, and undo stay consistent with manually clicking a
// tile. Parameter lists come from the live store, which means Shortcuts/Siri only offer devices,
// scenes, and rooms that exist in the connected home.
//
// MARK: - Entities

struct DeviceEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "设备"
    static let defaultQuery = DeviceEntityQuery()

    let id: String
    let name: String
    let roomName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(L10n.displayRoomName(roomName))"
        )
    }

    init(device: SmartDevice) {
        self.id = device.id
        self.name = device.name
        self.roomName = device.roomName
    }
}

struct DeviceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let wanted = Set(identifiers)
        return await MainActor.run {
            HomeStore.shared.controllableDevices
                .filter { wanted.contains($0.id) }
                .map { DeviceEntity(device: $0) }
        }
    }

    func suggestedEntities() async throws -> [DeviceEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        return await MainActor.run {
            HomeStore.shared.controllableDevices.map { DeviceEntity(device: $0) }
        }
    }

    func entities(matching string: String) async throws -> [DeviceEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            HomeStore.shared.controllableDevices
                .filter {
                    $0.name.lowercased().contains(needle)
                        || $0.roomName.lowercased().contains(needle)
                }
                .map { DeviceEntity(device: $0) }
        }
    }
}

struct SceneEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "场景"
    static let defaultQuery = SceneEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(scene: HomeScene) {
        self.id = scene.id
        self.name = scene.name
    }
}

struct SceneEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SceneEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let wanted = Set(identifiers)
        return await MainActor.run {
            HomeStore.shared.scenes
                .filter { wanted.contains($0.id) }
                .map { SceneEntity(scene: $0) }
        }
    }

    func suggestedEntities() async throws -> [SceneEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        return await MainActor.run {
            HomeStore.shared.scenes.map { SceneEntity(scene: $0) }
        }
    }

    func entities(matching string: String) async throws -> [SceneEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            HomeStore.shared.scenes
                .filter { $0.name.lowercased().contains(needle) }
                .map { SceneEntity(scene: $0) }
        }
    }
}

struct RoomEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "房间"
    static let defaultQuery = RoomEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(L10n.displayRoomName(name))")
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct RoomEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RoomEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let wanted = Set(identifiers)
        return await MainActor.run {
            Self.allRooms(in: HomeStore.shared).filter { wanted.contains($0.id) }
        }
    }

    func suggestedEntities() async throws -> [RoomEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        return await MainActor.run {
            Self.allRooms(in: HomeStore.shared)
        }
    }

    func entities(matching string: String) async throws -> [RoomEntity] {
        try await HomeStore.shared.waitForInitialSnapshot()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return await MainActor.run {
            Self.allRooms(in: HomeStore.shared)
                .filter {
                    $0.name.lowercased().contains(needle)
                        || L10n.displayRoomName($0.name).lowercased().contains(needle)
                }
        }
    }

    /// Areas from the registry plus any room that only exists as an environment reading.
    @MainActor
    private static func allRooms(in store: HomeStore) -> [RoomEntity] {
        var rooms = store.rooms.map { RoomEntity(id: $0.id, name: $0.name) }
        let knownNames = Set(rooms.map(\.name))
        for reading in store.environmentReadings
        where !reading.roomName.isEmpty && !knownNames.contains(reading.roomName) {
            if !rooms.contains(where: { $0.id == "reading:\(reading.roomName)" }) {
                rooms.append(RoomEntity(id: "reading:\(reading.roomName)", name: reading.roomName))
            }
        }
        return rooms
    }
}

// MARK: - Intents

struct ToggleDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "切换设备"
    static let description: IntentDescription? = IntentDescription(
        "打开或关闭一台可控设备，与菜单栏面板共用乐观更新、失败回滚和撤销逻辑。"
    )

    @Parameter(title: "设备")
    var device: DeviceEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await execute(in: HomeStore.shared)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }

    @MainActor
    func execute(in store: HomeStore) async throws -> String {
        try await store.waitForInitialSnapshot()
        guard let current = store.controllableDevices.first(where: { $0.id == device.id }) else {
            return L10n.format(
                "找不到可控设备「%@」",
                "Controllable device \"%@\" was not found",
                device.name
            )
        }
        let isMomentary = current.isMomentaryButton
        let task = store.togglePrimary(current)
        let isOn = store.devices.first(where: { $0.id == device.id })?.isActiveOn ?? false
        guard await task?.value == true else {
            return isMomentary
                ? L10n.format("%@ 触发失败", "Failed to trigger %@", current.name)
                : L10n.format("%@ 响应失败，已回滚", "%@ failed to respond; rolled back", current.name)
        }
        if isMomentary {
            return L10n.format("已触发 %@", "Triggered %@", current.name)
        }
        return isOn
            ? L10n.format("已打开 %@", "Turned on %@", current.name)
            : L10n.format("已关闭 %@", "Turned off %@", current.name)
    }
}

struct RunSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "执行场景"
    static let description: IntentDescription? = IntentDescription(
        "触发 Home Assistant 中已有的场景或脚本。"
    )

    @Parameter(title: "场景")
    var scene: SceneEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await execute(in: HomeStore.shared)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }

    @MainActor
    func execute(in store: HomeStore) async throws -> String {
        try await store.waitForInitialSnapshot()
        guard let current = store.scenes.first(where: { $0.id == scene.id }) else {
            return L10n.format(
                "找不到场景「%@」",
                "Scene \"%@\" was not found",
                scene.name
            )
        }
        guard await store.triggerScene(current).value else {
            return L10n.format("场景「%@」执行失败", "Scene \"%@\" failed", current.name)
        }
        return L10n.format("已触发场景：%@", "Activated scene: %@", current.name)
    }
}

struct AskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "一句话控制"
    static let description: IntentDescription? = IntentDescription(
        "用一句自然语言控制设备；与 AI 栏共用本地解析、云端回退和撤销。"
    )

    @Parameter(title: "指令")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else {
            return .result(dialog: intentDialog(L10n.tr(
                "请先说一句要执行的家居指令",
                "Say a smart-home command first"
            )))
        }

        try await HomeStore.shared.waitForInitialSnapshot()
        let message = await askAssistant(utterance)
        await notifyExternalAction(message)
        return .result(dialog: intentDialog(message))
    }
}

struct GetRoomClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "查询房间温湿度"
    static let description: IntentDescription? = IntentDescription(
        "返回某个房间最新的温度与湿度，可用于快捷指令中的条件判断。"
    )

    @Parameter(title: "房间")
    var room: RoomEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try await HomeStore.shared.waitForInitialSnapshot()
        let roomName = room.name
        let summary: (value: String, dialog: String) = await MainActor.run {
            let displayName = L10n.displayRoomName(roomName)
            let readings = HomeStore.shared.environmentReadings.filter { $0.roomName == roomName }
            guard let reading = readings.first(where: { $0.temperature != nil }) ?? readings.first else {
                return ("", missingClimateText(roomName: displayName))
            }

            var parts: [String] = []
            if let temperature = reading.temperature {
                // Spoken/returned value follows the display unit; the core stays Celsius (#52).
                parts.append(L10n.temperature(temperature, fractionDigits: 1))
            }
            if let humidity = reading.humidity {
                parts.append(String(format: "%.0f%%", humidity))
            }
            guard !parts.isEmpty else {
                return ("", missingClimateText(roomName: displayName))
            }
            let value = parts.joined(separator: " · ")
            // Whole sentence, not concatenation: zh-Hant/other tables can reorder it (#52).
            return (value, L10n.format("%@：%@", "%@: %@", displayName, value))
        }
        return .result(value: summary.value, dialog: intentDialog(summary.dialog))
    }
}

// MARK: - App Shortcuts

struct MenuBarMijiaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: ToggleDeviceIntent(),
                phrases: [
                    "用 \(.applicationName) 切换设备",
                    "用 \(.applicationName) 打开或关闭设备"
                ],
                shortTitle: "切换设备",
                systemImageName: "lightbulb"
            ),
            AppShortcut(
                intent: RunSceneIntent(),
                phrases: ["用 \(.applicationName) 执行场景"],
                shortTitle: "执行场景",
                systemImageName: "sparkles"
            ),
            AppShortcut(
                intent: AskAssistantIntent(),
                phrases: ["用 \(.applicationName) 执行家居指令"],
                shortTitle: "一句话控制",
                systemImageName: "text.bubble"
            ),
            AppShortcut(
                intent: GetRoomClimateIntent(),
                phrases: ["用 \(.applicationName) 查询房间温湿度"],
                shortTitle: "房间温湿度",
                systemImageName: "thermometer"
            )
        ]
    }
}

// MARK: - Helpers

/// Runs a natural-language command through the AI bar's entry point on the main actor and reduces
/// the store state to one line, so Shortcuts/Siri can show it as the intent result.
@MainActor
private func askAssistant(_ utterance: String) async -> String {
    let store = HomeStore.shared
    let plan = await store.runAssistantCommand(utterance)

    if store.pendingCloudConsent != nil {
        // The consent card lives in the assistant bar; open it so the user can allow this request.
        store.presentAssistantBar()
        HotkeyAndNotificationManager.shared.ensureMenuBarExtraWindowVisible()
        return L10n.tr(
            "这条指令需要云端 AI。请在 MenuBarMijia 面板里确认后重试。",
            "This command needs cloud AI. Confirm it in the MenuBarMijia panel and try again."
        )
    }
    if let plan, !plan.reply.isEmpty {
        return plan.reply
    }
    switch store.assistantState {
    case .done(let reply), .failed(let reply), .awaitingChoice(let reply):
        return reply
    case .thinking:
        return L10n.tr("正在执行…", "Working…")
    case .idle:
        return L10n.tr("没有找到可执行的设备操作", "No matching device actions")
    }
}

/// Runtime text (device names, assistant replies) is not a compile-time localization key, but
/// `IntentDialog` only accepts `LocalizedStringResource`; a literal resource falls back to the text
/// when no catalog entry exists.
private func intentDialog(_ text: String) -> IntentDialog {
    IntentDialog(LocalizedStringResource(stringLiteral: text))
}

private func missingClimateText(roomName: String) -> String {
    L10n.format(
        "%@ 没有可用的温湿度读数",
        "No temperature or humidity reading for %@",
        roomName
    )
}

/// Shortcuts/Siri show the dialog as the response; a banner also tells a user who invoked the
/// intent from Spotlight or Shortcuts that something happened. The notification is a no-op when the
/// app is not bundled or notifications were never allowed (#55).
@MainActor
private func notifyExternalAction(_ message: String) {
    HotkeyAndNotificationManager.shared.deliverExternalActionNotification(
        title: "MenuBarMijia",
        body: message
    )
}
