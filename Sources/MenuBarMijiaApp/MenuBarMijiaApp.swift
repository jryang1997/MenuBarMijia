import SwiftUI
import AppKit
import MijiaCore

@main
@MainActor
struct MenuBarMijiaApp: App {
    @State private var store = HomeStore.shared

    init() {
        _ = HomeStore.shared
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
