import SwiftUI
import AppKit
import MijiaCore

@main
@MainActor
struct MenuBarMijiaApp: App {
    @State private var store = HomeStore.shared
    @State private var speech = SpeechInputController.shared

    init() {
        let sharedStore = HomeStore.shared
        HotkeyAndNotificationManager.shared.start(with: sharedStore)
    }

    var body: some Scene {
        MenuBarExtra {
            ControlCenterPanel(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: speech.isListening ? "waveform" : store.menuBarSymbolName)
                if speech.isListening {
                    Text(menuBarSpeechText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                } else if let text = store.menuBarText {
                    Text(text)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
            .help("单击打开面板；按住直接说话控制设备")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSpeechText: String {
        let trimmed = speech.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "聆听中…" }
        if trimmed.count > 10 {
            return String(trimmed.suffix(10))
        }
        return trimmed
    }
}
