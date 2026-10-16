import Foundation
import os

/// `HomeProvider` that talks to Xiaomi cloud directly (no Home Assistant): discovers devices and
/// rooms, loads MIoT specs, polls properties and maps `DeviceCommand`s to MIoT writes.
public actor MiCloudProvider: HomeProvider {
    public typealias APIFactory = @Sendable (MiSession) -> any MiCloudAPI

    private let logger = Logger(subsystem: "com.yangzhiyuan.MenuBarMijia", category: "MiCloudProvider")
    private let sessionLoader: @Sendable () -> MiSession?
    private let apiFactory: APIFactory
    private let specSource: any MiotSpecSource
    private let pollInterval: Duration
    private let deviceRefreshEveryPolls: Int
    private let followUpDelay: Duration

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var api: (any MiCloudAPI)?

    private var devices: [MiDeviceRecord] = []
    private var rooms: [MiRoom] = []
    private var specsByModel: [String: MiotDeviceSpec] = [:]
    private var values: [MiotPropKey: JSONValue] = [:]

    public init(
        sessionLoader: @escaping @Sendable () -> MiSession? = { MiSessionStore.load() },
        apiFactory: @escaping APIFactory = { MiCloudClient(session: $0) },
        specSource: any MiotSpecSource = MiotSpecStore(),
        pollInterval: Duration = .seconds(6),
        deviceRefreshEveryPolls: Int = 20,
        followUpDelay: Duration = .milliseconds(800)
    ) {
        self.sessionLoader = sessionLoader
        self.apiFactory = apiFactory
        self.specSource = specSource
        self.pollInterval = pollInterval
        self.deviceRefreshEveryPolls = max(1, deviceRefreshEveryPolls)
        self.followUpDelay = followUpDelay
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
        do {
            try await discover(api)
            try await poll(api, dids: nil)
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
                    try await Task.sleep(for: pollInterval)
                    polls += 1
                    if polls % deviceRefreshEveryPolls == 0 {
                        try await refreshDeviceList(api)
                    }
                }
            } catch is CancellationError {
                return
            } catch MiCloudError.sessionExpired {
                report(MiCloudError.sessionExpired)
                return
            } catch {
                if Task.isCancelled { return }
                report(error)
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 60)
            }
        }
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

    private func loadMissingSpecs() async {
        var pending: [String: String?] = [:]
        for d in devices where specsByModel[d.model] == nil {
            pending[d.model] = d.specType
        }
        guard !pending.isEmpty else { return }
        let source = specSource
        let loaded = await withTaskGroup(of: (String, MiotDeviceSpec?, String?).self) { group in
            for (model, specType) in pending {
                group.addTask {
                    do {
                        return (model, try await source.spec(model: model, specType: specType), nil)
                    } catch {
                        return (model, nil, error.localizedDescription)
                    }
                }
            }
            var out: [(String, MiotDeviceSpec?, String?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (model, spec, error) in loaded {
            if let spec {
                specsByModel[model] = spec
            } else if let error {
                logger.error("Spec load failed for \(model, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    private func poll(_ api: any MiCloudAPI, dids: Set<String>?) async throws {
        var keys: [MiotPropKey] = []
        for d in devices where d.isOnline && (dids?.contains(d.did) ?? true) {
            guard let spec = specsByModel[d.model] else { continue }
            keys.append(contentsOf: MiotSynthesizer.requiredProps(for: d, spec: spec))
        }
        if !keys.isEmpty {
            let fresh = try await api.getProps(keys)
            values.merge(fresh) { _, new in new }
        }
        emitSnapshot()
    }

    private func emitSnapshot() {
        let home = MiotSynthesizer.synthesize(devices: devices, rooms: rooms, specs: specsByModel, values: values)
        continuation?.yield(.snapshotUpdated(home))
    }

    // MARK: Commands

    public func execute(_ command: DeviceCommand) async throws {
        let entityId = command.targetEntityId
        guard let (did, _) = MiotAddress.parse(entityId) else { throw MiotCommandError.invalidAddress(entityId) }
        guard let api else { throw MiCloudError.notLoggedIn }
        guard let record = devices.first(where: { $0.did == did }), let spec = specsByModel[record.model] else {
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
}
