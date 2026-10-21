import Foundation
import os
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Discovered TV & Configuration Models

public struct LGWebOSDiscoveredTV: Equatable, Sendable {
    public var host: String
    public var friendlyName: String
    public var modelName: String
    public var macAddress: String?
    public var uuid: String?

    public init(
        host: String,
        friendlyName: String = "LG C2 电视",
        modelName: String = "OLED42C2PCA",
        macAddress: String? = nil,
        uuid: String? = nil
    ) {
        self.host = host
        self.friendlyName = friendlyName
        self.modelName = modelName
        self.macAddress = macAddress
        self.uuid = uuid
    }
}

public struct LGWebOSConfig: Equatable, Sendable {
    public var isEnabled: Bool
    public var host: String
    public var macAddress: String
    public var name: String
    public var roomName: String
    public var clientKey: String

    public static let defaultHost = ""
    public static let defaultMAC = ""
    public static let defaultName = "LG C2 电视"
    public static let defaultRoom = "客厅"

    public var hasConfiguredHost: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        isEnabled: Bool = false,
        host: String = Self.defaultHost,
        macAddress: String = Self.defaultMAC,
        name: String = Self.defaultName,
        roomName: String = Self.defaultRoom,
        clientKey: String = ""
    ) {
        self.isEnabled = isEnabled
        self.host = host
        self.macAddress = macAddress
        self.name = name
        self.roomName = roomName
        self.clientKey = clientKey
    }

    public static func load(from defaults: UserDefaults) -> LGWebOSConfig {
        let enabled = defaults.object(forKey: "lg_webos_enabled") == nil
            ? false
            : defaults.bool(forKey: "lg_webos_enabled")
        let host = defaults.string(forKey: "lg_webos_host")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mac = defaults.string(forKey: "lg_webos_mac")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = defaults.string(forKey: "lg_webos_name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = defaults.string(forKey: "lg_webos_room")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = defaults.string(forKey: "lg_webos_client_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return LGWebOSConfig(
            isEnabled: enabled,
            host: (host?.isEmpty == false) ? host! : Self.defaultHost,
            macAddress: (mac?.isEmpty == false) ? mac! : Self.defaultMAC,
            name: (name?.isEmpty == false) ? name! : Self.defaultName,
            roomName: (room?.isEmpty == false) ? room! : Self.defaultRoom,
            clientKey: key
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: "lg_webos_enabled")
        defaults.set(host, forKey: "lg_webos_host")
        defaults.set(macAddress, forKey: "lg_webos_mac")
        defaults.set(name, forKey: "lg_webos_name")
        defaults.set(roomName, forKey: "lg_webos_room")
        defaults.set(clientKey, forKey: "lg_webos_client_key")
    }
}

// MARK: - Pure SSAP Protocol & Wake-on-LAN Helpers

public enum LGWebOSProtocol {
    public static let deviceId = "lg_webos_tv"
    public static let mediaEntityId = "lg_webos:media"
    public static let powerEntityId = "lg_webos:power"
    public static let muteEntityId = "lg_webos:mute"
    public static let screenOffEntityId = "lg_webos:screen_off"
    public static let wakeButtonId = "lg_webos:wake"
    public static let pairButtonId = "lg_webos:pair"

    public static func isLGEntity(_ entityId: String) -> Bool {
        entityId.hasPrefix("lg_webos:")
    }

    public enum RegistrationOutcome: Equatable, Sendable {
        case promptPending
        case registered(clientKey: String)
        case error(String)
        case ignored
    }

    /// Builds the canonical LG Connect SDK SSAP `register` packet so webOS grants power, audio, screen, and input permissions.
    public static func registrationPacket(id: String = "register_0", clientKey: String?) -> String {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": signedManifest
        ]
        if let key = clientKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            payload["client-key"] = key
        }
        let root: [String: Any] = [
            "type": "register",
            "id": id,
            "payload": payload
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public static func ssapRequest(
        id: String,
        uri: String,
        type: String = "request",
        payload: [String: Any]? = nil
    ) -> String {
        var root: [String: Any] = [
            "id": id,
            "type": type,
            "uri": uri
        ]
        if let payload {
            root["payload"] = payload
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public static func parseRegistrationOutcome(_ jsonText: String) -> RegistrationOutcome {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return .ignored
        }
        if type == "registered" {
            if let payload = obj["payload"] as? [String: Any],
               let key = payload["client-key"] as? String, !key.isEmpty {
                return .registered(clientKey: key)
            }
        }
        if type == "response", let payload = obj["payload"] as? [String: Any] {
            if (payload["pairingType"] as? String) == "PROMPT" {
                return .promptPending
            }
        }
        if type == "error" {
            let err = (obj["error"] as? String) ?? "电视拒绝配对"
            return .error(err)
        }
        return .ignored
    }

    public static func parseVolumePayload(_ payload: [String: Any]) -> (volume: Int, muted: Bool)? {
        let muted = (payload["muted"] as? Bool)
            ?? ((payload["volumeStatus"] as? [String: Any])?["muteStatus"] as? Bool)
            ?? false
        if let vol = payload["volume"] as? Int {
            return (max(0, min(100, vol)), muted)
        }
        if let status = payload["volumeStatus"] as? [String: Any],
           let vol = status["volume"] as? Int {
            return (max(0, min(100, vol)), muted)
        }
        return nil
    }

    public static func friendlySourceName(forAppId appId: String) -> String {
        let lower = appId.lowercased()
        if lower.hasSuffix(".hdmi1") || lower == "hdmi_1" || lower == "hdmi1" { return "HDMI 1" }
        if lower.hasSuffix(".hdmi2") || lower == "hdmi_2" || lower == "hdmi2" { return "HDMI 2" }
        if lower.hasSuffix(".hdmi3") || lower == "hdmi_3" || lower == "hdmi3" { return "HDMI 3" }
        if lower.hasSuffix(".hdmi4") || lower == "hdmi_4" || lower == "hdmi4" { return "HDMI 4" }
        if lower.contains("youtube") { return "YouTube" }
        if lower.contains("netflix") { return "Netflix" }
        if lower.contains("bilibili") { return "Bilibili" }
        if lower.contains("apple") { return "Apple TV" }
        if lower.contains("disney") { return "Disney+" }
        if lower.contains("airplay") { return "AirPlay" }
        if lower.contains("livetv") { return "直播电视" }
        if lower.isEmpty { return "主页" }
        return appId.components(separatedBy: ".").last?.capitalized ?? appId
    }

    public static func appIdOrInput(forSourceLabel label: String) -> (isInput: Bool, id: String) {
        switch label.uppercased() {
        case "HDMI 1", "HDMI1", "HDMI_1": return (true, "HDMI_1")
        case "HDMI 2", "HDMI2", "HDMI_2": return (true, "HDMI_2")
        case "HDMI 3", "HDMI3", "HDMI_3": return (true, "HDMI_3")
        case "HDMI 4", "HDMI4", "HDMI_4": return (true, "HDMI_4")
        case "YOUTUBE": return (false, "youtube.leanback.v4")
        case "NETFLIX": return (false, "netflix")
        case "APPLE TV": return (false, "com.apple.appletv")
        case "AIRPLAY": return (false, "com.webos.app.homeconnect")
        default: return (false, label)
        }
    }

    /// Builds a standard 102-byte Wake-on-LAN magic packet (`0xFF * 6` followed by 16 repetitions of the 6-byte MAC).
    public static func wakeOnLanMagicPacket(macAddress: String) -> Data? {
        let hexParts = macAddress
            .replacingOccurrences(of: "-", with: ":")
            .split(separator: ":")
        guard hexParts.count == 6 else { return nil }
        var macBytes: [UInt8] = []
        macBytes.reserveCapacity(6)
        for part in hexParts {
            guard let byte = UInt8(part, radix: 16) else { return nil }
            macBytes.append(byte)
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return packet
    }

    /// Parses UPnP XML description returned by LG webOS TV (e.g. `http://192.168.1.50:1869/`).
    public static func parseUPnPDescription(xml: String, host: String) -> LGWebOSDiscoveredTV {
        func extractTag(_ tag: String) -> String? {
            guard let open = xml.range(of: "<\(tag)>"),
                  let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else {
                return nil
            }
            let raw = String(xml[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }
        let rawFriendly = extractTag("friendlyName") ?? "LG C2 电视"
        let cleanName = rawFriendly
            .replacingOccurrences(of: "[LG] webOS TV ", with: "LG C2 电视 · ")
            .replacingOccurrences(of: "[LG] ", with: "")
        let model = extractTag("modelNumber") ?? extractTag("modelName") ?? "OLED42C2PCA"
        let udn = extractTag("UDN")?.replacingOccurrences(of: "uuid:", with: "")
        return LGWebOSDiscoveredTV(
            host: host,
            friendlyName: cleanName.contains("OLED") ? "LG C2 电视" : cleanName,
            modelName: model,
            macAddress: nil,
            uuid: udn
        )
    }

    private static var signedManifest: [String: Any] {
        [
            "manifestVersion": 1,
            "appVersion": "1.1",
            "signed": [
                "created": "20140509",
                "appId": "com.lge.test",
                "vendorId": "com.lge",
                "localizedAppNames": [
                    "": "LG Remote App",
                    "ko-KR": "리모컨 앱",
                    "zxx-XX": "ЛГ Rэмotэ AПП"
                ],
                "localizedVendorNames": [
                    "": "LG Electronics"
                ],
                "permissions": [
                    "TEST_SECURE",
                    "CONTROL_INPUT_TEXT",
                    "CONTROL_MOUSE_AND_KEYBOARD",
                    "READ_INSTALLED_APPS",
                    "READ_LGE_SDX",
                    "READ_NOTIFICATIONS",
                    "SEARCH",
                    "WRITE_SETTINGS",
                    "WRITE_NOTIFICATION_ALERT",
                    "CONTROL_POWER",
                    "READ_CURRENT_CHANNEL",
                    "READ_RUNNING_APPS",
                    "READ_UPDATE_INFO",
                    "UPDATE_FROM_REMOTE_APP",
                    "READ_LGE_TV_INPUT_EVENTS",
                    "READ_TV_CURRENT_TIME"
                ],
                "serial": "2f930e2d2cfe083771f68e4fe7bb07"
            ],
            "permissions": [
                "LAUNCH",
                "LAUNCH_WEBAPP",
                "APP_TO_APP",
                "CLOSE",
                "TEST_OPEN",
                "TEST_PROTECTED",
                "CONTROL_AUDIO",
                "CONTROL_DISPLAY",
                "CONTROL_INPUT_JOYSTICK",
                "CONTROL_INPUT_MEDIA_RECORDING",
                "CONTROL_INPUT_MEDIA_PLAYBACK",
                "CONTROL_INPUT_TV",
                "CONTROL_POWER",
                "READ_APP_STATUS",
                "READ_CURRENT_CHANNEL",
                "READ_INPUT_DEVICE_LIST",
                "READ_NETWORK_STATE",
                "READ_RUNNING_APPS",
                "READ_TV_CHANNEL_LIST",
                "WRITE_NOTIFICATION_TOAST",
                "READ_POWER_STATE",
                "READ_COUNTRY_INFO",
                "READ_SETTINGS",
                "CONTROL_TV_SCREEN",
                "CONTROL_TV_POWER",
                "CONTROL_WOL"
            ]
        ]
    }
}

// MARK: - Self-Signed TLS Trust Delegate for LG webOS Port 3001

private final class LGWebOSTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        #if canImport(Darwin)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Live LG webOS SSAP Controller

public actor LGWebOSClient {
    private let logger = Logger(subsystem: "com.yangzhiyuan.MenuBarMijia", category: "LGWebOS")
    private var config: LGWebOSConfig
    private let session: URLSession
    private let onDeviceUpdated: @Sendable (SmartDevice) -> Void
    private let onClientKeyRegistered: @Sendable (String) -> Void

    private var loopTask: Task<Void, Never>?
    private var activeWebSocket: URLSessionWebSocketTask?
    private var nextRequestId: Int = 1

    private var isConnected: Bool = false
    private var isWaitingForPairing: Bool = false
    private var isScreenOff: Bool = false
    private var volumePercent: Int = 20
    private var isMuted: Bool = false
    private var currentSource: String = "HDMI 1"
    private var availableSources: [String] = ["HDMI 1", "HDMI 2", "HDMI 3", "HDMI 4"]
    private var modelName: String = "OLED42C2PCA"

    public init(
        config: LGWebOSConfig,
        onDeviceUpdated: @escaping @Sendable (SmartDevice) -> Void,
        onClientKeyRegistered: @escaping @Sendable (String) -> Void
    ) {
        self.config = config
        self.onDeviceUpdated = onDeviceUpdated
        self.onClientKeyRegistered = onClientKeyRegistered

        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.connectionProxyDictionary = [:]
        urlConfig.timeoutIntervalForRequest = 30
        urlConfig.waitsForConnectivity = false
        self.session = URLSession(configuration: urlConfig, delegate: LGWebOSTrustDelegate(), delegateQueue: nil)
    }

    public func start() {
        guard config.isEnabled, config.hasConfiguredHost else { return }
        emitCurrentDevice()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        activeWebSocket?.cancel(with: .goingAway, reason: nil)
        activeWebSocket = nil
    }

    public func updateConfig(_ newConfig: LGWebOSConfig) {
        self.config = newConfig
        stop()
        if newConfig.isEnabled && newConfig.hasConfiguredHost {
            start()
        }
    }

    public func triggerPairing() async {
        if let ws = activeWebSocket {
            let packet = LGWebOSProtocol.registrationPacket(id: "reg_manual", clientKey: config.clientKey)
            try? await ws.send(.string(packet))
        } else {
            start()
        }
    }

    // MARK: - Command Execution

    public func execute(_ command: DeviceCommand) async throws {
        switch command {
        case .setSwitch(let eid, let isOn):
            if eid == LGWebOSProtocol.powerEntityId {
                try await setPower(isOn: isOn)
            } else if eid == LGWebOSProtocol.muteEntityId {
                try await setMuted(isOn)
            } else if eid == LGWebOSProtocol.screenOffEntityId {
                try await setScreenOff(isOn)
            }

        case .mediaSetVolume(_, let level):
            let pct = max(0, min(100, Int((level * 100.0).rounded())))
            try await setVolume(percent: pct)

        case .mediaSelectSource(_, let source):
            try await selectSource(source)

        case .pressButton(let eid):
            if eid == LGWebOSProtocol.wakeButtonId {
                try await setPower(isOn: true)
            } else if eid == LGWebOSProtocol.pairButtonId {
                await triggerPairing()
            }

        default:
            break
        }
    }

    private func setPower(isOn: Bool) async throws {
        if isOn {
            Self.sendWakeOnLan(macAddress: config.macAddress, host: config.host)
            isConnected = true
            isScreenOff = false
            emitCurrentDevice()
            if let ws = activeWebSocket {
                let req = LGWebOSProtocol.ssapRequest(
                    id: nextId("screen_on"),
                    uri: "ssap://com.webos.service.tvpower/power/turnOnScreen",
                    payload: ["standbyMode": "active"]
                )
                try? await ws.send(.string(req))
            }
        } else {
            guard let ws = activeWebSocket else { return }
            let req = LGWebOSProtocol.ssapRequest(
                id: nextId("power_off"),
                uri: "ssap://system/turnOff"
            )
            try await ws.send(.string(req))
            isConnected = false
            isScreenOff = false
            emitCurrentDevice()
        }
    }

    private func setMuted(_ muted: Bool) async throws {
        guard let ws = activeWebSocket else { return }
        isMuted = muted
        emitCurrentDevice()
        let req = LGWebOSProtocol.ssapRequest(
            id: nextId("mute"),
            uri: "ssap://audio/setMute",
            payload: ["mute": muted]
        )
        try await ws.send(.string(req))
    }

    private func setScreenOff(_ off: Bool) async throws {
        guard let ws = activeWebSocket else { return }
        isScreenOff = off
        emitCurrentDevice()
        let uri = off
            ? "ssap://com.webos.service.tvpower/power/turnOffScreen"
            : "ssap://com.webos.service.tvpower/power/turnOnScreen"
        let req = LGWebOSProtocol.ssapRequest(
            id: nextId("screen"),
            uri: uri,
            payload: ["standbyMode": "active"]
        )
        try await ws.send(.string(req))
    }

    private func setVolume(percent: Int) async throws {
        guard let ws = activeWebSocket else { return }
        volumePercent = percent
        if percent > 0 { isMuted = false }
        emitCurrentDevice()
        let req = LGWebOSProtocol.ssapRequest(
            id: nextId("vol"),
            uri: "ssap://audio/setVolume",
            payload: ["volume": percent]
        )
        try await ws.send(.string(req))
    }

    private func selectSource(_ label: String) async throws {
        guard let ws = activeWebSocket else { return }
        currentSource = label
        emitCurrentDevice()
        let mapped = LGWebOSProtocol.appIdOrInput(forSourceLabel: label)
        if mapped.isInput {
            let req = LGWebOSProtocol.ssapRequest(
                id: nextId("input"),
                uri: "ssap://tv/switchInput",
                payload: ["inputId": mapped.id]
            )
            try await ws.send(.string(req))
        } else {
            let req = LGWebOSProtocol.ssapRequest(
                id: nextId("launch"),
                uri: "ssap://system.launcher/launch",
                payload: ["id": mapped.id]
            )
            try await ws.send(.string(req))
        }
    }

    // MARK: - Connection & Subscription Loop

    private func runConnectionLoop() async {
        while !Task.isCancelled && config.isEnabled && config.hasConfiguredHost {
            do {
                try await connectAndListen()
            } catch {
                isConnected = false
                isWaitingForPairing = false
                emitCurrentDevice()
            }
            try? await Task.sleep(for: .seconds(6))
        }
    }

    private func connectAndListen() async throws {
        guard let url = URL(string: "wss://\(config.host):3001/") else { return }
        let ws = session.webSocketTask(with: url)
        self.activeWebSocket = ws
        ws.resume()

        let reg = LGWebOSProtocol.registrationPacket(id: "register_0", clientKey: config.clientKey)
        try await ws.send(.string(reg))

        while !Task.isCancelled {
            let msg = try await ws.receive()
            let text: String = switch msg {
            case .string(let s): s
            case .data(let d): String(data: d, encoding: .utf8) ?? ""
            @unknown default: ""
            }
            guard !text.isEmpty else { continue }
            await handleIncomingMessage(text, ws: ws)
        }
    }

    private func handleIncomingMessage(_ text: String, ws: URLSessionWebSocketTask) async {
        let outcome = LGWebOSProtocol.parseRegistrationOutcome(text)
        switch outcome {
        case .promptPending:
            isConnected = true
            isWaitingForPairing = true
            emitCurrentDevice()
            return

        case .registered(let key):
            isConnected = true
            isWaitingForPairing = false
            if config.clientKey != key {
                config.clientKey = key
                onClientKeyRegistered(key)
            }
            emitCurrentDevice()
            await subscribeToLiveState(ws: ws)
            return

        case .error:
            isWaitingForPairing = false
            emitCurrentDevice()
            return

        case .ignored:
            break
        }

        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let payload = obj["payload"] as? [String: Any] else {
            return
        }

        if id.hasPrefix("sub_vol"), let volInfo = LGWebOSProtocol.parseVolumePayload(payload) {
            self.volumePercent = volInfo.volume
            self.isMuted = volInfo.muted
            self.isConnected = true
            emitCurrentDevice()
        } else if id.hasPrefix("sub_app"), let appId = payload["appId"] as? String, !appId.isEmpty {
            self.currentSource = LGWebOSProtocol.friendlySourceName(forAppId: appId)
            self.isConnected = true
            emitCurrentDevice()
        } else if id.hasPrefix("get_inputs"), let devices = payload["devices"] as? [[String: Any]] {
            var inputs: [String] = []
            for d in devices {
                if let label = d["label"] as? String, !label.isEmpty {
                    inputs.append(label)
                } else if let inputId = d["id"] as? String {
                    inputs.append(LGWebOSProtocol.friendlySourceName(forAppId: inputId))
                }
            }
            for extra in ["YouTube", "Netflix", "Apple TV"] where !inputs.contains(extra) {
                inputs.append(extra)
            }
            if !inputs.isEmpty {
                self.availableSources = inputs
                emitCurrentDevice()
            }
        }
    }

    private func subscribeToLiveState(ws: URLSessionWebSocketTask) async {
        let volSub = LGWebOSProtocol.ssapRequest(
            id: "sub_vol",
            uri: "ssap://audio/getVolume",
            type: "subscribe"
        )
        let appSub = LGWebOSProtocol.ssapRequest(
            id: "sub_app",
            uri: "ssap://com.webos.applicationManager/getForegroundAppInfo",
            type: "subscribe"
        )
        let inputsReq = LGWebOSProtocol.ssapRequest(
            id: "get_inputs",
            uri: "ssap://tv/getExternalInputList",
            type: "request"
        )
        try? await ws.send(.string(volSub))
        try? await ws.send(.string(appSub))
        try? await ws.send(.string(inputsReq))
    }

    private func emitCurrentDevice() {
        let hasMAC = !config.macAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let dev = SmartDevice(
            id: LGWebOSProtocol.deviceId,
            name: config.name,
            roomId: "ke_ting",
            roomName: config.roomName,
            model: modelName,
            isOnline: isConnected || hasMAC,
            kind: .tv(
                TVSpec(
                    mediaEntityId: LGWebOSProtocol.mediaEntityId,
                    state: isConnected ? "on" : "standby",
                    volumePercent: volumePercent,
                    isMuted: isMuted,
                    isScreenOff: isScreenOff,
                    isPairingPromptActive: isWaitingForPairing,
                    currentSource: currentSource,
                    availableSources: availableSources,
                    turnOnButtonId: LGWebOSProtocol.wakeButtonId
                )
            )
        )
        onDeviceUpdated(dev)
    }

    private func nextId(_ prefix: String) -> String {
        defer { nextRequestId &+= 1 }
        return "\(prefix)_\(nextRequestId)"
    }

    // MARK: - UDP Wake-on-LAN Dispatch

    public static func sendWakeOnLan(macAddress: String, host: String) {
        #if canImport(Darwin)
        guard let packet = LGWebOSProtocol.wakeOnLanMagicPacket(macAddress: macAddress) else { return }
        let sock = socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP))
        guard sock >= 0 else { return }
        defer { close(sock) }

        var broadcastEnable: Int32 = 1
        _ = setsockopt(
            sock,
            SOL_SOCKET,
            SO_BROADCAST,
            &broadcastEnable,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var targets = ["255.255.255.255", host]
        let octets = host.split(separator: ".")
        if octets.count == 4 {
            targets.append("\(octets[0]).\(octets[1]).\(octets[2]).255")
        }

        for ip in targets {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(9).bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
            packet.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        _ = sendto(sock, base, packet.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        #endif
    }

    public static func discoverOnLAN(hostHint: String = LGWebOSConfig.defaultHost) async -> [LGWebOSDiscoveredTV] {
        var candidates: [String] = []
        var seen: Set<String> = []
        let trimmedHint = hostHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHint.isEmpty, seen.insert(trimmedHint).inserted {
            candidates.append(trimmedHint)
        }
        let arpHosts = await Task.detached(priority: .utility) {
            HADiscovery.queryARPHosts()
        }.value
        for ip in arpHosts where seen.insert(ip).inserted {
            candidates.append(ip)
        }
        guard !candidates.isEmpty else { return [] }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 0.9
        config.timeoutIntervalForResource = 1.2
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        return await withTaskGroup(of: (Int, LGWebOSDiscoveredTV?).self) { group in
            for (idx, host) in candidates.enumerated() {
                group.addTask {
                    guard let url = URL(string: "http://\(host):1869/") else { return (idx, nil) }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 0.9
                    do {
                        let (data, _) = try await session.data(for: req)
                        if let xml = String(data: data, encoding: .utf8),
                           xml.contains("webOS") || xml.contains("LGE") {
                            return (idx, LGWebOSProtocol.parseUPnPDescription(xml: xml, host: host))
                        }
                    } catch {}
                    return (idx, nil)
                }
            }
            var found: [(Int, LGWebOSDiscoveredTV)] = []
            for await (idx, tv) in group {
                if let tv { found.append((idx, tv)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
