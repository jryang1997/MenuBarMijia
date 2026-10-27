import Foundation

// Backend connections, discovery, provider events, device naming and polling rhythm (#48).
extension HomeStore {
    // MARK: - Backend Summary

    public var serverHostSummary: String {
        let _ = effectiveLanguage
        if homeBackend == .demo {
            return L10n.tr("演示模式（虚拟设备）", "Demo Mode (Virtual Devices)")
        }
        if homeBackend == .xiaomiCloud {
            return miSessionMaskedUserId.map { L10n.tr("米家云端 (\($0))", "Xiaomi Cloud (\($0))") }
                ?? L10n.tr("米家云端 (未登录)", "Xiaomi Cloud (Signed Out)")
        }
        if let url = URL(string: serverURLString), let host = url.host() {
            return host
        }
        return serverURLString
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    // MARK: - LG TV & Provider Events

    func startLGWebOSIfNeeded() {
        guard homeBackend != .demo else { return }
        let client = LGWebOSClient(
            config: lgConfig,
            onDeviceUpdated: { [weak self] dev in
                Task { @MainActor [weak self] in
                    self?.applyLGDeviceUpdate(dev)
                }
            },
            onClientKeyRegistered: { [weak self] key in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lgConfig.clientKey = key
                    self.showToast(L10n.tr("已成功配对 \(self.lgConfig.name)", "Paired with \(self.lgConfig.name)"))
                }
            },
            onSecurityFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.showToast(message, isError: true)
                }
            }
        )
        self.lgWebOSClient = client
        if lgConfig.isEnabled && lgConfig.hasConfiguredHost {
            Task { await client.start() }
        }
    }

    func applyLGDeviceUpdate(_ dev: SmartDevice) {
        // Demo mode never shows the LAN TV tile (#47), and a disabled or unconfigured TV drops it too.
        guard homeBackend != .demo, lgConfig.isEnabled, lgConfig.hasConfiguredHost else {
            latestLGDevice = nil
            devices.removeAll { $0.id == dev.id }
            return
        }
        latestLGDevice = dev
        rawDeviceNames[dev.id] = dev.name
        let now = ContinuousClock.now
        if let lockTime = optimisticLockUntil[dev.id], now < lockTime {
            return
        }
        if let idx = devices.firstIndex(where: { $0.id == dev.id }) {
            devices[idx] = dev
        } else {
            devices.append(dev)
            if favoriteDeviceIds.contains(dev.id) == false && favoriteOrder.count < 8 {
                favoriteDeviceIds.insert(dev.id)
                favoriteOrder.insert(dev.id, at: 0)
            }
        }
        applyDeviceAliases()
        if !rooms.contains(where: { $0.id == dev.roomId || $0.name == dev.roomName }) {
            rooms.append(RoomArea(id: dev.roomId, name: dev.roomName, sortOrder: 1))
        }
    }

    public func startListening() {
        hasReceivedInitialSnapshot = false
        eventTask?.cancel()
        let stream = provider.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                self.handleProviderEvent(event)
            }
        }
        pushPollingContext()
    }

    public func waitForInitialSnapshot(timeout: Duration = .seconds(4)) async throws {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !hasReceivedInitialSnapshot {
            guard ContinuousClock.now < deadline else {
                throw HomeProviderError.networkError(L10n.tr(
                    "家居数据尚未加载，请稍后重试",
                    "Home data has not loaded yet. Try again shortly."
                ))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Polling Rhythm (#26)

    /// The control center panel opened or closed.
    public func setPanelVisible(_ visible: Bool) {
        updatePollingContext { $0.panelVisible = visible }
    }

    /// False while the Mac or display sleeps, the screen is locked, or another user is active.
    public func setSystemActive(_ active: Bool) {
        updatePollingContext { $0.systemActive = active }
    }

    public func setLowPowerMode(_ enabled: Bool) {
        updatePollingContext { $0.lowPower = enabled }
    }

    private func updatePollingContext(_ change: (inout PollingContext) -> Void) {
        var next = pollingContext
        change(&next)
        guard next != pollingContext else { return }
        pollingContext = next
        pushPollingContext()
    }

    /// Chained so quick open/close changes reach the provider in order.
    private func pushPollingContext() {
        let previous = pollingContextSync
        let target = provider
        let context = pollingContext
        pollingContextSync = Task {
            await previous?.value
            await target.setPollingContext(context)
        }
    }

    private func handleProviderEvent(_ event: HomeProviderEvent) {
        switch event {
        case .statusChanged(let status):
            if connectionStatus != status { connectionStatus = status }

        case .snapshotUpdated(let snapshot):
            if !hasReceivedInitialSnapshot { hasReceivedInitialSnapshot = true }
            var nextRooms = snapshot.rooms
            if let lgDev = latestLGDevice, lgConfig.isEnabled,
               !nextRooms.contains(where: { $0.id == lgDev.roomId || $0.name == lgDev.roomName }) {
                nextRooms.append(RoomArea(id: lgDev.roomId, name: lgDev.roomName, sortOrder: 1))
            }
            if rooms != nextRooms { rooms = nextRooms }
            if homes != snapshot.homes { homes = snapshot.homes }
            if environmentReadings != snapshot.environmentReadings { environmentReadings = snapshot.environmentReadings }
            if pendingLegacyMenuBarTargetMigration,
               let first = snapshot.environmentReadings.first(where: { $0.temperature != nil }) {
                self.menuBarTargetId = "temp:\(first.id)"
                pendingLegacyMenuBarTargetMigration = false
            }
            if scenes != snapshot.scenes { scenes = snapshot.scenes }

            let now = ContinuousClock.now
            var merged: [SmartDevice] = []
            let existingById = Dictionary(uniqueKeysWithValues: self.devices.map { ($0.id, $0) })

            for incoming in snapshot.devices {
                rawDeviceNames[incoming.id] = incoming.name
                if let lockTime = optimisticLockUntil[incoming.id], now < lockTime,
                   let local = existingById[incoming.id] {
                    merged.append(local)
                } else {
                    merged.append(incoming)
                }
            }
            if let lgDev = latestLGDevice, lgConfig.isEnabled,
               !merged.contains(where: { $0.id == lgDev.id }) {
                rawDeviceNames[lgDev.id] = lgDev.name
                if let lockTime = optimisticLockUntil[lgDev.id], now < lockTime,
                   let local = existingById[lgDev.id] {
                    merged.insert(local, at: 0)
                } else {
                    merged.insert(lgDev, at: 0)
                }
            }
            // Compare the displayed names so aliases do not cause two observable writes per snapshot.
            let nextDevices = devicesWithAliases(merged)
            if devices != nextDevices { devices = nextDevices }
            seedDefaultFavoritesIfNeeded()
            energyHistory.record(devices: devices, now: Date())

            if enableSafetyAlerts, let handler = onSafetyAlert {
                for alert in evaluateSafetyAlerts(now: Date()) {
                    handler(alert)
                }
            }
            notifyMissedScheduledCommandsIfNeeded()
        }
    }

    private func seedDefaultFavoritesIfNeeded() {
        guard favoriteDeviceIds.isEmpty,
              userDefaults.object(forKey: "favorite_device_ids") == nil,
              !devices.isEmpty else {
            return
        }
        // Automatically star online controllable devices on first launch
        let initial = devices
            .filter { $0.isOnline && ($0.isPrimaryToggleable || $0.hasDetailDrawer) }
            .prefix(6)
            .map(\.id)
        if !initial.isEmpty {
            self.favoriteDeviceIds = Set(initial)
            self.favoriteOrder = initial
        }
    }

    public func originalDeviceName(for deviceId: String) -> String? {
        rawDeviceNames[deviceId] ?? devices.first(where: { $0.id == deviceId })?.name
    }

    public func applyDeviceAliases(_ overrides: [String: String]? = nil) {
        let nextDevices = devicesWithAliases(devices, overrides: overrides)
        if devices != nextDevices { devices = nextDevices }
    }

    private func devicesWithAliases(_ input: [SmartDevice], overrides: [String: String]? = nil) -> [SmartDevice] {
        var result = input
        let aliases: [String: String]
        if let overrides {
            aliases = overrides
            if let data = try? JSONEncoder().encode(overrides),
               let raw = String(data: data, encoding: .utf8) {
                userDefaults.set(raw, forKey: Self.deviceAliasesKey)
            }
        } else if let raw = userDefaults.string(forKey: Self.deviceAliasesKey),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) {
            aliases = decoded
        } else {
            aliases = [:]
        }
        for idx in result.indices {
            let id = result[idx].id
            let baseName = rawDeviceNames[id] ?? result[idx].name
            rawDeviceNames[id] = baseName
            if let alias = aliases[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !alias.isEmpty,
               alias != baseName {
                result[idx].name = alias
            } else {
                result[idx].name = baseName
            }
        }
        return result
    }

    // MARK: - Connection & Settings Management

    func makeHAProvider(baseURLString: String, token: String) -> HAWebSocketProvider {
        let callback: (@Sendable (HADiscoveredInstance) -> Void)?
        if isTestEnvironment {
            callback = nil
        } else {
            callback = { @Sendable [weak self] instance in
                Task { @MainActor [weak self] in
                    self?.offerHAAddress(instance)
                }
            }
        }
        return HAWebSocketProvider(
            baseURLString: baseURLString,
            token: token,
            onAddressSuggestion: callback
        )
    }

    /// Shows a found address as a question instead of switching to it (#18). An address whose instance id
    /// differs from the Home Assistant the user chose before is ignored.
    public func offerHAAddress(_ instance: HADiscoveredInstance) {
        guard homeBackend != .demo else { return }
        guard HAAddressPolicy.canOffer(
            instance,
            currentURL: serverURLString,
            rememberedUUID: userDefaults.string(forKey: HAAddressPolicy.rememberedUUIDKey),
            dismissedURLs: dismissedHAAddressURLs
        ) else { return }
        if !discoveredHAInstances.contains(where: { $0.baseURL == instance.baseURL }) {
            discoveredHAInstances.insert(instance, at: 0)
        }
        pendingHAAddressSuggestion = instance
    }

    public func acceptHAAddressSuggestion() {
        guard let instance = pendingHAAddressSuggestion else { return }
        pendingHAAddressSuggestion = nil
        applyDiscoveredHAInstance(instance, reconnectProvider: true)
    }

    public func dismissHAAddressSuggestion() {
        guard let instance = pendingHAAddressSuggestion else { return }
        pendingHAAddressSuggestion = nil
        dismissedHAAddressURLs.insert(HAWebSocketProvider.normalizeBaseURL(instance.baseURL))
    }

    /// Remembers which Home Assistant the user picked so a look-alike elsewhere is not offered later.
    private func rememberHAInstanceId(forURL url: String) {
        let normalized = HAWebSocketProvider.normalizeBaseURL(url)
        if let uuid = discoveredHAInstances.first(where: { $0.baseURL == normalized })?.uuid {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        } else {
            userDefaults.removeObject(forKey: HAAddressPolicy.rememberedUUIDKey)
        }
    }

    public func switchBackend(_ backend: HomeBackend) {
        let matches: Bool = switch backend {
        case .homeAssistant: provider is HAWebSocketProvider
        case .xiaomiCloud: provider is MiCloudProvider
        case .demo: provider is DemoHomeProvider
        }
        guard homeBackend != backend || !matches else { return }

        let previousBackend = homeBackend
        self.homeBackend = backend
        eventTask?.cancel()
        shutdownCurrentProvider()

        switch backend {
        case .homeAssistant:
            self.provider = makeHAProvider(baseURLString: serverURLString, token: KeychainHelper.loadToken(defaults: userDefaults))
        case .xiaomiCloud:
            nonisolated(unsafe) let ud = userDefaults
            self.provider = MiCloudProvider(sessionLoader: { MiSessionStore.load(defaults: ud) })
        case .demo:
            // Strictly offline: stop any LAN TV and update work started by the previous backend (#47).
            if let lgClient = lgWebOSClient {
                Task { await lgClient.stop() }
            }
            latestLGDevice = nil
            updateTask?.cancel()
            updateTask = nil
            activeUpdateAttemptID = nil
            if case .readyToRelaunch(let staged) = updateState {
                updater.cleanupStagedApp(staged)
            }
            updateState = .idle
            self.provider = DemoHomeProvider()
        }
        startListening()
        // Leaving demo mode resumes the LAN TV link that demo stopped; `start()` no-ops when the
        // config is disabled or has no host.
        if previousBackend == .demo, backend != .demo, let lgClient = lgWebOSClient {
            Task { await lgClient.start() }
        }
    }

    public func completeMiLogin(_ session: MiSession) {
        MiSessionStore.save(session, defaults: userDefaults)
        self.miSessionMaskedUserId = session.maskedUserId
        if let region = MiCloudRegion(rawValue: session.region.lowercased()) {
            self.miCloudRegion = region
        }
        self.homeBackend = .xiaomiCloud
        self.completeOnboarding()
        eventTask?.cancel()
        shutdownCurrentProvider()
        nonisolated(unsafe) let ud = userDefaults
        self.provider = MiCloudProvider(sessionLoader: { MiSessionStore.load(defaults: ud) })
        startListening()
        showToast(L10n.tr("已登录米家账号 (\(session.maskedUserId))", "Signed in to Xiaomi Home (\(session.maskedUserId))"))
    }

    public func logoutMiAccount() {
        MiSessionStore.clear(defaults: userDefaults)
        self.miSessionMaskedUserId = nil
        if homeBackend == .xiaomiCloud {
            self.devices = []
            self.rooms = []
            self.environmentReadings = []
            self.scenes = []
            eventTask?.cancel()
            shutdownCurrentProvider()
            nonisolated(unsafe) let ud = userDefaults
            self.provider = MiCloudProvider(sessionLoader: { MiSessionStore.load(defaults: ud) })
            startListening()
        }
        showToast(L10n.tr("已退出米家账号", "Signed out of Xiaomi Home"))
    }

    private func shutdownCurrentProvider() {
        if let old = provider as? MiCloudProvider {
            Task { await old.shutdown() }
        } else if let old = provider as? HAWebSocketProvider {
            Task { await old.shutdown() }
        }
    }

    public func updateConnection(serverURL: String, token: String) {
        let normalized = HAWebSocketProvider.normalizeBaseURL(serverURL)
        if normalized != HAWebSocketProvider.normalizeBaseURL(serverURLString) {
            rememberHAInstanceId(forURL: normalized)
        }
        pendingHAAddressSuggestion = nil
        self.serverURLString = normalized
        KeychainHelper.saveToken(token)
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.completeOnboarding()
        }
        if homeBackend != .homeAssistant || !(provider is HAWebSocketProvider) {
            switchBackend(.homeAssistant)
        } else if let haProvider = provider as? HAWebSocketProvider {
            Task {
                await haProvider.updateCredentials(baseURLString: normalized, token: token)
            }
        }
        showToast(L10n.tr("已保存并重新连接 Home Assistant", "Saved and reconnecting to Home Assistant"))
    }

    /// The user chose `instance` (a tap in setup or settings, or 切换 on a suggestion).
    public func applyDiscoveredHAInstance(_ instance: HADiscoveredInstance, reconnectProvider: Bool = true) {
        if !discoveredHAInstances.contains(where: { $0.baseURL == instance.baseURL }) {
            discoveredHAInstances.insert(instance, at: 0)
        }
        if let uuid = instance.uuid {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        }
        let normalizedCurrent = HAWebSocketProvider.normalizeBaseURL(serverURLString)
        if userDefaults.string(forKey: "home_name") == nil,
           !instance.locationName.isEmpty,
           instance.locationName != "Home Assistant" {
            self.homeName = instance.locationName
        }
        guard normalizedCurrent != instance.baseURL else { return }
        self.serverURLString = instance.baseURL
        if reconnectProvider, let haProvider = provider as? HAWebSocketProvider {
            let token = KeychainHelper.loadToken(defaults: userDefaults)
            Task {
                await haProvider.updateCredentials(baseURLString: instance.baseURL, token: token)
            }
        }
    }

    @discardableResult
    public func discoverHomeAssistantOnLAN(autoApplyIfDefault: Bool = false) async -> [HADiscoveredInstance] {
        // Demo mode is strictly offline: no LAN discovery, no network probe (#47).
        guard homeBackend != .demo else { return [] }
        isDiscoveringHA = true
        defer { isDiscoveringHA = false }
        let found = await HADiscovery.discoverOnLAN(currentURLHint: serverURLString)
        self.discoveredHAInstances = found
        // A user who typed the address by hand never went through a suggestion; the moment LAN
        // discovery identifies the instance the app is connected to, pin its id so look-alikes
        // elsewhere are filtered later (#18).
        if let uuid = HAAddressPolicy.uuidToPin(
            discovered: found,
            currentURL: serverURLString,
            rememberedUUID: userDefaults.string(forKey: HAAddressPolicy.rememberedUUIDKey)
        ) {
            userDefaults.set(uuid, forKey: HAAddressPolicy.rememberedUUIDKey)
        }
        // Only pre-fills the address during first setup. With a token already saved, the user picks the
        // address, because connecting sends the token to it (#18).
        if autoApplyIfDefault, let first = found.first {
            let normalizedCurrent = HAWebSocketProvider.normalizeBaseURL(serverURLString)
            let isDefaultURL = (normalizedCurrent == KeychainHelper.defaultNASURL)
                || (userDefaults.string(forKey: "ha_server_url") == nil)
            let hasToken = !KeychainHelper.loadToken(defaults: userDefaults).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isDefaultURL && !hasToken && first.baseURL != normalizedCurrent {
                applyDiscoveredHAInstance(first, reconnectProvider: false)
            }
        }
        return found
    }

    public func updateLGWebOSConfig(_ newConfig: LGWebOSConfig) {
        self.lgConfig = newConfig
        if !newConfig.isEnabled || !newConfig.hasConfiguredHost {
            latestLGDevice = nil
            devices.removeAll { $0.id == LGWebOSProtocol.deviceId }
        }
        // Demo mode persists the preference but never connects to the LAN (#47).
        guard homeBackend != .demo else {
            showToast(
                newConfig.isEnabled
                    ? L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs")
                    : L10n.tr("已停用 LG 电视局域网直连", "Disabled LG TV LAN direct connection")
            )
            return
        }
        if let lgClient = lgWebOSClient {
            Task {
                await lgClient.updateConfig(newConfig)
            }
        } else {
            startLGWebOSIfNeeded()
        }
        if newConfig.isEnabled {
            showToast(
                newConfig.hasConfiguredHost
                    ? L10n.tr("已保存并重连 \(newConfig.name)", "Saved and reconnecting to \(newConfig.name)")
                    : L10n.tr("请先填写或扫描电视局域网 IP", "Please enter or scan the TV LAN IP first"),
                isError: !newConfig.hasConfiguredHost
            )
        } else {
            showToast(L10n.tr("已停用 LG 电视局域网直连", "Disabled LG TV LAN direct connection"))
        }
    }

    public func triggerLGWebOSPairing() {
        guard homeBackend != .demo else {
            showToast(L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs"), isError: true)
            return
        }
        guard lgConfig.hasConfiguredHost else {
            showToast(L10n.tr("请先填写或扫描电视局域网 IP", "Please enter or scan the TV LAN IP first"), isError: true)
            return
        }
        if lgWebOSClient == nil {
            startLGWebOSIfNeeded()
        }
        guard let lgClient = lgWebOSClient else { return }
        showToast(L10n.tr("已向电视发送配对请求，请在电视屏幕点击「接受」", "Pairing request sent; accept the prompt on your TV screen"))
        Task {
            await lgClient.triggerPairing()
        }
    }

    /// Called only after Settings confirms discarding the saved TV identity.
    public func resetLGWebOSTrustAndPair() {
        guard homeBackend != .demo else {
            showToast(L10n.tr("演示模式下不会连接局域网电视", "Demo Mode does not connect to LAN TVs"), isError: true)
            return
        }
        guard lgConfig.hasConfiguredHost, let client = lgWebOSClient else { return }
        let host = lgConfig.host
        Task {
            do {
                try await client.resetTrustAndPair()
                guard lgConfig.host == host else { return }
                lgConfig.clientKey = ""
                showToast(L10n.tr("旧电视身份已清除，请在电视上确认重新配对", "Saved TV identity cleared; confirm the new pairing on your TV"))
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    public func discoverLGWebOSTVs(hostHint: String? = nil) async -> [LGWebOSDiscoveredTV] {
        // Demo mode is strictly offline: no LAN discovery (#47).
        guard homeBackend != .demo else { return [] }
        let hint = (hostHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHint = hint.isEmpty ? lgConfig.host : hint
        return await LGWebOSClient.discoverOnLAN(hostHint: effectiveHint)
    }

    /// Switches the visible Mi Home; nil shows every home's devices.
    public func selectMiHome(_ id: String?) {
        if let id {
            userDefaults.set(id, forKey: MiCloudProvider.selectedHomeKey)
            if userDefaults !== UserDefaults.standard {
                UserDefaults.standard.set(id, forKey: MiCloudProvider.selectedHomeKey)
            }
        } else {
            userDefaults.removeObject(forKey: MiCloudProvider.selectedHomeKey)
            if userDefaults !== UserDefaults.standard {
                UserDefaults.standard.removeObject(forKey: MiCloudProvider.selectedHomeKey)
            }
        }
        selectedMiHomeId = id
        selectedRoomId = nil
        refreshNow()
    }

    public func refreshNow() {
        Task {
            await provider.refreshNow()
            if homeBackend != .demo, lgConfig.isEnabled, lgConfig.hasConfiguredHost, let lgClient = lgWebOSClient {
                await lgClient.start()
            }
        }
    }
}
