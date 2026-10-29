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

    @Test("Classic skin in dark mode renders a dark panel background instead of light material")
    func classicDarkModeRendersDarkBackground() async throws {
        let (store, suite) = try await makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let prevSkin = UserDefaults.standard.string(forKey: AppSkin.storageKey)
        let prevAppearance = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        defer {
            if let prevSkin { UserDefaults.standard.set(prevSkin, forKey: AppSkin.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppSkin.storageKey) }
            if let prevAppearance { UserDefaults.standard.set(prevAppearance, forKey: AppAppearance.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AppAppearance.storageKey) }
        }

        UserDefaults.standard.set(AppSkin.classic.rawValue, forKey: AppSkin.storageKey)
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
}
