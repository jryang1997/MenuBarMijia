import Foundation
import Observation
import Testing
@testable import MijiaCore

@Suite("Provider snapshot observation")
struct SnapshotObservationTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private struct Provider: HomeProvider {
        let stream: AsyncStream<HomeProviderEvent>
        let continuation: AsyncStream<HomeProviderEvent>.Continuation
        init() {
            (stream, continuation) = AsyncStream.makeStream()
        }
        func events() -> AsyncStream<HomeProviderEvent> { stream }
        func execute(_ command: DeviceCommand) async throws {}
        func refreshNow() async {}
    }

    @MainActor
    private func drain(_ provider: Provider, store: HomeStore, marker: String) async throws {
        let status = ConnectionStatus.disconnected(marker)
        provider.continuation.yield(.statusChanged(status))
        for _ in 0..<100 where store.connectionStatus != status {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(store.connectionStatus == status, "Snapshot stream did not reach the fence")
    }

    @Test("Identical snapshots do not invalidate displayed state, including aliases", arguments: [false, true])
    @MainActor
    func repeatedSnapshots(useAlias: Bool) async throws {
        let suite = "test.snapshot.observation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = Provider()
        defer { provider.continuation.finish() }
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        let light = SmartDevice(
            id: "study", name: "书房灯", roomId: "study", roomName: "书房",
            model: "test.light", isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: false))
        )
        var snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "study", name: "书房")], devices: [light],
            environmentReadings: [EnvironmentReading(id: "env", label: "书房", roomName: "书房", temperature: 25, humidity: 50)]
        )
        provider.continuation.yield(.snapshotUpdated(snapshot))
        try await drain(provider, store: store, marker: "initial")
        if useAlias { store.applyDeviceAliases(["study": "阅读灯"]) }

        let changes = Counter()
        withObservationTracking {
            _ = store.rooms
            _ = store.homes
            _ = store.devices
            _ = store.scenes
            _ = store.environmentReadings
            _ = store.hasReceivedInitialSnapshot
        } onChange: { changes.increment() }
        for _ in 0..<100 { provider.continuation.yield(.snapshotUpdated(snapshot)) }
        try await drain(provider, store: store, marker: "duplicates")
        #expect(changes.value == 0)
        #expect(store.devices.first?.name == (useAlias ? "阅读灯" : "书房灯"))
        #expect(store.originalDeviceName(for: "study") == "书房灯")
        #expect(store.favoriteDeviceIds.contains("study"))

        snapshot.devices[0].kind = .light(LightSpec(entityId: "light.study", isOn: true, brightnessPercent: 73))
        provider.continuation.yield(.snapshotUpdated(snapshot))
        try await drain(provider, store: store, marker: "changed")
        #expect(changes.value == 1)
        #expect(store.devices.first?.isActiveOn == true)
        #expect(store.devices.first?.name == (useAlias ? "阅读灯" : "书房灯"))
        if case .light(let spec) = store.devices.first?.kind {
            #expect(spec.brightnessPercent == 73)
        } else { Issue.record("Updated light missing") }
        store.applyDeviceAliases([:])
        #expect(store.devices.first?.name == "书房灯")
    }

    @Test("Duplicate connection status does not invalidate observation")
    @MainActor
    func repeatedStatus() async throws {
        let suite = "test.status.observation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = Provider()
        defer { provider.continuation.finish() }
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        try await drain(provider, store: store, marker: "same")
        let changes = Counter()
        withObservationTracking { _ = store.connectionStatus } onChange: { changes.increment() }
        provider.continuation.yield(.statusChanged(.disconnected("same")))
        provider.continuation.yield(.snapshotUpdated(SynthesizedHome()))
        for _ in 0..<100 where !store.hasReceivedInitialSnapshot {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(store.hasReceivedInitialSnapshot)
        #expect(changes.value == 0)
        provider.continuation.yield(.statusChanged(.connected))
        for _ in 0..<100 where store.connectionStatus != .connected {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.connectionStatus == .connected)
        #expect(changes.value == 1)
    }
}
