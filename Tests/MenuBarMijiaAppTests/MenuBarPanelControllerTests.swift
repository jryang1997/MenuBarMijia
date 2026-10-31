import AppKit
import SwiftUI
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

/// #56: the control center is hosted by an app-owned `NSStatusItem` + `NSPanel` instead of the
/// `MenuBarExtra` scene. These tests drive the real AppKit objects — window creation, show/hide,
/// outside-click closing, sizing and positioning — with an in-memory home and no network.
///
/// `swift test` does not run the app, so the `Settings` scene, SwiftUI lifecycle and the menu bar
/// itself are out of reach; those remain manual acceptance on a Mac.
@MainActor
@Suite(.serialized)
struct MenuBarPanelControllerTests {
    private func makeStore() async throws -> (HomeStore, String) {
        let suite = "test.panel.controller.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<200 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.devices.isEmpty, "MockHomeProvider should deliver a snapshot right away")
        return (store, suite)
    }

    private func makeController(store: HomeStore) -> MenuBarPanelController {
        // `swift test` does not launch an app; AppKit still needs its shared application object
        // before a status item or a window can exist.
        _ = NSApplication.shared
        let controller = MenuBarPanelController()
        controller.presentsActively = false
        controller.install(with: store)
        return controller
    }

    @Test("Installing creates one status item with a button and uninstall releases it")
    func installCreatesStatusItem() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let item = try #require(controller.statusItem)
        #expect(item.button != nil)
        #expect(controller.panelWindow == nil, "the panel window is created lazily on first open")
        #expect(controller.isPanelVisible == false)

        controller.uninstall()
        #expect(controller.statusItem == nil)
        #expect(controller.panelWindow == nil)
    }

    @Test("Recreating the status item at launch finish keeps a single working item")
    func recoverStatusItemKeepsOneItem() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.recoverStatusItemIfNeeded()
        controller.recoverStatusItemIfNeeded()

        let item = try #require(controller.statusItem)
        #expect(item.button != nil)
        let expectedSymbol = SpeechInputController.shared.isListening ? "waveform" : store.menuBarSymbolName
        #expect(controller.labelSymbol == expectedSymbol)
    }

    @Test("Status item button carries the summary as tooltip and accessibility label")
    func statusItemShowsSummary() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let button = try #require(controller.statusItem?.button)
        controller.syncStatusItem()

        let summary = MenuBarStatusSummary.text(for: store)
        #expect(button.toolTip == summary)
        #expect(button.accessibilityLabel() == summary)
        let expectedTitle = try #require(store.menuBarText)
        #expect(button.attributedTitle.string.trimmingCharacters(in: .whitespaces) == expectedTitle)
    }

    @Test("Listening shows the waveform icon and the transcript instead of the store text")
    func listeningLabelMirrorsSpeech() async throws {
        let speech = SpeechInputController.shared
        let previousDraft = speech.draft
        let wasListening = speech.isListening
        let draft = "把书房的吸顶灯亮度调暗一点"
        speech.setPreviewState(isListening: true, isHoldToTalk: true, draft: draft)
        defer { speech.setPreviewState(isListening: wasListening, isHoldToTalk: false, draft: previousDraft) }

        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        let button = try #require(controller.statusItem?.button)
        controller.syncStatusItem()

        // 13 characters: the button shows the last ten, as the SwiftUI label did.
        #expect(button.attributedTitle.string.trimmingCharacters(in: .whitespaces) == "的吸顶灯亮度调暗一点")
        #expect(controller.labelSymbol == "waveform")
    }

    @Test("Speech label trims whitespace and caps the transcript at ten characters")
    func speechLabelFormatting() {
        #expect(MenuBarPanelController.speechLabel("   ") == "聆听中…")
        #expect(MenuBarPanelController.speechLabel("开灯") == "开灯")
        // Twelve characters: only the last ten fit in the menu bar.
        #expect(MenuBarPanelController.speechLabel("一二三四五六七八九十十一") == "三四五六七八九十十一")
        #expect(MenuBarPanelController.speechLabel("  关灯  ") == "关灯")
    }

    @Test("Showing the panel creates a key-capable 376 pt window and marks it visible")
    func showPanelCreatesVisibleWindow() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        var didShow = false
        let token = NotificationCenter.default.addObserver(
            forName: MenuBarPanelController.didShowNotification,
            object: nil,
            queue: nil
        ) { _ in
            didShow = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.showPanel()

        let panel = try #require(controller.panelWindow)
        #expect(controller.isPanelVisible)
        #expect(didShow)
        #expect(panel.isVisible)
        #expect(panel.canBecomeKey, "arrow keys and text fields need a key panel")
        #expect(panel.canBecomeMain == false)
        #expect(abs(panel.frame.width - MenuBarPanelController.panelWidth) < 1)
        #expect(panel.contentView is NSHostingView<ControlCenterPanel>)

        let expectedHeight = MenuBarPanelController.preferredContentSize().height
        #expect(abs(panel.frame.height - expectedHeight) < 1)
    }

    @Test("Hiding orders the window out, keeps the SwiftUI tree and posts the hide notification")
    func hidePanelKeepsContent() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView as? NSHostingView<ControlCenterPanel>)

        var didHide = false
        let token = NotificationCenter.default.addObserver(
            forName: MenuBarPanelController.didHideNotification,
            object: nil,
            queue: nil
        ) { _ in
            didHide = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.hidePanel()

        #expect(didHide)
        #expect(controller.isPanelVisible == false)
        #expect(panel.isVisible == false)
        #expect(panel.contentView === hosting, "the SwiftUI tree survives a close")
        #expect(controller.panelWindow === panel, "the window is reused, not recreated")
    }

    @Test("Toggle switches between visible and hidden while preserving the same SwiftUI tree")
    func toggleCyclesVisibility() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.togglePanel()
        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView as? NSHostingView<ControlCenterPanel>)
        #expect(controller.isPanelVisible)

        controller.togglePanel()
        #expect(controller.isPanelVisible == false)
        #expect(panel.contentView === hosting)

        controller.togglePanel()
        #expect(controller.isPanelVisible)
        #expect(panel.contentView === hosting)
    }

    @Test("The panel window is the only window recognised as the control center")
    func isPanelWindowMatchesOnlyThePanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { other.orderOut(nil) }

        let statusWindow = controller.statusItem?.button?.window
        #expect(controller.isPanelWindow(panel))
        #expect(controller.isPanelWindow(other) == false)
        #expect(controller.isPanelWindow(nil) == false)
        #expect(controller.isPanelWindow(statusWindow) == false, "the status item window is not the panel")
    }

    @Test("Panel tracks the panel-height preference and stays 376 wide")
    func panelSizingFollowsPreference() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let previous = UserDefaults.standard.string(forKey: PanelHeight.storageKey)
        UserDefaults.standard.set(PanelHeight.compact.rawValue, forKey: PanelHeight.storageKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: PanelHeight.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PanelHeight.storageKey)
            }
        }
        // The controller reads the preference through `UserDefaults.standard`, like the panel's
        // `@AppStorage`, so the window starts at the compact height.

        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)

        let compact = PanelHeight.compact.points
        let screenHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        // `preferredContentSize()` caps the preference to 24 pt below the visible frame.
        #expect(abs(panel.frame.height - min(compact, screenHeight - 24)) < 1)

        controller.updatePanelSize(width: MenuBarPanelController.panelWidth, height: 320)
        #expect(abs(panel.frame.height - 320) < 1)
        #expect(abs(panel.frame.width - MenuBarPanelController.panelWidth) < 1)
    }

    @Test("Sizing while the panel is closed does not create a window")
    func sizingBeforeOpenIsIgnored() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.updatePanelSize(width: MenuBarPanelController.panelWidth, height: 420)
        #expect(controller.panelWindow == nil)
    }

    @Test("The panel is placed under the menu bar of its screen and clamped on screen")
    func panelIsPositionedUnderTheMenuBar() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame

        if let visible {
            #expect(panel.frame.maxY <= visible.maxY + 1, "never above the visible frame")
            #expect(panel.frame.minY >= visible.minY - 1, "never below the screen")
            #expect(panel.frame.minX >= visible.minX - 1)
            #expect(panel.frame.maxX <= visible.maxX + 1)
        }
    }

    @Test("Another window taking key status closes the panel; the panel and its own children do not")
    func otherWindowBecameKeyClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)

        controller.handleOtherWindowBecameKey(panel)
        #expect(controller.isPanelVisible, "the panel itself is not 'another window'")

        // A context menu or sheet the panel spawned keeps it open.
        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { child.orderOut(nil) }
        panel.addChildWindow(child, ordered: .above)
        #expect(controller.isPanelWindow(child))
        controller.handleOtherWindowBecameKey(child)
        #expect(controller.isPanelVisible, "a panel-owned window must not dismiss the panel")

        let settingsLike = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { settingsLike.orderOut(nil) }

        controller.handleOtherWindowBecameKey(settingsLike)
        #expect(controller.isPanelVisible == false)
    }

    @Test("An outside mouse click closes the panel without an application deactivation")
    func outsideMouseClickClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        let outside = NSPoint(x: panel.frame.minX - 20, y: panel.frame.midY)
        controller.handleMouseDown(in: panel, at: panel.frame.origin)
        #expect(controller.isPanelVisible, "panel controls keep working")
        if let button = controller.statusItem?.button, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            controller.handleMouseDown(in: window, at: NSPoint(x: frame.midX, y: frame.midY))
            #expect(controller.isPanelVisible, "the status button must toggle on release")
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: outside, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        NSApp.sendEvent(event)

        #expect(!controller.isPanelVisible)
        #expect(!store.pollingContext.panelVisible)

        controller.showPanel()
        NSApp.sendEvent(event)
        #expect(!controller.isPanelVisible, "outside clicks still work after reopening")
    }

    @Test("Losing key status to another app closes the panel, but dictation keeps it")
    func appDeactivationClosesPanel() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        #expect(controller.isPanelVisible)

        let speech = SpeechInputController.shared
        let previousDraft = speech.draft
        let wasListening = speech.isListening
        speech.setPreviewState(isListening: true, isHoldToTalk: true, draft: "开灯")
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible, "a TCC prompt must not close the panel mid-dictation")

        speech.setPreviewState(isListening: wasListening, isHoldToTalk: false, draft: previousDraft)
        controller.handleApplicationResignActive()
        #expect(controller.isPanelVisible == false)
    }

    @Test("Showing the panel reports panel visibility to the store so polling can follow it")
    func showAndHideUpdatePollingContext() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        #expect(store.pollingContext.panelVisible)
        controller.hidePanel()
        #expect(store.pollingContext.panelVisible == false)
    }

    @Test("Keyboard shortcuts only take over inside the panel window")
    func keyboardHandlingIsPanelScoped() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let controller = makeController(store: store)
        defer { controller.uninstall() }

        controller.showPanel()
        let panel = try #require(controller.panelWindow)
        #expect(panel.canBecomeKey)
        #expect(controller.isPanelWindow(panel))
        // Settings is a different window, so ⌘,-style AppKit handling stays untouched there.
        #expect(controller.isPanelWindow(NSApp.keyWindow) == (NSApp.keyWindow === panel))
    }

    @Test("Dark appearance renders a dark panel background instead of light material")
    func classicDarkModeRendersDarkBackground() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let prevAppearance = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        defer {
            if let prevAppearance { UserDefaults.standard.set(prevAppearance, forKey: AppAppearance.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppAppearance.storageKey) }
        }

        UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: AppAppearance.storageKey)

        let controller = makeController(store: store)
        defer { controller.uninstall() }
        controller.showPanel()

        let panel = try #require(controller.panelWindow)
        let hosting = try #require(panel.contentView)
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        panel.displayIfNeeded()

        let size = hosting.bounds.size
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        // Sample background pixel in the outer top-left padding (x: 10, y: 6) where no header views render.
        let bgColor = try #require(bitmap.colorAt(x: 10, y: 6)?.usingColorSpace(.deviceRGB))
        let luminance = 0.2126 * bgColor.redComponent + 0.7152 * bgColor.greenComponent + 0.0722 * bgColor.blueComponent
        let effectiveName = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        #expect(effectiveName == .darkAqua)
        #expect(luminance < 0.35, "Classic dark mode panel background should be dark, got luminance \(luminance)")

        // Switching to forced light updates the panel's appearance right away.
        UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppAppearance.storageKey)
        controller.handlePreferencesChanged()
        #expect(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    @Test("Short global hotkey press toggles the panel; holding opens voice assistant without closing on release")
    func globalHotkeyShortPressAndLongHoldVoice() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        _ = NSApplication.shared
        let sharedController = MenuBarPanelController.shared
        let prevPresentsActively = sharedController.presentsActively
        sharedController.presentsActively = false
        sharedController.install(with: store)
        HotkeyAndNotificationManager.shared.attachStoreForTesting(store)
        defer {
            HotkeyAndNotificationManager.shared.attachStoreForTesting(nil)
            SpeechInputController.shared.stop(andSubmit: false, store: nil)
            SpeechInputController.shared.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
            sharedController.uninstall()
            sharedController.presentsActively = prevPresentsActively
        }

        // 1. Short tap (< threshold): toggles the panel open on release, without opening the voice bar.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.3)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered == false)
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown == false)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar == false)

        // Second short tap closes the panel.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.3)
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(sharedController.isPanelVisible == false)

        // 2. Long hold (>= threshold): opens the panel, presents the assistant bar, and starts Hold-to-Talk.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyPressed(holdThreshold: 0.03)
        try await Task.sleep(for: .milliseconds(70))
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar)
        #expect(SpeechInputController.shared.isHoldToTalk)

        // Releasing after a long hold finishes Hold-to-Talk instead of toggling the panel closed.
        HotkeyAndNotificationManager.shared.handleGlobalHotKeyReleased()
        #expect(HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown == false)
        #expect(HotkeyAndNotificationManager.shared.isHotkeyHoldTriggered == false)
        #expect(sharedController.isPanelVisible)
        #expect(store.isShowingAssistantBar)
    }

    @Test("Status item native long press opens voice assistant and suppresses trailing synthetic click")
    func statusItemLongPressOpensVoiceAndSuppressesTrailingClick() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let controller = makeController(store: store)
        defer {
            SpeechInputController.shared.stop(andSubmit: false, store: nil)
            SpeechInputController.shared.setPreviewState(isListening: false, isHoldToTalk: false, draft: "")
            controller.uninstall()
        }

        let item = try #require(controller.statusItem)
        if let targetIvar = class_getInstanceVariable(NSStatusItem.self, "_target") {
            let rawTarget = object_getIvar(item, targetIvar) as AnyObject?
            #expect(rawTarget === controller, "NSStatusItem->_target ivar must be set directly for _performSecondaryAction:type:")
        }
        let getLongSel = NSSelectorFromString("longPressAction")
        if item.responds(to: getLongSel),
           let method = class_getInstanceMethod(type(of: item), getLongSel) {
            typealias GetSelFn = @convention(c) (AnyObject, Selector) -> Selector?
            let imp = unsafeBitCast(method_getImplementation(method), to: GetSelFn.self)
            #expect(imp(item, getLongSel) == #selector(MenuBarPanelController.handleStatusItemNativeLongPress(_:)))
        }

        // Simulate macOS 26+ out-of-process menu bar secondary action (type 0 = long press on status item)
        let secondarySel = NSSelectorFromString("_performSecondaryAction:type:")
        if item.responds(to: secondarySel),
           let method = class_getInstanceMethod(type(of: item), secondarySel) {
            typealias PerformSecondaryFn = @convention(c) (AnyObject, Selector, AnyObject?, Int) -> Void
            let imp = unsafeBitCast(method_getImplementation(method), to: PerformSecondaryFn.self)
            imp(item, secondarySel, nil, 0)
        } else {
            controller.handleStatusItemNativeLongPress(item)
        }
        #expect(controller.isPanelVisible)
        #expect(store.isShowingAssistantBar)

        // A trailing synthetic click delivered right after releasing a long press must not close the panel
        controller.handleStatusItemPress()
        #expect(controller.isPanelVisible)
        #expect(store.isShowingAssistantBar)
    }

    @Test("Horizontal wheel monitor translates vertical mouse wheel and trackpad deltas into clamped horizontal scroll")
    func horizontalWheelMonitorScrollsAndClamps() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 32))
        scrollView.documentView = documentView

        // Rolling the mouse wheel down (negative deltaY) moves the horizontal strip right.
        let movedRight = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -2,
            hasPreciseDeltas: false
        )
        #expect(movedRight)
        #expect(scrollView.contentView.bounds.origin.x == 32)

        // Trackpad horizontal swipe right-to-left (negative deltaX) advances by exact points.
        let movedPrecise = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: -48,
            deltaY: -4,
            hasPreciseDeltas: true
        )
        #expect(movedPrecise)
        #expect(scrollView.contentView.bounds.origin.x == 80)

        // Clamps at maxOffsetX (640 - 240 = 400) and back at 0.
        _ = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -1000,
            hasPreciseDeltas: true
        )
        #expect(scrollView.contentView.bounds.origin.x == 400)

        _ = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: 1000,
            hasPreciseDeltas: true
        )
        #expect(scrollView.contentView.bounds.origin.x == 0)

        // Non-overflowing strip does not scroll.
        documentView.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        let movedWhenFitting = HorizontalWheelScrollMonitor.applyHorizontalScroll(
            to: scrollView,
            deltaX: 0,
            deltaY: -3,
            hasPreciseDeltas: false
        )
        #expect(!movedWhenFitting)
    }

    @Test("Room strip scrolls hidden rooms into view when selected or cycled")
    func classicSkinRoomStripScrollsToSelectedRoom() async throws {
        let rooms = [
            RoomArea(id: "r1", name: "书房", sortOrder: 0),
            RoomArea(id: "r2", name: "办公室", sortOrder: 1),
            RoomArea(id: "r3", name: "卧室", sortOrder: 2),
            RoomArea(id: "r4", name: "厨房", sortOrder: 3),
            RoomArea(id: "r5", name: "客厅", sortOrder: 4),
            RoomArea(id: "r6", name: "阳台", sortOrder: 5),
            RoomArea(id: "r7", name: "次卧", sortOrder: 6),
            RoomArea(id: "r8", name: "卫生间", sortOrder: 7)
        ]
        var base = DemoHomeProvider.defaultHome()
        base.rooms = rooms
        base.environmentReadings = []
        base.scenes = []

        let suite = "MenuBarPanelTests-rooms-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(false, forKey: "automatically_checks_for_updates")
        defaults.set(false, forKey: "show_quick_actions_bar")

        let store = HomeStore(provider: MockHomeProvider(snapshot: base), defaultsSuiteName: suite)
        for _ in 0..<50 where store.rooms.count < rooms.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.rooms.count == rooms.count)

        let hosting = NSHostingView(
            rootView: ControlCenterPanel(store: store)
                .defaultAppStorage(defaults)
                .environment(\.reduceMotionOverride, true)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 376, height: 560)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        Self.pumpMainRunLoop()

        func findRoomScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView,
               let doc = sv.documentView,
               doc.bounds.width > sv.contentView.bounds.width + 20,
               sv.frame.height < 60 {
                return sv
            }
            for sub in view.subviews {
                if let found = findRoomScrollView(in: sub) {
                    return found
                }
            }
            return nil
        }

        let roomScrollView = try #require(findRoomScrollView(in: hosting))
        #expect(roomScrollView.contentView.bounds.origin.x < 1)

        store.selectedRoomId = "r8"
        try await Task.sleep(for: .milliseconds(80))
        Self.pumpMainRunLoop()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        #expect(roomScrollView.contentView.bounds.origin.x > 40)

        store.selectedRoomId = nil
        try await Task.sleep(for: .milliseconds(80))
        Self.pumpMainRunLoop()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        #expect(roomScrollView.contentView.bounds.origin.x < 1)
    }

    @Test("CameraLivePanelController attaches NSHostingView contentView and elevates above MenuBarPanel")
    func cameraLivePanelAttachesHostingViewAndOrdersAboveMenuBarPanel() async throws {
        let suite = "MenuBarPanelTests-camera-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()), defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let camera = try #require(store.devices.first(where: {
            if case .camera = $0.kind { return true }
            return false
        }))

        let cameraController = CameraLivePanelController.shared
        cameraController.presentsActively = false
        cameraController.install(with: store)
        defer { cameraController.closePanel() }

        store.openCameraLiveView(camera.id)
        let panel = try #require(cameraController.panelWindow)
        #expect(panel.isVisible)
        #expect(panel.contentView is NSHostingView<CameraLivePanelView>, "NSPanel initializes with a blank NSView; present(device:) must replace it with NSHostingView<CameraLivePanelView>")
        #expect(panel.level.rawValue > NSWindow.Level.statusBar.rawValue)
    }

    private static func pumpMainRunLoop(_ seconds: TimeInterval = 0.05) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }
}
