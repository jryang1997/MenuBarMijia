import AppKit
import SwiftUI
import MijiaCore

/// App-owned menu-bar item and panel (#56).
///
/// `MenuBarExtra` keeps its status item and window inside private AppKit objects, so reaching them
/// required KVC on `_statusItem`, the private `setLongPressAction:` / `_requestExpandedInterfaceSession`
/// selectors, ivar scanning and window class-name sniffing. Owning the `NSStatusItem` and a borderless
/// `NSPanel` puts every capability the extra provided on public API:
///
/// - icon + text from `HomeStore.menuBarSymbolName` / `menuBarText`, with the listening waveform and
///   the live transcript while `SpeechInputController` records;
/// - tooltip and accessibility label from `MenuBarStatusSummary`;
/// - a left click toggles the panel; holding either button for 0.2 s starts hold-to-talk;
/// - the panel closes on an outside click or when the app deactivates (unless dictation is running);
/// - it becomes key, so arrow keys, Esc, ⌘, and its text fields behave as they did before;
/// - it is anchored under the item's own screen and stays on screen across display changes;
/// - width is the 376 pt the panel draws at, height follows `PanelHeight`.
///
/// The panel's SwiftUI tree stays alive between opens, like a `.window`-style `MenuBarExtra`, so
/// scroll position, search text and layout state survive a close; `didShow` / `didHide` notifications
/// let the panel replay its drop-in animation. `store.setPanelVisible` is driven from here, so the
/// polling rhythm does not depend on SwiftUI lifecycle callbacks firing per open.
@MainActor
final class MenuBarPanelController: NSObject {
    static let shared = MenuBarPanelController()

    /// Control center width, identical in every skin.
    static let panelWidth: CGFloat = 376
    /// The panel draws its own material; AppKit only clips it to the extra's rounded corners.
    static let panelCornerRadius: CGFloat = 12

    /// Posted after the panel becomes visible, and after it is ordered out.
    static let didShowNotification = Notification.Name("MenuBarMijia.panelDidShow")
    static let didHideNotification = Notification.Name("MenuBarMijia.panelDidHide")

    private static let topGap: CGFloat = 6
    private static let screenMargin: CGFloat = 8
    /// Press-and-hold on the icon starts dictation instead of toggling the panel.
    private static let holdThreshold: TimeInterval = 0.2
    private static let holdTick: TimeInterval = 0.03

    private(set) var statusItem: NSStatusItem?
    private(set) var panelWindow: NSPanel?

    /// Tests switch this off so `swift test` shows the window without stealing key status or focus
    /// from the terminal; the app keeps it on, which is what makes the panel key like the extra was.
    var presentsActively = true

    private weak var store: HomeStore?
    private var labelTimer: Timer?
    private var pressTimer: Timer?
    private var pressStartedAt: TimeInterval = 0
    private var pressTriggered = false
    /// Only a left click toggles; a right click exists solely to start dictation.
    private var pressAllowsToggle = true
    private var suppressReleaseUntil: TimeInterval = 0
    /// What the status button currently shows; kept after a sync so diagnostics and tests can read it.
    private(set) var labelSymbol: String?
    private(set) var labelText: String?
    private(set) var tooltipText: String?
    private var observers: [any NSObjectProtocol] = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var didInstall = false

    override init() {
        super.init()
    }

    // MARK: - Installation

    /// Creates the status item and keeps its label in sync. Safe to call twice.
    ///
    /// The app calls this from `App.init`, possibly before the status bar is ready. If the resulting
    /// item never acquired a button window (which only happens when it was created too early), it is
    /// recreated once at `applicationDidFinishLaunching`.
    func install(with store: HomeStore) {
        self.store = store
        guard !didInstall else { return }
        didInstall = true
        createStatusItem()
        installMouseMonitors()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverStatusItemIfNeeded()
            }
        })
        installObservers()
        startLabelUpdates()
    }

    /// A status item created before the status bar was ready stays blank; remove and recreate it.
    func recoverStatusItemIfNeeded() {
        if let statusItem, statusItem.button?.window == nil {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            labelSymbol = nil
            labelText = nil
            tooltipText = nil
        }
        createStatusItem()
        syncStatusItem()
    }

    /// Releases the status item, the panel and every observer. Used by tests; the app keeps the item
    /// for its whole lifetime.
    func uninstall() {
        removeMouseMonitors()
        labelTimer?.invalidate()
        labelTimer = nil
        stopPressTimer()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        panelWindow?.orderOut(nil)
        panelWindow?.contentView = nil
        panelWindow = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        store = nil
        didInstall = false
        labelSymbol = nil
        labelText = nil
        tooltipText = nil
    }

    private func createStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleStatusItemPress)
            // Send every press/release so a short click toggles and a hold tracks dictation instead
            // of AppKit acting on mouse-down alone.
            _ = button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
        }
        configureStatusItemLongPress(on: item)
        statusItem = item
        syncStatusItem()
    }

    /// Registers `setLongPressAction:` on `NSStatusItem` for macOS 26+, where the out-of-process
    /// menu bar (`NSMenuBarNavigationSceneExtension`) routes press-and-hold and secondary clicks
    /// through `-[NSStatusItem _performSecondaryAction:type:]` instead of delivering `leftMouseDown`
    /// to the button action when the finger first touches the trackpad.
    private func configureStatusItemLongPress(on item: NSStatusItem) {
        // Always assign `item.target` unconditionally: `-[NSStatusItem target]` falls back to
        // `button.target`, whereas `-[NSStatusItem _performSecondaryAction:type:]` reads the
        // `NSStatusItem->_target` ivar directly without consulting `button.target`.
        item.target = self
        let setLongSel = NSSelectorFromString("setLongPressAction:")
        guard item.responds(to: setLongSel),
              let method = class_getInstanceMethod(type(of: item), setLongSel) else { return }
        typealias SetSelFn = @convention(c) (AnyObject, Selector, Selector) -> Void
        let imp = unsafeBitCast(method_getImplementation(method), to: SetSelFn.self)
        imp(item, setLongSel, #selector(handleStatusItemNativeLongPress(_:)))
    }

    // MARK: - Menu Bar Label (#54)

    private func startLabelUpdates() {
        guard labelTimer == nil else { return }
        // A 0.5 s poll mirrors the old 2 s tooltip loop and adds the listening waveform; the label
        // lives in AppKit, so `@Observable` tracking cannot drive it.
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(handleLabelTimerTick(_:)),
            userInfo: nil,
            repeats: true
        )
        labelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleLabelTimerTick(_ timer: Timer) {
        syncStatusItem()
    }

    /// Pushes icon, text, tooltip and accessibility label onto the status button.
    func syncStatusItem() {
        guard let button = statusItem?.button, let store else { return }
        let speech = SpeechInputController.shared
        let symbol = speech.isListening ? "waveform" : store.menuBarSymbolName
        let text = speech.isListening ? Self.speechLabel(speech.draft) : store.menuBarText
        let summary = MenuBarStatusSummary.text(for: store)

        if symbol != labelSymbol {
            labelSymbol = symbol
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                image.isTemplate = true
                button.image = image
            }
        }
        if text != labelText {
            labelText = text
            button.attributedTitle = Self.statusTitle(text, isSpeech: speech.isListening)
        }
        if summary != tooltipText {
            tooltipText = summary
            button.toolTip = summary
            button.setAccessibilityLabel(summary)
            button.setAccessibilityHelp(summary)
        }
    }

    /// Last ten characters of the live transcript, or "聆听中…" before the first words arrive.
    static func speechLabel(_ draft: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.tr("聆听中…", "Listening…") }
        if trimmed.count > 10 {
            return String(trimmed.suffix(10))
        }
        return trimmed
    }

    /// Same typography as the SwiftUI label: 12 pt rounded, semibold for the live transcript and
    /// medium with monospaced digits for the device readout.
    private static func statusTitle(_ text: String?, isSpeech: Bool) -> NSAttributedString {
        guard let text, !text.isEmpty else { return NSAttributedString(string: "") }
        let size: CGFloat = 12
        let weight: NSFont.Weight = isSpeech ? .semibold : .medium
        var font: NSFont
        if !isSpeech, text.contains(where: { $0.isNumber }) {
            font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        } else {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            font = NSFont(descriptor: descriptor, size: size) ?? base
        }
        return NSAttributedString(
            string: " " + text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
    }

    // MARK: - Showing & Hiding

    var isPanelVisible: Bool {
        panelWindow?.isVisible == true
    }

    /// True for the control center panel or a window it owns (sheet, context menu, child), so both
    /// keyboard handling and the outside-click rule can tell it apart from Settings.
    func isPanelWindow(_ window: NSWindow?) -> Bool {
        guard let window, let panelWindow else { return false }
        if window === panelWindow { return true }
        if window.parent === panelWindow { return true }
        if panelWindow.attachedSheet === window { return true }
        return panelWindow.childWindows?.contains { $0 === window } ?? false
    }

    func togglePanel() {
        if isPanelVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let store else { return }
        let panel = panelWindow ?? Self.makePanel()
        panelWindow = panel
        panel.appearance = Self.preferredAppearance()
        if panel.contentView == nil {
            attachContent(to: panel)
        }

        let target = Self.frame(for: panel.frame.size, anchor: statusAnchor, screen: statusScreen)
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }

        let wasVisible = panel.isVisible
        installMouseMonitors()
        if presentsActively {
            // Order the window in first: cooperative activation only succeeds once the app has a
            // window to become active for, and this agent app owns none at that moment.
            panel.makeKeyAndOrderFront(nil)
            if !NSApp.isActive {
                NSApp.activate()
            }
        } else {
            panel.orderFront(nil)
        }
        // Re-showing an already visible panel (hotkey while open, URL scheme, intent) must not replay
        // the drop-in animation.
        guard !wasVisible else { return }
        store.setPanelVisible(true)
        NotificationCenter.default.post(name: Self.didShowNotification, object: panel)
    }

    func hidePanel() {
        guard let panel = panelWindow, panel.isVisible else { return }
        panel.orderOut(nil)
        store?.setPanelVisible(false)
        // The SwiftUI tree stays alive, exactly like a `.window`-style `MenuBarExtra`: scroll
        // position, the search field text and layout-editing state survive a close/reopen. The drop-in
        // animation is reset through `didShowNotification` in `ControlCenterPanel`.
        NotificationCenter.default.post(name: Self.didHideNotification, object: panel)
    }

    /// Sizing hook for `ControlCenterPanel`: 376 pt wide, `PanelHeight` tall, top edge kept under the
    /// menu bar and clamped to the screen the item is on. No-op while the panel is closed.
    func updatePanelSize(width: CGFloat, height: CGFloat) {
        guard let panel = panelWindow else { return }
        let target = Self.frame(
            for: NSSize(width: width, height: height),
            anchor: statusAnchor,
            screen: statusScreen
        )
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true)
    }

    private static func makePanel() -> NSPanel {
        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: preferredContentSize()),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = preferredAppearance()
        panel.contentView = nil
        return panel
    }

    /// Mirrors `AppAppearance` onto the AppKit panel so materials, dynamic `NSColor`s, menus and
    /// tooltips match the SwiftUI scheme.
    static func preferredAppearance() -> NSAppearance? {
        let raw = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        return (raw.flatMap(AppAppearance.init(rawValue:)) ?? .system).nsAppearance
    }

    private func attachContent(to panel: NSPanel) {
        guard let store else { return }
        let hosting = NSHostingView(rootView: ControlCenterPanel(store: store))
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Self.panelCornerRadius
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.initialFirstResponder = hosting
        _ = panel.makeFirstResponder(hosting)
    }

    /// Width is fixed; height comes from the same `PanelHeight` preference the panel draws at.
    static func preferredContentSize(screen: NSScreen? = nil) -> NSSize {
        let raw = UserDefaults.standard.string(forKey: PanelHeight.storageKey)
        let height = (raw.flatMap(PanelHeight.init(rawValue:)) ?? .standard).points
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return NSSize(width: panelWidth, height: min(height, available - 24))
    }

    // MARK: - Positioning

    private var statusAnchor: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var statusScreen: NSScreen? {
        statusItem?.button?.window?.screen ?? NSScreen.main
    }

    /// Puts the panel's top edge just under the status item, centred on it, clamped into the visible
    /// frame of whichever screen hosts the item (a menu bar on a secondary display included).
    private static func frame(for size: NSSize, anchor: NSRect?, screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(size.width, visible.width - screenMargin * 2)
        let height = min(size.height, visible.height - screenMargin * 2)
        var x = (anchor?.midX ?? visible.midX) - width / 2
        x = min(max(x, visible.minX + screenMargin), visible.maxX - width - screenMargin)
        let top = anchor?.minY ?? visible.maxY
        let y = max(top - height - topGap, visible.minY + screenMargin)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    // MARK: - Status Item Gesture

    /// A short left click toggles the panel and holding either button for 0.2 s starts dictation.
    /// On macOS 26+, the system menu bar (`NSMenuBarNavigationSceneExtension`) hosts status items
    /// out-of-process: it delivers holds via `setLongPressAction:` (`_performSecondaryAction:type:`)
    /// and delivers short clicks as a synthesized mouseDown+mouseUp pair upon release. Combining
    /// button actions, `setLongPressAction:`, and mouse-down monitors covers both in-process and
    /// out-of-process menu bar hosts.
    @objc func handleStatusItemPress() {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown?:
            guard ProcessInfo.processInfo.systemUptime >= suppressReleaseUntil, !pressTriggered else { return }
            pressAllowsToggle = true
            beginPress()
        case .rightMouseDown?:
            guard ProcessInfo.processInfo.systemUptime >= suppressReleaseUntil, !pressTriggered else { return }
            pressAllowsToggle = false
            beginPress()
        case .leftMouseUp?, .rightMouseUp?:
            // On macOS 26+ (NSSceneStatusItem), `-[NSStatusItem _performOneShotAction:]` synthesizes
            // both `leftMouseDown` and `leftMouseUp` back-to-back at the moment the press begins while
            // the physical mouse button is still held down. Only finish immediately when the button is
            // no longer physically pressed; otherwise let `pressTimer` track the hold threshold and
            // eventual release.
            if (NSEvent.pressedMouseButtons & 0x3) == 0 {
                finishPress()
            }
        default:
            if !pressTriggered, ProcessInfo.processInfo.systemUptime >= suppressReleaseUntil {
                togglePanel()
            }
        }
    }

    @objc func handleStatusItemNativeLongPress(_ sender: Any?) {
        let now = ProcessInfo.processInfo.systemUptime
        if !pressTriggered {
            pressTriggered = true
            pressAllowsToggle = false
            pressStartedAt = now
            beginHoldToTalk()
        }
        if (NSEvent.pressedMouseButtons & 0x3) != 0 {
            startPressTimerIfNeeded()
        } else {
            finishPress()
        }
    }

    private func beginHoldDetectionFromMonitor() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= suppressReleaseUntil, !pressTriggered else { return }
        if pressTimer == nil {
            pressAllowsToggle = false
            pressStartedAt = now
            startPressTimerIfNeeded()
        }
    }

    private func beginPress() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= suppressReleaseUntil, !pressTriggered else { return }
        if pressTimer == nil {
            pressStartedAt = now
        }
        startPressTimerIfNeeded()
    }

    private func startPressTimerIfNeeded() {
        guard pressTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.holdTick,
            target: self,
            selector: #selector(handlePressTick(_:)),
            userInfo: nil,
            repeats: true
        )
        pressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handlePressTick(_ timer: Timer) {
        if (NSEvent.pressedMouseButtons & 0x3) != 0 {
            guard !pressTriggered,
                  ProcessInfo.processInfo.systemUptime - pressStartedAt >= Self.holdThreshold else { return }
            // Keep ticking so the release still stops dictation.
            pressTriggered = true
            beginHoldToTalk()
            return
        }
        // Released outside the button: the up action never arrives, so finish from here.
        finishPress()
    }

    private func finishPress() {
        guard pressTimer != nil || pressTriggered else { return }
        let now = ProcessInfo.processInfo.systemUptime
        stopPressTimer()

        if pressTriggered {
            pressTriggered = false
            pressAllowsToggle = false
            suppressReleaseUntil = now + 0.45
            endHoldToTalk()
            return
        }

        // AppKit can deliver both the up action and the timer fallback for one release.
        guard now >= suppressReleaseUntil else { return }
        if pressAllowsToggle {
            pressAllowsToggle = false
            suppressReleaseUntil = now + 0.15
            togglePanel()
        }
    }

    private func stopPressTimer() {
        pressTimer?.invalidate()
        pressTimer = nil
    }

    // MARK: - Hold to Talk

    func beginHoldToTalk() {
        guard let store else { return }
        SpeechInputController.shared.startHoldToTalk(store: store)
        syncStatusItem()
        showPanel()
        store.presentAssistantBar(startVoice: false)
        // A microphone prompt or the first audio buffer can steal key status; re-assert the panel.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, let store = self.store, store.isShowingAssistantBar else { return }
            self.syncStatusItem()
            self.showPanel()
        }
    }

    func endHoldToTalk() {
        guard let store else { return }
        SpeechInputController.shared.finishHoldToTalk(store: store)
        syncStatusItem()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, let store = self.store, store.isShowingAssistantBar else { return }
            self.syncStatusItem()
            self.showPanel()
        }
    }

    // MARK: - Outside Click, Screens & Preferences

    private func installObservers() {
        // Outside clicks end the session through two public signals: activating another app
        // (`didResignActive`) and another window of ours taking key status. A SwiftUI context menu
        // opens its own window while the panel stays up, so that case is explicitly exempt.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                self?.handleOtherWindowBecameKey(window)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationResignActive()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersChanged()
            }
        })
        // Height or skin changed in Settings while the panel is open: apply it right away.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePreferencesChanged()
            }
        })
    }

    /// Another window of ours (Settings, an alert) took key status: the panel closes, like the extra
    /// did when the user moved to the Settings scene. The status item's own window and anything the
    /// panel spawned (sheet, popover, context menu) are exempt.
    func handleOtherWindowBecameKey(_ window: NSWindow?) {
        guard isPanelVisible, let window else { return }
        guard !isPanelWindow(window) else { return }
        guard window !== statusItem?.button?.window else { return }
        hidePanel()
    }

    private func installMouseMonitors() {
        guard localMouseMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow)
                    ?? event.locationInWindow
                self?.handleMouseDown(in: event.window, at: point)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMouseDown(in: nil, at: NSEvent.mouseLocation)
            }
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    /// A click need not activate another app (desktop, nonactivating panels, other status items).
    /// Keep our own controls and status button working, and never swallow the original click.
    func handleMouseDown(in window: NSWindow?, at screenPoint: NSPoint) {
        if let button = statusItem?.button,
           let statusWindow = button.window {
            let statusRect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if window === statusWindow || statusRect.insetBy(dx: -6, dy: -6).contains(screenPoint) {
                if (NSEvent.pressedMouseButtons & 0x3) != 0 {
                    beginHoldDetectionFromMonitor()
                }
                return
            }
        }
        guard isPanelVisible, let panel = panelWindow else { return }
        guard !isPanelWindow(window) else { return }
        if panel.frame.contains(screenPoint) { return }
        if let children = panel.childWindows,
           children.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) }) { return }
        if SpeechInputController.shared.isListening
            || SpeechInputController.shared.isHoldToTalk
            || pressTriggered
            || pressTimer != nil
            || HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown { return }
        hidePanel()
    }

    func handleApplicationResignActive() {
        guard isPanelVisible else { return }
        // A TCC prompt (microphone/speech) deactivates the app mid-dictation; keep the panel.
        if SpeechInputController.shared.isListening
            || SpeechInputController.shared.isHoldToTalk
            || pressTriggered
            || pressTimer != nil
            || HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown { return }
        hidePanel()
    }

    func handleScreenParametersChanged() {
        guard let panel = panelWindow, panel.isVisible else { return }
        panel.setFrame(
            Self.frame(for: panel.frame.size, anchor: statusAnchor, screen: statusScreen),
            display: true
        )
    }

    func handlePreferencesChanged() {
        panelWindow?.appearance = Self.preferredAppearance()
        guard isPanelVisible else { return }
        let height = Self.preferredContentSize(screen: statusScreen).height
        updatePanelSize(width: Self.panelWidth, height: height)
    }
}

/// Borderless panels are not key windows by default; the control center needs key status for arrow
/// keys, Esc, ⌘, and its text fields, as the `MenuBarExtra` window had.
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
