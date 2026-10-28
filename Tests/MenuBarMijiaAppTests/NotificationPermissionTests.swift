import AppKit
import Testing
@testable import MenuBarMijiaApp

@MainActor
@Suite(.serialized)
struct NotificationPermissionTests {
    @Test("Returning to the app refreshes notification permission without requesting it")
    func activationRefreshesPermission() async throws {
        // An unbundled test runner must query no system notification APIs.
        #expect(Bundle.main.bundleURL.pathExtension != "app")
        let state = NotificationPermissionState.shared
        let previousStatus = state.status
        let previousCanRequest = state.canRequest
        defer { state.update(previousStatus, canRequest: previousCanRequest) }
        _ = HotkeyAndNotificationManager.shared
        state.update(.denied, canRequest: false)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        for _ in 0..<100 where state.status == .denied {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Refresh uses the existing non-app guard, which clears stale status without a prompt.
        #expect(state.status == .notDetermined)
        #expect(!state.canRequest)
    }
}
