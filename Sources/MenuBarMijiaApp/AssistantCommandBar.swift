import SwiftUI
import AVFoundation
import Speech
import MijiaCore

// MARK: - Nonisolated ObjC Callback Bridge (prevents Swift 6 @MainActor thunk traps on TCC/Audio threads)

private nonisolated enum SpeechRuntimeBridge {
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func installAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    static func startRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onEvent: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = (error != nil)
            onEvent(transcript, isFinal, hasError)
        }
    }
}

// MARK: - Live Speech Recognizer (macOS Speech + AVAudioEngine)

@Observable
@MainActor
public final class SpeechInputController {
    public static let shared = SpeechInputController()

    public var draft: String = ""
    public private(set) var isListening: Bool = false
    public private(set) var isHoldToTalk: Bool = false
    public private(set) var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimerTask: Task<Void, Never>?
    private var holdReleaseTask: Task<Void, Never>?
    private var hasCapturedSpeech: Bool = false
    private var isStarting: Bool = false
    private var isHoldGestureActive: Bool = false

    public init() {}

    public func setPreviewState(isListening: Bool, isHoldToTalk: Bool, draft: String) {
        self.isListening = isListening
        self.isHoldToTalk = isHoldToTalk
        self.isHoldGestureActive = isHoldToTalk
        self.draft = draft
    }

    public var hasVoicePermissions: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public func requestPermissions() async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let micAllowed = await SpeechRuntimeBridge.requestMicrophoneAccess()
        guard micAllowed else { return false }
        let speechStatus = await SpeechRuntimeBridge.requestSpeechAuthorization()
        return speechStatus == .authorized
    }

    public func toggle(store: HomeStore) {
        if isListening {
            stop(andSubmit: hasCapturedSpeech, store: store)
        } else {
            Task { await start(holdMode: false, store: store) }
        }
    }

    public func startHoldToTalk(store: HomeStore) {
        holdReleaseTask?.cancel()
        holdReleaseTask = nil
        isHoldGestureActive = true
        isHoldToTalk = true
        if isListening {
            silenceTimerTask?.cancel()
            silenceTimerTask = nil
            return
        }
        Task { await start(holdMode: true, store: store) }
    }

    public func finishHoldToTalk(store: HomeStore) {
        isHoldGestureActive = false
        guard isHoldToTalk || isListening || isStarting else { return }
        holdReleaseTask?.cancel()
        holdReleaseTask = Task { @MainActor [weak self] in
            // Allow 320ms after mouse/key release for SFSpeechRecognizer to flush any syllables spoken while held.
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            let hasText = self.hasCapturedSpeech || !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if self.isListening {
                if hasText {
                    // User spoke while holding the menu bar icon or global hotkey (Push-to-Talk): stop and execute immediately.
                    self.stop(andSubmit: true, store: store)
                } else {
                    // User long-pressed to summon voice input and released before speaking:
                    // seamlessly transition to hands-free listening with 1.1s silence auto-submit.
                    self.isHoldToTalk = false
                }
            } else {
                self.isHoldToTalk = false
            }
        }
    }

    public func start(holdMode: Bool, store: HomeStore) async {
        guard !isListening, !isStarting else {
            if holdMode { isHoldToTalk = true }
            return
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            errorMessage = L10n.tr("语音识别仅在打包后的 App 中可用", "Speech recognition is only available in the packaged App")
            return
        }
        isStarting = true
        defer { isStarting = false }

        errorMessage = nil
        hasCapturedSpeech = false
        isHoldToTalk = holdMode
        if holdMode {
            draft = ""
        }

        let micAllowed = await SpeechRuntimeBridge.requestMicrophoneAccess()
        guard micAllowed else {
            isHoldToTalk = false
            errorMessage = L10n.tr(
                "请在「系统设置 → 隐私与安全性 → 麦克风」中允许 MenuBarMijia",
                "Please allow MenuBarMijia in System Settings → Privacy & Security → Microphone"
            )
            return
        }

        let speechStatus = await SpeechRuntimeBridge.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            isHoldToTalk = false
            errorMessage = L10n.tr(
                "请在「系统设置 → 隐私与安全性 → 语音识别」中允许 MenuBarMijia",
                "Please allow MenuBarMijia in System Settings → Privacy & Security → Speech Recognition"
            )
            return
        }

        let preferredLocale = Locale(identifier: store.effectiveLanguage.speechLocaleIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: preferredLocale)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            isHoldToTalk = false
            errorMessage = L10n.tr("当前系统语音识别服务暂不可用", "System speech recognition is currently unavailable")
            return
        }

        let gestureStillActive = isHoldGestureActive
        stop(andSubmit: false, store: store)
        isHoldGestureActive = gestureStillActive
        let isStillHoldingInput = gestureStillActive
            || ((NSEvent.pressedMouseButtons & 0x3) != 0)
            || HotkeyAndNotificationManager.shared.isHotkeyPhysicallyDown
        isHoldToTalk = holdMode && isStillHoldingInput

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Privacy option: keep recognition on this Mac when the system supports it.
        if store.prefersOnDeviceSpeech && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            isHoldToTalk = false
            errorMessage = L10n.tr("未检测到可用麦克风输入设备", "No available microphone input device detected")
            return
        }

        SpeechRuntimeBridge.installAudioTap(on: inputNode, format: format, request: request)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            isHoldToTalk = false
            errorMessage = L10n.tr(
                "麦克风启动失败：\(error.localizedDescription)",
                "Microphone failed to start: \(error.localizedDescription)"
            )
            return
        }

        self.audioEngine = engine
        self.recognitionRequest = request
        self.isListening = true

        self.recognitionTask = SpeechRuntimeBridge.startRecognitionTask(
            recognizer: recognizer,
            request: request
        ) { [weak self, weak store] transcript, isFinal, hasError in
            Task { @MainActor [weak self, weak store] in
                guard let self, let store, self.isListening else { return }
                if let transcript {
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.hasCapturedSpeech = true
                        self.draft = trimmed
                        if !self.isHoldToTalk {
                            self.scheduleSilenceAutoSubmit(store: store)
                        }
                    }
                }
                if isFinal || hasError {
                    if !self.isHoldToTalk {
                        self.stop(andSubmit: self.hasCapturedSpeech, store: store)
                    }
                }
            }
        }
    }

    public func stop(andSubmit: Bool, store: HomeStore?) {
        silenceTimerTask?.cancel()
        silenceTimerTask = nil
        holdReleaseTask?.cancel()
        holdReleaseTask = nil

        let textToSubmit = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSubmit = andSubmit && (hasCapturedSpeech || !textToSubmit.isEmpty)
        hasCapturedSpeech = false
        isListening = false
        isHoldToTalk = false
        isHoldGestureActive = false

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        if shouldSubmit, let store {
            submit(store: store)
        }
    }

    public func submit(store: HomeStore) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.assistantState != .thinking else { return }
        Task { @MainActor in
            await store.runAssistantCommand(text)
            if case .done = store.assistantState {
                self.draft = ""
            }
        }
    }

    private func scheduleSilenceAutoSubmit(store: HomeStore) {
        silenceTimerTask?.cancel()
        // Wait 1.1s after the last recognized syllable before auto-submitting the command.
        silenceTimerTask = Task { @MainActor [weak self, weak store] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let self, let store, self.isListening, !self.isHoldToTalk, self.hasCapturedSpeech else { return }
            self.stop(andSubmit: true, store: store)
        }
    }
}

// MARK: - AI Command Bar (top of the main dashboard)

struct AssistantCommandBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: HomeStore

    @Bindable private var speech = SpeechInputController.shared
    @State private var lastHandledVoiceRequest: Int = 0
    /// Asked once when the first timer is scheduled (#55).
    @State private var asksForTimerNotifications = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let _ = store.effectiveLanguage
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: speech.isListening ? "waveform" : "sparkles")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(speech.isListening ? Color.red : Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: speech.isListening)
                    .symbolEffect(.pulse, isActive: store.assistantState == .thinking)

                TextField(
                    placeholderText,
                    text: $speech.draft
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .focused($isFieldFocused)
                .onSubmit {
                    if speech.isListening {
                        speech.stop(andSubmit: false, store: store)
                    }
                    speech.submit(store: store)
                }

                micButton

                trailingAccessory
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .adaptiveGlass(in: shape, interactive: true)
            .overlay(
                shape.strokeBorder(
                    speech.isListening
                        ? Color.red.opacity(0.65)
                        : Color.accentColor.opacity(isFieldFocused ? 0.55 : 0.18),
                    lineWidth: 0.8
                )
            )

            if let reply = replyLine {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: reply.isChoice ? "hand.tap.fill" : (reply.isError ? "xmark.octagon.fill" : "checkmark.circle.fill"))
                        .foregroundStyle(reply.isChoice ? Color.orange : (reply.isError ? Color.red : Color.green))
                    if let receipt = reply.receipt {
                        ExecutionRouteBadge(receipt: receipt)
                    }
                    Text(reply.text)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if store.undoBanner == nil,
               UndoAvailabilityTracker.shared.isAvailable,
               store.pendingCloudConsent == nil {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(Color.orange)
                    Text(L10n.tr(
                        "刚才的操作 10 分钟内仍可撤销（也可以直接说「撤销」）",
                        "The last action can still be undone for 10 minutes (or just say \"undo\")"
                    ))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(L10n.tr("撤销上一步", "Undo")) {
                        Task { await UndoAvailabilityTracker.shared.performUndo(store: store) }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let consent = store.pendingCloudConsent {
                cloudConsentRow(consent)
            }

            if !store.missedScheduledCommands.isEmpty {
                missedScheduledRow
            }

            if !store.scheduledCommands.isEmpty {
                scheduledRow
            }

            if asksForTimerNotifications {
                timerNotificationPromptRow
            }

            suggestionsRow
        }
        .help(L10n.tr(
            "长按 ⌥M 或顶部菜单栏图标可按住说话；或点击麦克风说话，打字回车执行",
            "Hold ⌥M or the menu bar icon for Push-to-Talk, click the mic to speak, or type and press Return"
        ))
        .animation(AppleMotion.snappySpring, value: store.assistantState)
        .animation(AppleMotion.snappySpring, value: store.assistantSuggestions)
        .animation(AppleMotion.snappySpring, value: store.missedScheduledCommands)
        .animation(AppleMotion.snappySpring, value: store.pendingCloudConsent)
        .animation(AppleMotion.snappySpring, value: store.scheduledCommands)
        .animation(AppleMotion.snappySpring, value: asksForTimerNotifications)
        .animation(AppleMotion.snappySpring, value: speech.isListening)
        .onAppear {
            if store.assistantVoiceRequest != lastHandledVoiceRequest {
                lastHandledVoiceRequest = store.assistantVoiceRequest
                Task { await speech.start(holdMode: false, store: store) }
            } else if !speech.isListening && !speech.isHoldToTalk {
                isFieldFocused = true
            }
        }
        .onChange(of: store.assistantFocusRequest) { _, _ in
            if !speech.isListening && !speech.isHoldToTalk {
                isFieldFocused = true
            }
        }
        .onChange(of: store.assistantVoiceRequest) { _, newValue in
            lastHandledVoiceRequest = newValue
            speech.toggle(store: store)
        }
        // First timer: explain notifications before macOS ever asks (#55).
        .onChange(of: store.scheduledCommands.count) { oldValue, newValue in
            guard newValue > oldValue, !asksForTimerNotifications else { return }
            Task {
                await HotkeyAndNotificationManager.shared.refreshNotificationPermission()
                let permission = NotificationPermissionState.shared
                guard permission.canRequest,
                      !HotkeyAndNotificationManager.hasRequestedNotificationAuthorization else { return }
                asksForTimerNotifications = true
            }
        }
    }

    /// Asked once per AI service before anything is sent to the cloud (#20).
    private func cloudConsentRow(_ consent: PendingCloudConsent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundStyle(Color.accentColor)
                Text(consent.utterance == nil
                     ? L10n.tr("生成建议要用云端 AI（\(consent.endpoint)），可以发送吗？", "Suggestions need the cloud AI (\(consent.endpoint)). Send?")
                     : L10n.tr("这句话本机没听懂，要交给云端 AI（\(consent.endpoint)）处理吗？", "Not understood locally. Send it to the cloud AI (\(consent.endpoint))?"))
                    .foregroundStyle(.primary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.tr(
                "会发送：这句话、设备名称/房间/状态、时间段、室温\(store.isHabitLearningEnabled ? "、习惯摘要" : "")。只问这一次，可在设置里撤销。",
                "Sends: your words, device names/rooms/states, time of day, room temperature\(store.isHabitLearningEnabled ? ", habit summary" : ""). Asked once; revoke in Settings."
            ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(L10n.tr("不用了", "Not Now")) {
                    store.declinePendingCloudRequest()
                }
                .buttonStyle(PillActionButtonStyle())
                Button(L10n.tr("允许并发送", "Allow & Send")) {
                    Task { @MainActor in
                        await store.allowPendingCloudRequest()
                        if case .done = store.assistantState {
                            speech.draft = ""
                        }
                    }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Asked once, right after the first timed command, before the system prompt (#55).
    private var timerNotificationPromptRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(Color.accentColor)
                Text(L10n.tr(
                    "定时到点后要靠系统通知提醒你。通知只在本机显示，不上传任何内容。允许通知吗？",
                    "Timers are announced with local macOS notifications. They stay on this Mac. Allow notifications?"
                ))
                .foregroundStyle(.primary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(L10n.tr("暂不", "Not Now")) {
                    asksForTimerNotifications = false
                }
                .buttonStyle(PillActionButtonStyle())
                Button(L10n.tr("允许通知", "Allow Notifications")) {
                    asksForTimerNotifications = false
                    Task { _ = await HotkeyAndNotificationManager.shared.requestNotificationAuthorization() }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Timers that expired while the app was closed; user can run or dismiss each one.
    private var missedScheduledRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(store.missedScheduledCommands) { entry in
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.clock.fill")
                        .foregroundStyle(Color.orange)
                    Text(L10n.tr("已错过：\(entry.reply)", "Missed: \(entry.reply)"))
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(L10n.tr("立即执行", "Run Now")) {
                        Task { await store.runMissedScheduledCommand(id: entry.id) }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                    Button {
                        store.dismissMissedScheduledCommand(id: entry.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("忽略已错过的定时", "Dismiss missed timer")))
                    .help(L10n.tr("忽略这个已错过的定时", "Dismiss this missed timer"))
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 4)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Pending "10 分钟后关灯" commands with a live countdown and a cancel button.
    private var scheduledRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(store.scheduledCommands) { entry in
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .foregroundStyle(Color.orange)
                    Text(entry.reply)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.fireDate, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        store.cancelScheduledCommands(id: entry.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.tr("取消这个定时", "Cancel this timer")))
                    .help(L10n.tr("取消这个定时", "Cancel this timer"))
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 4)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var suggestionsRow: some View {
        let isJev = ModelIntentResolver.isSystemOneModel(store.assistantConfig.model)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    Task { await store.requestProactiveJevSuggestions() }
                } label: {
                    HStack(spacing: 3.5) {
                        if store.isProactiveRecommending {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(isJev ? L10n.tr("Jev 猜你想做", "Jev Suggests") : L10n.tr("AI 猜你想做", "AI Suggests"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(store.isProactiveRecommending)
                .help(L10n.tr(
                    "结合当前室温、时间段与你的个人习惯，实时推演最可能执行的设备操作",
                    "Infer your most likely device actions based on room temperature, time of day, and habits"
                ))

                ForEach(store.assistantSuggestions) { suggestion in
                    Button {
                        Task { await store.applyAssistantSuggestion(suggestion) }
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: suggestion.confidencePercent != nil ? "sparkle" : "clock.arrow.circlepath")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(suggestion.confidencePercent != nil ? Color.orange : Color.secondary)
                            Text(suggestion.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.88))
                            if let pct = suggestion.confidencePercent {
                                Text("\(pct)%")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.orange)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(
                        suggestion.confidencePercent != nil
                            ? L10n.tr("AI 置信度推演建议（点击立即执行）", "AI confidence-ranked suggestion (click to execute)")
                            : L10n.tr("你在当前时间段的常用习惯（点击立即执行）", "Your frequent habit in this time slot (click to execute)")
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var placeholderText: String {
        if speech.isHoldToTalk {
            return L10n.tr(
                "按住快捷键或菜单栏说话，松开立即执行（如：准备写代码、书房灯月光模式）",
                "Hold shortcut or menu bar to speak, release to run (e.g. turn on study light, moonlight mode)"
            )
        }
        if speech.isListening {
            return L10n.tr(
                "正在聆听…说完自动执行（如：准备写代码、书房灯月光模式）",
                "Listening… auto-runs when done (e.g. turn on study light, moonlight mode)"
            )
        }
        return L10n.tr(
            "支持模糊情境与习惯（如：准备写代码、有点闷热、书房灯月光模式）",
            "Type or speak a command (e.g. turn on study light, AC 24 degrees, moonlight mode)"
        )
    }

    private var micButton: some View {
        Button {
            speech.toggle(store: store)
        } label: {
            Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(speech.isListening ? Color.red : Color.accentColor)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(speech.isListening
            ? L10n.tr("停止聆听", "Stop listening")
            : L10n.tr("语音输入", "Voice input")))
        .help(speech.isListening
              ? L10n.tr("停止聆听并执行", "Stop listening and run")
              : L10n.tr("语音输入（快捷键 V，或长按 ⌥M / 菜单栏图标）", "Voice input (Shortcut V, or hold ⌥M / menu bar icon)"))
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if store.assistantState == .thinking {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        } else {
            Button {
                speech.stop(andSubmit: false, store: store)
                withAnimation(AppleMotion.snappySpring) {
                    store.dismissAssistantBar()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("关闭 AI 指令栏", "Close AI command bar")))
            .help(L10n.tr("关闭 (Esc)", "Close (Esc)"))
        }
    }

    private var replyLine: (text: String, isError: Bool, isChoice: Bool, receipt: AssistantExecutionReceipt?)? {
        if let speechError = speech.errorMessage {
            return (speechError, true, false, nil)
        }
        switch store.assistantState {
        case .done(let text):
            return (
                text.isEmpty ? L10n.tr("已执行", "Done") : text,
                false,
                false,
                store.lastAssistantReceipt
            )
        case .failed(let message): return (message, true, false, nil)
        case .awaitingChoice(let message): return (message, false, true, nil)
        case .idle, .thinking: return nil
        }
    }
}

/// Compact evidence of which resolver ran and how long the command took (#93).
private struct ExecutionRouteBadge: View {
    let receipt: AssistantExecutionReceipt

    private var routeTitle: String {
        switch receipt.route {
        case .localRule: return L10n.tr("本地", "Local")
        case .aiModel: return L10n.tr("AI", "AI")
        }
    }

    private var elapsedText: String {
        receipt.elapsedMilliseconds == 0 ? "<1ms" : "\(receipt.elapsedMilliseconds)ms"
    }

    private var accessibilityText: String {
        var text = "\(routeTitle) · \(elapsedText)"
        if receipt.usedHabitContext {
            text += " · \(L10n.tr("习惯", "Habit"))"
        }
        return text
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(receipt.route == .localRule ? "⚡" : "🧠")
            Text(routeTitle)
            Text("· \(elapsedText)")
            if receipt.usedHabitContext {
                Text("· 💡 \(L10n.tr("习惯", "Habit"))")
            }
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
        .help(receipt.habitSummary ?? accessibilityText)
    }
}

// MARK: - Settings: AI 指令

struct AssistantSettingsSection: View {
    let store: HomeStore

    @State private var selectedPreset: AssistantProviderPreset = .openRouterJev
    @State private var baseURLDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var apiKeyDraft: String = ""
    @State private var isTestingConnection = false
    @State private var isShowingHabits = false
    /// Habit memory lives in UserDefaults (not observed), so bump this to redraw after edits.
    @State private var habitRevision = 0
    /// Imported-key labels and cloud consent also live in UserDefaults; bump to redraw after import/undo/revoke.
    @State private var storageRevision = 0

    var body: some View {
        let _ = store.effectiveLanguage
        let _ = habitRevision
        let _ = storageRevision
        let habitItems = store.userHabitMemory.readableItems(devices: store.devices, scenes: store.scenes)
        let habitCount = habitItems.count
        let hasCustomKey = !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let importedSource = hasCustomKey ? AssistantConfig.importedKeySource(forBaseURL: baseURLDraft) : nil
        let isLoopback = AssistantConfig(baseURL: baseURLDraft, model: modelDraft, apiKey: "").isLoopbackEndpoint
        let isInsecure = !baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !AssistantConfig(baseURL: baseURLDraft, model: modelDraft, apiKey: "").allowsSendingAPIKey
        let isSystemOne = ModelIntentResolver.isSystemOneModel(modelDraft)

        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.tr("AI 决策模型与习惯记忆", "AI Decision Model & Habit Memory"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isInsecure {
                    Text(L10n.tr("● 地址需用 https，否则不会发送", "● Use https; nothing will be sent"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                } else if let importedSource {
                    Text(L10n.tr("● 已从 \(importedSource) 导入", "● Imported from \(importedSource)"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green)
                } else if hasCustomKey {
                    Text(L10n.tr("● 已配置自定义密钥", "● Custom API Key Set"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green)
                } else if isLoopback {
                    Text(L10n.tr("● 本机免密接口", "● Local Endpoint"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Text(L10n.tr("● 待填 API Key（常规指令本地可用）", "● No Key (Local Rules Active)"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(L10n.tr("AI 服务商预设", "AI Provider"))
                    .font(.system(size: 11.5))
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { selectedPreset },
                        set: { newPreset in
                            let oldPreset = selectedPreset
                            selectedPreset = newPreset
                            if newPreset != .custom {
                                baseURLDraft = newPreset.defaultBaseURL
                                modelDraft = newPreset.defaultModel
                                apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: newPreset.defaultBaseURL)
                            } else {
                                if modelDraft == oldPreset.defaultModel || ModelIntentResolver.isSystemOneModel(modelDraft) {
                                    modelDraft = "gpt-4o-mini"
                                }
                                // Keys never follow the user to another provider; a custom key reappears once its own URL is typed.
                                apiKeyDraft = AssistantProviderPreset.infer(baseURL: baseURLDraft) == .custom
                                    ? AssistantConfig.userStoredAPIKey(forBaseURL: baseURLDraft)
                                    : ""
                            }
                        }
                    )
                ) {
                    ForEach(AssistantProviderPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .controlSize(.small)
            }

            labeledField(L10n.tr(
                "服务地址 (支持 /v1/systemone 协议与 OpenAI 兼容 /v1/chat/completions)",
                "Endpoint URL (Supports /v1/systemone & OpenAI-compatible /v1/chat/completions)"
            )) {
                TextField(
                    selectedPreset.defaultBaseURL.isEmpty ? AssistantConfig.defaultBaseURL : selectedPreset.defaultBaseURL,
                    text: Binding(
                        get: { baseURLDraft },
                        set: { newValue in
                            let oldPreset = selectedPreset
                            let oldURL = baseURLDraft
                            baseURLDraft = newValue
                            let inferred = AssistantProviderPreset.infer(baseURL: newValue)
                            if inferred == .custom, inferred == oldPreset,
                               AssistantEndpoint(newValue)?.identity != AssistantEndpoint(oldURL)?.identity,
                               apiKeyDraft.isEmpty || apiKeyDraft == AssistantConfig.userStoredAPIKey(forBaseURL: oldURL) {
                                // Another custom server: the saved key stays with its own server (#19).
                                apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: newValue)
                            }
                            if inferred != oldPreset {
                                selectedPreset = inferred
                                apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: newValue)
                                if !inferred.defaultModel.isEmpty {
                                    modelDraft = inferred.defaultModel
                                } else if modelDraft == oldPreset.defaultModel || ModelIntentResolver.isSystemOneModel(modelDraft) {
                                    modelDraft = "gpt-4o-mini"
                                }
                            }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(isSystemOne
                         ? L10n.tr("模型 (System One 协议 · 单次多头并发决策)", "Model (System One · Multi-Head Decision)")
                         : L10n.tr("模型 (OpenAI 兼容 Chat Completions)", "Model (OpenAI-Compatible Chat)"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(selectedPreset.recommendedModels.prefix(2), id: \.self) { candidate in
                        Button(candidate) {
                            modelDraft = candidate
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: modelDraft == candidate ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(modelDraft == candidate ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            (modelDraft == candidate ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)),
                            in: Capsule()
                        )
                    }
                }
                TextField(
                    selectedPreset.defaultModel.isEmpty ? AssistantConfig.defaultModel : selectedPreset.defaultModel,
                    text: $modelDraft
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11.5, design: .monospaced))
            }

            labeledField(L10n.tr(
                "API Key（只存在本机钥匙串）",
                "API Key (Stored only in your Keychain)"
            )) {
                SecureField(
                    selectedPreset.keyPlaceholder,
                    text: $apiKeyDraft
                )
                .textFieldStyle(.roundedBorder)
            }

            if selectedPreset.supportsKeyImport {
                keyImportRow(importedSource: importedSource)
            }

            privacySection(habitItems: habitItems, habitCount: habitCount)

            HStack(spacing: 6) {
                Button(L10n.tr("恢复默认", "Restore Defaults")) {
                    selectedPreset = .openRouterJev
                    baseURLDraft = AssistantConfig.defaultBaseURL
                    modelDraft = AssistantConfig.defaultModel
                    apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: AssistantConfig.defaultBaseURL)
                    _ = saveCurrentDraft()
                    store.showToast(L10n.tr("已恢复默认 AI 配置", "Restored default AI configuration"))
                }
                .buttonStyle(PillActionButtonStyle())

                Button(isTestingConnection ? L10n.tr("测试中…", "Testing…") : L10n.tr("测试连接", "Test AI")) {
                    let saved = saveCurrentDraft()
                    isTestingConnection = true
                    Task {
                        let result = await store.verifyAssistantConfig(saved)
                        isTestingConnection = false
                        store.showToast(result.message, isError: !result.isSuccess)
                    }
                }
                .buttonStyle(PillActionButtonStyle())
                .disabled(isTestingConnection)

                Spacer()

                Button(L10n.tr("保存 AI 配置", "Save AI Config")) {
                    _ = saveCurrentDraft()
                    store.showToast(L10n.tr("已保存 AI 指令配置", "Saved AI configuration"))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            }
            .padding(.top, 2)
        }
        .padding(12)
        .glassTile(isActive: false, accent: .accentColor, cornerRadius: 12)
        .onAppear {
            let config = store.assistantConfig
            baseURLDraft = config.baseURL
            modelDraft = config.model
            selectedPreset = AssistantProviderPreset.infer(baseURL: config.baseURL)
            apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: config.baseURL)
        }
    }

    @discardableResult
    private func saveCurrentDraft() -> AssistantConfig {
        let normalizedBase = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (selectedPreset.defaultBaseURL.isEmpty ? AssistantConfig.defaultBaseURL : selectedPreset.defaultBaseURL)
            : baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackModel = selectedPreset.defaultModel.isEmpty ? "gpt-4o-mini" : selectedPreset.defaultModel
        let normalizedModel = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackModel
            : modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = AssistantConfig(
            baseURL: normalizedBase,
            model: normalizedModel,
            apiKey: apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        store.assistantConfig = cfg
        let resolved = store.assistantConfig
        baseURLDraft = resolved.baseURL
        modelDraft = resolved.model
        selectedPreset = resolved.preset
        return cfg
    }

    /// Whether the current UI language ships an on-device recognizer on this Mac (#50).
    private static func supportsOnDeviceSpeech(for language: AppLanguage) -> Bool {
        let locale = Locale(identifier: language.speechLocaleIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    @ViewBuilder
    private func privacySection(habitItems: [UserHabitMemory.ReadableItem], habitCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { store.isHabitLearningEnabled },
                set: { store.isHabitLearningEnabled = $0 }
            )) {
                Text(L10n.tr("学习我的使用习惯（用于猜你想做）", "Learn my usage habits (for proactive suggestions)"))
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: Binding(
                get: { store.prefersOnDeviceSpeech },
                set: { store.prefersOnDeviceSpeech = $0 }
            )) {
                Text(L10n.tr("语音只在本机识别（不把声音发给苹果，系统支持时生效）", "On-device speech recognition only (when supported by macOS)"))
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            // #50: say so instead of silently falling back to Apple's servers.
            if store.prefersOnDeviceSpeech && !Self.supportsOnDeviceSpeech(for: store.effectiveLanguage) {
                Label(
                    L10n.tr(
                        "当前语言（\(store.effectiveLanguage.speechLocaleIdentifier)）不支持本机识别，语音将使用苹果服务器。",
                        "This language (\(store.effectiveLanguage.speechLocaleIdentifier)) can't be recognized on-device; Apple's servers will be used."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(isShowingHabits
                       ? L10n.tr("收起已学习的习惯", "Hide learned habits")
                       : L10n.tr("查看已学习的习惯（\(habitCount) 条）", "View learned habits (\(habitCount))")) {
                    isShowingHabits.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .disabled(habitCount == 0)
                Spacer()
                if habitCount > 0 {
                    Button(L10n.tr("清空记忆", "Clear Memory")) {
                        store.userHabitMemory = UserHabitMemory()
                        habitRevision &+= 1
                        store.showToast(L10n.tr("已清空个人习惯记忆", "Cleared personal habit memory"))
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }

            if isShowingHabits {
                ForEach(habitItems) { item in
                    HStack(spacing: 6) {
                        Text(item.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button {
                            var memory = store.userHabitMemory
                            memory.forget(itemId: item.id)
                            store.userHabitMemory = memory
                            habitRevision &+= 1
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("忘掉这一条", "Forget this habit"))
                    }
                }
            }

            let consented = store.consentedCloudEndpoints
            if !consented.isEmpty {
                HStack(spacing: 6) {
                    Text(L10n.tr("已允许发送到：\(consented.joined(separator: "、"))", "Allowed to send to: \(consented.joined(separator: ", "))"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button(L10n.tr("撤销授权", "Revoke")) {
                        store.revokeCloudConsent()
                        storageRevision &+= 1
                        store.showToast(L10n.tr("已撤销，下次发往云端前会再问你", "Revoked; you will be asked before the next cloud request"))
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }

            Text(L10n.tr(
                "发给 AI 的内容：你说的那句话、设备名称/房间/当前状态、时间段、室温\(store.isHabitLearningEnabled ? "、习惯摘要" : "")。只有本机解析不了的指令才会发送。API Key 和米家登录信息只存在本机钥匙串，不会发送。",
                "Sent to AI only when local parsing cannot resolve: your command text, device names/rooms/states, time slot, room temperature\(store.isHabitLearningEnabled ? ", and habit summary" : ""). API keys and Xiaomi credentials stay in your local Keychain."
            ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Keys from CodexBar or environment variables are only read and copied when the user clicks (#20).
    @ViewBuilder
    private func keyImportRow(importedSource: String?) -> some View {
        let target = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? selectedPreset.defaultBaseURL
            : baseURLDraft
        HStack(spacing: 6) {
            if let importedSource {
                Text(L10n.tr("来源：\(importedSource)（已复制到本机钥匙串）", "Source: \(importedSource) (copied to Keychain)"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button(L10n.tr("撤销导入", "Remove")) {
                    AssistantConfig.removeStoredAPIKey(forBaseURL: target)
                    apiKeyDraft = ""
                    storageRevision &+= 1
                    store.showToast(L10n.tr("已删除导入的 Key", "Removed the imported key"))
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            } else {
                Button(L10n.tr("从 CodexBar / 环境变量导入 Key", "Import key from CodexBar / environment")) {
                    if let label = AssistantConfig.importAmbientAPIKey(forBaseURL: target) {
                        apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: target)
                        storageRevision &+= 1
                        store.showToast(L10n.tr("已从 \(label) 导入 \(selectedPreset.shortTitle) 的 Key", "Imported the \(selectedPreset.shortTitle) key from \(label)"))
                    } else {
                        store.showToast(
                            L10n.tr("CodexBar 和环境变量里都没有 \(selectedPreset.shortTitle) 的 Key", "No \(selectedPreset.shortTitle) key in CodexBar or environment variables"),
                            isError: true
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .help(L10n.tr("点了才会读取 ~/.config/codexbar/config.json 和环境变量", "Reads ~/.config/codexbar/config.json and environment variables only when clicked"))
            }
            Spacer(minLength: 0)
        }
    }

    private func labeledField<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            field()
                .controlSize(.small)
                .font(.system(size: 11.5, design: .monospaced))
        }
    }
}
