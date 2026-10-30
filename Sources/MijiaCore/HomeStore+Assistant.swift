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

    /// Uses the configured AI model (Jev System One or OpenAI-compatible Chat) to infer personalized proactive suggestions
    /// from current room temp/humidity, time of day, active devices, and the user's learned habit memory.
    public func requestProactiveJevSuggestions() async {
        guard !isProactiveRecommending else { return }
        guard homeBackend != .demo else {
            // 演示模式完全离线（#47）：只给基于本地习惯记忆的建议。
            assistantSuggestions = userHabitMemory.topSuggestions(devices: devices, scenes: scenes, limit: 3)
            setAssistantState(.done(L10n.tr("演示模式建议基于内置虚拟设备", "Demo suggestions are based on the built-in virtual home")))
            return
        }
        let config = assistantConfig
        if shouldRejectMissingAPIKey(for: config) {
            setAssistantState(.failed(AssistantError.userMessage(for: AssistantError.missingAPIKey)))
            return
        }
        if let consent = cloudConsentNeeded(for: config, utterance: nil) {
            pendingCloudConsent = consent
            return
        }
        isProactiveRecommending = true
        defer { isProactiveRecommending = false }

        let resolver = makeAssistantResolver(config: config)
        let context = buildAssistantContext()
        do {
            let inferred = try await resolver.recommendProactiveSuggestions(
                devices: devices,
                scenes: scenes,
                context: context
            )
            if !inferred.isEmpty {
                assistantSuggestions = inferred
                let label = ModelIntentResolver.isSystemOneModel(config.model) ? "Jev" : "AI"
                setAssistantState(.done(L10n.tr("\(label) 已结合室温与习惯生成建议", "\(label) generated suggestions from room climate & habits")))
            } else {
                let fallback = userHabitMemory.topSuggestions(devices: devices, scenes: scenes, limit: 3)
                assistantSuggestions = fallback
                setAssistantState(.done(L10n.tr("当前居家状态已处于理想区间", "Home environment is already in an ideal range")))
            }
        } catch {
            setAssistantState(.failed(AssistantError.userMessage(for: error)))
        }
    }

    /// Persists and verifies the given AI configuration against the live endpoint using the same reloaded `assistantConfig` as normal command execution.
    public func verifyAssistantConfig(_ draftConfig: AssistantConfig) async -> (isSuccess: Bool, message: String) {
        assistantConfig = draftConfig
        guard homeBackend != .demo else {
            return (false, L10n.tr("演示模式不联网，请切换数据源后测试连接", "Demo mode is offline; switch the data source to test this connection"))
        }
        let resolved = assistantConfig
        if shouldRejectMissingAPIKey(for: resolved) {
            return (false, AssistantError.userMessage(for: AssistantError.missingAPIKey))
        }
        let resolver = makeAssistantResolver(config: resolved)
        do {
            let ms = try await resolver.testConnection()
            let presetLabel = resolved.preset.shortTitle
            return (
                true,
                L10n.tr(
                    "连接成功 (\(presetLabel) · \(ms) ms)",
                    "Connected (\(presetLabel) · \(ms) ms)"
                )
            )
        } catch {
            return (false, AssistantError.userMessage(for: error))
        }
    }

    // MARK: - Cloud consent (#20)

    static let cloudConsentKey = "assistant_cloud_consent_v1"

    /// AI services (host[:port]) the user has allowed to receive commands. Local endpoints never need this.
    public var consentedCloudEndpoints: [String] {
        userDefaults.stringArray(forKey: Self.cloudConsentKey) ?? []
    }

    /// The consent request to show before the first cloud call to this service, or nil when sending is already allowed.
    func cloudConsentNeeded(for config: AssistantConfig, utterance: String?) -> PendingCloudConsent? {
        guard assistantResolverOverride == nil, !config.isLoopbackEndpoint,
              let endpoint = AssistantEndpoint(config.baseURL)?.identity,
              !consentedCloudEndpoints.contains(endpoint) else {
            return nil
        }
        return PendingCloudConsent(utterance: utterance, endpoint: endpoint, providerTitle: config.preset.shortTitle)
    }

    /// Remembers the user's OK for the waiting service, then runs what was waiting.
    @discardableResult
    public func allowPendingCloudRequest() async -> IntentPlan? {
        guard let pending = pendingCloudConsent else { return nil }
        pendingCloudConsent = nil
        var endpoints = consentedCloudEndpoints
        if !endpoints.contains(pending.endpoint) {
            endpoints.append(pending.endpoint)
        }
        userDefaults.set(endpoints, forKey: Self.cloudConsentKey)
        guard let utterance = pending.utterance else {
            await requestProactiveJevSuggestions()
            return nil
        }
        return await runAssistantCommand(utterance)
    }

    public func declinePendingCloudRequest() {
        guard pendingCloudConsent != nil else { return }
        pendingCloudConsent = nil
        setAssistantState(.failed(L10n.tr(
            "没有发送。「打开书房灯」这类简单指令不用联网",
            "Not sent. Direct commands like \"turn on study light\" work offline."
        )))
    }

    /// Forgets every allowed AI service; the next cloud request asks again.
    public func revokeCloudConsent() {
        userDefaults.removeObject(forKey: Self.cloudConsentKey)
        pendingCloudConsent = nil
    }

    private func shouldRejectMissingAPIKey(for config: AssistantConfig) -> Bool {
        assistantResolverOverride == nil && !config.hasAPIKey && !config.isLoopbackEndpoint
    }

    private func makeAssistantResolver(config: AssistantConfig) -> ModelIntentResolver {
        assistantResolverOverride ?? ModelIntentResolver(config: config, transport: assistantTransportOverride)
    }

    public func applyAssistantSuggestion(_ suggestion: AssistantSuggestion) async {
        assistantSuggestions.removeAll { $0.id == suggestion.id }
        let reply = IntentReply.describe(suggestion.intents, devices: devices, scenes: scenes)
        let plan = IntentPlan(intents: suggestion.intents, reply: reply, source: .model)
        _ = await executeIntentPlan(plan, recordedUtterance: nil, origin: .userInitiated)
    }

    /// Resolves a natural-language command (local parser first, model fallback) and applies it.
    @discardableResult
    public func runAssistantCommand(_ text: String) async -> IntentPlan? {
        let controlContext = controlContextID
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return nil }
        let startedAt = Date()
        if DelayPhrase.isCancel(spoken) {
            let count = cancelScheduledCommands()
            setAssistantState(
                count > 0
                    ? .done(L10n.tr("已取消 \(count) 个定时", "Cancelled \(count) timer(s)"))
                    : .failed(L10n.tr("现在没有定时任务", "No active timers"))
            )
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
        var habitSummary: String?
        if let local = LocalIntentParser.parse(utterance, devices: devices, scenes: scenes) {
            plan = local
        } else if homeBackend == .demo {
            // 演示模式完全离线（#47）：本地解析不了的指令绝不送云端。
            setAssistantState(.failed(L10n.tr(
                "演示模式只在本机解析。试试「打开客厅灯」「空调调到 26 度」这类说法",
                "Demo mode parses locally. Try phrases like \"Turn on the living room light\" or \"Set the AC to 26\""
            )))
            return nil
        } else {
            let config = assistantConfig
            if shouldRejectMissingAPIKey(for: config) {
                setAssistantState(.failed(AssistantError.userMessage(for: AssistantError.missingAPIKey)))
                return nil
            }
            if let consent = cloudConsentNeeded(for: config, utterance: spoken) {
                pendingCloudConsent = consent
                setAssistantState(.idle)
                return nil
            }
            let resolver = makeAssistantResolver(config: config)
            let context = buildAssistantContext()
            if !context.habitSummary.isEmpty {
                habitSummary = context.habitSummary
            }
            do {
                plan = try await resolver.resolve(utterance, devices: devices, scenes: scenes, context: context)
            } catch {
                guard controlContext == controlContextID else { return nil }
                setAssistantState(.failed(AssistantError.userMessage(for: error)))
                return nil
            }
        }
        guard controlContext == controlContextID else { return nil }
        guard !plan.intents.isEmpty else {
            if !plan.suggestions.isEmpty {
                assistantSuggestions = plan.suggestions
                setAssistantState(.awaitingChoice(plan.reply.isEmpty
                    ? ModelActionPolicy.confirmationReply(ranReply: nil)
                    : plan.reply))
                return plan
            }
            setAssistantState(.failed(plan.reply.isEmpty ? L10n.tr("没有找到可执行的设备操作", "No matching device actions found") : plan.reply))
            return plan
        }

        if let delayed {
            return schedule(plan, after: delayed.delay)
        }
        // A locally parsed command is the user's explicit ask. A model plan is the AI filling in
        // devices/actions the user never spelled out, so it does not train habits (#34).
        let origin: AssistantExecutionOrigin = plan.source == .local ? .userInitiated : .aiAutomatic
        return await executeIntentPlan(
            plan,
            recordedUtterance: utterance,
            origin: origin,
            receiptStartedAt: startedAt,
            usedHabitContext: habitSummary != nil,
            habitSummary: habitSummary
        )
    }

    // MARK: - Voice Undo

    /// Restores only the devices the last assistant action touched; others may have changed since.
    private func undoLastAssistantAction() async {
        guard let last = lastAssistantUndo, Date().timeIntervalSince(last.at) <= Self.voiceUndoWindow else {
            lastAssistantUndo = nil
            setAssistantState(.failed(L10n.tr("没有可以撤销的操作", "Nothing to undo")))
            return
        }
        lastAssistantUndo = nil
        undoTimerTask?.cancel()
        undoBanner = nil
        let commands = applyUndoCommands(last.restore)
        if let receipt = last.habitReceipt {
            var memory = userHabitMemory
            memory.unrecord(receipt)
            userHabitMemory = memory
        }
        let context = controlContextID
        for cmd in commands {
            guard context == controlContextID else { return }
            try? await executeDeviceCommand(cmd)
        }
        guard context == controlContextID else { return }
        let what = last.reply.hasPrefix("已") ? String(last.reply.dropFirst()) : last.reply
        setAssistantState(.done(L10n.tr("已撤销：\(what)", "Undone: \(what)")))
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
        persistAllScheduledCommands()
        startScheduledTask(for: entry, delay: delay)
        var reply = plan
        reply.reply = L10n.tr("好的，", "Scheduled — ") + entry.reply
        setAssistantState(.done(reply.reply))
        return reply
    }

    private func persistAllScheduledCommands() {
        ScheduledCommand.save(scheduledCommands + missedScheduledCommands, to: userDefaults)
    }

    private func startScheduledTask(for entry: ScheduledCommand, delay: TimeInterval) {
        scheduledTasks[entry.id]?.cancel()
        let sleep = assistantSleep
        let waitSeconds = max(0, delay)
        scheduledTasks[entry.id] = Task { [weak self] in
            do { try await sleep(.seconds(waitSeconds)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // Task.sleep keeps counting while the Mac sleeps, so after a closed lid it returns the moment
            // the Mac wakes. A timer that is more than a minute late is not run silently (#22).
            if self.assistantNow().timeIntervalSince(entry.fireDate) > Self.lateTimerGrace {
                self.moveToMissed(entry)
                return
            }
            await self.waitForInitialSnapshotIfNeeded()
            guard !Task.isCancelled else { return }
            _ = await self.executeIntentPlan(entry.plan, recordedUtterance: nil, origin: .scheduled)
            self.scheduledCommands.removeAll { $0.id == entry.id }
            self.scheduledTasks[entry.id] = nil
            self.persistAllScheduledCommands()
        }
    }

    private func moveToMissed(_ entry: ScheduledCommand) {
        scheduledTasks[entry.id] = nil
        scheduledCommands.removeAll { $0.id == entry.id }
        if !missedScheduledCommands.contains(where: { $0.id == entry.id }) {
            missedScheduledCommands.append(entry)
        }
        isShowingAssistantBar = true
        notifyMissedScheduledCommandsIfNeeded()
        persistAllScheduledCommands()
    }

    private func waitForInitialSnapshotIfNeeded() async {
        for _ in 0..<50 where devices.isEmpty && scenes.isEmpty && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Restores persisted timers on launch. Future timers resume their countdown; expired timers move to
    /// `missedScheduledCommands` so an overdue heater or light timer never fires silently hours later.
    /// Timers the Mac sleeps through take the same path when they wake up late (see `startScheduledTask`).
    public func restoreScheduledCommands(now: Date = Date()) {
        for task in scheduledTasks.values {
            task.cancel()
        }
        scheduledTasks.removeAll()

        let persisted = ScheduledCommand.load(from: userDefaults)
        guard !persisted.isEmpty else {
            scheduledCommands = []
            missedScheduledCommands = []
            return
        }

        var upcoming: [ScheduledCommand] = []
        var missed: [ScheduledCommand] = []
        for entry in persisted {
            if entry.fireDate > now {
                upcoming.append(entry)
            } else {
                missed.append(entry)
            }
        }

        scheduledCommands = upcoming.sorted { $0.fireDate < $1.fireDate }
        for entry in scheduledCommands {
            startScheduledTask(for: entry, delay: entry.fireDate.timeIntervalSince(now))
        }

        if !missed.isEmpty {
            for entry in missed where !missedScheduledCommands.contains(where: { $0.id == entry.id }) {
                missedScheduledCommands.append(entry)
            }
            isShowingAssistantBar = true
            notifyMissedScheduledCommandsIfNeeded()
        }
        persistAllScheduledCommands()
    }

    public func notifyMissedScheduledCommandsIfNeeded() {
        guard let handler = onMissedScheduledCommand else { return }
        for entry in missedScheduledCommands where !notifiedMissedTimerIds.contains(entry.id) {
            notifiedMissedTimerIds.insert(entry.id)
            handler(entry)
        }
    }

    @discardableResult
    public func runMissedScheduledCommand(id: UUID) async -> IntentPlan? {
        guard let idx = missedScheduledCommands.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = missedScheduledCommands.remove(at: idx)
        notifiedMissedTimerIds.remove(id)
        persistAllScheduledCommands()
        await waitForInitialSnapshotIfNeeded()
        return await executeIntentPlan(entry.plan, recordedUtterance: nil, origin: .scheduled)
    }

    public func dismissMissedScheduledCommand(id: UUID) {
        missedScheduledCommands.removeAll { $0.id == id }
        notifiedMissedTimerIds.remove(id)
        persistAllScheduledCommands()
    }

    /// Cancels one pending command, or all of them when `id` is nil. Returns how many were cancelled.
    @discardableResult
    public func cancelScheduledCommands(id: UUID? = nil) -> Int {
        let targets = scheduledCommands.filter { id == nil || $0.id == id }
        for entry in targets {
            scheduledTasks.removeValue(forKey: entry.id)?.cancel()
        }
        scheduledCommands.removeAll { entry in targets.contains { $0.id == entry.id } }

        let missedTargets = missedScheduledCommands.filter { id == nil || $0.id == id }
        for entry in missedTargets {
            notifiedMissedTimerIds.remove(entry.id)
        }
        missedScheduledCommands.removeAll { entry in missedTargets.contains { $0.id == entry.id } }
        persistAllScheduledCommands()
        return targets.count + missedTargets.count
    }

    /// Where an executed plan came from; only explicit user actions train habits (#34).
    enum AssistantExecutionOrigin: Equatable, Sendable {
        /// Local plan from a typed/spoken command, or a suggestion the user tapped.
        case userInitiated
        /// The model inferred device actions the user did not spell out.
        case aiAutomatic
        /// A scheduled command fired (including a missed timer the user confirmed).
        case scheduled
        /// A Mac-state automation rule fired (lock, sleep, display change); never trains habits (#59).
        case automation

        var recordsHabits: Bool { self == .userInitiated }
    }

    func executeIntentPlan(
        _ plan: IntentPlan,
        recordedUtterance: String?,
        origin: AssistantExecutionOrigin,
        receiptStartedAt: Date? = nil,
        usedHabitContext: Bool = false,
        habitSummary: String? = nil
    ) async -> IntentPlan {
        let context = controlContextID
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
                    guard context == self.controlContextID else { return out }
                    out.append(await self.apply(intent, context: context))
                }
                return out
            }
        }
        var outcomes: [AssistantApplyOutcome] = []
        for task in deviceTasks {
            outcomes.append(contentsOf: await task.value)
        }
        guard context == controlContextID else { return plan }

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

        // Only explicit user actions become habits; AI-inferred and timer executions do not (#34).
        var habitReceipt: UserHabitMemory.RecordingReceipt?
        if origin.recordsHabits, isHabitLearningEnabled, failedNames.isEmpty, !appliedDeviceIds.isEmpty {
            var memory = userHabitMemory
            habitReceipt = memory.record(utterance: recordedUtterance, intents: plan.intents, devices: devices, scenes: scenes)
            userHabitMemory = memory
        }

        if !appliedDeviceIds.isEmpty {
            lastAssistantUndo = (
                reply: plan.reply,
                restore: restoreCommands.reversed(),
                previous: previousSnapshot.filter { appliedDeviceIds.contains($0.id) },
                at: Date(),
                habitReceipt: habitReceipt
            )
        }

        // Automation rules always offer undo, even for one device, and keep the banner long enough
        // to survive a lock/sleep round trip (#59). The panel keeps its 2+ device rule (#53).
        if !appliedDeviceIds.isEmpty, appliedDeviceIds.count > 1 || origin == .automation {
            scheduleUndoBanner(
                title: plan.reply.isEmpty ? L10n.tr("已执行 AI 指令", "Executed AI command") : plan.reply,
                restoreCommands: restoreCommands.reversed(),
                previousDevices: previousSnapshot,
                deviceCount: appliedDeviceIds.count,
                habitReceipt: habitReceipt,
                duration: origin == .automation ? AutomationPolicy.undoWindow : nil
            )
        }

        if !failedNames.isEmpty {
            let sep = L10n.isEnglish ? ", " : "、"
            setAssistantState(.failed(L10n.tr("\(failedNames.joined(separator: sep)) 未响应", "\(failedNames.joined(separator: sep)) did not respond")))
        } else if outcomes.allSatisfy({ if case .applied = $0 { return false } else { return true } }) {
            let sep = L10n.isEnglish ? ", " : "、"
            let reason = offlineNames.isEmpty
                ? L10n.tr("没有可执行的设备操作", "No matching device actions")
                : L10n.tr("\(offlineNames.joined(separator: sep)) 当前离线", "\(offlineNames.joined(separator: sep)) offline")
            setAssistantState(.failed(reason))
        } else {
            if !plan.suggestions.isEmpty {
                assistantSuggestions = plan.suggestions
            } else {
                assistantSuggestions = userHabitMemory.topSuggestions(devices: devices, scenes: scenes, limit: 3)
            }
            let receipt = receiptStartedAt.map { start in
                AssistantExecutionReceipt(
                    route: plan.source == .local ? .localRule : .aiModel,
                    elapsedMilliseconds: elapsedMilliseconds(since: start),
                    usedHabitContext: usedHabitContext,
                    habitSummary: usedHabitContext ? habitSummary : nil
                )
            }
            setAssistantState(.done(plan.reply), receipt: receipt)
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
    private func apply(_ intent: DeviceIntent, context: UUID) async -> AssistantApplyOutcome {
        guard context == controlContextID else { return .skipped }
        if intent.operation == .activateScene {
            guard let scene = scenes.first(where: { $0.id == intent.targetId }) else { return .skipped }
            do {
                try await executeDeviceCommand(.activateScene(entityId: scene.entityId))
                guard context == controlContextID else { return .skipped }
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
            guard context == controlContextID else { return .skipped }
            return .applied(deviceId: previous.id, restore: effect.restore)
        } catch {
            guard context == controlContextID else { return .skipped }
            if let revertIdx = devices.firstIndex(where: { $0.id == previous.id }) {
                devices[revertIdx] = previous
            }
            optimisticLockUntil.removeValue(forKey: previous.id)
            return .failed(previous.name)
        }
    }

    static func undoEffect(of command: DeviceCommand, on device: SmartDevice) -> SmartDevice? {
        let operation: IntentOperation
        switch command {
        case .setLightPower(_, let on), .setFanPower(_, let on), .setSwitch(_, let on): operation = .power(on)
        case .setLightBrightness(_, let percent): operation = .brightness(percent)
        case .setLightColorTemp(_, let kelvin): operation = .colorTemperature(kelvin)
        case .setLightEffect(_, let effect): operation = .lightEffect(effect)
        case .setClimatePower(_, let on, let mode): operation = .hvacMode(on ? mode : "off")
        case .setClimateMode(_, let mode): operation = .hvacMode(mode)
        case .setClimateTemperature(_, let temperature): operation = .targetTemperature(temperature)
        case .setClimateFanMode(_, let mode), .setFanPresetMode(_, let mode): operation = .fanSpeed(mode)
        case .setFanOscillating(_, let on): operation = .oscillation(on)
        case .vacuumAction(_, .start): operation = .power(true)
        case .vacuumAction(_, .returnToBase): operation = .power(false)
        default: return nil
        }
        guard let effect = assistantEffect(of: operation, on: device),
              effect.command.targetEntityId == command.targetEntityId else { return nil }
        if case .setClimatePower = command { return effect.updated }
        guard effect.command == command else { return nil }
        return effect.updated
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

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000).rounded()))
    }

    func setAssistantState(_ state: AssistantState, receipt: AssistantExecutionReceipt? = nil) {
        assistantState = state
        lastAssistantReceipt = receipt
        assistantResetTask?.cancel()
        switch state {
        case .done, .failed, .awaitingChoice:
            // A "tap a suggestion" hint stays longer so it can be read next to the chips.
            let delay: Double = if case .awaitingChoice = state { 8 } else { 3.2 }
            assistantResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.assistantState == state else { return }
                self.assistantState = .idle
                self.lastAssistantReceipt = nil
            }
        case .idle, .thinking:
            break
        }
    }
}
