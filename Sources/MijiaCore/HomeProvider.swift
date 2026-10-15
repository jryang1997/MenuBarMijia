import Foundation
import os

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
        case .invalidURL(let u): return "无效的 HA 地址：\(u)"
        case .unauthorized: return "令牌无效或已过期，请在设置中更新"
        case .serviceCallFailed(let code, let msg): return "指令执行失败 (\(code))：\(msg)"
        case .networkError(let msg): return "网络异常：\(msg)"
        }
    }
}

public protocol HomeProvider: Sendable {
    func events() -> AsyncStream<HomeProviderEvent>
    func execute(_ command: DeviceCommand) async throws
    func refreshNow() async
}

// MARK: - Live Home Assistant WebSocket + REST Provider

public actor HAWebSocketProvider: HomeProvider {
    private let logger = Logger(subsystem: "com.yangzhiyuan.MenuBarMijia", category: "HAWebSocket")
    private var baseURLString: String
    private var token: String
    private let session: URLSession

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var activeWebSocket: URLSessionWebSocketTask?

    private var areas: [HAAreaEntry] = []
    private var devices: [HADeviceEntry] = []
    private var entities: [HAEntityEntry] = []
    private var states: [String: HAEntityState] = [:]

    public init(baseURLString: String, token: String) {
        self.baseURLString = Self.normalizeBaseURL(baseURLString)
        self.token = token

        // Bypass system proxies for direct LAN communication with NAS
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func updateCredentials(baseURLString: String, token: String) {
        self.baseURLString = Self.normalizeBaseURL(baseURLString)
        self.token = token
        restartLoop()
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
        while !Task.isCancelled {
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continuation?.yield(.statusChanged(.disconnected("请在设置中配置访问令牌")))
                return
            }
            continuation?.yield(.statusChanged(.connecting))
            do {
                try await connectAndListen()
                backoffSeconds = 0.8
            } catch {
                if Task.isCancelled { break }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("WebSocket disconnected: \(msg, privacy: .public)")
                continuation?.yield(.statusChanged(.disconnected(msg)))
                try? await Task.sleep(for: .seconds(backoffSeconds))
                backoffSeconds = min(backoffSeconds * 1.8, 10.0)
            }
        }
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
            handleIncomingMessage(msg)
        }
    }

    private func handleIncomingMessage(_ msg: [String: JSONValue]) {
        let type = msg["type"]?.stringValue ?? ""

        if type == "result", let id = msg["id"]?.intValue {
            switch id {
            case 1:
                if let arr = msg["result"] {
                    self.areas = decodeValue([HAAreaEntry].self, from: arr) ?? []
                }
            case 2:
                if let arr = msg["result"] {
                    self.devices = decodeValue([HADeviceEntry].self, from: arr) ?? []
                }
            case 3:
                if let arr = msg["result"] {
                    self.entities = decodeValue([HAEntityEntry].self, from: arr) ?? []
                }
            case 4, 1000...9999:
                if case .array(let items) = msg["result"] {
                    var newStates: [String: HAEntityState] = [:]
                    for item in items {
                        if let st = Self.parseEntityState(from: item) {
                            newStates[st.entityId] = st
                        }
                    }
                    self.states = newStates
                    emitSynthesizedSnapshot()
                }
            default:
                break
            }
        } else if type == "event",
                  case .object(let eventObj) = msg["event"],
                  eventObj["event_type"]?.stringValue == "state_changed",
                  case .object(let dataObj) = eventObj["data"],
                  let newStateVal = dataObj["new_state"],
                  let st = Self.parseEntityState(from: newStateVal) {
            self.states[st.entityId] = st
            emitSynthesizedSnapshot()
        }
    }

    private func emitSynthesizedSnapshot() {
        let home = DeviceSynthesizer.synthesize(
            areas: areas,
            devices: devices,
            entities: entities,
            states: states
        )
        continuation?.yield(.snapshotUpdated(home))
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

    private func decodeValue<T: Decodable>(_ type: T.Type, from val: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(val) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func parseEntityState(from val: JSONValue) -> HAEntityState? {
        guard case .object(let obj) = val,
              let eid = obj["entity_id"]?.stringValue,
              let st = obj["state"]?.stringValue else {
            return nil
        }
        let attrs: [String: JSONValue]
        if case .object(let a) = obj["attributes"] {
            attrs = a
        } else {
            attrs = [:]
        }
        return HAEntityState(entityId: eid, state: st, attributes: attrs)
    }

    private static func normalizeBaseURL(_ raw: String) -> String {
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

// MARK: - Mock Provider for Testing & Instant Previews

public actor MockHomeProvider: HomeProvider {
    private var snapshot: SynthesizedHome
    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    public private(set) var executedCommands: [DeviceCommand] = []
    public var shouldFailCommands: Bool = false

    public init(snapshot: SynthesizedHome = .init()) {
        self.snapshot = snapshot
    }

    public func setShouldFail(_ fail: Bool) {
        self.shouldFailCommands = fail
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { cont in
            Task {
                await self.register(cont)
            }
        }
    }

    private func register(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        self.continuation = cont
        cont.yield(.statusChanged(.connected))
        cont.yield(.snapshotUpdated(snapshot))
    }

    public func execute(_ command: DeviceCommand) async throws {
        if shouldFailCommands {
            throw HomeProviderError.serviceCallFailed(500, "模拟网络失败")
        }
        executedCommands.append(command)
    }

    public func refreshNow() async {
        continuation?.yield(.snapshotUpdated(snapshot))
    }
}
