import Foundation
import os

public enum HomeBackend: String, CaseIterable, Identifiable, Sendable {
    case homeAssistant = "homeAssistant"
    case xiaomiCloud = "xiaomiCloud"
    /// A built-in virtual home that works without an account and never touches the network (#47).
    case demo = "demo"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .homeAssistant: return "Home Assistant"
        case .xiaomiCloud: return L10n.tr("米家云端直连", "Xiaomi Cloud Direct")
        case .demo: return L10n.tr("演示模式", "Demo Mode")
        }
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public enum HomeProviderEvent: Sendable {
    case statusChanged(ConnectionStatus)
    case snapshotUpdated(SynthesizedHome)
}

public enum HomeProviderError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case unauthorized
    case serviceCallFailed(Int, String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return L10n.tr("无效的 HA 地址：\(u)", "Invalid HA URL: \(u)")
        case .unauthorized: return L10n.tr("令牌无效或已过期，请在设置中更新", "Invalid or expired token; update it in Settings")
        case .serviceCallFailed(let code, let msg): return L10n.tr("指令执行失败 (\(code))：\(msg)", "Command failed (\(code)): \(msg)")
        case .networkError(let msg): return L10n.tr("网络异常：\(msg)", "Network error: \(msg)")
        }
    }
}

public protocol HomeProvider: Sendable {
    func events() -> AsyncStream<HomeProviderEvent>
    func execute(_ command: DeviceCommand) async throws
    func refreshNow() async
    /// Tells a polling provider whether the panel is open and the Mac is awake, so it can slow down or pause (#26).
    func setPollingContext(_ context: PollingContext) async
    /// Fetches historical temperature and humidity readings for `deviceId` over `window`.
    func fetchSensorHistory(deviceId: String, window: SensorHistoryWindow, now: Date) async -> [SensorHistorySample]
}

extension HomeProvider {
    /// Push-based providers (Home Assistant) have nothing to slow down.
    public func setPollingContext(_ context: PollingContext) async {}
    public func fetchSensorHistory(deviceId: String, window: SensorHistoryWindow, now: Date) async -> [SensorHistorySample] { [] }
}

// MARK: - Live Home Assistant WebSocket + REST Provider

public actor HAWebSocketProvider: HomeProvider {
    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "HAWebSocket")
    private var baseURLString: String
    private var token: String
    private let session: URLSession

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var activeWebSocket: URLSessionWebSocketTask?

    private var snapshot = HAHomeSnapshot()
    /// Told about another Home Assistant address found after repeated disconnects. The provider never
    /// switches by itself: the token only goes to a new address after the user agrees (#18).
    private let onAddressSuggestion: (@Sendable (HADiscoveredInstance) -> Void)?
    private var lastRediscoveryAt: Date?
    /// Test seam for the LAN scan after a disconnect.
    private let rediscover: @Sendable (String) async -> [HADiscoveredInstance]

    public init(
        baseURLString: String,
        token: String,
        onAddressSuggestion: (@Sendable (HADiscoveredInstance) -> Void)? = nil,
        rediscover: @escaping @Sendable (String) async -> [HADiscoveredInstance] = { await HADiscovery.discoverOnLAN(currentURLHint: $0) }
    ) {
        self.baseURLString = Self.normalizeBaseURL(baseURLString)
        self.token = token
        self.onAddressSuggestion = onAddressSuggestion
        self.rediscover = rediscover

        // Bypass system proxies for direct LAN communication with NAS
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// The address the provider is using; it only changes through `updateCredentials`.
    public var currentBaseURLString: String { baseURLString }

    public func updateCredentials(baseURLString: String, token: String) {
        self.baseURLString = Self.normalizeBaseURL(baseURLString)
        self.token = token
        restartLoop()
    }

    public func shutdown() {
        loopTask?.cancel()
        loopTask = nil
        activeWebSocket?.cancel(with: .goingAway, reason: nil)
        activeWebSocket = nil
        continuation?.finish()
        continuation = nil
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            Task {
                await self.attachContinuation(continuation)
            }
        }
    }

    private func attachContinuation(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        self.continuation = cont
        restartLoop()
    }

    public func refreshNow() async {
        if let ws = activeWebSocket {
            try? await sendJSON(ws: ws, ["id": Int.random(in: 1000...9999), "type": "get_states"])
        } else {
            restartLoop()
        }
    }

    private func restartLoop() {
        loopTask?.cancel()
        activeWebSocket?.cancel(with: .goingAway, reason: nil)
        activeWebSocket = nil

        loopTask = Task {
            await runConnectionLoop()
        }
    }

    private func runConnectionLoop() async {
        var backoffSeconds: Double = 0.8
        var consecutiveFailures = 0
        while !Task.isCancelled {
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continuation?.yield(.statusChanged(.disconnected(L10n.tr("请在设置中配置访问令牌", "Configure your access token in Settings"))))
                return
            }
            continuation?.yield(.statusChanged(.connecting))
            do {
                try await connectAndListen()
                backoffSeconds = 0.8
                consecutiveFailures = 0
            } catch {
                if Task.isCancelled { break }
                if case HomeProviderError.unauthorized = error {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    logger.error("WebSocket unauthorized: \(msg, privacy: .public)")
                    continuation?.yield(.statusChanged(.disconnected(msg)))
                } else {
                    consecutiveFailures += 1
                    await suggestOtherAddressIfDue(consecutiveFailures: consecutiveFailures)
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    logger.error("WebSocket disconnected: \(msg, privacy: .public)")
                    continuation?.yield(.statusChanged(.disconnected(msg)))
                }
                try? await Task.sleep(for: .seconds(backoffSeconds))
                backoffSeconds = min(backoffSeconds * 1.8, 10.0)
            }
        }
    }

    /// After two failures in a row, looks for Home Assistant elsewhere on the network at most every
    /// `HAAddressPolicy.rediscoveryInterval`, and only reports what it finds (#18).
    private func suggestOtherAddressIfDue(consecutiveFailures: Int, now: Date = Date()) async {
        guard let onAddressSuggestion, consecutiveFailures >= 2 else { return }
        if let last = lastRediscoveryAt, now.timeIntervalSince(last) < HAAddressPolicy.rediscoveryInterval { return }
        lastRediscoveryAt = now
        let current = baseURLString
        guard let candidate = await rediscover(current).first(where: { Self.normalizeBaseURL($0.baseURL) != current }) else { return }
        logger.info("Found another Home Assistant address; asking the user before switching: \(candidate.baseURL, privacy: .public)")
        onAddressSuggestion(candidate)
    }

    private func connectAndListen() async throws {
        guard let wsURL = Self.makeWebSocketURL(from: baseURLString) else {
            throw HomeProviderError.invalidURL(baseURLString)
        }

        let ws = session.webSocketTask(with: wsURL)
        ws.maximumMessageSize = 16 * 1024 * 1024
        self.activeWebSocket = ws
        ws.resume()

        // 1. Expect auth_required
        _ = try await receiveJSON(ws: ws)

        // 2. Send auth
        try await sendJSON(ws: ws, [
            "type": "auth",
            "access_token": token
        ])

        let authResp = try await receiveJSON(ws: ws)
        let authType = authResp["type"]?.stringValue ?? ""
        if authType != "auth_ok" {
            ws.cancel(with: .goingAway, reason: nil)
            throw HomeProviderError.unauthorized
        }

        snapshot = HAHomeSnapshot()

        continuation?.yield(.statusChanged(.connected))

        // 3. Request registries & initial states + subscribe state_changed
        try await sendJSON(ws: ws, ["id": 1, "type": "config/area_registry/list"])
        try await sendJSON(ws: ws, ["id": 2, "type": "config/device_registry/list"])
        try await sendJSON(ws: ws, ["id": 3, "type": "config/entity_registry/list"])
        try await sendJSON(ws: ws, ["id": 4, "type": "get_states"])
        try await sendJSON(ws: ws, [
            "id": 5,
            "type": "subscribe_events",
            "event_type": "state_changed"
        ])

        // 4. Periodic 25-second ping task to keep connection alive forever
        let pingTask = Task { [weak self] in
            var pingId = 100_000
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { break }
                pingId += 1
                try? await self?.sendJSON(ws: ws, ["id": pingId, "type": "ping"])
            }
        }
        defer {
            pingTask.cancel()
            ws.cancel(with: .goingAway, reason: nil)
        }

        // 5. Receive loop
        while !Task.isCancelled {
            let msg = try await receiveJSON(ws: ws)
            if let home = try snapshot.receive(msg) {
                continuation?.yield(.snapshotUpdated(home))
            }
        }
    }

    // MARK: - Command Execution via REST Service Endpoint

    public func execute(_ command: DeviceCommand) async throws {
        let (domain, service, payload) = Self.mapCommandToService(command)
        guard let url = URL(string: "\(baseURLString)/api/services/\(domain)/\(service)") else {
            throw HomeProviderError.invalidURL(baseURLString)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HomeProviderError.networkError("无 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw HomeProviderError.serviceCallFailed(http.statusCode, bodyText)
        }
    }

    public static func mapCommandToService(_ command: DeviceCommand) -> (domain: String, service: String, payload: [String: Any]) {
        switch command {
        case .setLightPower(let eid, let isOn):
            return ("light", isOn ? "turn_on" : "turn_off", ["entity_id": eid])

        case .setLightBrightness(let eid, let pct):
            return ("light", "turn_on", [
                "entity_id": eid,
                "brightness_pct": max(1, min(100, pct))
            ])

        case .setLightColorTemp(let eid, let kelvin):
            return ("light", "turn_on", [
                "entity_id": eid,
                "color_temp_kelvin": kelvin
            ])

        case .setLightEffect(let eid, let effect):
            return ("light", "turn_on", [
                "entity_id": eid,
                "effect": effect
            ])

        case .setClimatePower(let eid, let isOn, let fallbackMode):
            if isOn {
                return ("climate", "set_hvac_mode", [
                    "entity_id": eid,
                    "hvac_mode": fallbackMode == "off" ? "cool" : fallbackMode
                ])
            } else {
                return ("climate", "turn_off", ["entity_id": eid])
            }

        case .setClimateMode(let eid, let mode):
            return ("climate", "set_hvac_mode", [
                "entity_id": eid,
                "hvac_mode": mode
            ])

        case .setClimateTemperature(let eid, let temp):
            return ("climate", "set_temperature", [
                "entity_id": eid,
                "temperature": temp
            ])

        case .setClimateFanMode(let eid, let fanMode):
            return ("climate", "set_fan_mode", [
                "entity_id": eid,
                "fan_mode": fanMode
            ])

        case .setClimateSwingMode(let eid, let swingMode):
            return ("climate", "set_swing_mode", [
                "entity_id": eid,
                "swing_mode": swingMode
            ])

        case .setFanPower(let eid, let isOn):
            return ("fan", isOn ? "turn_on" : "turn_off", ["entity_id": eid])

        case .setFanPresetMode(let eid, let preset):
            return ("fan", "set_preset_mode", [
                "entity_id": eid,
                "preset_mode": preset
            ])

        case .setFanOscillating(let eid, let oscillating):
            return ("fan", "oscillate", [
                "entity_id": eid,
                "oscillating": oscillating
            ])

        case .setSwitch(let eid, let isOn):
            return ("switch", isOn ? "turn_on" : "turn_off", ["entity_id": eid])

        case .setSelectOption(let eid, let option):
            return ("select", "select_option", [
                "entity_id": eid,
                "option": option
            ])

        case .setNumberValue(let eid, let value):
            return ("number", "set_value", [
                "entity_id": eid,
                "value": value
            ])

        case .vacuumAction(let eid, let action):
            return ("vacuum", action.rawValue, ["entity_id": eid])

        case .mediaSetVolume(let eid, let level):
            return ("media_player", "volume_set", [
                "entity_id": eid,
                "volume_level": max(0.0, min(1.0, level))
            ])

        case .mediaSelectSource(let eid, let source):
            return ("media_player", "select_source", [
                "entity_id": eid,
                "source": source
            ])

        case .pressButton(let eid):
            return ("button", "press", ["entity_id": eid])

        case .sendNotifyMessage(let eid, let message):
            return ("notify", "send_message", [
                "entity_id": eid,
                "message": message
            ])

        case .activateScene(let eid):
            let domain = eid.hasPrefix("script.") ? "script" : "scene"
            return (domain, "turn_on", ["entity_id": eid])
        }
    }

    // MARK: - Helpers

    private func sendJSON(ws: URLSessionWebSocketTask, _ dict: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let str = String(data: data, encoding: .utf8) else { return }
        try await ws.send(.string(str))
    }

    private func receiveJSON(ws: URLSessionWebSocketTask) async throws -> [String: JSONValue] {
        let msg = try await ws.receive()
        let data: Data = switch msg {
        case .string(let s): Data(s.utf8)
        case .data(let d): d
        @unknown default: Data()
        }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }

    public static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            s = "http://\(s)"
        }
        return s
    }

    private static func makeWebSocketURL(from baseURL: String) -> URL? {
        var wsStr = baseURL
        if wsStr.hasPrefix("https://") {
            wsStr = "wss://" + wsStr.dropFirst("https://".count)
        } else if wsStr.hasPrefix("http://") {
            wsStr = "ws://" + wsStr.dropFirst("http://".count)
        }
        return URL(string: "\(wsStr)/api/websocket")
    }
}
