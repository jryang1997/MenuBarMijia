import Foundation
import Testing
import Observation
@testable import MijiaCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UndoScopeTests {
    private func light(_ id: String, room: String = "a") -> SmartDevice {
        SmartDevice(id: id, name: id, roomId: room, roomName: room, model: "test.light", isOnline: true,
                    kind: .light(LightSpec(entityId: "light.\(id)", isOn: true, brightnessPercent: 80)))
    }

    private func makeStore() async throws -> (HomeStore, GatedUndoProvider, String) {
        let provider = GatedUndoProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "a", name: "a", sortOrder: 0), RoomArea(id: "b", name: "b", sortOrder: 1)],
            devices: [light("a"), light("b", room: "b")]
        ))
        let suite = "test.undo.scope.\(UUID().uuidString)"
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await store.waitForInitialSnapshot()
        #expect(store.devices.count == 2)
        return (store, provider, suite)
    }

    private func waitForDevices(_ store: HomeStore, matching condition: ([SmartDevice]) -> Bool) async {
        while !condition(store.devices) {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = store.devices
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    @Test("Banner undo preserves later changes to other devices")
    func unrelatedDeviceKeepsItsLaterState() async throws {
        let (store, provider, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        store.selectedRoomId = "a"
        store.turnAllOff()
        let other = try #require(store.devices.first { $0.id == "b" })
        let task = try #require(store.togglePrimary(other))
        _ = await task.value
        store.undoTurnAllOff()
        await provider.waitForCommands(3)
        #expect(store.devices.first { $0.id == "a" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "b" }?.isActiveOn == false)
        #expect(!(await provider.commands).contains(.setLightPower(entityId: "light.b", isOn: true)))
    }

    @Test("Undo keeps the current device membership and does not send to a removed target")
    func currentMembershipSurvivesUndo() async throws {
        let (store, provider, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        store.turnAllOff()
        await provider.waitForCommands(2)
        await provider.replace(SynthesizedHome(devices: [light("a"), light("c")]))
        await waitForDevices(store) { $0.map(\.id) == ["a", "c"] }
        store.undoTurnAllOff()
        await provider.waitForCommands(3)
        #expect(store.devices.map(\.id) == ["a", "c"])
        #expect((await provider.commands).filter { $0 == .setLightPower(entityId: "light.b", isOn: true) }.isEmpty)
    }

    @Test("Power undo preserves a later brightness change on the same device")
    func otherFieldsSurviveVoiceUndo() async throws {
        let (store, _, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        _ = await store.runAssistantCommand("关闭a")
        store.setLightBrightness("a", percent: 33)
        _ = await store.runAssistantCommand("撤销")
        let device = try #require(store.devices.first { $0.id == "a" })
        guard case .light(let spec) = device.kind else { Issue.record("Expected a light"); return }
        #expect(spec.isOn)
        #expect(spec.brightnessPercent == 33)
    }

    @Test("Connection context changes discard both undo entry points")
    func contextChangesDiscardUndo() async throws {
        for change in 0..<5 {
            let (store, _, suite) = try await makeStore()
            defer { store.userDefaults.removePersistentDomain(forName: suite) }
            _ = await store.runAssistantCommand("关闭所有灯")
            #expect(store.undoBanner != nil)
            #expect(store.lastAssistantActionAt != nil)
            switch change {
            case 0: store.switchBackend(.demo)
            case 1: store.selectMiHome("test-other-home")
            case 2:
                store.applyDiscoveredHAInstance(HADiscoveredInstance(baseURL: "http://127.0.0.1:1"), reconnectProvider: false)
            case 3:
                store.homeBackend = .xiaomiCloud
                store.logoutMiAccount()
            default:
                store.updateLGWebOSConfig(LGWebOSConfig(host: "127.0.0.1"))
            }
            #expect(store.undoBanner == nil)
            #expect(store.lastAssistantActionAt == nil)
        }
    }

    @Test("Selecting a home in a private store leaves production preferences alone")
    func homeSelectionUsesItsOwnPreferences() async throws {
        let (store, _, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        let previous = UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey)
        store.selectMiHome("test-home")
        #expect(store.userDefaults.string(forKey: MiCloudProvider.selectedHomeKey) == "test-home")
        #expect(UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey) == previous)
        store.selectMiHome(nil)
        #expect(store.userDefaults.string(forKey: MiCloudProvider.selectedHomeKey) == nil)
        #expect(UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey) == previous)
    }

    @Test("A queued bulk action cannot dispatch into a replacement backend")
    func queuedBulkActionCannotEnterNewBackend() async throws {
        let (store, _, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        store.turnAllOff()
        store.switchBackend(.demo)
        let next = try #require(store.provider as? DemoHomeProvider)
        try await Task.sleep(for: .milliseconds(30))
        #expect((await next.executedCommands).isEmpty)
    }

    @Test("A failed old assistant request cannot roll back a new home with the same device id")
    func failedOldRequestCannotRollBackNewHome() async throws {
        let (store, provider, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        await provider.pauseNext()
        let request = Task { await store.runAssistantCommand("关闭a") }
        await provider.waitUntilPaused()
        store.selectMiHome("test-new-home")
        var incoming = light("a")
        incoming.name = "new home device"
        await provider.replace(SynthesizedHome(devices: [incoming]))
        await waitForDevices(store) { $0.first?.name == "new home device" }
        await provider.release(failing: true)
        _ = await request.value
        #expect(store.devices.first?.name == "new home device")
        #expect(store.undoBanner == nil)
        #expect(store.lastAssistantActionAt == nil)
    }

    @Test("An in-flight undo cannot send remaining commands into a new backend")
    func inFlightUndoStaysInItsContext() async throws {
        let (store, provider, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        store.turnAllOff()
        await provider.waitForCommands(2)
        await provider.pauseNext()
        store.undoTurnAllOff()
        await provider.waitUntilPaused()
        store.switchBackend(.demo)
        let next = try #require(store.provider as? DemoHomeProvider)
        await provider.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect((await next.executedCommands).isEmpty)
        #expect((await provider.commands).count == 3)
    }

    @Test("An old assistant completion cannot recreate undo in a new backend")
    func oldAssistantCompletionCannotRestoreUndo() async throws {
        let (store, provider, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        await provider.pauseNext()
        let request = Task { await store.runAssistantCommand("关闭所有灯") }
        await provider.waitUntilPaused()
        #expect(store.assistantState == .thinking)
        store.switchBackend(.demo)
        #expect(store.assistantState == .idle)
        try await store.waitForInitialSnapshot()
        let newPlan = try #require(await store.runAssistantCommand("关闭所有灯"))
        let newState = store.assistantState
        let newUndoID = store.undoBanner?.id
        let newActionAt = store.lastAssistantActionAt
        #expect(newState == .done(newPlan.reply))
        await provider.release()
        _ = await request.value
        #expect(store.assistantState == newState)
        #expect(store.undoBanner?.id == newUndoID)
        #expect(store.lastAssistantActionAt == newActionAt)
    }

    @Test("A model response resolved for the previous home cannot control the selected home")
    func oldModelResponseCannotRunInANewHome() async throws {
        let (store, provider, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(model: "test-model"), transport: { request in
            await provider.suspendResponse()
            let content = #"{"actions":[{"device":"d1","op":"power","value":false}],"reply":"done"}"#
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let request = Task { await store.runAssistantCommand("please prepare this home for a break") }
        await provider.waitUntilPaused()
        #expect(store.assistantState == .thinking)
        store.pendingCloudConsent = PendingCloudConsent(utterance: "打开a", endpoint: "example.invalid", providerTitle: "test")
        store.assistantSuggestions = [AssistantSuggestion(
            id: "old-home", title: "old action", confidencePercent: 99,
            intents: [DeviceIntent(targetId: "a", operation: .power(false))]
        )]
        store.selectMiHome("test-new-home")
        #expect(store.assistantState == .idle)
        #expect(store.pendingCloudConsent == nil)
        #expect(store.assistantSuggestions.isEmpty)
        let newPlan = try #require(await store.runAssistantCommand("打开a"))
        let newState = store.assistantState
        let newActionAt = store.lastAssistantActionAt
        #expect(newState == .done(newPlan.reply))
        await provider.release()
        _ = await request.value
        #expect(await provider.commands == [.setLightPower(entityId: "light.a", isOn: true)])
        #expect(store.assistantState == newState)
        #expect(store.lastAssistantActionAt == newActionAt)
    }
}

private actor GatedUndoProvider: HomeProvider {
    private nonisolated let stream: AsyncStream<HomeProviderEvent>
    private let continuation: AsyncStream<HomeProviderEvent>.Continuation
    private var shouldPause = false
    private var gate: CheckedContinuation<Void, Never>?
    private var failReleasedCommand = false
    private(set) var commands: [DeviceCommand] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var commandWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(snapshot: SynthesizedHome) {
        let pair = AsyncStream<HomeProviderEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        continuation.yield(.snapshotUpdated(snapshot))
    }
    nonisolated func events() -> AsyncStream<HomeProviderEvent> { stream }
    func waitForCommands(_ count: Int) async {
        guard commands.count < count else { return }
        await withCheckedContinuation { commandWaiters.append((count, $0)) }
    }
    func waitUntilPaused() async {
        guard gate == nil else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }
    private func suspend() async {
        await withCheckedContinuation { continuation in
            gate = continuation
            for waiter in pauseWaiters { waiter.resume() }
            pauseWaiters.removeAll()
        }
    }
    func execute(_ command: DeviceCommand) async throws {
        commands.append(command)
        let ready = commandWaiters.filter { $0.count <= commands.count }
        commandWaiters.removeAll { $0.count <= commands.count }
        for waiter in ready { waiter.continuation.resume() }
        if shouldPause {
            shouldPause = false
            await suspend()
            if failReleasedCommand {
                throw HomeProviderError.serviceCallFailed(500, "test failure")
            }
        }
    }
    func pauseNext() { shouldPause = true }
    func suspendResponse() async { await suspend() }
    func release(failing: Bool = false) {
        failReleasedCommand = failing
        gate?.resume()
        gate = nil
    }
    func replace(_ snapshot: SynthesizedHome) { continuation.yield(.snapshotUpdated(snapshot)) }
    func refreshNow() async {}
}
