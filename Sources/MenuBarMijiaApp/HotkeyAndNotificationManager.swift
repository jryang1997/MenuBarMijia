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
    private var safetyTimerTask: Task<Void, Never>?
    private var pendingAlertsById: [String: SafetyAlert] = [:]

    private static let turnOffActionId = "TURN_OFF_ACTION"
    private static let safetyCategoryId = "MIJIA_SAFETY_ALERT"

    private override init() {
        super.init()
    }

    public func start(with store: HomeStore) {
        self.store = store
        store.onGlobalHotkeyPreferenceChanged = { [weak self] enabled in
            self?.syncGlobalHotKeyRegistration(enabled: enabled)
        }
        syncGlobalHotKeyRegistration(enabled: store.enableGlobalHotkey)
        setupLocalKeyboardMonitors()
        setupNotificationsIfBundled()
        startSafetyTimer()
    }

    // MARK: - 1. Global Hotkey (Option + M) via Carbon RegisterEventHotKey

    private func syncGlobalHotKeyRegistration(enabled: Bool) {
        if enabled {
            setupGlobalHotKey()
        } else {
            if let ref = hotKeyRef {
                UnregisterEventHotKey(ref)
                hotKeyRef = nil
            }
        }
    }

    private func setupGlobalHotKey() {
        guard hotKeyRef == nil else { return }

        if eventHandlerRef == nil {
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
            guard status == noErr else { return }
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D49_4A41), id: 1) // 'MIJA'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func handleGlobalHotKeyTriggered() {
        guard let store, store.enableGlobalHotkey else { return }
        toggleMenuBarExtraWindow()
    }

    public func toggleMenuBarExtraWindow() {
        // Find the status bar button or existing MenuBarExtra panel window
        if let panelWindow = NSApp.windows.first(where: { win in
            win.isVisible && win.level == .popUpMenu || String(describing: type(of: win)).contains("MenuBarExtraWindow")
        }), panelWindow.isVisible {
            panelWindow.orderOut(nil)
            return
        }

        // Click the NSStatusBarButton in the status bar window to open MenuBarExtra(.window)
        for window in NSApp.windows {
            if let button = findStatusBarButton(in: window.contentView) {
                NSApp.activate(ignoringOtherApps: true)
                button.performClick(nil)
                return
            }
        }
    }

    private func findStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        for sub in view.subviews {
            if let found = findStatusBarButton(in: sub) {
                return found
            }
        }
        return nil
    }

    // MARK: - 2. Local Keyboard Navigation inside ControlCenterPanel

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
    }

    private func handleKeyDown(_ event: NSEvent, store: HomeStore) -> Bool {
        let code = Int(event.keyCode)
        // Do not intercept typing when a text field (e.g., XiaoAi input or Settings URL) is first responder
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            if code == kVK_Escape {
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        // Option+M inside open window closes it
        if event.modifierFlags.contains(.option),
           event.charactersIgnoringModifiers?.lowercased() == "m",
           store.enableGlobalHotkey {
            NSApp.keyWindow?.orderOut(nil)
            return true
        }

        if store.isShowingSettings {
            if code == kVK_Escape {
                store.isShowingSettings = false
                return true
            }
            return false
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
            if store.expandedDeviceId != nil {
                store.expandedDeviceId = nil
            } else if store.focusedDeviceId != nil {
                store.focusedDeviceId = nil
            } else {
                NSApp.keyWindow?.orderOut(nil)
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

    // MARK: - 3. Native macOS Safety Alerts (UNUserNotificationCenter)

    private func setupNotificationsIfBundled() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let turnOffAction = UNNotificationAction(
            identifier: Self.turnOffActionId,
            title: "立即关闭",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.safetyCategoryId,
            actions: [turnOffAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        store?.onSafetyAlert = { [weak self] alert in
            self?.deliverNotification(for: alert)
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

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let alertId = response.notification.request.identifier
        if response.actionIdentifier == Self.turnOffActionId,
           let alert = pendingAlertsById[alertId] {
            store?.executeSafetyAlertAction(alert)
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
