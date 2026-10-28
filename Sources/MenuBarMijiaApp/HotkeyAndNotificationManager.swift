import AppKit
import Carbon
import Foundation
import UserNotifications
import MijiaCore

@MainActor
public final class HotkeyAndNotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    public static let shared = HotkeyAndNotificationManager()

    private weak var store: HomeStore?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var windowBecomeKeyObserver: NSObjectProtocol?
    private var applicationBecomeActiveObserver: NSObjectProtocol?
    private var safetyTimerTask: Task<Void, Never>?
    private var pendingAlertsById: [String: SafetyAlert] = [:]

    private static let turnOffActionId = "TURN_OFF_ACTION"
    private static let safetyCategoryId = "MIJIA_SAFETY_ALERT"
    private static let runMissedTimerActionId = "RUN_MISSED_TIMER_ACTION"
    private static let missedTimerCategoryId = "MIJIA_MISSED_TIMER"

    private override init() {
        super.init()
        applicationBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshNotificationPermission()
            }
        }
    }

    public func start(with store: HomeStore) {
        self.store = store
        store.onTerminateForUpdate = {
            NSApplication.shared.terminate(nil)
        }
        store.onGlobalHotkeyPreferenceChanged = { [weak self] enabled in
            self?.syncGlobalHotKeyRegistration(enabled: enabled)
        }
        syncGlobalHotKeyRegistration(enabled: store.enableGlobalHotkey)
        MenuBarPanelController.shared.install(with: store)
        setupLocalKeyboardMonitors()
        setupNotificationsIfBundled()
        startSafetyTimer()
        // The status item exists as soon as `install` returns, but the first launch has no window to
        // host yet; give SwiftUI one run-loop turn before an onboarding panel is requested.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, let store = self.store, store.shouldShowOnboarding else { return }
            self.ensureMenuBarExtraWindowVisible()
        }
    }

    // MARK: - 1. Global Hotkey (user-recorded, ⌥M by default) via Carbon RegisterEventHotKey

    private func syncGlobalHotKeyRegistration(enabled: Bool) {
        if enabled {
            applyHotkeyPreference()
        } else {
            unregisterGlobalHotKey()
            HotkeySettingsState.shared.markDisabled()
        }
    }

    /// Re-registers with the stored shortcut. Called when the toggle flips (#43 rule 3) and after
    /// the recorder saves a new combination.
    public func applyHotkeyPreference() {
        guard let store, store.enableGlobalHotkey else {
            unregisterGlobalHotKey()
            HotkeySettingsState.shared.markDisabled()
            return
        }
        let shortcut = HotkeyPreferences.load()
        HotkeySettingsState.shared.reload()
        registerGlobalHotKey(shortcut)
    }

    /// Retry button next to the registration error.
    public func retryHotkeyRegistration() {
        applyHotkeyPreference()
    }

    private func unregisterGlobalHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func registerGlobalHotKey(_ shortcut: HotkeyShortcut) {
        unregisterGlobalHotKey()
        guard installHotKeyHandler() else {
            reportHotkeyFailure(shortcut, status: OSStatus(-1))
            return
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D49_4A41), id: 1) // 'MIJA'
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRef = ref
            HotkeySettingsState.shared.markRegistered(shortcut)
        } else {
            reportHotkeyFailure(shortcut, status: status)
        }
    }

    /// Never let a shortcut fail silently (#43): Settings shows the error and, when the panel is
    /// visible, a toast says why the hotkey does nothing.
    private func reportHotkeyFailure(_ shortcut: HotkeyShortcut, status: OSStatus) {
        HotkeySettingsState.shared.markFailed(shortcut, status: status)
        if let message = HotkeySettingsState.shared.registrationError {
            store?.showToast(message, isError: true)
        }
    }

    private func installHotKeyHandler() -> Bool {
        if eventHandlerRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                Task { @MainActor in
                    HotkeyAndNotificationManager.shared.handleGlobalHotKeyTriggered()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        return status == noErr
    }

    private static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    private func handleGlobalHotKeyTriggered() {
        guard let store, store.enableGlobalHotkey else { return }
        toggleMenuBarExtraWindow()
    }

    /// Opens the control center, or closes it when it is already on screen.
    ///
    /// The name predates #56: the panel is an app-owned `NSPanel` now, not a `MenuBarExtra` window.
    /// Other app files (Settings, URL scheme, App Intents) call it, so the seam is kept.
    public func toggleMenuBarExtraWindow() {
        MenuBarPanelController.shared.togglePanel()
    }

    /// Brings the control center on screen without toggling, e.g. to show an onboarding guide or an
    /// undo banner. Same legacy name as `toggleMenuBarExtraWindow()`.
    public func ensureMenuBarExtraWindowVisible() {
        MenuBarPanelController.shared.showPanel()
    }

    // MARK: - 2. Local Keyboard Monitors

    /// ⌥-state tracking and panel shortcuts. Mouse handling for the status item lives in
    /// `MenuBarPanelController`, which owns the item (#56).
    private func setupLocalKeyboardMonitors() {
        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.store?.isOptionKeyPressed = event.modifierFlags.contains(.option)
                return event
            }
        }

        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let store = self.store else { return event }
                if self.handleKeyDown(event, store: store) {
                    return nil
                }
                return event
            }
        }

        // Opening any window of our own (Settings, the panel) is a chance to run the daily update
        // check. Menu-bar gestures are handled by the status item controller.
        if windowBecomeKeyObserver == nil {
            windowBecomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        await self?.store?.checkForUpdatesIfNeeded()
                    }
                }
            }
        }
    }

    // MARK: - 3. Local Keyboard Shortcuts

    private func handleKeyDown(_ event: NSEvent, store: HomeStore) -> Bool {
        let code = Int(event.keyCode)

        // Settings is a separate scene; the panel has no app menu of its own (agent app).
        if code == kVK_ANSI_Comma, event.modifierFlags.contains(.command) {
            SettingsWindowOpener.shared.show()
            return true
        }

        // #60: an open search owns ↑↓ / Return / → / Esc / typing. With no search it returns false for
        // every key, so the shortcuts below — and the text-field guard right after this — are unchanged.
        if PanelSearchKeyboard.handle(event, store: store) {
            return true
        }

        // Do not intercept typing when a text field (e.g., XiaoAi input or Settings URL) is first responder
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            if code == kVK_Escape {
                if store.isShowingAssistantBar {
                    store.dismissAssistantBar()
                }
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        // Arrow/space/digit shortcuts belong to the menu-bar panel. The Settings window (⌘,) keeps
        // normal AppKit control behavior instead of triggering device actions (#42).
        if !MenuBarPanelController.shared.isPanelWindow(NSApp.keyWindow) {
            return false
        }

        // The configured global shortcut also closes an open panel instead of being re-triggered.
        if store.enableGlobalHotkey, HotkeyRecorderController.matches(event) {
            MenuBarPanelController.shared.hidePanel()
            return true
        }

        if event.charactersIgnoringModifiers == "/",
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            store.presentAssistantBar()
            return true
        }

        if event.charactersIgnoringModifiers?.lowercased() == "v",
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            store.presentAssistantBar(startVoice: true)
            return true
        }

        switch code {
        case kVK_UpArrow:
            store.moveFocus(delta: -1)
            return true
        case kVK_DownArrow:
            store.moveFocus(delta: 1)
            return true
        case kVK_LeftArrow:
            store.adjustFocusedDevice(delta: -1)
            return true
        case kVK_RightArrow:
            store.adjustFocusedDevice(delta: 1)
            return true
        case kVK_Space, kVK_Return:
            store.toggleFocusedDevice()
            return true
        case kVK_Tab:
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            store.cycleRoom(delta: delta)
            return true
        case kVK_Escape:
            if store.isShowingAssistantBar {
                store.dismissAssistantBar()
            } else if store.expandedDeviceId != nil {
                store.expandedDeviceId = nil
            } else if store.focusedDeviceId != nil {
                store.focusedDeviceId = nil
            } else {
                MenuBarPanelController.shared.hidePanel()
            }
            return true
        default:
            break
        }

        if let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let digit = Int(chars),
           (1...9).contains(digit) {
            store.selectQuickIndex(digit)
            return true
        }

        return false
    }

    // MARK: - 4. Native macOS Safety Alerts (UNUserNotificationCenter)

    private func setupNotificationsIfBundled() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let turnOffAction = UNNotificationAction(
            identifier: Self.turnOffActionId,
            title: L10n.tr("立即关闭", "Turn Off Now"),
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.safetyCategoryId,
            actions: [turnOffAction],
            intentIdentifiers: [],
            options: []
        )
        let runMissedAction = UNNotificationAction(
            identifier: Self.runMissedTimerActionId,
            title: L10n.tr("立即补执行", "Run Now"),
            options: []
        )
        let missedCategory = UNNotificationCategory(
            identifier: Self.missedTimerCategoryId,
            actions: [runMissedAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category, missedCategory])

        // Permission is requested on demand (#55): first time 守护提醒 is enabled or a timer is set,
        // after an in-app explanation. Nothing is asked at launch.
        store?.onSafetyAlert = { [weak self] alert in
            self?.deliverNotification(for: alert)
        }
        store?.onMissedScheduledCommand = { [weak self] entry in
            self?.deliverMissedTimerNotification(for: entry)
        }
        store?.notifyMissedScheduledCommandsIfNeeded()
        Task { [weak self] in
            await self?.refreshNotificationPermission()
        }
    }

    // MARK: - Notification Permission on Demand (#55)

    /// Set the first time the user is asked, so a denial is not re-prompted in-app forever.
    public static let notificationPromptedKey = "notification_permission_prompted"

    public static var hasRequestedNotificationAuthorization: Bool {
        UserDefaults.standard.bool(forKey: notificationPromptedKey)
    }

    /// Shows the macOS prompt only when it can still be shown. Returns whether banners are allowed.
    public func requestNotificationAuthorization() async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            UserDefaults.standard.set(true, forKey: Self.notificationPromptedKey)
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshNotificationPermission()
            return granted
        }
        await refreshNotificationPermission()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Mirrors the system state into the settings UI (authorized / denied / not asked yet).
    public func refreshNotificationPermission() async {
        let state = NotificationPermissionState.shared
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            state.update(.notDetermined, canRequest: false)
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        state.update(settings.authorizationStatus, canRequest: settings.authorizationStatus == .notDetermined)
    }

    /// "打开系统设置" next to a denied state.
    public func openNotificationSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private struct MissedTimerNotificationIdentifier {
        private static let prefix = "missed-timer:"
        let commandId: UUID

        var rawValue: String { "\(Self.prefix)\(commandId.uuidString)" }

        init(commandId: UUID) {
            self.commandId = commandId
        }

        init?(rawValue: String) {
            guard rawValue.hasPrefix(Self.prefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(Self.prefix.count))) else {
                return nil
            }
            self.commandId = id
        }
    }

    private func startSafetyTimer() {
        safetyTimerTask?.cancel()
        safetyTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let store = self.store else { break }
                if store.enableSafetyAlerts {
                    for alert in store.evaluateSafetyAlerts(now: Date()) {
                        self.deliverNotification(for: alert)
                    }
                }
                await store.checkForUpdatesIfNeeded()
            }
        }
    }

    private func deliverNotification(for alert: SafetyAlert) {
        pendingAlertsById[alert.id] = alert
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        if alert.turnOffCommand != nil {
            content.categoryIdentifier = Self.safetyCategoryId
        }

        let request = UNNotificationRequest(
            identifier: alert.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Banner for actions invoked from outside the panel (URL Scheme / App Intents, #57).
    ///
    /// This never asks for permission: if the user has not allowed notifications, it silently does
    /// nothing and the in-panel toast / intent dialog remains the feedback. The bundle check keeps
    /// `swift test` from touching `UNUserNotificationCenter` (#55).
    public func deliverExternalActionNotification(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "external-action-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func deliverMissedTimerNotification(for entry: ScheduledCommand) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.tr("已错过定时任务", "Missed Scheduled Command")
        content.body = L10n.tr(
            "应用关闭或电脑睡眠时错过的定时：「\(entry.reply)」。没有自动执行，可点通知按钮立即补执行。",
            "Missed while the app was closed or the Mac was asleep: \"\(entry.reply)\". It did not run. Click Run Now to run it."
        )
        content.sound = .default
        content.categoryIdentifier = Self.missedTimerCategoryId

        let request = UNNotificationRequest(
            identifier: MissedTimerNotificationIdentifier(commandId: entry.id).rawValue,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let alertId = response.notification.request.identifier
        if response.actionIdentifier == Self.turnOffActionId,
           let alert = pendingAlertsById[alertId] {
            store?.executeSafetyAlertAction(alert)
        } else if response.actionIdentifier == Self.runMissedTimerActionId,
                  let missedId = MissedTimerNotificationIdentifier(rawValue: alertId) {
            Task { @MainActor [weak self] in
                _ = await self?.store?.runMissedScheduledCommand(id: missedId.commandId)
            }
        }
        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
