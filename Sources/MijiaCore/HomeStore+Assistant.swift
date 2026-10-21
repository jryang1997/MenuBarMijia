import Foundation
import Observation

// Assistant side of HomeStore: command bar, model/local intent resolution,
// spoken delays, voice undo and applying intents to devices.
// Stored state lives in HomeStore.swift (extensions cannot hold stored properties).
extension HomeStore {
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
        let habitSummary = isHabitLearningEnabled
            ? userHabitMemory.promptSummary(for: now, devices: devices, scenes: scenes)
            : ""

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
        let config = assistantConfig
        if assistantResolverOverride == nil && !config.hasAPIKey && !config.isLoopbackEndpoint {
            setAssistantState(.failed(AssistantError.userMessage(for: AssistantError.missingAPIKey)))
            return
        }
        isProactiveRecommending = true
        defer { isProactiveRecommending = false }

        let resolver = assistantResolverOverride ?? ModelIntentResolver(config: config)
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
            let config = assistantConfig
            if assistantResolverOverride == nil && !config.hasAPIKey && !config.isLoopbackEndpoint {
                setAssistantState(.failed(AssistantError.userMessage(for: AssistantError.missingAPIKey)))
                return nil
            }
            let resolver = assistantResolverOverride ?? ModelIntentResolver(config: config)
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
            try? await executeDeviceCommand(cmd)
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
            if isHabitLearningEnabled { userHabitMemory = memory }

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
                try await executeDeviceCommand(.activateScene(entityId: scene.entityId))
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
            try await executeDeviceCommand(effect.command)
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

        case (.power(let on), .tv(var s)):
            let wasOn = s.state != "off" && s.state != "standby"
            let powerEntity = LGWebOSProtocol.isLGEntity(s.mediaEntityId) ? LGWebOSProtocol.powerEntityId : s.mediaEntityId
            let restore = DeviceCommand.setSwitch(entityId: powerEntity, isOn: wasOn)
            s.state = on ? "on" : "standby"
            if on { s.isScreenOff = false }
            updated.kind = .tv(s)
            return AssistantEffect(
                updated: updated,
                command: .setSwitch(entityId: powerEntity, isOn: on),
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
