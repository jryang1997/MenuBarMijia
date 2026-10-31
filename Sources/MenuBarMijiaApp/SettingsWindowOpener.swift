import AppKit
import Observation

/// Opens the ⌘, Settings window from code paths that cannot read SwiftUI's environment (the local
/// key monitor in `HotkeyAndNotificationManager`, the panel's gear button, URL and intent callbacks).
///
/// Public API only (#56):
/// 1. `open` — the public `openSettings` environment action, registered by a view in a real scene.
/// 2. The app menu's Settings… item, performed with `NSMenu.performActionForItem(at:)`, which is the
///    documented way to run a menu item as if it were clicked. The item is found by its ⌘, key
///    equivalent, so no localized title is matched.
///
/// Both are attempted because either can be inert: a view hosted outside a scene may get a no-op
/// `openSettings`, and the app menu has no Settings item until SwiftUI builds it. Opening the same
/// window twice is harmless — the second call just brings it forward.
@Observable
@MainActor
final class SettingsWindowOpener {
    static let shared = SettingsWindowOpener()

    @ObservationIgnored var open: (() -> Void)?
    var requestedTab: SettingsTab?

    private init() {}

    func show(tab: SettingsTab? = nil) {
        if let tab {
            requestedTab = tab
        }
        NSApp.activate()
        // Both paths are attempted because either can be inert: this app hosts the control center in
        // a plain `NSHostingView`, which is not part of a scene, so the `openSettings` action it sees
        // can be a no-op; and the app menu has no Settings item until SwiftUI builds it. Calling both
        // only ever brings the same window forward twice.
        open?()
        performSettingsMenuItem()
    }

    /// Runs the app menu's Settings… item. Returns whether such an item existed.
    @discardableResult
    func performSettingsMenuItem() -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        let menus = [mainMenu] + mainMenu.items.compactMap(\.submenu)
        for menu in menus {
            guard let index = menu.items.firstIndex(where: Self.isSettingsItem) else { continue }
            menu.performActionForItem(at: index)
            return true
        }
        return false
    }

    func settingsMenuItem() -> NSMenuItem? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        let menus = [mainMenu] + mainMenu.items.compactMap(\.submenu)
        for menu in menus {
            if let item = menu.items.first(where: Self.isSettingsItem) {
                return item
            }
        }
        return nil
    }

    private static func isSettingsItem(_ item: NSMenuItem) -> Bool {
        guard !item.isSeparatorItem, item.keyEquivalent == "," else { return false }
        return item.keyEquivalentModifierMask.contains(.command)
    }
}
