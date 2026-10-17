import Foundation
import Testing
@testable import MijiaCore

/// 方案 v1 第 2 步：定时/延时（"10 分钟后关灯"、"取消定时"）。
struct AssistantScheduleTests {
    @Test("DelayPhrase pulls a spoken delay off the front or back of the command")
    func extractsDelays() {
        func check(_ text: String, _ seconds: TimeInterval, _ rest: String) {
            let got = DelayPhrase.extract(text)
            #expect(got?.delay == seconds, "\(text)")
            #expect(got?.remainder == rest, "\(text)")
        }
        check("10分钟后关灯", 600, "关灯")
        check("半小时后打开空调", 1800, "打开空调")
        check("过两分钟关掉书房灯", 120, "关掉书房灯")
        check("一个半小时后关空调", 5400, "关空调")
        check("二十分钟以后关灯", 1200, "关灯")
        check("关灯，30秒后", 30, "关灯")
        check("1小时后把空调调到26度", 3600, "把空调调到26度")
        #expect(DelayPhrase.extract("打开空调") == nil)
        #expect(DelayPhrase.extract("把空调调到26度") == nil)
        #expect(DelayPhrase.extract("10分钟后") == nil)
    }

    @Test("Spoken delays read back naturally")
    func describesDelays() {
        #expect(DelayPhrase.describe(30) == "30 秒后")
        #expect(DelayPhrase.describe(600) == "10 分钟后")
        #expect(DelayPhrase.describe(5400) == "1 小时 30 分钟后")
        #expect(DelayPhrase.isCancel("取消定时"))
        #expect(DelayPhrase.isCancel("把定时都取消了"))
        #expect(!DelayPhrase.isCancel("打开空调"))
    }

    static let ceiling = SmartDevice(
        id: "dev_study_ceiling", name: "书房吸顶灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study_ceiling", isOn: true))
    )

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.schedule.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.assistantSleep = { _ in try await Task.sleep(for: .milliseconds(80)) }
        return (store, mock)
    }

    @Test("A delayed command waits, then runs through the normal execution path")
    @MainActor
    func delayedCommandRunsLater() async throws {
        let (store, mock) = try await makeStore()
        let plan = try #require(await store.runAssistantCommand("10分钟后关闭书房吸顶灯"))
        #expect(plan.reply == "好的，10 分钟后关闭书房吸顶灯")
        #expect(store.assistantState == .done("好的，10 分钟后关闭书房吸顶灯"))
        #expect(store.scheduledCommands.map(\.reply) == ["10 分钟后关闭书房吸顶灯"])
        #expect(await mock.executedCommands.isEmpty)

        for _ in 0..<50 where store.scheduledCommands.isEmpty == false {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.scheduledCommands.isEmpty)
        #expect(await mock.executedCommands == [.setLightPower(entityId: "light.study_ceiling", isOn: false)])
    }

    @Test("取消定时 cancels pending commands so they never run")
    @MainActor
    func cancelStopsPending() async throws {
        let (store, mock) = try await makeStore()
        _ = await store.runAssistantCommand("10分钟后关闭书房吸顶灯")
        #expect(store.scheduledCommands.count == 1)
        _ = await store.runAssistantCommand("取消定时")
        #expect(store.assistantState == .done("已取消 1 个定时"))
        #expect(store.scheduledCommands.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await mock.executedCommands.isEmpty)

        _ = await store.runAssistantCommand("取消定时")
        #expect(store.assistantState == .failed("现在没有定时任务"))
    }
}
