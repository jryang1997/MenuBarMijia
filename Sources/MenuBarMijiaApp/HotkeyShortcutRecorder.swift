import AppKit
import Carbon
import MijiaCore
import Observation
import SwiftUI
import UserNotifications

// MARK: - Global Hotkey Settings State (#43)

/// Primitives extracted from an `NSEvent` so the recording can cross the monitor
/// handler's `@Sendable` boundary (`NSEvent` itself is not Sendable).
private struct RecordedKeyPayload: Sendable {
    var keyCode: UInt16
    var label: String
    var modifiers: HotkeyModifiers
}

/// Mirrors the Carbon registration result so Settings can show "快捷键已被占用" instead of failing
/// silently. The manager owns the registration; this type is only the UI-facing state.
@Observable
@MainActor
public final class HotkeySettingsState {
    public static let shared = HotkeySettingsState()

    public private(set) var shortcut: HotkeyShortcut = HotkeyPreferences.load()
    public private(set) var registrationError: String?
    public private(set) var isRegistered = false

    private init() {}

    func reload() {
        shortcut = HotkeyPreferences.load()
    }

    func markRegistered(_ shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
        isRegistered = true
        registrationError = nil
    }

    func markFailed(_ shortcut: HotkeyShortcut, status: OSStatus) {
        self.shortcut = shortcut
        isRegistered = false
        registrationError = Self.message(for: status)
    }

    func markDisabled() {
        isRegistered = false
        registrationError = nil
    }

    /// Carbon reports `eventHotKeyExistsErr` (-9878) when another app owns the chord.
    private static let hotKeyExistsStatus: OSStatus = -9878

    private static func message(for status: OSStatus) -> String {
        if status == hotKeyExistsStatus {
            return L10n.tr(
                "这个组合已被其他应用占用，换一个再试。",
                "Another app already owns this shortcut. Try a different combination."
            )
        }
        return L10n.tr(
            "快捷键注册失败（错误码 \(status)），换一个组合再试。",
            "Could not register the shortcut (error \(status)). Try another combination."
        )
    }
}

// MARK: - Notification Permission State (#55)

@Observable
@MainActor
public final class NotificationPermissionState {
    public static let shared = NotificationPermissionState()

    public private(set) var status: UNAuthorizationStatus = .notDetermined
    public private(set) var canRequest = false

    private init() {}

    func update(_ status: UNAuthorizationStatus, canRequest: Bool) {
        self.status = status
        self.canRequest = canRequest
    }

    public var isAuthorized: Bool {
        status == .authorized || status == .provisional
    }

    public var isDenied: Bool {
        status == .denied
    }

    /// Status line shown in Settings next to 守护提醒.
    public var statusText: String {
        switch status {
        case .authorized, .provisional:
            return L10n.tr("通知已允许", "Notifications allowed")
        case .denied:
            return L10n.tr("通知已关闭", "Notifications are off")
        case .notDetermined:
            return L10n.tr("尚未请求通知权限", "Notification permission not requested yet")
        @unknown default:
            return L10n.tr("通知状态未知", "Unknown notification state")
        }
    }
}

// MARK: - Shortcut Recorder (#43)

/// Captures the next key chord while the Settings recorder button is armed. A local monitor is used
/// instead of a first-responder view so the recording works no matter which control has focus.
@Observable
@MainActor
final class HotkeyRecorderController {
    static let shared = HotkeyRecorderController()

    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?
    private let state: HotkeySettingsState

    private init(state: HotkeySettingsState = .shared) {
        self.state = state
    }

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            // NSEvent 不能跨 Sendable 边界：先把需要的原语提出来（本地监视器保证主线程）。
            let payload = RecordedKeyPayload(
                keyCode: event.keyCode,
                label: Self.label(for: event),
                modifiers: Self.modifiers(from: event.modifierFlags)
            )
            let swallow = MainActor.assumeIsolated { self.apply(payload) }
            return swallow ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    /// Records the captured key. Returns `true` when the event was consumed (always, while recording:
    /// cancel, unusable chord beep, or a saved shortcut — none of them should leak to other apps).
    @MainActor
    private func apply(_ key: RecordedKeyPayload) -> Bool {
        // Esc cancels instead of closing the Settings window.
        if key.keyCode == UInt16(kVK_Escape) {
            stop()
            return true
        }

        let shortcut = HotkeyShortcut(
            keyCode: key.keyCode,
            keyLabel: key.label,
            modifiers: key.modifiers
        )
        // A plain letter would be swallowed system-wide; keep listening for a usable chord.
        guard shortcut.isValid else {
            NSSound.beep()
            return true
        }

        HotkeyPreferences.save(shortcut)
        HotkeyAndNotificationManager.shared.applyHotkeyPreference()
        state.reload()
        stop()
        return true
    }

    /// Whether a key event is the currently configured global shortcut.
    static func matches(_ event: NSEvent) -> Bool {
        let shortcut = HotkeyPreferences.load()
        guard event.keyCode == shortcut.keyCode else { return false }
        return modifiers(from: event.modifierFlags) == shortcut.modifiers
    }

    nonisolated static func modifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// Non-printable keys keep a readable label; letters/digits use the current keyboard layout.
    nonisolated private static func label(for event: NSEvent) -> String {
        if let special = specialLabels[event.keyCode] {
            return special
        }
        let raw = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            return ""
        }
        return raw.uppercased()
    }

    nonisolated private static let specialLabels: [UInt16: String] = {
        // 分步构建：单个巨型字面量会让类型检查器超时。
        let pairs: [(UInt16, String)] = [
            (UInt16(kVK_Space), "Space"),
            (UInt16(kVK_Tab), "Tab"),
            (UInt16(kVK_Return), "Return"),
            (UInt16(kVK_Delete), "Delete"),
            (UInt16(kVK_LeftArrow), "←"),
            (UInt16(kVK_RightArrow), "→"),
            (UInt16(kVK_UpArrow), "↑"),
            (UInt16(kVK_DownArrow), "↓"),
            (UInt16(kVK_Home), "Home"),
            (UInt16(kVK_End), "End"),
            (UInt16(kVK_PageUp), "PgUp"),
            (UInt16(kVK_PageDown), "PgDn"),
            (UInt16(kVK_F1), "F1"),
            (UInt16(kVK_F2), "F2"),
            (UInt16(kVK_F3), "F3"),
            (UInt16(kVK_F4), "F4"),
            (UInt16(kVK_F5), "F5"),
            (UInt16(kVK_F6), "F6"),
            (UInt16(kVK_F7), "F7"),
            (UInt16(kVK_F8), "F8"),
            (UInt16(kVK_F9), "F9"),
            (UInt16(kVK_F10), "F10"),
            (UInt16(kVK_F11), "F11"),
            (UInt16(kVK_F12), "F12"),
            (UInt16(kVK_F13), "F13"),
            (UInt16(kVK_F14), "F14"),
            (UInt16(kVK_F15), "F15"),
            (UInt16(kVK_F16), "F16"),
            (UInt16(kVK_F17), "F17"),
            (UInt16(kVK_F18), "F18"),
            (UInt16(kVK_F19), "F19"),
            (UInt16(kVK_F20), "F20"),
        ]
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }()
}

// MARK: - Recorder Row

struct HotkeyRecorderRow: View {
    private var state: HotkeySettingsState { .shared }
    private var recorder: HotkeyRecorderController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.tr("呼出面板的快捷键", "Show Dashboard Shortcut"))
                    .font(.system(size: DesignTokens.TypeSize.body))
                Spacer()

                Button {
                    recorder.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: recorder.isRecording ? "record.circle" : "keyboard")
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        Text(recorder.isRecording
                             ? L10n.tr("按下组合…", "Press keys…")
                             : state.shortcut.displayString)
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: recorder.isRecording, tintColor: .accentColor))
                .help(L10n.tr("点击后按下新的组合；Esc 取消", "Click, then press a new combination; Esc cancels"))

                if !state.shortcut.isDefault {
                    Button(L10n.tr("恢复 ⌥M", "Reset ⌥M")) {
                        HotkeyPreferences.reset()
                        state.reload()
                        HotkeyAndNotificationManager.shared.applyHotkeyPreference()
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }

            if recorder.isRecording {
                Text(L10n.tr(
                    "需要至少一个 ⌘ / ⌥ / ⌃ / ⇧，或单按 F1–F20。Esc 取消。",
                    "Use at least one of ⌘ / ⌥ / ⌃ / ⇧, or a single F1–F20 key. Esc cancels."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
            }

            if let error = state.registrationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(L10n.tr("重试", "Retry")) {
                        HotkeyAndNotificationManager.shared.retryHotkeyRegistration()
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }
        }
        .onDisappear {
            recorder.stop()
        }
    }
}

// MARK: - Notification Permission Row (#55)

struct NotificationPermissionRow: View {
    private var state: NotificationPermissionState { .shared }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.isAuthorized ? "bell.badge.fill" : (state.isDenied ? "bell.slash.fill" : "bell"))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(state.isAuthorized ? .green : (state.isDenied ? .orange : .secondary))

            Text(state.statusText)
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(state.isDenied ? .orange : .secondary)

            Spacer(minLength: 4)

            if state.isDenied {
                Button(L10n.tr("打开系统设置", "Open System Settings")) {
                    HotkeyAndNotificationManager.shared.openNotificationSystemSettings()
                }
                .buttonStyle(PillActionButtonStyle())
            } else if state.canRequest {
                Button(L10n.tr("允许通知", "Allow Notifications")) {
                    Task { _ = await HotkeyAndNotificationManager.shared.requestNotificationAuthorization() }
                }
                .buttonStyle(PillActionButtonStyle())
            }
        }
    }
}
