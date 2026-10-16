import SwiftUI
import AVFoundation
import Speech
import MijiaCore

// MARK: - Live Speech Recognizer (macOS Speech + AVAudioEngine)

@Observable
@MainActor
final class SpeechInputController {
    private(set) var isListening: Bool = false
    private(set) var errorMessage: String?

    var onTranscript: ((String) -> Void)?
    var onAutoSubmit: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimerTask: Task<Void, Never>?
    private var hasCapturedSpeech: Bool = false

    func toggle() {
        if isListening {
            stop(andSubmit: hasCapturedSpeech)
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isListening else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            errorMessage = "语音识别仅在打包后的 App 中可用"
            return
        }
        errorMessage = nil
        hasCapturedSpeech = false

        let micAllowed = await Self.requestMicrophoneAccess()
        guard micAllowed else {
            errorMessage = "请在「系统设置 → 隐私与安全性 → 麦克风」中允许米家控制中心"
            return
        }

        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            errorMessage = "请在「系统设置 → 隐私与安全性 → 语音识别」中允许米家控制中心"
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            errorMessage = "当前系统语音识别服务暂不可用"
            return
        }

        stop(andSubmit: false)

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "未检测到可用麦克风输入设备"
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            errorMessage = "麦克风启动失败：\(error.localizedDescription)"
            return
        }

        self.audioEngine = engine
        self.recognitionRequest = request
        self.isListening = true

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = (error != nil)
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let transcript {
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.hasCapturedSpeech = true
                        self.onTranscript?(trimmed)
                        self.scheduleSilenceAutoSubmit()
                    }
                }
                if isFinal || hasError {
                    self.stop(andSubmit: self.hasCapturedSpeech)
                }
            }
        }
    }

    func stop(andSubmit: Bool) {
        silenceTimerTask?.cancel()
        silenceTimerTask = nil

        let shouldSubmit = andSubmit && hasCapturedSpeech
        hasCapturedSpeech = false
        isListening = false

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        if shouldSubmit {
            onAutoSubmit?()
        }
    }

    private func scheduleSilenceAutoSubmit() {
        silenceTimerTask?.cancel()
        // Wait 1.1s after the last recognized syllable before auto-submitting the command.
        silenceTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let self, self.isListening, self.hasCapturedSpeech else { return }
            self.stop(andSubmit: true)
        }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

// MARK: - AI Command Bar (top of the main dashboard)

struct AssistantCommandBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: HomeStore

    @State private var draft: String = ""
    @State private var speech = SpeechInputController()
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
                    speech.isListening ? "正在聆听…说完自动执行（如：书房灯月光模式）" : "例如：书房灯月光模式（支持语音或打字）",
                    text: $draft
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .focused($isFieldFocused)
                .onSubmit {
                    if speech.isListening {
                        speech.stop(andSubmit: false)
                    }
                    submit()
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
        .help("点击麦克风直接说话（说完停顿 1 秒自动执行），或打字回车执行；Esc 关闭")
        .animation(AppleMotion.snappySpring, value: store.assistantState)
        .animation(AppleMotion.snappySpring, value: speech.isListening)
        .onAppear {
            speech.onTranscript = { text in
                draft = text
            }
            speech.onAutoSubmit = {
                submit()
            }
            if store.assistantVoiceRequest != lastHandledVoiceRequest {
                lastHandledVoiceRequest = store.assistantVoiceRequest
                Task { await speech.start() }
            } else {
                isFieldFocused = true
            }
        }
        .onDisappear {
            speech.stop(andSubmit: false)
        }
        .onChange(of: store.assistantFocusRequest) { _, _ in
            isFieldFocused = true
        }
        .onChange(of: store.assistantVoiceRequest) { _, newValue in
            lastHandledVoiceRequest = newValue
            speech.toggle()
        }
    }

    private var micButton: some View {
        Button {
            speech.toggle()
        } label: {
            Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(speech.isListening ? Color.red : Color.accentColor)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(speech.isListening ? "停止聆听并执行" : "语音输入（快捷键 V）")
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
                speech.stop(andSubmit: false)
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

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, store.assistantState != .thinking else { return }
        Task {
            await store.runAssistantCommand(text)
            if case .done = store.assistantState {
                draft = ""
            }
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
                Text("AI 指令")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("常规指令本地 0ms，复杂指令走 Chat 或 System One")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            labeledField("服务地址 (Magpie / OpenAI 兼容 /v1)") {
                TextField(AssistantConfig.defaultBaseURL, text: $baseURLDraft)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("模型 (支持 glm-5.1、qwen3.8-flash 或 System One 决策模型 jev-latest)") {
                TextField(AssistantConfig.defaultModel, text: $modelDraft)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("API Key (本地路由可留空，存入钥匙串)") {
                SecureField("可留空", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("恢复默认") {
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
