import Foundation

// Scenes, quick actions, 全关 and the unified undo banner (#48).
extension HomeStore {
    func invalidateUndoContext() {
        controlContextID = UUID()
        undoTimerTask?.cancel()
        undoBanner = nil
        lastAssistantUndo = nil
        setAssistantState(.idle)
        pendingCloudConsent = nil
        assistantSuggestions = []
        optimisticLockUntil.removeAll()
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
    }

    // MARK: - Scenes & Built-In QuickActions with 5-Second Undo

    @discardableResult
    public func triggerScene(_ scene: HomeScene) -> Task<Bool, Never> {
        Task {
            do {
                try await executeDeviceCommand(.activateScene(entityId: scene.entityId))
                showToast(L10n.tr("已触发场景：\(scene.name)", "Activated scene: \(scene.name)"))
                return true
            } catch {
                showToast(L10n.tr("场景「\(scene.name)」执行失败", "Scene \"\(scene.name)\" failed"), isError: true)
                return false
            }
        }
    }

    public func executeQuickAction(_ action: QuickAction, undoBannerDuration: TimeInterval? = nil) {
        let previousSnapshot = devices
        var commands: [DeviceCommand] = []
        var restoreCommands: [DeviceCommand] = []
        var affectedDeviceIds: Set<String> = []

        switch action {
        case .lightsOff:
            for idx in devices.indices where devices[idx].isOnline {
                guard case .light(var s) = devices[idx].kind, s.isOn else { continue }
                affectedDeviceIds.insert(devices[idx].id)
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
                // Prefer the light the user last switched on by hand; otherwise the first light (#36).
                let fallbackIdx = lastManuallyUsedLightId.flatMap { lastLightId in
                    devices.indices.first(where: { isOnlineLight(devices[$0]) && devices[$0].id == lastLightId })
                } ?? devices.indices.first(where: { isOnlineLight(devices[$0]) })
                if let fallbackIdx {
                    targetIndices = [fallbackIdx]
                    if lastManuallyUsedLightId == nil {
                        // No manual pick yet: remember the light this action chose so the next tap is stable.
                        recordManualLightUse(devices[fallbackIdx].id)
                    }
                }
            }
            for idx in targetIndices {
                guard case .light(var s) = devices[idx].kind else { continue }
                affectedDeviceIds.insert(devices[idx].id)
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
                    affectedDeviceIds.insert(devices[idx].id)
                    lockOptimistic(devices[idx].id, duration: .seconds(3.0))
                    commands.append(.setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: prevMode))
                    restoreCommands.append(.setClimatePower(entityId: s.entityId, isOn: true, fallbackMode: prevMode))
                    s.isOn = false
                    s.hvacMode = "off"
                    devices[idx].kind = .climate(s)
                case .fan(var s) where s.isOn:
                    affectedDeviceIds.insert(devices[idx].id)
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
            showToast(L10n.tr("当前无需执行「\(action.title)」", "No devices need \"\(action.title)\""))
            return
        }

        scheduleUndoBanner(
            title: L10n.tr("已执行「\(action.title)」", "Executed \"\(action.title)\""),
            restoreCommands: restoreCommands,
            previousDevices: previousSnapshot,
            deviceCount: affectedDeviceIds.count,
            duration: undoBannerDuration
        )

        let context = controlContextID
        Task {
            for cmd in commands {
                guard context == controlContextID else { return }
                try? await executeDeviceCommand(cmd)
            }
        }
    }

    // MARK: - Turn All Off with Undo

    /// Plugs often power a router, fridge or NAS, and 全关 should not send a cleaning vacuum home (#23).
    public nonisolated static func joinsAllOffByDefault(_ device: SmartDevice) -> Bool {
        switch device.kind {
        case .plug, .vacuum: return false
        default: return true
        }
    }

    public func joinsAllOff(_ device: SmartDevice) -> Bool {
        allOffOverrides[device.id] ?? Self.joinsAllOffByDefault(device)
    }

    public func setJoinsAllOff(_ joins: Bool, deviceId: String) {
        guard let device = devices.first(where: { $0.id == deviceId }) else { return }
        allOffOverrides[deviceId] = joins == Self.joinsAllOffByDefault(device) ? nil : joins
    }

    /// What 全关 turns off: devices on screen right now (current room, not hidden) that are on,
    /// take part in 全关, and can actually be switched off from here.
    public var allOffTargets: [SmartDevice] {
        filteredDevices.filter { $0.isActiveOn && joinsAllOff($0) && Self.allOffChange(for: $0) != nil }
    }

    /// The room 全关 is limited to, or nil for the whole visible home.
    public var allOffRoomName: String? {
        guard let roomId = selectedRoomId else { return nil }
        return rooms.first(where: { $0.id == roomId })?.name
    }

    /// The command that switches `device` off, the one that brings it back, and the optimistic state.
    nonisolated static func allOffChange(for device: SmartDevice) -> (off: DeviceCommand, restore: DeviceCommand, kind: DeviceKind)? {
        switch device.kind {
        case .light(var s):
            s.isOn = false
            return (.setLightPower(entityId: s.entityId, isOn: false), .setLightPower(entityId: s.entityId, isOn: true), .light(s))
        case .climate(var s):
            let prevMode = s.hvacMode
            s.isOn = false
            s.hvacMode = "off"
            return (
                .setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: prevMode),
                .setClimatePower(entityId: s.entityId, isOn: true, fallbackMode: prevMode),
                .climate(s)
            )
        case .fan(var s):
            s.isOn = false
            return (.setFanPower(entityId: s.entityId, isOn: false), .setFanPower(entityId: s.entityId, isOn: true), .fan(s))
        case .plug(var s):
            s.isOn = false
            return (.setSwitch(entityId: s.switchEntityId, isOn: false), .setSwitch(entityId: s.switchEntityId, isOn: true), .plug(s))
        case .vacuum(var s):
            s.status = "returning"
            return (.vacuumAction(entityId: s.entityId, action: .returnToBase), .vacuumAction(entityId: s.entityId, action: .start), .vacuum(s))
        case .tv(var s):
            guard LGWebOSProtocol.isLGEntity(s.mediaEntityId) else { return nil }
            s.state = "standby"
            return (
                .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: false),
                .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true),
                .tv(s)
            )
        case .speaker, .fridge, .sensor:
            return nil
        }
    }

    public func turnAllOff() {
        let targetIds = Set(allOffTargets.map(\.id))
        guard !targetIds.isEmpty else {
            showToast(L10n.tr("当前没有开启的设备", "No active devices are currently on"))
            return
        }

        let previousSnapshot = devices
        var offCommands: [DeviceCommand] = []
        var restoreCommands: [DeviceCommand] = []

        for idx in devices.indices where targetIds.contains(devices[idx].id) {
            guard let change = Self.allOffChange(for: devices[idx]) else { continue }
            lockOptimistic(devices[idx].id, duration: .seconds(3.0))
            offCommands.append(change.off)
            restoreCommands.append(change.restore)
            devices[idx].kind = change.kind
        }

        scheduleUndoBanner(
            title: L10n.tr("已关闭 \(offCommands.count) 台设备", "Turned off \(offCommands.count) device(s)"),
            restoreCommands: restoreCommands,
            previousDevices: previousSnapshot,
            deviceCount: targetIds.count
        )

        let context = controlContextID
        Task {
            for cmd in offCommands {
                guard context == controlContextID else { return }
                try? await executeDeviceCommand(cmd)
            }
        }
    }

    /// How long the 撤销 banner stays after 全关 and similar bulk actions (#23): 10 s for one or two
    /// devices, 15 s from three on so the user can read which devices the AI touched (#53).
    nonisolated static func undoBannerSeconds(forDeviceCount count: Int) -> Double {
        count >= 3 ? 15 : 10
    }

    func scheduleUndoBanner(
        title: String,
        restoreCommands: [DeviceCommand],
        previousDevices: [SmartDevice],
        deviceCount: Int,
        habitReceipt: UserHabitMemory.RecordingReceipt? = nil,
        duration: TimeInterval? = nil
    ) {
        let banner = UndoBanner(
            title: title,
            restoreCommands: restoreCommands,
            previousDevices: previousDevices,
            habitReceipt: habitReceipt,
            duration: duration
        )
        self.undoBanner = banner
        undoTimerTask?.cancel()
        // `duration` overrides the panel's 10/15 s rule for automation, which usually fires while
        // the panel is closed (#59).
        let seconds = duration ?? Self.undoBannerSeconds(forDeviceCount: deviceCount)
        undoTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self?.undoBanner?.id == banner.id {
                self?.undoBanner = nil
            }
        }
    }

    public func undoTurnAllOff() {
        guard let banner = undoBanner else { return }
        lastAssistantUndo = nil
        undoTimerTask?.cancel()
        self.undoBanner = nil
        let commands = applyUndoCommands(banner.restoreCommands)

        if let receipt = banner.habitReceipt {
            var memory = userHabitMemory
            memory.unrecord(receipt)
            userHabitMemory = memory
        }

        let context = controlContextID
        Task {
            for cmd in commands {
                guard context == controlContextID else { return }
                try? await executeDeviceCommand(cmd)
            }
            guard context == controlContextID else { return }
            showToast(L10n.tr("已恢复关闭前的状态", "Restored previous device states"))
        }
    }

    func applyUndoCommands(_ commands: [DeviceCommand]) -> [DeviceCommand] {
        var applicable: [DeviceCommand] = []
        for command in commands {
            for idx in devices.indices {
                guard let restored = Self.undoEffect(of: command, on: devices[idx]) else { continue }
                devices[idx] = restored
                lockOptimistic(restored.id, duration: .seconds(3.0))
                applicable.append(command)
                break
            }
        }
        return applicable
    }
}
