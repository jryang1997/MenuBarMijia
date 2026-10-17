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
    public private(set) var devices: [SmartDevice] = []
    public private(set) var environmentReadings: [EnvironmentReading] = []
    public private(set) var scenes: [HomeScene] = []

    public var selectedRoomId: String? = nil // nil = 全部 / 常用
    public var expandedDeviceId: String? = nil
    public var focusedDeviceId: String? = nil
    public var isOptionKeyPressed: Bool = false
    public var isShowingSettings: Bool = false

    private let userDefaults: UserDefaults

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

    public var serverURLString: String {
        didSet { userDefaults.set(serverURLString, forKey: "ha_server_url") }
    }

    public private(set) var homeBackend: HomeBackend {
        didSet { userDefaults.set(homeBackend.rawValue, forKey: "home_backend") }
    }

    public private(set) var miSessionMaskedUserId: String?

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

    private var provider: any HomeProvider
    private var eventTask: Task<Void, Never>?
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var undoTimerTask: Task<Void, Never>?
    private var toastTimerTask: Task<Void, Never>?
    private var optimisticLockUntil: [String: ContinuousClock.Instant] = [:]

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
        self.homeName = ud.string(forKey: "home_name") ?? KeychainHelper.defaultHomeName
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
            self.rooms = snapshot.rooms
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

        case .speaker, .tv, .fridge, .sensor:
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
        userHabitMemory = memory

        Task {
            do {
                try await provider.execute(cmd)
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
        userHabitMemory = memory

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
                try await provider.execute(.sendNotifyMessage(entityId: eid, message: trimmed))
                showToast(asDirective ? "已向小爱下发指令：「\(trimmed)」" : "小爱已播报：「\(trimmed)」")
            } catch {
                showToast("发送失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    public func pressDeviceButton(_ buttonEntityId: String, label: String) {
        Task {
            do {
                try await provider.execute(.pressButton(entityId: buttonEntityId))
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
                try await provider.execute(.activateScene(entityId: scene.entityId))
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
                try? await provider.execute(cmd)
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
                try? await provider.execute(cmd)
            }
        }
    }

    private func scheduleUndoBanner(
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
                try? await provider.execute(cmd)
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
        if homeBackend != .homeAssistant || !(provider is HAWebSocketProvider) {
            switchBackend(.homeAssistant)
        } else if let haProvider = provider as? HAWebSocketProvider {
            Task {
                await haProvider.updateCredentials(baseURLString: serverURL, token: token)
            }
        }
        showToast("已保存并重新连接 Home Assistant")
    }

    public func refreshNow() {
        Task {
            await provider.refreshNow()
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

    private func lockOptimistic(_ deviceId: String, duration: Duration) {
        optimisticLockUntil[deviceId] = ContinuousClock.now.advanced(by: duration)
    }

    private func dispatchImmediate(
        deviceId: String,
        fallback: SmartDevice,
        command: DeviceCommand
    ) {
        Task {
            do {
                try await provider.execute(command)
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
                try await self.provider.execute(command)
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
    public private(set) var assistantFocusRequest: Int = 0
    /// Bumped to ask the command bar to start or toggle live speech recognition.
    public private(set) var assistantVoiceRequest: Int = 0
    public internal(set) var assistantState: AssistantState = .idle
    public internal(set) var assistantSuggestions: [AssistantSuggestion] = []
    public private(set) var isProactiveRecommending: Bool = false
    private var assistantResetTask: Task<Void, Never>?
    /// Test seam replacing the network resolver built from `assistantConfig`.
    var assistantResolverOverride: ModelIntentResolver?
    /// Commands waiting on a spoken delay ("10 分钟后关灯"), soonest first. Not persisted across launches.
    public private(set) var scheduledCommands: [ScheduledCommand] = []
    private var scheduledTasks: [UUID: Task<Void, Never>] = [:]
    /// The most recent assistant action, kept so "撤销" can restore it after the 5 s banner is gone.
    private var lastAssistantUndo: (reply: String, restore: [DeviceCommand], previous: [SmartDevice], at: Date)?
    /// How long a spoken "撤销" can still reach back.
    static let voiceUndoWindow: TimeInterval = 10 * 60
    /// Test seam for the delay before a scheduled command fires.
    var assistantSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public var assistantConfig: AssistantConfig {
        get { AssistantConfig.load(from: userDefaults) }
        set { newValue.save(to: userDefaults) }
    }

    public var userHabitMemory: UserHabitMemory {
        get { UserHabitMemory.load(from: userDefaults) }
        set { newValue.save(to: userDefaults) }
    }

    public func presentAssistantBar(startVoice: Bool = false) {
        isShowingAssistantBar = true
        if assistantSuggestions.isEmpty {
            assistantSuggestions = userHabitMemory.topSuggestions(devices: devices, scenes: scenes, limit: 3)
        }
        if startVoice {
            assistantVoiceRequest &+= 1
        } else {
            assistantFocusRequest &+= 1
        }
    }

    public func setPreviewState(
        assistantState: AssistantState,
        suggestions: [AssistantSuggestion],
        undoBanner: UndoBanner? = nil,
        homeBackend: HomeBackend? = nil,
        miSessionMaskedUserId: String? = nil
    ) {
        self.assistantState = assistantState
        self.assistantSuggestions = suggestions
        self.undoBanner = undoBanner
        if let homeBackend {
            self.homeBackend = homeBackend
        }
        if let miSessionMaskedUserId {
            self.miSessionMaskedUserId = miSessionMaskedUserId
        }
    }

    public func dismissAssistantBar() {
        isShowingAssistantBar = false
        if assistantState != .thinking {
            setAssistantState(.idle)
        }
    }

    public func buildAssistantContext(now: Date = Date()) -> AssistantContext {
        let bucket = UserHabitMemory.TimeBucket.from(date: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeSummary = "\(bucket.rawValue) \(formatter.string(from: now))"

        let envParts = environmentReadings.map { reading -> String in
            var text = "\(reading.roomName)"
            if let t = reading.temperature { text += " \(String(format: "%.1f°C", t))" }
            if let h = reading.humidity { text += " \(Int(h.rounded()))%" }
            return text
        }
        let environmentSummary = envParts.joined(separator: "，")

        let activeParts = devices.filter { $0.isOnline && $0.isActiveOn }.map { dev in
            "\(dev.name)(\(IntentCatalog.stateSummary(dev)))"
        }
        let activeSummary = activeParts.isEmpty ? "全屋设备均关闭" : activeParts.joined(separator: "、")
        let habitSummary = userHabitMemory.promptSummary(for: now, devices: devices, scenes: scenes)

        return AssistantContext(
            timeSummary: timeSummary,
            environmentSummary: environmentSummary,
            activeDevicesSummary: activeSummary,
            habitSummary: habitSummary
        )
    }

    /// Uses Jev System One to infer personalized proactive suggestions from current room temp/humidity,
    /// time of day, active devices, and the user's learned habit memory.
    public func requestProactiveJevSuggestions() async {
        guard !isProactiveRecommending else { return }
        isProactiveRecommending = true
        defer { isProactiveRecommending = false }

        let resolver = assistantResolverOverride ?? ModelIntentResolver(config: assistantConfig)
        let context = buildAssistantContext()
        do {
            let inferred = try await resolver.recommendProactiveSuggestions(
                devices: devices,
                scenes: scenes,
                context: context
            )
            if !inferred.isEmpty {
                assistantSuggestions = inferred
                setAssistantState(.done("Jev 已结合室温与习惯生成建议"))
            } else {
                let fallback = userHabitMemory.topSuggestions(devices: devices, scenes: scenes, limit: 3)
                assistantSuggestions = fallback
                setAssistantState(.done("当前居家状态已处于理想区间"))
            }
        } catch {
            setAssistantState(.failed(AssistantError.userMessage(for: error)))
        }
    }

    public func applyAssistantSuggestion(_ suggestion: AssistantSuggestion) async {
        assistantSuggestions.removeAll { $0.id == suggestion.id }
        let reply = IntentReply.describe(suggestion.intents, devices: devices, scenes: scenes)
        let plan = IntentPlan(intents: suggestion.intents, reply: reply, source: .model)
        _ = await executeIntentPlan(plan, recordedUtterance: nil)
    }

    /// Resolves a natural-language command (local parser first, model fallback) and applies it.
    @discardableResult
    public func runAssistantCommand(_ text: String) async -> IntentPlan? {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return nil }
        if DelayPhrase.isCancel(spoken) {
            let count = cancelScheduledCommands()
            setAssistantState(count > 0 ? .done("已取消 \(count) 个定时") : .failed("现在没有定时任务"))
            return nil
        }
        if UndoPhrase.isUndo(spoken) {
            await undoLastAssistantAction()
            return nil
        }
        let delayed = DelayPhrase.extract(spoken)
        let utterance = delayed?.remainder ?? spoken
        setAssistantState(.thinking)

        let plan: IntentPlan
        if let local = LocalIntentParser.parse(utterance, devices: devices, scenes: scenes) {
            plan = local
        } else {
            let resolver = assistantResolverOverride ?? ModelIntentResolver(config: assistantConfig)
            let context = buildAssistantContext()
            do {
                plan = try await resolver.resolve(utterance, devices: devices, scenes: scenes, context: context)
            } catch {
                setAssistantState(.failed(AssistantError.userMessage(for: error)))
                return nil
            }
        }
        guard !plan.intents.isEmpty else {
            if !plan.suggestions.isEmpty {
                assistantSuggestions = plan.suggestions
            }
            setAssistantState(.failed(plan.reply.isEmpty ? "没有找到可执行的设备操作" : plan.reply))
            return plan
        }

        if let delayed {
            return schedule(plan, after: delayed.delay)
        }
        return await executeIntentPlan(plan, recordedUtterance: utterance)
    }

    // MARK: - Voice Undo

    /// Restores only the devices the last assistant action touched; others may have changed since.
    private func undoLastAssistantAction() async {
        guard let last = lastAssistantUndo, Date().timeIntervalSince(last.at) <= Self.voiceUndoWindow else {
            lastAssistantUndo = nil
            setAssistantState(.failed("没有可以撤销的操作"))
            return
        }
        lastAssistantUndo = nil
        undoTimerTask?.cancel()
        undoBanner = nil
        for previous in last.previous {
            guard let idx = devices.firstIndex(where: { $0.id == previous.id }) else { continue }
            devices[idx] = previous
            lockOptimistic(previous.id, duration: .seconds(3.0))
        }
        for cmd in last.restore {
            try? await provider.execute(cmd)
        }
        let what = last.reply.hasPrefix("已") ? String(last.reply.dropFirst()) : last.reply
        setAssistantState(.done("已撤销：\(what)"))
    }

    // MARK: - Scheduled Commands

    private func schedule(_ plan: IntentPlan, after delay: TimeInterval) -> IntentPlan {
        var action = IntentReply.describe(plan.intents, devices: devices, scenes: scenes)
        if action.hasPrefix("已") { action.removeFirst() }
        let entry = ScheduledCommand(
            reply: DelayPhrase.describe(delay) + action,
            fireDate: Date().addingTimeInterval(delay),
            plan: plan
        )
        scheduledCommands.append(entry)
        scheduledCommands.sort { $0.fireDate < $1.fireDate }
        let sleep = assistantSleep
        scheduledTasks[entry.id] = Task { [weak self] in
            do { try await sleep(.seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduledCommands.removeAll { $0.id == entry.id }
            self.scheduledTasks[entry.id] = nil
            _ = await self.executeIntentPlan(entry.plan, recordedUtterance: nil)
        }
        var reply = plan
        reply.reply = "好的，" + entry.reply
        setAssistantState(.done(reply.reply))
        return reply
    }

    /// Cancels one pending command, or all of them when `id` is nil. Returns how many were cancelled.
    @discardableResult
    public func cancelScheduledCommands(id: UUID? = nil) -> Int {
        let targets = scheduledCommands.filter { id == nil || $0.id == id }
        for entry in targets {
            scheduledTasks.removeValue(forKey: entry.id)?.cancel()
        }
        scheduledCommands.removeAll { entry in targets.contains { $0.id == entry.id } }
        return targets.count
    }

    private func executeIntentPlan(_ plan: IntentPlan, recordedUtterance: String?) async -> IntentPlan {
        let previousSnapshot = devices
        var groupOrder: [String] = []
        var intentsByTarget: [String: [DeviceIntent]] = [:]
        for intent in plan.intents {
            if intentsByTarget[intent.targetId] == nil { groupOrder.append(intent.targetId) }
            intentsByTarget[intent.targetId, default: []].append(intent)
        }

        // Devices run concurrently so every tile flips at once; one device's intents stay ordered
        // (e.g. hvac mode before target temperature).
        let deviceTasks = groupOrder.map { targetId in
            let intents = intentsByTarget[targetId] ?? []
            return Task { () -> [AssistantApplyOutcome] in
                var out: [AssistantApplyOutcome] = []
                for intent in intents {
                    out.append(await self.apply(intent))
                }
                return out
            }
        }
        var outcomes: [AssistantApplyOutcome] = []
        for task in deviceTasks {
            outcomes.append(contentsOf: await task.value)
        }

        var restoreCommands: [DeviceCommand] = []
        var failedNames: [String] = []
        var offlineNames: [String] = []
        var appliedDeviceIds: Set<String> = []
        for outcome in outcomes {
            switch outcome {
            case .applied(let deviceId, let restore):
                restoreCommands.append(contentsOf: restore)
                if let deviceId { appliedDeviceIds.insert(deviceId) }
            case .failed(let name):
                if !failedNames.contains(name) { failedNames.append(name) }
            case .offline(let name):
                if !offlineNames.contains(name) { offlineNames.append(name) }
            case .skipped:
                break
            }
        }

        if !appliedDeviceIds.isEmpty {
            lastAssistantUndo = (
                reply: plan.reply,
                restore: restoreCommands.reversed(),
                previous: previousSnapshot.filter { appliedDeviceIds.contains($0.id) },
                at: Date()
            )
        }

        if appliedDeviceIds.count > 1 {
            scheduleUndoBanner(
                title: plan.reply.isEmpty ? "已执行 AI 指令" : plan.reply,
                restoreCommands: restoreCommands.reversed(),
                previousDevices: previousSnapshot
            )
        }

        if !failedNames.isEmpty {
            setAssistantState(.failed("\(failedNames.joined(separator: "、")) 未响应"))
        } else if outcomes.allSatisfy({ if case .applied = $0 { return false } else { return true } }) {
            let reason = offlineNames.isEmpty ? "没有可执行的设备操作" : "\(offlineNames.joined(separator: "、")) 当前离线"
            setAssistantState(.failed(reason))
        } else {
            var memory = userHabitMemory
            memory.record(utterance: recordedUtterance, intents: plan.intents, devices: devices, scenes: scenes)
            userHabitMemory = memory

            if !plan.suggestions.isEmpty {
                assistantSuggestions = plan.suggestions
            } else {
                assistantSuggestions = memory.topSuggestions(devices: devices, scenes: scenes, limit: 3)
            }
            setAssistantState(.done(plan.reply))
        }
        return plan
    }

    private enum AssistantApplyOutcome: Sendable {
        case applied(deviceId: String?, restore: [DeviceCommand])
        case failed(String)
        case offline(String)
        case skipped
    }

    private struct AssistantEffect {
        let updated: SmartDevice
        let command: DeviceCommand
        let restore: [DeviceCommand]
    }

    /// The single execution path for assistant intents: optimistic update, lock, dispatch, rollback on failure.
    private func apply(_ intent: DeviceIntent) async -> AssistantApplyOutcome {
        if intent.operation == .activateScene {
            guard let scene = scenes.first(where: { $0.id == intent.targetId }) else { return .skipped }
            do {
                try await provider.execute(.activateScene(entityId: scene.entityId))
                return .applied(deviceId: nil, restore: [])
            } catch {
                return .failed(scene.name)
            }
        }

        guard let idx = devices.firstIndex(where: { $0.id == intent.targetId }) else { return .skipped }
        let previous = devices[idx]
        guard previous.isOnline else { return .offline(previous.name) }
        guard let effect = Self.assistantEffect(of: intent.operation, on: previous) else { return .skipped }

        devices[idx] = effect.updated
        lockOptimistic(previous.id, duration: .seconds(3.0))
        do {
            try await provider.execute(effect.command)
            return .applied(deviceId: previous.id, restore: effect.restore)
        } catch {
            if let revertIdx = devices.firstIndex(where: { $0.id == previous.id }) {
                devices[revertIdx] = previous
            }
            optimisticLockUntil.removeValue(forKey: previous.id)
            return .failed(previous.name)
        }
    }

    private static func assistantEffect(of operation: IntentOperation, on device: SmartDevice) -> AssistantEffect? {
        guard let op = IntentValidator.normalize(operation, for: device) else { return nil }
        var updated = device

        switch (op, device.kind) {
        case (.power(let on), .light(var s)):
            let restore = DeviceCommand.setLightPower(entityId: s.entityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .light(s)
            return AssistantEffect(updated: updated, command: .setLightPower(entityId: s.entityId, isOn: on), restore: [restore])

        case (.brightness(let percent), .light(var s)):
            let restore: DeviceCommand = s.isOn
                ? .setLightBrightness(entityId: s.entityId, percent: s.brightnessPercent ?? 100)
                : .setLightPower(entityId: s.entityId, isOn: false)
            s.isOn = true
            s.brightnessPercent = percent
            updated.kind = .light(s)
            return AssistantEffect(updated: updated, command: .setLightBrightness(entityId: s.entityId, percent: percent), restore: [restore])

        case (.colorTemperature(let kelvin), .light(var s)):
            let restore: DeviceCommand
            if !s.isOn {
                restore = .setLightPower(entityId: s.entityId, isOn: false)
            } else if let prevKelvin = s.colorTempKelvin {
                restore = .setLightColorTemp(entityId: s.entityId, kelvin: prevKelvin)
            } else {
                restore = .setLightPower(entityId: s.entityId, isOn: true)
            }
            s.isOn = true
            s.colorTempKelvin = kelvin
            s.currentEffect = nil
            updated.kind = .light(s)
            return AssistantEffect(updated: updated, command: .setLightColorTemp(entityId: s.entityId, kelvin: kelvin), restore: [restore])

        case (.lightEffect(let effect), .light(var s)):
            let restore: DeviceCommand
            if !s.isOn {
                restore = .setLightPower(entityId: s.entityId, isOn: false)
            } else if let prevEffect = s.currentEffect {
                restore = .setLightEffect(entityId: s.entityId, effect: prevEffect)
            } else if let prevKelvin = s.colorTempKelvin {
                restore = .setLightColorTemp(entityId: s.entityId, kelvin: prevKelvin)
            } else {
                restore = .setLightPower(entityId: s.entityId, isOn: true)
            }
            s.isOn = true
            s.currentEffect = effect
            updated.kind = .light(s)
            return AssistantEffect(
                updated: updated,
                command: .setLightEffect(entityId: s.entityId, effect: effect),
                restore: [restore]
            )

        case (.power(let on), .climate(var s)):
            let wasOn = s.isOn && s.hvacMode != "off"
            let resumeMode = s.hvacMode == "off" ? (s.availableModes.first(where: { $0 != "off" }) ?? "heat") : s.hvacMode
            let restore = DeviceCommand.setClimatePower(entityId: s.entityId, isOn: wasOn, fallbackMode: resumeMode)
            s.isOn = on
            s.hvacMode = on ? resumeMode : "off"
            updated.kind = .climate(s)
            return AssistantEffect(
                updated: updated,
                command: .setClimatePower(entityId: s.entityId, isOn: on, fallbackMode: resumeMode),
                restore: [restore]
            )

        case (.hvacMode(let mode), .climate(var s)):
            let restore = DeviceCommand.setClimateMode(entityId: s.entityId, hvacMode: s.isOn ? s.hvacMode : "off")
            s.hvacMode = mode
            s.isOn = (mode != "off")
            updated.kind = .climate(s)
            return AssistantEffect(updated: updated, command: .setClimateMode(entityId: s.entityId, hvacMode: mode), restore: [restore])

        case (.targetTemperature(let temperature), .climate(var s)):
            let restore = DeviceCommand.setClimateTemperature(entityId: s.entityId, temperature: s.targetTemperature)
            s.targetTemperature = temperature
            updated.kind = .climate(s)
            return AssistantEffect(
                updated: updated,
                command: .setClimateTemperature(entityId: s.entityId, temperature: temperature),
                restore: [restore]
            )

        case (.power(let on), .fan(var s)):
            let restore = DeviceCommand.setFanPower(entityId: s.entityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .fan(s)
            return AssistantEffect(updated: updated, command: .setFanPower(entityId: s.entityId, isOn: on), restore: [restore])

        case (.power(let on), .plug(var s)):
            let restore = DeviceCommand.setSwitch(entityId: s.switchEntityId, isOn: s.isOn)
            s.isOn = on
            updated.kind = .plug(s)
            return AssistantEffect(updated: updated, command: .setSwitch(entityId: s.switchEntityId, isOn: on), restore: [restore])

        case (.power(let on), .vacuum(var s)):
            let restore = DeviceCommand.vacuumAction(entityId: s.entityId, action: s.isCleaning ? .start : .returnToBase)
            s.status = on ? "cleaning" : "returning"
            updated.kind = .vacuum(s)
            return AssistantEffect(
                updated: updated,
                command: .vacuumAction(entityId: s.entityId, action: on ? .start : .returnToBase),
                restore: [restore]
            )

        case (.fanSpeed(let preset), .fan(var s)):
            let restore: DeviceCommand
            if !s.isOn {
                restore = .setFanPower(entityId: s.entityId, isOn: false)
            } else if let previous = s.presetMode {
                restore = .setFanPresetMode(entityId: s.entityId, presetMode: previous)
            } else {
                restore = .setFanPower(entityId: s.entityId, isOn: true)
            }
            s.isOn = true
            s.presetMode = preset
            updated.kind = .fan(s)
            return AssistantEffect(updated: updated, command: .setFanPresetMode(entityId: s.entityId, presetMode: preset), restore: [restore])

        case (.fanSpeed(let fanMode), .climate(var s)):
            let restore = s.fanMode.map { [DeviceCommand.setClimateFanMode(entityId: s.entityId, fanMode: $0)] } ?? []
            s.fanMode = fanMode
            updated.kind = .climate(s)
            return AssistantEffect(updated: updated, command: .setClimateFanMode(entityId: s.entityId, fanMode: fanMode), restore: restore)

        case (.oscillation(let on), .fan(var s)):
            let restore = DeviceCommand.setFanOscillating(entityId: s.entityId, oscillating: s.isOscillating ?? !on)
            s.isOscillating = on
            updated.kind = .fan(s)
            return AssistantEffect(updated: updated, command: .setFanOscillating(entityId: s.entityId, oscillating: on), restore: [restore])

        default:
            return nil
        }
    }

    private func setAssistantState(_ state: AssistantState) {
        assistantState = state
        assistantResetTask?.cancel()
        switch state {
        case .done, .failed:
            assistantResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3.2))
                guard !Task.isCancelled, let self, self.assistantState == state else { return }
                self.assistantState = .idle
            }
        case .idle, .thinking:
            break
        }
    }
}
