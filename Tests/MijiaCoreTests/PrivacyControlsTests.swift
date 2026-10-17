import Foundation
import Testing
@testable import MijiaCore

/// 方案 v1 第 4 步：习惯记忆可查看、可单条删除、可关闭；关闭后不学习也不发给 AI。
struct PrivacyControlsTests {
    static let ceiling = AssistantScheduleTests.ceiling

    @Test("Learned habits list as readable items that can be forgotten one by one")
    func readableItemsAndForget() {
        var memory = UserHabitMemory()
        memory.record(
            utterance: "老规矩",
            intents: [DeviceIntent(targetId: Self.ceiling.id, operation: .power(false))],
            devices: [Self.ceiling], scenes: [],
            now: Date(timeIntervalSince1970: 0)
        )
        let items = memory.readableItems(devices: [Self.ceiling], scenes: [])
        #expect(items.count == 2)
        #expect(items.contains { $0.text.contains("关闭书房吸顶灯") && $0.text.contains("1 次") })
        #expect(items.contains { $0.text.hasPrefix("口头禅「老规矩」") })

        for item in items { memory.forget(itemId: item.id) }
        #expect(memory.entries.isEmpty)
        #expect(memory.phrases.isEmpty)
    }

    @Test("Turning habit learning off stops recording and keeps habits out of the AI prompt")
    @MainActor
    func learningSwitch() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.privacy.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.isHabitLearningEnabled)
        _ = await store.runAssistantCommand("关闭书房吸顶灯")
        #expect(store.userHabitMemory.entries.count == 1)
        #expect(!store.buildAssistantContext().habitSummary.isEmpty)

        store.isHabitLearningEnabled = false
        _ = await store.runAssistantCommand("打开书房吸顶灯")
        #expect(store.userHabitMemory.entries.count == 1)
        #expect(store.buildAssistantContext().habitSummary.isEmpty)
    }

    @Test("Privacy preferences persist across launches")
    @MainActor
    func persisted() async throws {
        let suite = "test.privacy.persist.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: []))
        let first = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(first.prefersOnDeviceSpeech == false)
        first.isHabitLearningEnabled = false
        first.prefersOnDeviceSpeech = true
        let second = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(second.isHabitLearningEnabled == false)
        #expect(second.prefersOnDeviceSpeech == true)
    }
}
