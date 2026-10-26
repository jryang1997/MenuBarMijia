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
    private var localMouseDownMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var windowBecomeKeyObserver: NSObjectProtocol?
    private var windowResignKeyObserver: NSObjectProtocol?
    private var statusBarHoldTimer: Timer?
    private var statusBarHoldStartTime: TimeInterval = 0
    private var statusBarHoldTriggered: Bool = false
    private var suppressNextStatusBarMouseUpUntil: TimeInterval = 0
    private var safetyTimerTask: Task<Void, Never>?
    private var pendingAlertsById: [String: SafetyAlert] = [:]

    private static let turnOffActionId = "TURN_OFF_ACTION"
    private static let safetyCategoryId = "MIJIA_SAFETY_ALERT"
    private static let runMissedTimerActionId = "RUN_MISSED_TIMER_ACTION"
    private static let missedTimerCategoryId = "MIJIA_MISSED_TIMER"

    private override init() {
        super.init()
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
        setupLocalKeyboardMonitors()
        setupNotificationsIfBundled()
        startSafetyTimer()
        Task { @MainActor [weak self] in
            for (idx, delayMs) in [350, 900].enumerated() {
                try? await Task.sleep(for: .milliseconds(delayMs))
                _ = self?.findAnyStatusBarItem()
                if idx == 0, let self, let store = self.store, store.shouldShowOnboarding {
                    self.ensureMenuBarExtraWindowVisible()
                }
            }
        }
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
        if let panelWindow = findMenuBarExtraPanelWindow(), panelWindow.isVisible {
            let endSel = NSSelectorFromString("_endExpandedInterfaceSession:animate:")
            if let item = findAnyStatusBarItem(), item.responds(to: endSel) {
                _ = item.perform(endSel, with: nil, with: nil)
            }
            panelWindow.orderOut(nil)
            return
        }

        ensureMenuBarExtraWindowVisible()
    }

    public func ensureMenuBarExtraWindowVisible() {
        if let panelWindow = findMenuBarExtraPanelWindow(), panelWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panelWindow.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let requestSel = NSSelectorFromString("_requestExpandedInterfaceSession")
        if let item = findAnyStatusBarItem(), item.responds(to: requestSel) {
            if item.responds(to: NSSelectorFromString("_lastExpandedInterfaceDismissTimestamp"))
                || Self.hasIvar("_lastExpandedInterfaceDismissTimestamp", on: item) {
                item.setValue(0.0, forKey: "_lastExpandedInterfaceDismissTimestamp")
            }
            _ = item.perform(requestSel)
        } else if let button = findAnyStatusBarButton() {
            button.performClick(nil)
        }
        if let panelWindow = findMenuBarExtraPanelWindow() {
            panelWindow.makeKeyAndOrderFront(nil)
        }
    }

    private static func hasIvar(_ name: String, on object: AnyObject) -> Bool {
        var cls: AnyClass? = object_getClass(object)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for idx in 0..<Int(count) {
                    if let ivarName = ivar_getName(ivars[idx]), String(cString: ivarName) == name {
                        return true
                    }
                }
            }
            cls = class_getSuperclass(current)
        }
        return false
    }

    private func isStatusBarWindow(_ window: NSWindow) -> Bool {
        if String(describing: type(of: window)).contains("StatusBar") {
            return true
        }
        return findStatusBarButton(in: window.contentView) != nil
            || findStatusBarButton(in: window.contentView?.superview) != nil
    }

    private func findActiveStatusBarWindow() -> NSWindow? {
        for window in NSApp.windows where isStatusBarWindow(window) {
            if findStatusBarButton(in: window.contentView) != nil
                || findStatusBarButton(in: window.contentView?.superview) != nil {
                return window
            }
        }
        return NSApp.windows.first(where: { isStatusBarWindow($0) && $0.frame.origin.y >= 0 })
    }

    private func findAnyStatusBarItem() -> NSStatusItem? {
        for window in NSApp.windows where isStatusBarWindow(window) {
            if Self.hasIvar("_statusItem", on: window),
               let item = window.value(forKey: "_statusItem") as? NSStatusItem,
               item.button != nil {
                configureNativeLongPressIfNeeded(on: item)
                return item
            }
        }
        return nil
    }

    private func configureNativeLongPressIfNeeded(on item: NSStatusItem) {
        let setLongSel = NSSelectorFromString("setLongPressAction:")
        guard item.responds(to: setLongSel) else { return }
        if item.target !== self {
            item.target = self
        }
        if let method = class_getInstanceMethod(type(of: item), setLongSel) {
            typealias SetSelFn = @convention(c) (AnyObject, Selector, Selector) -> Void
            let imp = unsafeBitCast(method_getImplementation(method), to: SetSelFn.self)
            imp(item, setLongSel, #selector(handleStatusBarNativeLongPress(_:)))
        }
    }

    @objc private func handleStatusBarNativeLongPress(_ sender: Any?) {
        statusBarHoldTriggered = true
        activateStatusBarHoldToTalk()
        if (NSEvent.pressedMouseButtons & 0x3) != 0 {
            beginStatusBarHoldDetection(statusWindow: findActiveStatusBarWindow(), eventLocationInWindow: nil)
        } else if let store {
            SpeechInputController.shared.finishHoldToTalk(store: store)
        }
    }

    private func isMouseInStatusBarItem() -> Bool {
        let mouse = NSEvent.mouseLocation
        for window in NSApp.windows where isStatusBarWindow(window) {
            let frame = window.frame
            guard frame.width > 4, frame.height > 4, frame.origin.y >= 0 else { continue }
            if frame.insetBy(dx: -8, dy: -8).contains(mouse) {
                return true
            }
        }
        if let panel = findMenuBarExtraPanelWindow(),
           let screen = panel.screen ?? NSScreen.main {
            let menuBarMinY = screen.frame.maxY - 42
            if mouse.y >= menuBarMinY,
               mouse.x >= panel.frame.minX - 40,
               mouse.x <= panel.frame.maxX + 40 {
                return true
            }
        }
        return false
    }

    private func isMouseInMenuBarStrip() -> Bool {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.insetBy(dx: -4, dy: -4).contains(mouse),
               mouse.y >= screen.frame.maxY - 44 {
                return true
            }
        }
        return isMouseInStatusBarItem()
    }

    private func findMenuBarExtraPanelWindow() -> NSWindow? {
        NSApp.windows.first { win in
            !isStatusBarWindow(win) && (
                String(describing: type(of: win)).contains("MenuBarExtra")
                || String(describing: type(of: win)).contains("Popover")
                || win.level == .popUpMenu
                || win.level == .statusBar
                || win.level == .floating
            )
        }
    }

    private func findAnyStatusBarButton() -> NSStatusBarButton? {
        if let itemButton = findAnyStatusBarItem()?.button {
            return itemButton
        }
        for window in NSApp.windows {
            if let button = findStatusBarButton(in: window.contentView)
                ?? findStatusBarButton(in: window.contentView?.superview) {
                return button
            }
        }
        return nil
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

    // MARK: - 2. Local Keyboard & Menu Bar Hold-to-Talk Monitors

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

        if localMouseDownMonitor == nil {
            localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = event.window, self.isStatusBarWindow(window) else {
                    return event
                }
                self.beginStatusBarHoldDetection(statusWindow: window, eventLocationInWindow: event.locationInWindow)
                return event
            }
        }

        if localMouseUpMonitor == nil {
            localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
                guard let self, let window = event.window, self.isStatusBarWindow(window) else {
                    return event
                }
                if ProcessInfo.processInfo.systemUptime < self.suppressNextStatusBarMouseUpUntil {
                    self.suppressNextStatusBarMouseUpUntil = 0
                    return nil
                }
                return event
            }
        }

        if globalMouseDownMonitor == nil {
            globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isMouseInStatusBarItem() else { return }
                    self.beginStatusBarHoldDetection(statusWindow: self.findActiveStatusBarWindow(), eventLocationInWindow: nil)
                }
            }
        }

        if windowBecomeKeyObserver == nil {
            windowBecomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let win = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, !self.isStatusBarWindow(win) else { return }
                    Task { @MainActor [weak self] in
                        await self?.store?.checkForUpdatesIfNeeded()
                    }
                    guard (NSEvent.pressedMouseButtons & 0x3) != 0, self.isMouseInMenuBarStrip() else { return }
                    self.beginStatusBarHoldDetection(statusWindow: self.findActiveStatusBarWindow(), eventLocationInWindow: nil)
                }
            }
        }

        if windowResignKeyObserver == nil {
            windowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let win = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, !self.isStatusBarWindow(win) else { return }
                    guard (NSEvent.pressedMouseButtons & 0x3) != 0, self.isMouseInStatusBarItem() else { return }
                    self.beginStatusBarHoldDetection(statusWindow: self.findActiveStatusBarWindow(), eventLocationInWindow: nil)
                }
            }
        }
    }

    private weak var statusBarHoldTargetWindow: NSWindow?
    private var statusBarHoldEventLocation: NSPoint = NSPoint(x: 16, y: 16)

    private func beginStatusBarHoldDetection(statusWindow: NSWindow?, eventLocationInWindow: NSPoint?) {
        // Avoid resetting the timer if another monitor/notification already started tracking this same press.
        if statusBarHoldTimer != nil {
            return
        }
        guard (NSEvent.pressedMouseButtons & 0x3) != 0 else { return }

        statusBarHoldStartTime = ProcessInfo.processInfo.systemUptime
        statusBarHoldTriggered = false
        statusBarHoldTargetWindow = statusWindow ?? findActiveStatusBarWindow()
        statusBarHoldEventLocation = eventLocationInWindow ?? NSPoint(x: 16, y: 16)

        // Schedule in RunLoop.Mode.common so the timer fires even while NSStatusBarButtonCell.trackMouse
        // blocks RunLoop.main inside NSEventTrackingRunLoopMode.
        let timer = Timer(
            timeInterval: 0.03,
            target: self,
            selector: #selector(handleStatusBarHoldTimerTick(_:)),
            userInfo: nil,
            repeats: true
        )
        statusBarHoldTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleStatusBarHoldTimerTick(_ timer: Timer) {
        let isMouseDown = (NSEvent.pressedMouseButtons & 0x3) != 0
        let elapsed = ProcessInfo.processInfo.systemUptime - statusBarHoldStartTime

        if !statusBarHoldTriggered {
            if !isMouseDown {
                stopStatusBarHoldTimer()
                return
            }
            if elapsed >= 0.20 {
                statusBarHoldTriggered = true
                suppressNextStatusBarMouseUpUntil = ProcessInfo.processInfo.systemUptime + 10.0

                if RunLoop.main.currentMode == .eventTracking, let win = statusBarHoldTargetWindow {
                    if let upEvent = NSEvent.mouseEvent(
                        with: .leftMouseUp,
                        location: statusBarHoldEventLocation,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: win.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 1,
                        pressure: 0.0
                    ) {
                        NSApp.postEvent(upEvent, atStart: true)
                    }
                }

                activateStatusBarHoldToTalk()
            }
        } else {
            if !isMouseDown {
                stopStatusBarHoldTimer()
                suppressNextStatusBarMouseUpUntil = ProcessInfo.processInfo.systemUptime + 0.25
                if let store {
                    SpeechInputController.shared.finishHoldToTalk(store: store)
                    ensureMenuBarExtraWindowVisible()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(70))
                        guard let self, let store = self.store, store.isShowingAssistantBar else { return }
                        self.ensureMenuBarExtraWindowVisible()
                    }
                }
            }
        }
    }

    private func stopStatusBarHoldTimer() {
        statusBarHoldTimer?.invalidate()
        statusBarHoldTimer = nil
        statusBarHoldTargetWindow = nil
    }

    private func activateStatusBarHoldToTalk() {
        guard let store else { return }
        ensureMenuBarExtraWindowVisible()
        store.presentAssistantBar(startVoice: false)
        SpeechInputController.shared.startHoldToTalk(store: store)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, let store = self.store, store.isShowingAssistantBar else { return }
            self.ensureMenuBarExtraWindowVisible()
        }
    }

    private func handleKeyDown(_ event: NSEvent, store: HomeStore) -> Bool {
        let code = Int(event.keyCode)
        // Do not intercept typing when a text field (e.g., XiaoAi input or Settings URL) is first responder
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            if code == kVK_Escape {
                if store.isShowingAssistantBar && !store.isShowingSettings {
                    store.dismissAssistantBar()
                }
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

        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        store?.onSafetyAlert = { [weak self] alert in
            self?.deliverNotification(for: alert)
        }
        store?.onMissedScheduledCommand = { [weak self] entry in
            self?.deliverMissedTimerNotification(for: entry)
        }
        store?.notifyMissedScheduledCommandsIfNeeded()
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

    private func deliverMissedTimerNotification(for entry: ScheduledCommand) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.tr("已错过定时任务", "Missed Scheduled Command")
        content.body = L10n.tr(
            "应用关闭期间已过期的定时：「\(entry.reply)」。可点击通知按钮立即补执行。",
            "Expired while the app was closed: \"\(entry.reply)\". Click Run Now to execute it."
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
