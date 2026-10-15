import SwiftUI
import AppKit
import MijiaCore

@main
@MainActor
struct MenuBarMijiaApp: App {
    @State private var store = HomeStore.shared

    init() {
        let sharedStore = HomeStore.shared
        HotkeyAndNotificationManager.shared.start(with: sharedStore)
    }

    var body: some Scene {
        MenuBarExtra {
            ControlCenterPanel(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.menuBarSymbolName)
                if let text = store.menuBarText {
                    Text(text)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
