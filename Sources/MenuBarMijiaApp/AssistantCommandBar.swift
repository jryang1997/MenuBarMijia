import SwiftUI
import MijiaCore

// MARK: - AI Command Bar (top of the main dashboard)

struct AssistantCommandBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: HomeStore

    @State private var draft: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, isActive: store.assistantState == .thinking)

                TextField("例如：打开书房灯", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($isFieldFocused)
                    .onSubmit(submit)

                trailingAccessory
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular.interactive(), in: shape)
            .overlay(
                shape.strokeBorder(
                    Color.accentColor.opacity(isFieldFocused ? 0.55 : 0.18),
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
        .help("输入指令后回车执行，也可以用 macOS 听写直接说；Esc 关闭")
        .animation(AppleMotion.snappySpring, value: store.assistantState)
        .onAppear { isFieldFocused = true }
        .onChange(of: store.assistantFocusRequest) { _, _ in
            isFieldFocused = true
        }
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
                Text("简单指令本地秒回，复杂的交给模型")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            labeledField("服务地址 (OpenAI 兼容 /v1)") {
                TextField(AssistantConfig.defaultBaseURL, text: $baseURLDraft)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("模型") {
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
