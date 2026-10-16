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

    public init() {}

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
        if isListening {
            isHoldToTalk = true
            silenceTimerTask?.cancel()
            silenceTimerTask = nil
            return
        }
        Task { await start(holdMode: true, store: store) }
    }

    public func finishHoldToTalk(store: HomeStore) {
        guard isHoldToTalk || isListening else { return }
        holdReleaseTask?.cancel()
        recognitionRequest?.endAudio()
        holdReleaseTask = Task { @MainActor [weak self] in
            // Allow 320ms after mouse release for SFSpeechRecognizer to flush the final syllable.
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            if self.isListening {
                let hasText = self.hasCapturedSpeech || !self.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                self.stop(andSubmit: hasText, store: store)
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
            errorMessage = "语音识别仅在打包后的 App 中可用"
            return
        }
        isStarting = true
        defer { isStarting = false }

        let authStartTime = ContinuousClock.now
        errorMessage = nil
        hasCapturedSpeech = false
        isHoldToTalk = holdMode
        if holdMode {
            draft = ""
        }

        let micAllowed = await SpeechRuntimeBridge.requestMicrophoneAccess()
        guard micAllowed else {
            isHoldToTalk = false
            errorMessage = "请在「系统设置 → 隐私与安全性 → 麦克风」中允许米家控制中心"
            return
        }

        let speechStatus = await SpeechRuntimeBridge.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            isHoldToTalk = false
            errorMessage = "请在「系统设置 → 隐私与安全性 → 语音识别」中允许米家控制中心"
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            isHoldToTalk = false
            errorMessage = "当前系统语音识别服务暂不可用"
            return
        }

        // If a system permission prompt appeared during Hold-to-Talk and the user already released the mouse,
        // seamlessly switch to hands-free silence auto-submit so they can speak right away.
        let authElapsed = ContinuousClock.now - authStartTime
        if isHoldToTalk && (NSEvent.pressedMouseButtons & 1) == 0 {
            if authElapsed > .milliseconds(450) {
                isHoldToTalk = false
                holdReleaseTask?.cancel()
                holdReleaseTask = nil
            } else {
                isHoldToTalk = false
                return
            }
        }

        stop(andSubmit: false, store: store)
        isHoldToTalk = holdMode && ((NSEvent.pressedMouseButtons & 1) != 0)

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            isHoldToTalk = false
            errorMessage = "未检测到可用麦克风输入设备"
            return
        }

        SpeechRuntimeBridge.installAudioTap(on: inputNode, format: format, request: request)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            isHoldToTalk = false
            errorMessage = "麦克风启动失败：\(error.localizedDescription)"
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
    @FocusState private var isFieldFocused: Bool

    var body: some View {
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
            .glassEffect(.regular.interactive(), in: shape)
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
                    Image(systemName: reply.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(reply.isError ? Color.red : Color.green)
                    Text(reply.text)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .help("长按顶部菜单栏温度图标可按住说话；或点击麦克风说话，打字回车执行")
        .animation(AppleMotion.snappySpring, value: store.assistantState)
        .animation(AppleMotion.snappySpring, value: speech.isListening)
        .onAppear {
            if store.assistantVoiceRequest != lastHandledVoiceRequest {
                lastHandledVoiceRequest = store.assistantVoiceRequest
                Task { await speech.start(holdMode: false, store: store) }
            } else if !speech.isListening {
                isFieldFocused = true
            }
        }
        .onChange(of: store.assistantFocusRequest) { _, _ in
            if !speech.isListening {
                isFieldFocused = true
            }
        }
        .onChange(of: store.assistantVoiceRequest) { _, newValue in
            lastHandledVoiceRequest = newValue
            speech.toggle(store: store)
        }
    }

    private var placeholderText: String {
        if speech.isHoldToTalk {
            return "按住菜单栏说话，松开立即执行（如：书房灯月光模式）"
        }
        if speech.isListening {
            return "正在聆听…说完自动执行（如：书房灯月光模式）"
        }
        return "例如：书房灯月光模式（支持按住菜单栏说话或打字）"
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
        .help(speech.isListening ? "停止聆听并执行" : "语音输入（快捷键 V，或长按菜单栏图标）")
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
            .help("关闭 (Esc)")
        }
    }

    private var replyLine: (text: String, isError: Bool)? {
        if let speechError = speech.errorMessage {
            return (speechError, true)
        }
        switch store.assistantState {
        case .done(let text): return (text.isEmpty ? "已执行" : text, false)
        case .failed(let message): return (message, true)
        case .idle, .thinking: return nil
        }
    }
}

// MARK: - Settings: AI 指令

struct AssistantSettingsSection: View {
    let store: HomeStore

    @State private var baseURLDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var apiKeyDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("AI 指令 (Jev System One)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(AssistantConfig.loadCodexBarOpenRouterKey() != nil ? "已自动接入 CodexBar OpenRouter" : "常规指令 0ms，复杂指令走 Jev")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            labeledField("服务地址 (默认 OpenRouter /v1，支持 System One 决策协议)") {
                TextField(AssistantConfig.defaultBaseURL, text: $baseURLDraft)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("模型 (默认 ~typesafe/jev-latest，也支持 glm-5.1 / qwen)") {
                TextField(AssistantConfig.defaultModel, text: $modelDraft)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("API Key (留空将自动读取 CodexBar 的 OpenRouter Key)") {
                SecureField("留空自动读取 CodexBar，或手动输入存入钥匙串", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("恢复 Jev 默认") {
                    baseURLDraft = AssistantConfig.defaultBaseURL
                    modelDraft = AssistantConfig.defaultModel
                }
                .buttonStyle(PillActionButtonStyle())

                Spacer()

                Button("保存 AI 配置") {
                    store.assistantConfig = AssistantConfig(
                        baseURL: baseURLDraft,
                        model: modelDraft,
                        apiKey: apiKeyDraft
                    )
                    store.showToast("已保存 AI 指令配置")
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
            apiKeyDraft = config.apiKey
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
