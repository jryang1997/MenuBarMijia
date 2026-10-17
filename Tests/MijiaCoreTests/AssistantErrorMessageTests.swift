import Foundation
import Testing
@testable import MijiaCore

/// 方案 v1 第 1 步：看得懂的错误提示。
struct AssistantErrorMessageTests {
    @Test("Network and HTTP failures read as plain advice")
    func plainMessages() {
        #expect(AssistantError.userMessage(for: URLError(.timedOut)).hasPrefix("AI 服务 10 秒没回应"))
        #expect(AssistantError.userMessage(for: URLError(.notConnectedToInternet)).hasPrefix("连不上 AI 服务"))
        #expect(AssistantError.userMessage(for: URLError(.cannotConnectToHost)).hasPrefix("连不上 AI 服务"))
        #expect(AssistantError.userMessage(for: AssistantError.httpStatus(401)) == "AI 服务的 API Key 无效或已过期，请到设置里重新填写")
        #expect(AssistantError.userMessage(for: AssistantError.httpStatus(429)) == "AI 服务请求太频繁，稍等几秒再试")
        #expect(AssistantError.userMessage(for: AssistantError.httpStatus(503)) == "AI 服务暂时出错（503），稍后再试")
        #expect(AssistantError.userMessage(for: AssistantError.malformedResponse) == "AI 返回的内容看不懂，换个说法再试")
    }

    @Test("A failing model call surfaces the plain message in the command bar")
    @MainActor
    func storeShowsPlainMessage() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [AssistantScheduleTests.ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.err.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.assistantResolverOverride = ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://example.invalid/v1", model: "m", apiKey: "k"),
            transport: { _ in throw URLError(.timedOut) }
        )
        _ = await store.runAssistantCommand("我有点冷怎么办")
        guard case .failed(let message) = store.assistantState else {
            Issue.record("expected failure"); return
        }
        #expect(message.hasPrefix("AI 服务 10 秒没回应"))
    }
}
