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
    /// Habit records written while executing this action; undoing the banner takes them back (#34).
    public var habitReceipt: UserHabitMemory.RecordingReceipt?
    /// Explicit window for actions outside the panel (automation, #59); nil uses the device-count rule.
    public var duration: TimeInterval?

    public init(
        id: UUID = UUID(),
        title: String,
        restoreCommands: [DeviceCommand],
        previousDevices: [SmartDevice],
        habitReceipt: UserHabitMemory.RecordingReceipt? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.restoreCommands = restoreCommands
        self.previousDevices = previousDevices
        self.habitReceipt = habitReceipt
        self.duration = duration
    }
}

@Observable
@MainActor
public final class HomeStore {
    public static let shared = HomeStore()

    public internal(set) var connectionStatus: ConnectionStatus = .connecting
    public internal(set) var rooms: [RoomArea] = []
    /// Mi Home 家庭 list from the cloud backend; empty elsewhere.
    public internal(set) var homes: [HomeOption] = []
    public internal(set) var selectedMiHomeId: String? = UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey)
    public internal(set) var devices: [SmartDevice] = []
    public internal(set) var environmentReadings: [EnvironmentReading] = []
    public internal(set) var scenes: [HomeScene] = []
    public internal(set) var hasReceivedInitialSnapshot = false

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

    /// Per-device choice for 全关; a missing entry means the default from `joinsAllOffByDefault` (#23).
    public var allOffOverrides: [String: Bool] {
        didSet { userDefaults.set(allOffOverrides, forKey: "all_off_overrides") }
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

    public var appLanguagePreference: AppLanguagePreference = .system {
        didSet {
            userDefaults.set(appLanguagePreference.rawValue, forKey: "app_language")
            syncEffectiveLanguage()
        }
    }

    public private(set) var effectiveLanguage: AppLanguage = .zhHans

    public var miCloudRegion: MiCloudRegion = .cn {
        didSet {
            userDefaults.set(miCloudRegion.rawValue, forKey: "mi_cloud_region")
        }
    }

    /// When off, nothing new is learned and no habit summary is sent to the AI model.
    public var isHabitLearningEnabled: Bool = true {
        didSet { userDefaults.set(isHabitLearningEnabled, forKey: "assistant_habit_learning_enabled") }
    }

    /// Ask macOS to keep speech recognition on this Mac (no audio sent to Apple) when the language supports it.
    /// Defaults on for privacy; an explicitly saved `false` still wins (#50).
    public var prefersOnDeviceSpeech: Bool = true {
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
        let hasHAToken = !KeychainHelper.loadToken(defaults: userDefaults).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        didSet {
            userDefaults.set(serverURLString, forKey: "ha_server_url")
            syncSensorHistoryScope()
        }
    }

    public internal(set) var homeBackend: HomeBackend {
        didSet {
            userDefaults.set(homeBackend.rawValue, forKey: "home_backend")
            syncSensorHistoryScope()
        }
    }

    public internal(set) var miSessionMaskedUserId: String?
    var miSessionScopeIdentifier: String? {
        didSet { syncSensorHistoryScope() }
    }

    public private(set) var toastNotice: ToastNotice?
    public internal(set) var undoBanner: UndoBanner?
    public var onSafetyAlert: ((SafetyAlert) -> Void)?
    public var onGlobalHotkeyPreferenceChanged: ((Bool) -> Void)?

    public static let automaticUpdateCheckInterval: TimeInterval = 6 * 3600
    public internal(set) var updateState: AppUpdateState = .idle
    public var automaticallyChecksForUpdates: Bool = true {
        didSet {
            userDefaults.set(automaticallyChecksForUpdates, forKey: "automatically_checks_for_updates")
            if automaticallyChecksForUpdates && !oldValue {
                Task { @MainActor [weak self] in
                    await self?.checkForUpdatesIfNeeded()
                }
            }
        }
    }
    public var onTerminateForUpdate: (() -> Void)?
    public var updater: AppUpdater
    /// Local energy history fed by provider snapshots (#62).
    public let energyHistory: EnergyHistory
    /// Local + cloud merged history for temperature and humidity sensors.
    public let sensorHistory: SensorHistory
    var updateTask: Task<Void, Never>?
    var activeUpdateAttemptID: UUID?

    public var lgConfig: LGWebOSConfig {
        didSet { lgConfig.save(to: userDefaults) }
    }

    public internal(set) var discoveredHAInstances: [HADiscoveredInstance] = []
    /// Another Home Assistant address found after disconnects; only used if the user taps 切换 (#18).
    public internal(set) var pendingHAAddressSuggestion: HADiscoveredInstance?
    var dismissedHAAddressURLs: Set<String> = []
    public internal(set) var isDiscoveringHA: Bool = false

    var provider: any HomeProvider
    var controlContextID = UUID()
    var lgWebOSClient: LGWebOSClient?
    let isTestEnvironment: Bool
    var latestLGDevice: SmartDevice?
    var eventTask: Task<Void, Never>?
    /// Panel open, Mac awake, Low Power Mode; the provider paces polling with it (#26).
    public internal(set) var pollingContext = PollingContext()
    var pollingContextSync: Task<Void, Never>?
    var debounceTasks: [String: Task<Void, Never>] = [:]
    var undoTimerTask: Task<Void, Never>?
    private var toastTimerTask: Task<Void, Never>?
    var optimisticLockUntil: [String: ContinuousClock.Instant] = [:]
    public static let deviceAliasesKey = "device_aliases"
    var rawDeviceNames: [String: String] = [:]

    var lowBatteryAlertedAt: [String: Date] = [:]
    var activeSinceByDeviceId: [String: Date] = [:]
    var longRunAlertedForSession: Set<String> = []

    static let lastManualLightIdKey = "last_manual_light_id"
    /// Last light the user switched on by hand; the 柔和夜灯 fallback uses it instead of "主卧" (#36).
    var lastManuallyUsedLightId: String?
    /// A legacy 主卧/阳台 menu-bar mode was migrated; pick the first temperature sensor when readings arrive.
    var pendingLegacyMenuBarTargetMigration = false
    var previousOnlineDeviceIds: Set<String> = []

    public init(
        provider: (any HomeProvider)? = nil,
        defaultsSuiteName: String? = nil,
        updater: AppUpdater? = nil
    ) {
        let ud = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.userDefaults = ud
        let isTestEnvironment = (provider != nil || defaultsSuiteName != nil)
        self.isTestEnvironment = isTestEnvironment
        self.updater = updater ?? AppUpdater()
        self.energyHistory = EnergyHistory(defaults: ud)
        self.sensorHistory = SensorHistory(defaults: ud)
        // ≤1.0.6 mirrored credentials into plain `UserDefaults`; move them into the Keychain before any read (#16).
        if !isTestEnvironment && ud === UserDefaults.standard {
            KeychainHelper.migratePlaintextCredentialsToKeychain(defaults: ud)
        }
        let boolOrDefaultTrue = { (key: String) -> Bool in
            ud.object(forKey: key) == nil ? true : ud.bool(forKey: key)
        }
        self.automaticallyChecksForUpdates = boolOrDefaultTrue("automatically_checks_for_updates")

        let savedLangPref = ud.string(forKey: "app_language").flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
        self.appLanguagePreference = savedLangPref
        let initialEffective: AppLanguage = (self.isTestEnvironment && savedLangPref == .system)
            ? .zhHans
            : savedLangPref.resolved()
        self.effectiveLanguage = initialEffective
        if !self.isTestEnvironment {
            L10n.currentLanguage = initialEffective
        }

        let initialMiSession = MiSessionStore.load(defaults: ud)
        let savedRegion = ud.string(forKey: "mi_cloud_region").flatMap(MiCloudRegion.init(rawValue:))
            ?? initialMiSession.flatMap { MiCloudRegion(rawValue: $0.region.lowercased()) }
            ?? .cn
        self.miCloudRegion = savedRegion

        let savedURL = ud.string(forKey: "ha_server_url") ?? KeychainHelper.defaultNASURL
        self.serverURLString = savedURL
        let initialBackend = ud.string(forKey: "home_backend").flatMap(HomeBackend.init(rawValue:)) ?? .homeAssistant
        self.homeBackend = initialBackend
        self.miSessionMaskedUserId = initialMiSession?.maskedUserId
        self.miSessionScopeIdentifier = initialMiSession?.historyScopeIdentifier
        self.selectedMiHomeId = ud.string(forKey: MiCloudProvider.selectedHomeKey)
        self.lgConfig = LGWebOSConfig.load(from: ud)
        self.homeName = ud.string(forKey: "home_name") ?? KeychainHelper.localizedDefaultHomeName
        self.isHabitLearningEnabled = boolOrDefaultTrue("assistant_habit_learning_enabled")
        // Privacy-first default: ask for on-device recognition unless the user explicitly opted out (#50).
        self.prefersOnDeviceSpeech = boolOrDefaultTrue("assistant_on_device_speech")
        self.hasCompletedOnboarding = ud.bool(forKey: "has_completed_onboarding")
        self.hideOfflineDevices = ud.bool(forKey: "hide_offline_devices")
        self.showQuickActionsBar = boolOrDefaultTrue("show_quick_actions_bar")
        self.enableGlobalHotkey = boolOrDefaultTrue("enable_global_hotkey")
        self.enableSafetyAlerts = boolOrDefaultTrue("enable_safety_alerts")
        self.isCompactGridMode = ud.bool(forKey: "compact_grid_mode")
        self.menuBarTargetId = ud.string(forKey: "menubar_target_id") ?? "auto:primary"
        self.lastManuallyUsedLightId = ud.string(forKey: Self.lastManualLightIdKey)
        self.lowBatteryAlertedAt = Self.loadLowBatteryAlertedAt(from: ud)

        let savedModeRaw = ud.string(forKey: "menubar_display_mode")
        if let savedModeRaw, let mode = MenuBarDisplayMode(rawValue: savedModeRaw) {
            self.menuBarDisplayMode = mode
        } else if let savedModeRaw, MenuBarDisplayMode.legacyTemperatureRawValues.contains(savedModeRaw) {
            // ≤1.0.x stored 主卧/阳台 modes. Keep the user on a temperature readout, but let the
            // generic sensor option pick whichever sensor exists in this home (#36).
            self.menuBarDisplayMode = .sensorTemperature
            ud.set(MenuBarDisplayMode.sensorTemperature.rawValue, forKey: "menubar_display_mode")
            let savedTarget = ud.string(forKey: "menubar_target_id")
            self.pendingLegacyMenuBarTargetMigration = savedTarget == nil || savedTarget == "auto:primary"
        } else {
            self.menuBarDisplayMode = .sensorTemperature
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
        self.allOffOverrides = ud.dictionary(forKey: "all_off_overrides") as? [String: Bool] ?? [:]

        let initialHAToken = (provider == nil && initialBackend == .homeAssistant) ? KeychainHelper.loadToken(defaults: ud) : ""
        if let provider {
            self.provider = provider
        } else if initialBackend == .xiaomiCloud {
            nonisolated(unsafe) let ud = userDefaults
            self.provider = MiCloudProvider(sessionLoader: { MiSessionStore.load(defaults: ud) })
        } else if initialBackend == .demo {
            self.provider = DemoHomeProvider()
        } else {
            self.provider = HAWebSocketProvider(baseURLString: savedURL, token: initialHAToken)
        }
        if provider == nil, initialBackend == .homeAssistant, !isTestEnvironment {
            self.provider = makeHAProvider(baseURLString: savedURL, token: initialHAToken)
        }
        syncSensorHistoryScope()
        startListening()
        restoreScheduledCommands()
        // Demo mode is strictly offline: no LAN discovery, no LG connection (#47).
        if provider == nil, initialBackend != .demo {
            startLGWebOSIfNeeded()
            Task { [weak self] in
                _ = await self?.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
            }
        }
    }

    /// Re-resolves `effectiveLanguage` and pushes it to `L10n`; also called from the language
    /// preference setter and from localization extensions (#52).
    func syncEffectiveLanguage() {
        let next: AppLanguage = (isTestEnvironment && appLanguagePreference == .system)
            ? .zhHans
            : appLanguagePreference.resolved()
        effectiveLanguage = next
        if !isTestEnvironment {
            L10n.currentLanguage = next
        }
        if homeName == "我的家" || homeName == "My Home" {
            let localizedDefault = next == .en ? "My Home" : "我的家"
            if homeName != localizedDefault {
                homeName = localizedDefault
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

    // MARK: - Command Execution & Optimistic Locks

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

    // MARK: - Assistant Commands & Personalized Jev Context

    public var isShowingAssistantBar: Bool = false
    /// Bumped to ask an already-visible command bar to take keyboard focus.
    public internal(set) var assistantFocusRequest: Int = 0
    /// Bumped to ask the command bar to start or toggle live speech recognition.
    public internal(set) var assistantVoiceRequest: Int = 0
    public internal(set) var assistantState: AssistantState = .idle
    /// Receipt for the latest command, cleared as soon as the reply resets (#93).
    public internal(set) var lastAssistantReceipt: AssistantExecutionReceipt?
    /// A command or suggestion request waiting for the user to allow sending it to a cloud AI service (#20).
    public internal(set) var pendingCloudConsent: PendingCloudConsent?
    public internal(set) var assistantSuggestions: [AssistantSuggestion] = []
    public internal(set) var isProactiveRecommending: Bool = false
    var assistantResetTask: Task<Void, Never>?
    /// Test seam replacing the network resolver built from `assistantConfig`.
    var assistantResolverOverride: ModelIntentResolver?
    /// Test seam replacing only the HTTP transport while still resolving `assistantConfig` from `userDefaults`.
    var assistantTransportOverride: ModelIntentResolver.Transport?
    /// Commands waiting on a spoken delay ("10 分钟后关灯"), soonest first. Persisted across launches.
    public internal(set) var scheduledCommands: [ScheduledCommand] = []
    /// Timers that came due while the app was closed or the Mac slept. Never auto-executed without user confirmation.
    public internal(set) var missedScheduledCommands: [ScheduledCommand] = []
    public var onMissedScheduledCommand: ((ScheduledCommand) -> Void)?
    var notifiedMissedTimerIds: Set<UUID> = []
    var scheduledTasks: [UUID: Task<Void, Never>] = [:]
    /// The most recent assistant action, kept so "撤销" can restore it after the 5 s banner is gone.
    var lastAssistantUndo: (
        reply: String,
        restore: [DeviceCommand],
        previous: [SmartDevice],
        at: Date,
        habitReceipt: UserHabitMemory.RecordingReceipt?
    )?
    public var lastAssistantActionAt: Date? { lastAssistantUndo?.at }
    /// How long a spoken "撤销" can still reach back.
    static let voiceUndoWindow: TimeInterval = 10 * 60
    /// Test seam for the delay before a scheduled command fires.
    var assistantSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Test seam for "now" when a timer wakes up, so a Mac that slept through it can be simulated.
    var assistantNow: @Sendable () -> Date = { Date() }
    /// A timer that wakes up later than this (the Mac slept, the app was frozen) waits for the user (#22).
    static let lateTimerGrace: TimeInterval = 60
}
