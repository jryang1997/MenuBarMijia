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

    public var selectedRoomId: String? = nil // nil = 全部 / 常用
    public var expandedDeviceId: String? = nil
    public var isShowingSettings: Bool = false

    public var hideOfflineDevices: Bool {
        didSet { UserDefaults.standard.set(hideOfflineDevices, forKey: "hide_offline_devices") }
    }

    public var favoriteDeviceIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(favoriteDeviceIds), forKey: "favorite_device_ids")
        }
    }

    public var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { UserDefaults.standard.set(menuBarDisplayMode.rawValue, forKey: "menubar_display_mode") }
    }

    public var homeName: String {
        didSet { UserDefaults.standard.set(homeName, forKey: "home_name") }
    }

    public var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: "ha_server_url") }
    }

    public var serverHostSummary: String {
        if let url = URL(string: serverURLString), let host = url.host() {
            return host
        }
        return serverURLString
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    public private(set) var toastNotice: ToastNotice?
    public private(set) var undoBanner: UndoBanner?

    private var provider: any HomeProvider
    private var eventTask: Task<Void, Never>?
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var undoTimerTask: Task<Void, Never>?
    private var toastTimerTask: Task<Void, Never>?
    private var optimisticLockUntil: [String: ContinuousClock.Instant] = [:]

    public init(provider: (any HomeProvider)? = nil) {
        let savedURL = UserDefaults.standard.string(forKey: "ha_server_url") ?? KeychainHelper.defaultNASURL
        self.serverURLString = savedURL
        self.homeName = UserDefaults.standard.string(forKey: "home_name") ?? KeychainHelper.defaultHomeName
        self.hideOfflineDevices = UserDefaults.standard.bool(forKey: "hide_offline_devices")

        if let modeRaw = UserDefaults.standard.string(forKey: "menubar_display_mode"),
           let mode = MenuBarDisplayMode(rawValue: modeRaw) {
            self.menuBarDisplayMode = mode
        } else {
            self.menuBarDisplayMode = .primaryTemp
        }

        if let savedFavs = UserDefaults.standard.stringArray(forKey: "favorite_device_ids") {
            self.favoriteDeviceIds = Set(savedFavs)
        } else {
            self.favoriteDeviceIds = []
        }

        let token = KeychainHelper.loadToken()
        self.provider = provider ?? HAWebSocketProvider(baseURLString: savedURL, token: token)
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
        }
    }

    private func seedDefaultFavoritesIfNeeded() {
        guard favoriteDeviceIds.isEmpty,
              UserDefaults.standard.object(forKey: "favorite_device_ids") == nil,
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
        }
    }

    // MARK: - Computed Views of State

    public var activeDeviceCount: Int {
        devices.filter(\.isActiveOn).count
    }

    public var onlineDeviceCount: Int {
        devices.filter(\.isOnline).count
    }

    public var filteredDevices: [SmartDevice] {
        devices.filter { dev in
            if hideOfflineDevices && !dev.isOnline { return false }
            if let roomId = selectedRoomId {
                return dev.roomId == roomId
            }
            return true
        }
    }

    public var favoriteDevices: [SmartDevice] {
        filteredDevices.filter { favoriteDeviceIds.contains($0.id) }
    }

    public var nonFavoriteDevices: [SmartDevice] {
        filteredDevices.filter { !favoriteDeviceIds.contains($0.id) }
    }

    public var menuBarSymbolName: String {
        activeDeviceCount > 0 ? "house.fill" : "house"
    }

    public var menuBarText: String? {
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

    // MARK: - User Actions & Optimistic State Mutations

    public func toggleFavorite(_ deviceId: String) {
        if favoriteDeviceIds.contains(deviceId) {
            favoriteDeviceIds.remove(deviceId)
        } else {
            favoriteDeviceIds.insert(deviceId)
        }
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

        let banner = UndoBanner(
            title: "已关闭 \(offCommands.count) 台设备",
            restoreCommands: restoreCommands,
            previousDevices: previousSnapshot
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

        Task {
            for cmd in offCommands {
                try? await provider.execute(cmd)
            }
        }
    }

    public func undoTurnAllOff() {
        guard let banner = undoBanner else { return }
        undoTimerTask?.cancel()
        self.undoBanner = nil
        self.devices = banner.previousDevices

        for dev in banner.previousDevices where dev.isActiveOn {
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

    public func updateConnection(serverURL: String, token: String) {
        self.serverURLString = serverURL
        KeychainHelper.saveToken(token)
        if let haProvider = provider as? HAWebSocketProvider {
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
}
