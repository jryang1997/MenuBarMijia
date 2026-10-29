import Foundation
import os

/// `HomeProvider` that talks to Xiaomi cloud directly (no Home Assistant): discovers devices and
/// rooms, loads MIoT specs, polls properties and maps `DeviceCommand`s to MIoT writes.
public actor MiCloudProvider: HomeProvider {
    public typealias APIFactory = @Sendable (MiSession) -> any MiCloudAPI

    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "MiCloudProvider")
    private let sessionLoader: @Sendable () -> MiSession?
    private let apiFactory: APIFactory
    private let specSource: any MiotSpecSource
    /// Poll interval while the panel is open; see `PollingPolicy` for the rest (#26).
    private let pollInterval: Duration
    private let closedPollInterval: Duration
    private let deviceRefreshEveryPolls: Int
    private let followUpDelay: Duration
    private let selectedHomeLoader: @Sendable () -> String?

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var api: (any MiCloudAPI)?

    private var devices: [MiDeviceRecord] = []
    private var rooms: [MiRoom] = []
    private var specsByModel: [String: MiotDeviceSpec] = [:]
    private var values: [MiotPropKey: JSONValue] = [:]
    /// Lights whose `mode` write the cloud rejected as unsupported; their scene chips are hidden.
    private var effectsUnsupported: Set<String> = []

    private var pollingContext = PollingContext()
    private var lastFullPollAt: ContinuousClock.Instant?
    /// The loop's current wait; cancelling it makes the loop re-check `pollingContext` right away.
    private var waitTask: Task<Void, Never>?
    private var pollsSinceContextChange = 0
    /// Set on wake or unlock: poll once right away, however recent the last poll was.
    private var pollRequested = false

    public init(
        sessionLoader: @escaping @Sendable () -> MiSession? = { MiSessionStore.load() },
        apiFactory: @escaping APIFactory = { MiCloudClient(session: $0) },
        specSource: any MiotSpecSource = MiotSpecStore(),
        pollInterval: Duration = PollingPolicy.panelOpenInterval,
        closedPollInterval: Duration = PollingPolicy.panelClosedInterval,
        deviceRefreshEveryPolls: Int = 20,
        followUpDelay: Duration = .milliseconds(800),
        selectedHomeLoader: @escaping @Sendable () -> String? = { UserDefaults.standard.string(forKey: MiCloudProvider.selectedHomeKey) }
    ) {
        self.sessionLoader = sessionLoader
        self.apiFactory = apiFactory
        self.specSource = specSource
        self.pollInterval = pollInterval
        self.closedPollInterval = closedPollInterval
        self.deviceRefreshEveryPolls = max(1, deviceRefreshEveryPolls)
        self.followUpDelay = followUpDelay
        self.selectedHomeLoader = selectedHomeLoader
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        continuation = cont
        restartLoop()
    }

    /// Stops polling and finishes the event stream; used when the user switches backends.
    public func shutdown() {
        loopTask?.cancel()
        loopTask = nil
        continuation?.finish()
        continuation = nil
    }

    public func refreshNow() async {
        guard let api else {
            restartLoop()
            return
        }
        // After switching homes, devices of a home never polled would flash as off; wait for their values.
        if !devices.isEmpty, hasValuesForScope() {
            emitSnapshot()
        }
        do {
            try await discover(api)
            try await poll(api, dids: nil)
            continuation?.yield(.statusChanged(.connected))
        } catch {
            report(error)
        }
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = Task { await self.runLoop() }
    }

    private func runLoop() async {
        guard let session = sessionLoader() else {
            api = nil
            continuation?.yield(.statusChanged(.disconnected(MiCloudError.notLoggedIn.localizedDescription)))
            return
        }
        let api = apiFactory(session)
        self.api = api
        var backoff: Double = 2

        while !Task.isCancelled {
            continuation?.yield(.statusChanged(.connecting))
            do {
                try await discover(api)
                continuation?.yield(.statusChanged(.connected))
                backoff = 2
                var polls = 0
                while !Task.isCancelled {
                    try await poll(api, dids: nil)
                    try await waitForNextPoll()
                    polls += 1
                    if polls % deviceRefreshEveryPolls == 0 {
                        try await refreshDeviceList(api)
                    }
                }
            } catch is CancellationError {
                return
            } catch MiCloudError.sessionExpired {
                self.api = nil
                report(MiCloudError.sessionExpired)
                return
            } catch {
                if Task.isCancelled { return }
                report(error)
                // Xiaomi throttles busy clients; back off for minutes instead of seconds (#26).
                let throttled = (error as? MiCloudError) == .http(429)
                if throttled { backoff = max(backoff, 60) }
                try? await Task.sleep(for: .seconds(backoff))
                await waitWhilePaused()
                backoff = min(backoff * 2, throttled ? 900 : 60)
            }
        }
    }

    // MARK: Polling Rhythm (#26)

    /// Called by the app when the panel opens or closes, the Mac sleeps or wakes, the screen locks, or
    /// Low Power Mode changes. Opening the panel or waking up polls right away if the data is older
    /// than the new interval.
    /// Declared `async` so it wins over the protocol's no-op default in async callers.
    public func setPollingContext(_ context: PollingContext) async {
        guard context != pollingContext else { return }
        logger.info("Mi cloud polling: \(context.description, privacy: .public) (\(self.pollsSinceContextChange, privacy: .public) polls since last change)")
        if context.systemActive && !pollingContext.systemActive { pollRequested = true }
        pollingContext = context
        pollsSinceContextChange = 0
        waitTask?.cancel()
    }

    private var currentInterval: Duration? {
        PollingPolicy.interval(for: pollingContext, panelOpen: pollInterval, panelClosed: closedPollInterval)
    }

    /// Sleeps until the next poll is due. A context change wakes it to re-check, so the panel
    /// opening after a minute polls at once, and closing it stretches the wait.
    private func waitForNextPoll() async throws {
        while true {
            try Task.checkCancellation()
            guard let interval = currentInterval else {
                await sleepUntilWoken(for: nil)
                continue
            }
            if pollRequested { return }
            let remaining = (lastFullPollAt ?? .now).advanced(by: interval) - ContinuousClock.now
            guard remaining > .zero else { return }
            await sleepUntilWoken(for: remaining)
        }
    }

    private func waitWhilePaused() async {
        while !Task.isCancelled, currentInterval == nil {
            await sleepUntilWoken(for: nil)
        }
    }

    /// Sleeps for `duration` (an hour when nil), returning early on `setPollingContext` or cancellation.
    private func sleepUntilWoken(for duration: Duration?) async {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: duration ?? .seconds(3600)) }
        waitTask = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        waitTask = nil
    }

    private func report(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logger.error("Mi cloud error: \(message, privacy: .public)")
        continuation?.yield(.statusChanged(.disconnected(message)))
    }

    // MARK: Discovery & Polling

    private func discover(_ api: any MiCloudAPI) async throws {
        try await refreshDeviceList(api)
        do {
            rooms = try await api.homeRooms()
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            logger.notice("Room list unavailable, devices go to 全屋: \(error.localizedDescription, privacy: .public)")
        }
        logger.info("Mi cloud rooms: \(self.rooms.count, privacy: .public)")
    }

    private func refreshDeviceList(_ api: any MiCloudAPI) async throws {
        devices = try await api.deviceList()
        await loadMissingSpecs()

        var unsupported: Set<String> = []
        var supported = 0
        for d in devices {
            if let spec = specsByModel[d.model], MiotSynthesizer.supportedServiceName(for: spec) != nil {
                supported += 1
            } else {
                unsupported.insert(d.model)
            }
        }
        let online = devices.filter(\.isOnline).count
        logger.info("Mi cloud devices: \(self.devices.count, privacy: .public) total, \(online, privacy: .public) online, \(supported, privacy: .public) supported")
        if !unsupported.isEmpty {
            logger.notice("Unsupported models (skipped): \(unsupported.sorted().joined(separator: ", "), privacy: .public)")
        }
    }

    private struct SpecLoadOutcome: Sendable {
        let model: String
        let spec: MiotDeviceSpec?
        let errorDescription: String?
    }

    private func loadMissingSpecs() async {
        var pending: [String: String?] = [:]
        for d in devices where specsByModel[d.model] == nil {
            pending[d.model] = d.specType
        }
        guard !pending.isEmpty else { return }
        let source = specSource
        let loaded = await withTaskGroup(of: SpecLoadOutcome.self) { group in
            for (model, specType) in pending {
                group.addTask {
                    do {
                        let spec = try await source.spec(model: model, specType: specType)
                        return SpecLoadOutcome(model: model, spec: spec, errorDescription: nil)
                    } catch {
                        return SpecLoadOutcome(model: model, spec: nil, errorDescription: error.localizedDescription)
                    }
                }
            }
            var out: [SpecLoadOutcome] = []
            for await r in group { out.append(r) }
            return out
        }
        for outcome in loaded {
            if let spec = outcome.spec {
                specsByModel[outcome.model] = spec
            } else if let error = outcome.errorDescription {
                logger.error("Spec load failed for \(outcome.model, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Reads the selected home's devices only (all homes when none is selected) (#26).
    private func poll(_ api: any MiCloudAPI, dids: Set<String>?) async throws {
        let keys = propKeys(of: scopedDevicesAndRooms().devices, dids: dids)
        if !keys.isEmpty {
            let fresh = try await api.getProps(keys)
            values.merge(fresh) { _, new in new }
        }
        if dids == nil {
            lastFullPollAt = .now
            pollRequested = false
            pollsSinceContextChange += 1
        }
        emitSnapshot()
    }

    private func propKeys(of scoped: [MiDeviceRecord], dids: Set<String>?) -> [MiotPropKey] {
        var keys: [MiotPropKey] = []
        for d in scoped where d.isOnline && (dids?.contains(d.miotDid) ?? true) {
            guard let spec = specsByModel[d.model] else { continue }
            keys.append(contentsOf: MiotSynthesizer.requiredProps(for: d, spec: spec))
        }
        return keys
    }

    private func hasValuesForScope() -> Bool {
        propKeys(of: scopedDevicesAndRooms().devices, dids: nil).allSatisfy { values[$0] != nil }
    }

    /// The selected home's rooms and devices, plus parents of included split keys so their spec and
    /// values stay available. Everything when no (known) home is selected.
    private func scopedDevicesAndRooms() -> (devices: [MiDeviceRecord], rooms: [MiRoom]) {
        guard let selected = selectedHomeLoader(),
              Self.homeOptions(from: rooms).contains(where: { $0.id == selected }) else {
            return (devices, rooms)
        }
        let visibleRooms = rooms.filter { $0.homeId == selected }
        let dids = Set(visibleRooms.flatMap(\.dids))
        var visibleDevices = devices.filter { dids.contains($0.did) || ($0.splitParentDid.map(dids.contains) ?? false) }
        let parents = Set(visibleDevices.compactMap(\.splitParentDid))
        let includedIds = Set(visibleDevices.map(\.did))
        visibleDevices += devices.filter { parents.contains($0.did) && !includedIds.contains($0.did) }
        return (visibleDevices, visibleRooms)
    }

    /// UserDefaults key for the selected Mi Home id; absent or unknown means every home.
    public static let selectedHomeKey = "mi_selected_home_id"
    /// MIoT per-item code for "property not supported by this device".
    static let propertyUnsupportedCode = -704002000

    private func emitSnapshot() {
        let (visibleDevices, visibleRooms) = scopedDevicesAndRooms()
        var home = MiotSynthesizer.synthesize(devices: visibleDevices, rooms: visibleRooms, specs: specsByModel, values: values)
        home.homes = Self.homeOptions(from: rooms)
        // Light groups advertise `mode` but their members reject it; hide scenes there too.
        for i in home.devices.indices {
            guard case .light(var spec) = home.devices[i].kind,
                  home.devices[i].id.hasPrefix("group.") || effectsUnsupported.contains(home.devices[i].id) else { continue }
            spec.availableEffects = []
            home.devices[i].kind = .light(spec)
        }
        continuation?.yield(.snapshotUpdated(home))
    }

    static func homeOptions(from rooms: [MiRoom]) -> [HomeOption] {
        var order: [String] = []
        var names: [String: String] = [:]
        var didsByHome: [String: Set<String>] = [:]
        for room in rooms where !room.homeId.isEmpty {
            if names[room.homeId] == nil { order.append(room.homeId); names[room.homeId] = room.homeName }
            didsByHome[room.homeId, default: []].formUnion(room.dids)
        }
        return order.map { HomeOption(id: $0, name: names[$0] ?? "", deviceCount: didsByHome[$0]?.count ?? 0) }
    }

    // MARK: Commands

    public func execute(_ command: DeviceCommand) async throws {
        let entityId = command.targetEntityId
        guard let (did, _) = MiotAddress.parse(entityId) else { throw MiotCommandError.invalidAddress(entityId) }
        guard let api else { throw MiCloudError.notLoggedIn }
        guard let record = devices.first(where: { $0.did == did }) ?? devices.first(where: { $0.miotDid == did }),
              let spec = specsByModel[record.model] else {
            throw MiotCommandError.unsupported("设备规格未加载")
        }
        let write = try MiotCommandMapper.map(command, spec: spec)
        do {
            switch write {
            case .setProps(let writes): try await api.setProps(writes)
            case .action(let call): try await api.action(call)
            }
        } catch MiCloudError.sessionExpired {
            report(MiCloudError.sessionExpired)
            throw MiCloudError.sessionExpired
        } catch MiCloudError.api(let code, let message) {
            if case .setLightEffect = command, code == Self.propertyUnsupportedCode {
                effectsUnsupported.insert(record.did)
                emitSnapshot()
            }
            throw MiCloudError.api(code: code, message: message)
        }

        let delay = followUpDelay
        Task {
            try? await Task.sleep(for: delay)
            await self.followUpPoll(did: did)
        }
    }

    private func followUpPoll(did: String) async {
        guard let api else { return }
        try? await poll(api, dids: [did])
    }

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        guard let api else { return [] }
        let record = devices.first { $0.did == deviceId } ?? devices.first { $0.miotDid == deviceId }
        let did = record?.miotDid ?? deviceId
        let keys: (temperature: String?, humidity: String?)
        if let record, let spec = specsByModel[record.model] {
            keys = MiotSynthesizer.sensorPropertyKeys(for: record, spec: spec)
        } else {
            keys = (nil, nil)
        }
        do {
            return try await api.sensorHistory(
                did: did,
                temperatureKey: keys.temperature,
                humidityKey: keys.humidity,
                window: window,
                now: now
            )
        } catch MiCloudError.sessionExpired {
            report(MiCloudError.sessionExpired)
            return []
        } catch {
            logger.notice("Sensor history fetch failed for \(did, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
