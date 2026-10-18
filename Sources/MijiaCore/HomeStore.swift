import Foundation
import Observation

public struct ToastNotice: Equatable, Sendable {
    public let id: UUID
    public var message: String
    public var isError: Bool

    public init(id: UUID = UUID(), message: String, isError: Bool = false) {
        self.id = id
        self.message = message
        self.isError = isError
    }
}

public struct UndoBanner: Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var restoreCommands: [DeviceCommand]
    public var previousDevices: [SmartDevice]

    public init(
        id: UUID = UUID(),
        title: String,
        restoreCommands: [DeviceCommand],
        previousDevices: [SmartDevice]
    ) {
        self.id = id
        self.title = title
        self.restoreCommands = restoreCommands
        self.previousDevices = previousDevices
    }
}

@Observable
@MainActor
public final class HomeStore {
    public static let shared = HomeStore()

    public private(set) var connectionStatus: ConnectionStatus = .connecting
    public private(set) var rooms: [RoomArea] = []
    public internal(set) var devices: [SmartDevice] = []
    public private(set) var environmentReadings: [EnvironmentReading] = []
    public private(set) var scenes: [HomeScene] = []

    public var selectedRoomId: String? = nil // nil = 全部 / 常用
    public var expandedDeviceId: String? = nil
    public var focusedDeviceId: String? = nil
    public var isOptionKeyPressed: Bool = false
    public var isShowingSettings: Bool = false

    let userDefaults: UserDefaults

    public var hideOfflineDevices: Bool {
        didSet { userDefaults.set(hideOfflineDevices, forKey: "hide_offline_devices") }
    }

    public var showQuickActionsBar: Bool {
        didSet { userDefaults.set(showQuickActionsBar, forKey: "show_quick_actions_bar") }
    }

    public var enableGlobalHotkey: Bool {
        didSet {
            userDefaults.set(enableGlobalHotkey, forKey: "enable_global_hotkey")
            onGlobalHotkeyPreferenceChanged?(enableGlobalHotkey)
        }
    }

    public var isCompactGridMode: Bool {
        didSet { userDefaults.set(isCompactGridMode, forKey: "compact_grid_mode") }
    }

    public var favoriteDeviceIds: Set<String> {
        didSet {
            userDefaults.set(Array(favoriteDeviceIds), forKey: "favorite_device_ids")
        }
    }

    public var favoriteOrder: [String] {
        didSet {
            userDefaults.set(favoriteOrder, forKey: "favorite_order")
        }
    }

    public var hiddenDeviceIds: Set<String> {
        didSet {
            userDefaults.set(Array(hiddenDeviceIds), forKey: "hidden_device_ids")
        }
    }

    public var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { userDefaults.set(menuBarDisplayMode.rawValue, forKey: "menubar_display_mode") }
    }

    public var menuBarTargetId: String {
        didSet { userDefaults.set(menuBarTargetId, forKey: "menubar_target_id") }
    }

    public var enableSafetyAlerts: Bool {
        didSet { userDefaults.set(enableSafetyAlerts, forKey: "enable_safety_alerts") }
    }

    public var homeName: String {
        didSet { userDefaults.set(homeName, forKey: "home_name") }
    }

    /// When off, nothing new is learned and no habit summary is sent to the AI model.
    public var isHabitLearningEnabled: Bool = true {
        didSet { userDefaults.set(isHabitLearningEnabled, forKey: "assistant_habit_learning_enabled") }
    }

    /// Ask macOS to keep speech recognition on this Mac (no audio sent to Apple) when the language supports it.
    public var prefersOnDeviceSpeech: Bool = false {
        didSet { userDefaults.set(prefersOnDeviceSpeech, forKey: "assistant_on_device_speech") }
    }

    /// Persisted flag set once the user finishes or dismisses the first-launch onboarding guide.
    public var hasCompletedOnboarding: Bool = false {
        didSet { userDefaults.set(hasCompletedOnboarding, forKey: "has_completed_onboarding") }
    }

    /// Transient flag allowing the user to reopen the onboarding guide from Settings at any time.
    public var isShowingOnboarding: Bool = false

    public var shouldShowOnboarding: Bool {
        if isShowingOnboarding { return true }
        guard !hasCompletedOnboarding, devices.isEmpty else { return false }
        if case .connected = connectionStatus { return false }
        let hasMiSession = (miSessionMaskedUserId != nil)
        let hasHAToken = !KeychainHelper.loadToken().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !hasMiSession && !hasHAToken
    }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        isShowingOnboarding = false
    }

    public func reopenOnboarding() {
        isShowingSettings = false
        isShowingOnboarding = true
    }

    public var serverURLString: String {
        didSet { userDefaults.set(serverURLString, forKey: "ha_server_url") }
    }

    public internal(set) var homeBackend: HomeBackend {
        didSet { userDefaults.set(homeBackend.rawValue, forKey: "home_backend") }
    }

    public internal(set) var miSessionMaskedUserId: String?

    public var serverHostSummary: String {
        if homeBackend == .xiaomiCloud {
            return miSessionMaskedUserId.map { "米家云端 (\($0))" } ?? "米家云端 (未登录)"
        }
        if let url = URL(string: serverURLString), let host = url.host() {
            return host
        }
        return serverURLString
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    public private(set) var toastNotice: ToastNotice?
    public internal(set) var undoBanner: UndoBanner?
    public var onSafetyAlert: ((SafetyAlert) -> Void)?
    public var onGlobalHotkeyPreferenceChanged: ((Bool) -> Void)?

    public var lgConfig: LGWebOSConfig {
        didSet { lgConfig.save(to: userDefaults) }
    }

    var provider: any HomeProvider
    var lgWebOSClient: LGWebOSClient?
    private var latestLGDevice: SmartDevice?
    private var eventTask: Task<Void, Never>?
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    var undoTimerTask: Task<Void, Never>?
    private var toastTimerTask: Task<Void, Never>?
    var optimisticLockUntil: [String: ContinuousClock.Instant] = [:]

    private var lowBatteryAlertedAt: [String: Date] = [:]
    private var activeSinceByDeviceId: [String: Date] = [:]
    private var longRunAlertedForSession: Set<String> = []
    private var previousOnlineDeviceIds: Set<String> = []

    public init(provider: (any HomeProvider)? = nil, defaultsSuiteName: String? = nil) {
        let ud = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.userDefaults = ud
        let boolOrDefaultTrue = { (key: String) -> Bool in
            ud.object(forKey: key) == nil ? true : ud.bool(forKey: key)
        }

        let savedURL = ud.string(forKey: "ha_server_url") ?? KeychainHelper.defaultNASURL
        self.serverURLString = savedURL
        let initialBackend = ud.string(forKey: "home_backend").flatMap(HomeBackend.init(rawValue:)) ?? .homeAssistant
        self.homeBackend = initialBackend
        self.miSessionMaskedUserId = MiSessionStore.load()?.maskedUserId
        self.lgConfig = LGWebOSConfig.load(from: ud)
        self.homeName = ud.string(forKey: "home_name") ?? KeychainHelper.defaultHomeName
        self.isHabitLearningEnabled = boolOrDefaultTrue("assistant_habit_learning_enabled")
        self.prefersOnDeviceSpeech = ud.bool(forKey: "assistant_on_device_speech")
        self.hasCompletedOnboarding = ud.bool(forKey: "has_completed_onboarding")
        self.hideOfflineDevices = ud.bool(forKey: "hide_offline_devices")
        self.showQuickActionsBar = boolOrDefaultTrue("show_quick_actions_bar")
        self.enableGlobalHotkey = boolOrDefaultTrue("enable_global_hotkey")
        self.enableSafetyAlerts = boolOrDefaultTrue("enable_safety_alerts")
        self.isCompactGridMode = ud.bool(forKey: "compact_grid_mode")
        self.menuBarTargetId = ud.string(forKey: "menubar_target_id") ?? "auto:primary"

        if let modeRaw = ud.string(forKey: "menubar_display_mode"),
           let mode = MenuBarDisplayMode(rawValue: modeRaw) {
            self.menuBarDisplayMode = mode
        } else {
            self.menuBarDisplayMode = .primaryTemp
        }

        if let savedFavs = ud.stringArray(forKey: "favorite_device_ids") {
            self.favoriteDeviceIds = Set(savedFavs)
        } else {
            self.favoriteDeviceIds = []
        }
        self.favoriteOrder = ud.stringArray(forKey: "favorite_order") ?? []
        if let savedHidden = ud.stringArray(forKey: "hidden_device_ids") {
            self.hiddenDeviceIds = Set(savedHidden)
        } else {
            self.hiddenDeviceIds = []
        }

        if let provider {
            self.provider = provider
        } else if initialBackend == .xiaomiCloud {
            self.provider = MiCloudProvider()
        } else {
            let token = KeychainHelper.loadToken()
            self.provider = HAWebSocketProvider(baseURLString: savedURL, token: token)
        }
        startListening()
        if provider == nil {
            startLGWebOSIfNeeded()
        }
    }

    private func startLGWebOSIfNeeded() {
        let client = LGWebOSClient(
            config: lgConfig,
            onDeviceUpdated: { [weak self] dev in
                Task { @MainActor [weak self] in
                    self?.applyLGDeviceUpdate(dev)
                }
            },
            onClientKeyRegistered: { [weak self] key in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lgConfig.clientKey = key
                    self.showToast("已成功配对 \(self.lgConfig.name)")
                }
            }
        )
        self.lgWebOSClient = client
        if lgConfig.isEnabled {
            Task { await client.start() }
        }
    }

    func applyLGDeviceUpdate(_ dev: SmartDevice) {
        guard lgConfig.isEnabled else {
            latestLGDevice = nil
            devices.removeAll { $0.id == dev.id }
            return
        }
        latestLGDevice = dev
        let now = ContinuousClock.now
        if let lockTime = optimisticLockUntil[dev.id], now < lockTime {
            return
        }
        if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
            devices[idx] = dev
        } else {
            devices.append(dev)
            if favoriteDeviceIds.contains(dev.id) == false && favoriteOrder.count < 8 {
                favoriteDeviceIds.insert(dev.id)
                favoriteOrder.insert(dev.id, at: 0)
            }
        }
        if !rooms.contains(where: { $0.id == dev.roomId || $0.name == dev.roomName }) {
            rooms.append(RoomArea(id: dev.roomId, name: dev.roomName, sortOrder: 1))
        }
    }

    public func startListening() {
        eventTask?.cancel()
        let stream = provider.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                self.handleProviderEvent(event)
            }
        }
    }

    private func handleProviderEvent(_ event: HomeProviderEvent) {
        switch event {
        case .statusChanged(let status):
            self.connectionStatus = status

        case .snapshotUpdated(let snapshot):
            var nextRooms = snapshot.rooms
            if let lgDev = latestLGDevice, lgConfig.isEnabled,
               !nextRooms.contains(where: { $0.id == lgDev.roomId || $0.name == lgDev.roomName }) {
                nextRooms.append(RoomArea(id: lgDev.roomId, name: lgDev.roomName, sortOrder: 1))
            }
            self.rooms = nextRooms
            self.environmentReadings = snapshot.environmentReadings
            self.scenes = snapshot.scenes

            let now = ContinuousClock.now
            var merged: [SmartDevice] = []
            let existingById = Dictionary(uniqueKeysWithValues: self.devices.map { ($0.id, $0) })

            for incoming in snapshot.devices {
                if let lockTime = optimisticLockUntil[incoming.id], now < lockTime,
                   let local = existingById[incoming.id] {
                    merged.append(local)
                } else {
                    merged.append(incoming)
                }
            }
            if let lgDev = latestLGDevice, lgConfig.isEnabled,
               !merged.contains(where: { $0.id == lgDev.id }) {
                if let lockTime = optimisticLockUntil[lgDev.id], now < lockTime,
                   let local = existingById[lgDev.id] {
                    merged.insert(local, at: 0)
                } else {
                    merged.insert(lgDev, at: 0)
                }
            }
            self.devices = merged
            seedDefaultFavoritesIfNeeded()

            if enableSafetyAlerts, let handler = onSafetyAlert {
                for alert in evaluateSafetyAlerts(now: Date()) {
                    handler(alert)
                }
            }
        }
    }

    private func seedDefaultFavoritesIfNeeded() {
        guard favoriteDeviceIds.isEmpty,
              userDefaults.object(forKey: "favorite_device_ids") == nil,
              !devices.isEmpty else {
            return
        }
        // Automatically star online controllable devices on first launch
        let initial = devices
            .filter { $0.isOnline && $0.hasDetailDrawer }
            .prefix(6)
            .map(\.id)
        if !initial.isEmpty {
            self.favoriteDeviceIds = Set(initial)
            self.favoriteOrder = initial
        }
    }

    // MARK: - Computed Views of State

    public var activeDeviceCount: Int {
        devices.filter(\.isActiveOn).count
    }

    public var onlineDeviceCount: Int {
        devices.filter(\.isOnline).count
    }

    public var totalPowerWatts: Double {
        devices.reduce(0.0) { acc, dev in
            guard dev.isOnline, case .plug(let s) = dev.kind, s.isOn else { return acc }
            return acc + (s.powerWatts ?? 0)
        }
    }

    public var availableMenuBarOptions: [MenuBarMetricOption] {
        var opts: [MenuBarMetricOption] = [
            MenuBarMetricOption(id: "auto:primary", title: "自动（主卧温度优先）")
        ]
        for env in environmentReadings {
            opts.append(MenuBarMetricOption(id: "temp:\(env.id)", title: "\(env.label) · 温度"))
            if env.humidity != nil {
                opts.append(MenuBarMetricOption(id: "temp_hum:\(env.id)", title: "\(env.label) · 温湿度"))
            }
        }
        opts.append(MenuBarMetricOption(id: "power:total", title: "全屋实时总功率 (W)"))
        opts.append(MenuBarMetricOption(id: "active:count", title: "开启设备数量"))
        opts.append(MenuBarMetricOption(id: "icon:only", title: "仅显示图标"))
        return opts
    }

    public var hiddenDevices: [SmartDevice] {
        devices.filter { hiddenDeviceIds.contains($0.id) }
    }

    public var filteredDevices: [SmartDevice] {
        devices.filter { dev in
            if hiddenDeviceIds.contains(dev.id) { return false }
            if hideOfflineDevices && !dev.isOnline { return false }
            if let roomId = selectedRoomId {
                return dev.roomId == roomId
            }
            return true
        }
    }

    public var favoriteDevices: [SmartDevice] {
        let favs = filteredDevices.filter { favoriteDeviceIds.contains($0.id) }
        guard !favoriteOrder.isEmpty else { return favs }
        let orderIndex = Dictionary(uniqueKeysWithValues: favoriteOrder.enumerated().map { ($1, $0) })
        return favs.sorted { a, b in
            let ia = orderIndex[a.id] ?? Int.max
            let ib = orderIndex[b.id] ?? Int.max
            if ia != ib { return ia < ib }
            return false
        }
    }

    public var nonFavoriteDevices: [SmartDevice] {
        filteredDevices.filter { !favoriteDeviceIds.contains($0.id) }
    }

    public var orderedVisibleDevices: [SmartDevice] {
        if selectedRoomId == nil {
            return favoriteDevices + nonFavoriteDevices
        }
        return filteredDevices
    }

    public var menuBarSymbolName: String {
        activeDeviceCount > 0 ? "house.fill" : "house"
    }

    public var menuBarText: String? {
        let sensorReading = { (prefix: String) -> EnvironmentReading? in
            guard self.menuBarTargetId.hasPrefix(prefix) else { return nil }
            let sensorId = String(self.menuBarTargetId.dropFirst(prefix.count))
            return self.environmentReadings.first(where: { $0.id == sensorId }) ?? self.environmentReadings.first
        }

        if let env = sensorReading("temp:"), let t = env.temperature {
            return String(format: "%.1f°", t)
        }
        if let env = sensorReading("temp_hum:"), let t = env.temperature {
            if let h = env.humidity {
                return String(format: "%.1f° %.0f%%", t, h)
            }
            return String(format: "%.1f°", t)
        }
        if menuBarTargetId == "power:total" {
            return String(format: "%.0fW", totalPowerWatts)
        }
        if menuBarTargetId == "active:count" {
            return activeDeviceCount > 0 ? "\(activeDeviceCount)开" : nil
        }
        if menuBarTargetId == "icon:only" {
            return nil
        }

        switch menuBarDisplayMode {
        case .iconOnly:
            return nil
        case .primaryTemp:
            if let primary = environmentReadings.first(where: { $0.label.contains("主卧") }) ?? environmentReadings.first,
               let t = primary.temperature {
                return String(format: "%.1f°", t)
            }
            return nil
        case .balconyTemp:
            if let bal = environmentReadings.first(where: { $0.label.contains("阳台") }) ?? environmentReadings.last,
               let t = bal.temperature {
                return String(format: "%.1f°", t)
            }
            return nil
        case .activeCount:
            return activeDeviceCount > 0 ? "\(activeDeviceCount)开" : nil
        }
    }

    // MARK: - SafetyAlert Evaluation Engine

    @discardableResult
    public func evaluateSafetyAlerts(now: Date = Date()) -> [SafetyAlert] {
        guard enableSafetyAlerts else { return [] }
        var emitted: [SafetyAlert] = []

        for dev in devices {
            // 1. Starred device offline transition check
            if favoriteDeviceIds.contains(dev.id) {
                if previousOnlineDeviceIds.contains(dev.id) && !dev.isOnline {
                    emitted.append(
                        SafetyAlert(
                            id: "offline:\(dev.id):\(Int(now.timeIntervalSince1970))",
                            deviceId: dev.id,
                            title: "\(dev.name) 已离线",
                            body: "\(dev.roomName)的「\(dev.name)」刚刚断开连接或断电。"
                        )
                    )
                }
            }

            // 2. Low battery check (<15% for sensors/locks, 24h cooldown)
            if dev.isOnline, case .sensor(let s) = dev.kind, let bat = s.battery, bat > 0 && bat < 15 {
                let lastAlert = lowBatteryAlertedAt[dev.id]
                if lastAlert == nil || now.timeIntervalSince(lastAlert!) >= 86_400 {
                    lowBatteryAlertedAt[dev.id] = now
                    emitted.append(
                        SafetyAlert(
                            id: "battery:\(dev.id)",
                            deviceId: dev.id,
                            title: "\(dev.name) 电量低 (\(bat)%)",
                            body: "请及时为\(dev.roomName)的「\(dev.name)」更换电池或充电。"
                        )
                    )
                }
            }

            // 3. Long-running plug (>=45m) or climate (>=4h) check
            if dev.isActiveOn {
                let startedAt = activeSinceByDeviceId[dev.id] ?? {
                    activeSinceByDeviceId[dev.id] = now
                    return now
                }()
                let elapsed = now.timeIntervalSince(startedAt)

                switch dev.kind {
                case .plug(let s) where elapsed >= 45 * 60 && !longRunAlertedForSession.contains(dev.id):
                    longRunAlertedForSession.insert(dev.id)
                    emitted.append(
                        SafetyAlert(
                            id: "longrun:\(dev.id)",
                            deviceId: dev.id,
                            title: "\(dev.name) 已开启超过 45 分钟",
                            body: "当前功率 \(Int((s.powerWatts ?? 0).rounded()))W，如需关闭可直接点击通知按钮。",
                            turnOffCommand: .setSwitch(entityId: s.switchEntityId, isOn: false)
                        )
                    )
                case .climate(let s) where elapsed >= 4 * 3600 && !longRunAlertedForSession.contains(dev.id):
                    longRunAlertedForSession.insert(dev.id)
                    emitted.append(
                        SafetyAlert(
                            id: "longrun:\(dev.id)",
                            deviceId: dev.id,
                            title: "\(dev.name) 已连续运行 4 小时",
                            body: "当前设定 \(Int(s.targetTemperature.rounded()))°C，请确认是否仍需开启。",
                            turnOffCommand: .setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: s.hvacMode)
                        )
                    )
                default:
                    break
                }
            } else {
                activeSinceByDeviceId.removeValue(forKey: dev.id)
                longRunAlertedForSession.remove(dev.id)
            }
        }

        previousOnlineDeviceIds = Set(devices.filter(\.isOnline).map(\.id))
        return emitted
    }

    public func executeSafetyAlertAction(_ alert: SafetyAlert) {
        guard let cmd = alert.turnOffCommand else { return }
        Task {
            try? await provider.execute(cmd)
            await provider.refreshNow()
        }
    }

    // MARK: - Keyboard Navigation & Quick Number Shortcuts

    public func selectQuickIndex(_ oneBasedIndex: Int) {
        let list = orderedVisibleDevices
        let idx = oneBasedIndex - 1
        guard idx >= 0 && idx < list.count else { return }
        togglePrimary(list[idx])
    }

    public func moveFocus(delta: Int) {
        let list = orderedVisibleDevices
        guard !list.isEmpty else {
            focusedDeviceId = nil
            return
        }
        guard let currentId = focusedDeviceId,
              let curIdx = list.firstIndex(where: { $0.id == currentId }) else {
            focusedDeviceId = delta >= 0 ? list.first?.id : list.last?.id
            return
        }
        let nextIdx = (curIdx + delta + list.count) % list.count
        focusedDeviceId = list[nextIdx].id
    }

    public func toggleFocusedDevice() {
        let list = orderedVisibleDevices
        guard !list.isEmpty else { return }
        if let fid = focusedDeviceId, let dev = list.first(where: { $0.id == fid }) {
            togglePrimary(dev)
        } else if let first = list.first {
            focusedDeviceId = first.id
            togglePrimary(first)
        }
    }

    public func adjustFocusedDevice(delta: Int) {
        guard let fid = focusedDeviceId,
              let dev = devices.first(where: { $0.id == fid }) else { return }

        if expandedDeviceId != dev.id {
            if delta > 0 && dev.hasDetailDrawer {
                expandedDeviceId = dev.id
            }
            return
        }

        switch dev.kind {
        case .light(let s):
            let current = s.brightnessPercent ?? (s.isOn ? 80 : 0)
            let next = max(1, min(100, current + delta * 10))
            setLightBrightness(dev.id, percent: next)
        case .climate:
            stepClimateTemperature(dev.id, delta: Double(delta) * 1.0)
        case .speaker(let s):
            setSpeakerVolume(dev.id, percent: max(0, min(100, s.volumePercent + delta * 10)))
        case .tv(let s):
            setSpeakerVolume(dev.id, percent: max(0, min(100, s.volumePercent + delta * 10)))
        default:
            if delta < 0 {
                expandedDeviceId = nil
            }
        }
    }

    public func cycleRoom(delta: Int = 1) {
        let options: [String?] = [nil] + rooms.map { Optional($0.id) }
        guard options.count > 1 else { return }
        let curIdx = options.firstIndex(where: { $0 == selectedRoomId }) ?? 0
        let nextIdx = (curIdx + delta + options.count) % options.count
        selectedRoomId = options[nextIdx]
    }

    // MARK: - User Actions & Optimistic State Mutations

    public func toggleFavorite(_ deviceId: String) {
        if favoriteDeviceIds.contains(deviceId) {
            favoriteDeviceIds.remove(deviceId)
            favoriteOrder.removeAll { $0 == deviceId }
        } else {
            favoriteDeviceIds.insert(deviceId)
            if !favoriteOrder.contains(deviceId) {
                favoriteOrder.append(deviceId)
            }
        }
    }

    public func moveFavorite(deviceId: String, direction: Int) {
        var currentIds = favoriteDevices.map(\.id)
        for id in favoriteOrder where favoriteDeviceIds.contains(id) && !currentIds.contains(id) {
            currentIds.append(id)
        }
        guard let idx = currentIds.firstIndex(of: deviceId) else { return }
        let targetIdx = idx + direction
        guard targetIdx >= 0 && targetIdx < currentIds.count else { return }
        currentIds.swapAt(idx, targetIdx)
        favoriteOrder = currentIds
    }

    public func hideDevice(_ deviceId: String) {
        hiddenDeviceIds.insert(deviceId)
        if expandedDeviceId == deviceId {
            expandedDeviceId = nil
        }
        if focusedDeviceId == deviceId {
            focusedDeviceId = nil
        }
    }

    public func unhideDevice(_ deviceId: String) {
        hiddenDeviceIds.remove(deviceId)
    }

    public func toggleExpanded(_ deviceId: String) {
        if expandedDeviceId == deviceId {
            expandedDeviceId = nil
        } else {
            expandedDeviceId = deviceId
        }
    }

    public func togglePrimary(_ device: SmartDevice) {
        guard device.isOnline else {
            showToast("\(device.name) 当前离线（可能断电）", isError: true)
            return
        }
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let previous = devices[idx]
        var updated = previous
        var command: DeviceCommand?

        switch updated.kind {
        case .light(var s):
            s.isOn.toggle()
            updated.kind = .light(s)
            command = .setLightPower(entityId: s.entityId, isOn: s.isOn)

        case .climate(var s):
            s.isOn.toggle()
            let targetMode = s.isOn ? (s.hvacMode == "off" ? (s.availableModes.first(where: { $0 != "off" }) ?? "heat") : s.hvacMode) : "off"
            s.hvacMode = targetMode
            updated.kind = .climate(s)
            command = .setClimatePower(entityId: s.entityId, isOn: s.isOn, fallbackMode: targetMode)

        case .fan(var s):
            s.isOn.toggle()
            updated.kind = .fan(s)
            command = .setFanPower(entityId: s.entityId, isOn: s.isOn)

        case .plug(var s):
            s.isOn.toggle()
            updated.kind = .plug(s)
            command = .setSwitch(entityId: s.switchEntityId, isOn: s.isOn)

        case .vacuum(var s):
            let startCleaning = !s.isCleaning
            s.status = startCleaning ? "cleaning" : "returning"
            updated.kind = .vacuum(s)
            command = .vacuumAction(entityId: s.entityId, action: startCleaning ? .start : .returnToBase)

        case .tv(var s):
            let turnOn = (s.state == "off" || s.state == "standby")
            s.state = turnOn ? "on" : "standby"
            if turnOn { s.isScreenOff = false }
            updated.kind = .tv(s)
            if LGWebOSProtocol.isLGEntity(s.mediaEntityId) {
                command = .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: turnOn)
            } else if turnOn, let btnId = s.turnOnButtonId {
                command = .pressButton(entityId: btnId)
            } else {
                toggleExpanded(device.id)
                return
            }

        case .speaker, .fridge, .sensor:
            toggleExpanded(device.id)
            return
        }

        guard let cmd = command else { return }
        devices[idx] = updated
        lockOptimistic(device.id, duration: .seconds(2.2))

        var memory = userHabitMemory
        memory.record(
            utterance: nil,
            intents: [DeviceIntent(targetId: device.id, operation: .power(updated.isActiveOn))],
            devices: devices,
            scenes: scenes
        )
        if isHabitLearningEnabled { userHabitMemory = memory }

        Task {
            do {
                try await executeDeviceCommand(cmd)
            } catch {
                if let revertIdx = self.devices.firstIndex(where: { $0.id == device.id }) {
                    self.devices[revertIdx] = previous
                }
                self.optimisticLockUntil.removeValue(forKey: device.id)
                self.showToast("\(device.name) 响应失败，已回滚", isError: true)
            }
        }
    }

    // MARK: - Detail Drawer Controls (Debounced & Optimistic)

    public func setLightBrightness(_ deviceId: String, percent: Int) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .light(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isOn = percent > 0
        s.brightnessPercent = percent
        devices[idx].kind = .light(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchDebounced(
            key: "\(deviceId).brightness",
            deviceId: deviceId,
            fallback: previous,
            command: .setLightBrightness(entityId: s.entityId, percent: percent)
        )
    }

    public func setLightColorTemp(_ deviceId: String, kelvin: Int) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .light(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isOn = true
        s.colorTempKelvin = kelvin
        s.currentEffect = nil
        devices[idx].kind = .light(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchDebounced(
            key: "\(deviceId).colortemp",
            deviceId: deviceId,
            fallback: previous,
            command: .setLightColorTemp(entityId: s.entityId, kelvin: kelvin)
        )
    }

    public func setLightEffect(_ deviceId: String, effect: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .light(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isOn = true
        s.currentEffect = effect
        devices[idx].kind = .light(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        var memory = userHabitMemory
        memory.record(
            utterance: nil,
            intents: [DeviceIntent(targetId: deviceId, operation: .lightEffect(effect))],
            devices: devices,
            scenes: scenes
        )
        if isHabitLearningEnabled { userHabitMemory = memory }

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setLightEffect(entityId: s.entityId, effect: effect)
        )
    }

    public func stepClimateTemperature(_ deviceId: String, delta: Double) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .climate(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        let nextTemp = max(s.minTemp, min(s.maxTemp, s.targetTemperature + delta))
        s.targetTemperature = nextTemp
        devices[idx].kind = .climate(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchDebounced(
            key: "\(deviceId).temp",
            deviceId: deviceId,
            fallback: previous,
            command: .setClimateTemperature(entityId: s.entityId, temperature: nextTemp)
        )
    }

    public func setClimateMode(_ deviceId: String, mode: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .climate(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.hvacMode = mode
        s.isOn = (mode != "off")
        devices[idx].kind = .climate(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setClimateMode(entityId: s.entityId, hvacMode: mode)
        )
    }

    public func setFanPresetMode(_ deviceId: String, preset: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .fan(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isOn = true
        s.presetMode = preset
        devices[idx].kind = .fan(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setFanPresetMode(entityId: s.entityId, presetMode: preset)
        )
    }

    public func setPlugChildLock(_ deviceId: String, locked: Bool) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .plug(var s) = devices[idx].kind,
              let lockEid = s.childLockEntityId else { return }
        let previous = devices[idx]
        s.isChildLocked = locked
        devices[idx].kind = .plug(s)
        lockOptimistic(deviceId, duration: .seconds(2.0))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: lockEid, isOn: locked)
        )
    }

    public func setFridgeMode(_ deviceId: String, mode: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .fridge(var s) = devices[idx].kind,
              let modeEid = s.modeEntityId else { return }
        let previous = devices[idx]
        s.currentMode = mode
        devices[idx].kind = .fridge(s)
        lockOptimistic(deviceId, duration: .seconds(2.0))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSelectOption(entityId: modeEid, option: mode)
        )
    }

    public func stepFridgeTargetTemp(_ deviceId: String, isFreezer: Bool, delta: Double) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .fridge(var s) = devices[idx].kind else { return }
        let previous = devices[idx]

        if isFreezer {
            guard let eid = s.freezerTargetEntityId else { return }
            let next = max(-24, min(-15, s.freezerTargetTemp + delta))
            s.freezerTargetTemp = next
            devices[idx].kind = .fridge(s)
            lockOptimistic(deviceId, duration: .seconds(2.5))
            dispatchDebounced(
                key: "\(deviceId).freezer",
                deviceId: deviceId,
                fallback: previous,
                command: .setNumberValue(entityId: eid, value: next)
            )
        } else {
            guard let eid = s.fridgeTargetEntityId else { return }
            let next = max(2, min(8, s.fridgeTargetTemp + delta))
            s.fridgeTargetTemp = next
            devices[idx].kind = .fridge(s)
            lockOptimistic(deviceId, duration: .seconds(2.5))
            dispatchDebounced(
                key: "\(deviceId).fridge",
                deviceId: deviceId,
                fallback: previous,
                command: .setNumberValue(entityId: eid, value: next)
            )
        }
    }

    public func performVacuumAction(_ deviceId: String, action: VacuumAction) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .vacuum(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        switch action {
        case .start: s.status = "cleaning"
        case .pause: s.status = "paused"
        case .returnToBase: s.status = "returning"
        }
        devices[idx].kind = .vacuum(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .vacuumAction(entityId: s.entityId, action: action)
        )
    }

    public func setSpeakerVolume(_ deviceId: String, percent: Int) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        let previous = devices[idx]
        let clamped = max(0, min(100, percent))

        let mediaEid: String
        switch devices[idx].kind {
        case .speaker(var s):
            s.volumePercent = clamped
            devices[idx].kind = .speaker(s)
            mediaEid = s.mediaEntityId
        case .tv(var s):
            s.volumePercent = clamped
            devices[idx].kind = .tv(s)
            mediaEid = s.mediaEntityId
        default:
            return
        }

        lockOptimistic(deviceId, duration: .seconds(2.5))
        dispatchDebounced(
            key: "\(deviceId).volume",
            deviceId: deviceId,
            fallback: previous,
            command: .mediaSetVolume(entityId: mediaEid, volumeLevel: Double(clamped) / 100.0)
        )
    }

    public func toggleSpeakerMute(_ deviceId: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .speaker(var s) = devices[idx].kind,
              let muteEid = s.muteSwitchEntityId else { return }
        let previous = devices[idx]
        s.isMuted.toggle()
        devices[idx].kind = .speaker(s)
        lockOptimistic(deviceId, duration: .seconds(2.0))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: muteEid, isOn: s.isMuted)
        )
    }

    public func toggleTVMute(_ deviceId: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .tv(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isMuted.toggle()
        devices[idx].kind = .tv(s)
        lockOptimistic(deviceId, duration: .seconds(2.0))

        let entityId = LGWebOSProtocol.isLGEntity(s.mediaEntityId) ? LGWebOSProtocol.muteEntityId : s.mediaEntityId
        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: entityId, isOn: s.isMuted)
        )
    }

    public func toggleTVScreenOff(_ deviceId: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .tv(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isScreenOff.toggle()
        if !s.isScreenOff && (s.state == "off" || s.state == "standby") {
            s.state = "on"
        }
        devices[idx].kind = .tv(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: LGWebOSProtocol.screenOffEntityId, isOn: s.isScreenOff)
        )
    }

    public func selectTVSource(_ deviceId: String, source: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .tv(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.currentSource = source
        s.state = "on"
        s.isScreenOff = false
        devices[idx].kind = .tv(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .mediaSelectSource(entityId: s.mediaEntityId, source: source)
        )
    }

    public func sendSpeakerText(_ deviceId: String, text: String, asDirective: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .speaker(let s) = devices[idx].kind else { return }

        let targetEid = asDirective ? s.directiveNotifyEntityId : s.ttsNotifyEntityId
        guard let eid = targetEid else {
            showToast("该音箱不支持此指令通道", isError: true)
            return
        }

        Task {
            do {
                try await executeDeviceCommand(.sendNotifyMessage(entityId: eid, message: trimmed))
                showToast(asDirective ? "已向小爱下发指令：「\(trimmed)」" : "小爱已播报：「\(trimmed)」")
            } catch {
                showToast("发送失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    public func pressDeviceButton(_ buttonEntityId: String, label: String) {
        Task {
            do {
                try await executeDeviceCommand(.pressButton(entityId: buttonEntityId))
                showToast("已触发：\(label)")
            } catch {
                showToast("\(label) 执行失败", isError: true)
            }
        }
    }

    // MARK: - Scenes & Built-In QuickActions with 5-Second Undo

    public func triggerScene(_ scene: HomeScene) {
        Task {
            do {
                try await executeDeviceCommand(.activateScene(entityId: scene.entityId))
                showToast("已触发场景：\(scene.name)")
            } catch {
                showToast("场景「\(scene.name)」执行失败", isError: true)
            }
        }
    }

    public func executeQuickAction(_ action: QuickAction) {
        let previousSnapshot = devices
        var commands: [DeviceCommand] = []
        var restoreCommands: [DeviceCommand] = []

        switch action {
        case .lightsOff:
            for idx in devices.indices where devices[idx].isOnline {
                guard case .light(var s) = devices[idx].kind, s.isOn else { continue }
                lockOptimistic(devices[idx].id, duration: .seconds(3.0))
                commands.append(.setLightPower(entityId: s.entityId, isOn: false))
                restoreCommands.append(.setLightPower(entityId: s.entityId, isOn: true))
                s.isOn = false
                devices[idx].kind = .light(s)
            }

        case .softNightLight:
            var targetIndices = devices.indices.filter { idx in
                guard devices[idx].isOnline, case .light(let s) = devices[idx].kind else { return false }
                return s.isOn
            }
            if targetIndices.isEmpty {
                let isOnlineLight = { (dev: SmartDevice) -> Bool in
                    if dev.isOnline, case .light = dev.kind { return true }
                    return false
                }
                let fallbackIdx = devices.indices.first(where: { isOnlineLight(devices[$0]) && favoriteDeviceIds.contains(devices[$0].id) })
                    ?? devices.indices.first(where: { isOnlineLight(devices[$0]) && devices[$0].roomName == "主卧" })
                    ?? devices.indices.first(where: { isOnlineLight(devices[$0]) })
                if let fallbackIdx {
                    targetIndices = [fallbackIdx]
                }
            }
            for idx in targetIndices {
                guard case .light(var s) = devices[idx].kind else { continue }
                lockOptimistic(devices[idx].id, duration: .seconds(3.0))
                let prevOn = s.isOn
                let prevBri = s.brightnessPercent ?? 80
                let prevKelvin = s.colorTempKelvin ?? 4000
                commands.append(.setLightBrightness(entityId: s.entityId, percent: 15))
                commands.append(.setLightColorTemp(entityId: s.entityId, kelvin: max(s.minKelvin, 2700)))
                if prevOn {
                    restoreCommands.append(.setLightBrightness(entityId: s.entityId, percent: prevBri))
                    restoreCommands.append(.setLightColorTemp(entityId: s.entityId, kelvin: prevKelvin))
                } else {
                    restoreCommands.append(.setLightPower(entityId: s.entityId, isOn: false))
                }
                s.isOn = true
                s.brightnessPercent = 15
                s.colorTempKelvin = max(s.minKelvin, 2700)
                s.currentEffect = nil
                devices[idx].kind = .light(s)
            }

        case .climateSleepOff:
            for idx in devices.indices where devices[idx].isOnline {
                switch devices[idx].kind {
                case .climate(var s) where s.isOn && s.hvacMode != "off":
                    let prevMode = s.hvacMode
                    lockOptimistic(devices[idx].id, duration: .seconds(3.0))
                    commands.append(.setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: prevMode))
                    restoreCommands.append(.setClimatePower(entityId: s.entityId, isOn: true, fallbackMode: prevMode))
                    s.isOn = false
                    s.hvacMode = "off"
                    devices[idx].kind = .climate(s)
                case .fan(var s) where s.isOn:
                    lockOptimistic(devices[idx].id, duration: .seconds(3.0))
                    commands.append(.setFanPower(entityId: s.entityId, isOn: false))
                    restoreCommands.append(.setFanPower(entityId: s.entityId, isOn: true))
                    s.isOn = false
                    devices[idx].kind = .fan(s)
                default:
                    break
                }
            }
        }

        guard !commands.isEmpty else {
            showToast("当前无需执行「\(action.title)」")
            return
        }

        scheduleUndoBanner(
            title: "已执行「\(action.title)」",
            restoreCommands: restoreCommands,
            previousDevices: previousSnapshot
        )

        Task {
            for cmd in commands {
                try? await executeDeviceCommand(cmd)
            }
        }
    }

    // MARK: - Turn All Off with 5-Second Undo

    public func turnAllOff() {
        let activeDevs = devices.filter(\.isActiveOn)
        guard !activeDevs.isEmpty else {
            showToast("当前没有开启的设备")
            return
        }

        let previousSnapshot = devices
        var offCommands: [DeviceCommand] = []
        var restoreCommands: [DeviceCommand] = []

        for idx in devices.indices {
            guard devices[idx].isActiveOn else { continue }
            let devId = devices[idx].id
            lockOptimistic(devId, duration: .seconds(3.0))

            switch devices[idx].kind {
            case .light(var s):
                offCommands.append(.setLightPower(entityId: s.entityId, isOn: false))
                restoreCommands.append(.setLightPower(entityId: s.entityId, isOn: true))
                s.isOn = false
                devices[idx].kind = .light(s)

            case .climate(var s):
                let prevMode = s.hvacMode
                offCommands.append(.setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: prevMode))
                restoreCommands.append(.setClimatePower(entityId: s.entityId, isOn: true, fallbackMode: prevMode))
                s.isOn = false
                s.hvacMode = "off"
                devices[idx].kind = .climate(s)

            case .fan(var s):
                offCommands.append(.setFanPower(entityId: s.entityId, isOn: false))
                restoreCommands.append(.setFanPower(entityId: s.entityId, isOn: true))
                s.isOn = false
                devices[idx].kind = .fan(s)

            case .plug(var s):
                offCommands.append(.setSwitch(entityId: s.switchEntityId, isOn: false))
                restoreCommands.append(.setSwitch(entityId: s.switchEntityId, isOn: true))
                s.isOn = false
                devices[idx].kind = .plug(s)

            case .vacuum(var s):
                offCommands.append(.vacuumAction(entityId: s.entityId, action: .returnToBase))
                restoreCommands.append(.vacuumAction(entityId: s.entityId, action: .start))
                s.status = "returning"
                devices[idx].kind = .vacuum(s)

            case .tv(var s):
                if LGWebOSProtocol.isLGEntity(s.mediaEntityId) {
                    offCommands.append(.setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: false))
                    restoreCommands.append(.setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true))
                    s.state = "standby"
                    devices[idx].kind = .tv(s)
                }

            default:
                break
            }
        }

        scheduleUndoBanner(
            title: "已关闭 \(offCommands.count) 台设备",
            restoreCommands: restoreCommands,
            previousDevices: previousSnapshot
        )

        Task {
            for cmd in offCommands {
                try? await executeDeviceCommand(cmd)
            }
        }
    }

    func scheduleUndoBanner(
        title: String,
        restoreCommands: [DeviceCommand],
        previousDevices: [SmartDevice]
    ) {
        let banner = UndoBanner(
            title: title,
            restoreCommands: restoreCommands,
            previousDevices: previousDevices
        )
        self.undoBanner = banner
        undoTimerTask?.cancel()
        undoTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5.0))
            guard !Task.isCancelled else { return }
            if self?.undoBanner?.id == banner.id {
                self?.undoBanner = nil
            }
        }
    }

    public func undoTurnAllOff() {
        guard let banner = undoBanner else { return }
        undoTimerTask?.cancel()
        self.undoBanner = nil
        let currentMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        self.devices = banner.previousDevices

        for dev in banner.previousDevices where currentMap[dev.id] != dev {
            lockOptimistic(dev.id, duration: .seconds(3.0))
        }

        Task {
            for cmd in banner.restoreCommands {
                try? await executeDeviceCommand(cmd)
            }
            showToast("已恢复关闭前的状态")
        }
    }

    // MARK: - Connection & Settings Management

    public func switchBackend(_ backend: HomeBackend) {
        let matches: Bool = switch backend {
        case .homeAssistant: provider is HAWebSocketProvider
        case .xiaomiCloud: provider is MiCloudProvider
        }
        guard homeBackend != backend || !matches else { return }

        self.homeBackend = backend
        eventTask?.cancel()
        shutdownCurrentProvider()

        switch backend {
        case .homeAssistant:
            self.provider = HAWebSocketProvider(baseURLString: serverURLString, token: KeychainHelper.loadToken())
        case .xiaomiCloud:
            self.provider = MiCloudProvider()
        }
        startListening()
    }

    public func completeMiLogin(_ session: MiSession) {
        MiSessionStore.save(session)
        self.miSessionMaskedUserId = session.maskedUserId
        self.homeBackend = .xiaomiCloud
        self.completeOnboarding()
        eventTask?.cancel()
        shutdownCurrentProvider()
        self.provider = MiCloudProvider()
        startListening()
        showToast("已登录米家账号 (\(session.maskedUserId))")
    }

    public func logoutMiAccount() {
        MiSessionStore.clear()
        self.miSessionMaskedUserId = nil
        if homeBackend == .xiaomiCloud {
            eventTask?.cancel()
            shutdownCurrentProvider()
            self.provider = MiCloudProvider()
            startListening()
        }
        showToast("已退出米家账号")
    }

    private func shutdownCurrentProvider() {
        if let old = provider as? MiCloudProvider {
            Task { await old.shutdown() }
        } else if let old = provider as? HAWebSocketProvider {
            Task { await old.shutdown() }
        }
    }

    public func updateConnection(serverURL: String, token: String) {
        self.serverURLString = serverURL
        KeychainHelper.saveToken(token)
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.completeOnboarding()
        }
        if homeBackend != .homeAssistant || !(provider is HAWebSocketProvider) {
            switchBackend(.homeAssistant)
        } else if let haProvider = provider as? HAWebSocketProvider {
            Task {
                await haProvider.updateCredentials(baseURLString: serverURL, token: token)
            }
        }
        showToast("已保存并重新连接 Home Assistant")
    }

    public func updateLGWebOSConfig(_ newConfig: LGWebOSConfig) {
        self.lgConfig = newConfig
        if !newConfig.isEnabled {
            latestLGDevice = nil
            devices.removeAll { $0.id == LGWebOSProtocol.deviceId }
        }
        if let lgClient = lgWebOSClient {
            Task {
                await lgClient.updateConfig(newConfig)
            }
        } else {
            startLGWebOSIfNeeded()
        }
        showToast(newConfig.isEnabled ? "已保存并重连 \(newConfig.name)" : "已停用 LG 电视局域网直连")
    }

    public func triggerLGWebOSPairing() {
        if lgWebOSClient == nil {
            startLGWebOSIfNeeded()
        }
        guard let lgClient = lgWebOSClient else { return }
        showToast("已向电视发送配对请求，请在电视屏幕点击「接受」")
        Task {
            await lgClient.triggerPairing()
        }
    }

    public func discoverLGWebOSTVs() async -> [LGWebOSDiscoveredTV] {
        await LGWebOSClient.discoverOnLAN(hostHint: lgConfig.host)
    }

    public func refreshNow() {
        Task {
            await provider.refreshNow()
            if lgConfig.isEnabled, let lgClient = lgWebOSClient {
                await lgClient.start()
            }
        }
    }

    public func showToast(_ message: String, isError: Bool = false) {
        let notice = ToastNotice(message: message, isError: isError)
        self.toastNotice = notice
        toastTimerTask?.cancel()
        toastTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            if self?.toastNotice?.id == notice.id {
                self?.toastNotice = nil
            }
        }
    }

    // MARK: - Internal Dispatch Helpers

    func executeDeviceCommand(_ command: DeviceCommand) async throws {
        if LGWebOSProtocol.isLGEntity(command.targetEntityId), let lgClient = lgWebOSClient {
            try await lgClient.execute(command)
        } else {
            try await provider.execute(command)
        }
    }

    func lockOptimistic(_ deviceId: String, duration: Duration) {
        optimisticLockUntil[deviceId] = ContinuousClock.now.advanced(by: duration)
    }

    private func dispatchImmediate(
        deviceId: String,
        fallback: SmartDevice,
        command: DeviceCommand
    ) {
        Task {
            do {
                try await executeDeviceCommand(command)
            } catch {
                if let idx = self.devices.firstIndex(where: { $0.id == deviceId }) {
                    self.devices[idx] = fallback
                }
                self.optimisticLockUntil.removeValue(forKey: deviceId)
                self.showToast("\(fallback.name) 操作未生效", isError: true)
            }
        }
    }

    private func dispatchDebounced(
        key: String,
        deviceId: String,
        fallback: SmartDevice,
        command: DeviceCommand
    ) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.executeDeviceCommand(command)
            } catch {
                if let idx = self.devices.firstIndex(where: { $0.id == deviceId }) {
                    self.devices[idx] = fallback
                }
                self.optimisticLockUntil.removeValue(forKey: deviceId)
                self.showToast("\(fallback.name) 调节未生效", isError: true)
            }
        }
    }

    // MARK: - Assistant Commands & Personalized Jev Context

    public var isShowingAssistantBar: Bool = false
    /// Bumped to ask an already-visible command bar to take keyboard focus.
    public internal(set) var assistantFocusRequest: Int = 0
    /// Bumped to ask the command bar to start or toggle live speech recognition.
    public internal(set) var assistantVoiceRequest: Int = 0
    public internal(set) var assistantState: AssistantState = .idle
    public internal(set) var assistantSuggestions: [AssistantSuggestion] = []
    public internal(set) var isProactiveRecommending: Bool = false
    var assistantResetTask: Task<Void, Never>?
    /// Test seam replacing the network resolver built from `assistantConfig`.
    var assistantResolverOverride: ModelIntentResolver?
    /// Commands waiting on a spoken delay ("10 分钟后关灯"), soonest first. Not persisted across launches.
    public internal(set) var scheduledCommands: [ScheduledCommand] = []
    var scheduledTasks: [UUID: Task<Void, Never>] = [:]
    /// The most recent assistant action, kept so "撤销" can restore it after the 5 s banner is gone.
    var lastAssistantUndo: (reply: String, restore: [DeviceCommand], previous: [SmartDevice], at: Date)?
    /// How long a spoken "撤销" can still reach back.
    static let voiceUndoWindow: TimeInterval = 10 * 60
    /// Test seam for the delay before a scheduled command fires.
    var assistantSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}
