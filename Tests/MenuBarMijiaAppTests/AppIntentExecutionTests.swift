import Foundation
import Testing
import MijiaCore
@testable import MenuBarMijiaApp

@MainActor
struct AppIntentExecutionTests {
    private static let lamp = SmartDevice(
        id: "test-lamp", name: "Test lamp", roomId: "study", roomName: "Study",
        model: "test.light", isOnline: true,
        kind: .light(LightSpec(entityId: "light.test", isOn: false))
    )
    private static let scene = HomeScene(id: "test-scene", name: "Test scene", entityId: "scene.test")

    @Test("External actions wait for the first snapshot, including an empty home")
    func firstSnapshot() async throws {
        let suite = "test.intent.snapshot.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let provider = ControlledIntentProvider()
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        var returned = false
        let waiting = Task {
            try await store.waitForInitialSnapshot()
            returned = true
        }
        await Task.yield()
        #expect(!returned)
        await provider.sendSnapshot(SynthesizedHome())
        try await waiting.value
        #expect(returned)
        #expect(store.devices.isEmpty)
        #expect(store.hasReceivedInitialSnapshot)
    }

    @Test("Missing initial data times out instead of looking like an empty home")
    func snapshotTimeout() async throws {
        let suite = "test.intent.timeout.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: ControlledIntentProvider(), defaultsSuiteName: suite)
        await #expect(throws: HomeProviderError.self) {
            try await store.waitForInitialSnapshot(timeout: .milliseconds(10))
        }
    }

    @Test("Device intent waits for provider rejection and reports rollback")
    func rejectedToggle() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.toggle.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider()
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            let intent = ToggleDeviceIntent()
            intent.device = DeviceEntity(device: Self.lamp)
            var returned = false
            let invocation = Task {
                let message = try await intent.execute(in: store)
                returned = true
                return message
            }
            await Task.yield()
            #expect(!returned)
            await provider.sendSnapshot(SynthesizedHome(devices: [Self.lamp]))
            for _ in 0..<100 where await provider.commandCount == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await provider.commandCount == 1)
            #expect(store.devices.first?.isActiveOn == true)
            #expect(!returned)
            await provider.complete(failing: true)
            let message = try await invocation.value
            #expect(message == "Test lamp failed to respond; rolled back")
            #expect(store.devices.first?.isActiveOn == false)
        }
    }

    @Test("Scene intent reports provider failure and only reports success after acknowledgment")
    func sceneResult() async throws {
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.scene.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider()
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            await provider.sendSnapshot(SynthesizedHome(scenes: [Self.scene]))
            let intent = RunSceneIntent()
            intent.scene = SceneEntity(scene: Self.scene)
            let failed = Task { try await intent.execute(in: store) }
            for _ in 0..<100 where await provider.commandCount == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await provider.commandCount == 1)
            await provider.complete(failing: true)
            #expect(try await failed.value == "Scene \"Test scene\" failed")
            let succeeded = Task { try await intent.execute(in: store) }
            for _ in 0..<100 where await provider.commandCount == 1 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await provider.commandCount == 2)
            await provider.complete(failing: false)
            #expect(try await succeeded.value == "Activated scene: Test scene")
        }
    }

    @Test("Momentary button device intent reports Triggered instead of Turned off (#100)")
    func momentaryButtonIntentResult() async throws {
        let wolDevice = SmartDevice(
            id: "wol_pc", name: "Study PC", roomId: "study", roomName: "Study",
            model: "Wake on LAN", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "button.wake_on_lan_pc", isOn: false))
        )
        try await L10n.$overrideLanguage.withValue(.en) {
            let suite = "test.intent.wol.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let provider = ControlledIntentProvider()
            let store = HomeStore(provider: provider, defaultsSuiteName: suite)
            await provider.sendSnapshot(SynthesizedHome(devices: [wolDevice]))
            let intent = ToggleDeviceIntent()
            intent.device = DeviceEntity(device: wolDevice)
            let succeeded = Task { try await intent.execute(in: store) }
            for _ in 0..<100 where await provider.commandCount == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await provider.commandCount == 1)
            await provider.complete(failing: false)
            #expect(try await succeeded.value == "Triggered Study PC")
        }
    }
}

private actor ControlledIntentProvider: HomeProvider {
    nonisolated let stream: AsyncStream<HomeProviderEvent>
    private let continuation: AsyncStream<HomeProviderEvent>.Continuation
    private var pending: CheckedContinuation<Void, any Error>?
    private(set) var commandCount = 0

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    nonisolated func events() -> AsyncStream<HomeProviderEvent> { stream }
    func refreshNow() async {}

    func sendSnapshot(_ home: SynthesizedHome) {
        continuation.yield(.snapshotUpdated(home))
    }

    func execute(_ command: DeviceCommand) async throws {
        commandCount += 1
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func complete(failing: Bool) {
        if failing {
            pending?.resume(throwing: HomeProviderError.networkError("Test rejection"))
        } else {
            pending?.resume()
        }
        pending = nil
    }
}
