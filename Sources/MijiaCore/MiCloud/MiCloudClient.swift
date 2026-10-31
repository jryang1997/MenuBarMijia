import Foundation
import os

// MARK: - Cloud Records

public struct MiDeviceRecord: Equatable, Sendable {
    public var did: String
    public var name: String
    public var model: String
    public var isOnline: Bool
    public var specType: String?
    /// Set on a split key of a multi-key panel (did like `<parent>.s2`): MIoT reads and writes
    /// go to the parent did, limited to the switch service `splitSiid`.
    public var splitParentDid: String?
    public var splitSiid: Int?
    public var localIp: String?

    public init(did: String, name: String, model: String, isOnline: Bool, specType: String? = nil,
                splitParentDid: String? = nil, splitSiid: Int? = nil, localIp: String? = nil) {
        self.did = did
        self.name = name
        self.model = model
        self.isOnline = isOnline
        self.specType = specType
        self.splitParentDid = splitParentDid
        self.splitSiid = splitSiid
        self.localIp = localIp
    }

    /// The did MIoT property and action calls address.
    public var miotDid: String { splitParentDid ?? did }
}

public struct MiRoom: Equatable, Sendable {
    public var id: String
    public var name: String
    public var dids: [String]
    public var homeId: String
    public var homeName: String

    public init(id: String, name: String, dids: [String], homeId: String = "", homeName: String = "") {
        self.id = id
        self.name = name
        self.dids = dids
        self.homeId = homeId
        self.homeName = homeName
    }
}

public struct MiotPropKey: Hashable, Sendable {
    public var did: String
    public var siid: Int
    public var piid: Int

    public init(did: String, siid: Int, piid: Int) {
        self.did = did
        self.siid = siid
        self.piid = piid
    }
}

public struct MiotPropWrite: Equatable, Sendable {
    public var did: String
    public var siid: Int
    public var piid: Int
    public var value: JSONValue

    public init(did: String, siid: Int, piid: Int, value: JSONValue) {
        self.did = did
        self.siid = siid
        self.piid = piid
        self.value = value
    }
}

public struct MiotActionCall: Equatable, Sendable {
    public var did: String
    public var siid: Int
    public var aiid: Int
    public var inputs: [JSONValue]

    public init(did: String, siid: Int, aiid: Int, inputs: [JSONValue] = []) {
        self.did = did
        self.siid = siid
        self.aiid = aiid
        self.inputs = inputs
    }
}

public struct MiCameraP2PVendor: Equatable, Sendable {
    public var vendorName: String
    public var p2pId: String?
    public var devicePublicKey: String
    public var sign: String

    public init(vendorName: String, p2pId: String? = nil, devicePublicKey: String, sign: String) {
        self.vendorName = vendorName
        self.p2pId = p2pId
        self.devicePublicKey = devicePublicKey
        self.sign = sign
    }
}

public enum MiCloudError: LocalizedError, Equatable, Sendable {
    case notLoggedIn
    case sessionExpired
    case http(Int)
    case api(code: Int, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return L10n.tr("请在设置中扫码登录米家账号", "Scan QR code in Settings to sign in to Xiaomi Home")
        case .sessionExpired: return L10n.tr("米家登录已过期，请重新扫码", "Xiaomi Home session expired; please scan again")
        case .http(429): return L10n.tr("米家云提示请求太频繁，已放慢刷新，稍后自动重试", "Xiaomi Cloud is rate limiting; refreshing less often and retrying later")
        case .http(let code): return L10n.tr("米家云服务 HTTP \(code)", "Xiaomi Cloud HTTP \(code)")
        case .api(let code, let message): return L10n.tr("米家云指令失败 (\(code))：\(message)", "Xiaomi Cloud command failed (\(code)): \(message)")
        case .badResponse(let what): return L10n.tr("米家云响应异常：\(what)", "Invalid Xiaomi Cloud response: \(what)")
        }
    }
}

// MARK: - API Seam

public protocol MiCloudAPI: Sendable {
    func deviceList() async throws -> [MiDeviceRecord]
    func homeRooms() async throws -> [MiRoom]
    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue]
    func setProps(_ writes: [MiotPropWrite]) async throws
    func action(_ call: MiotActionCall) async throws
    func callAction(_ call: MiotActionCall) async throws -> JSONValue
    func sensorHistory(
        did: String,
        temperatureKey: String?,
        humidityKey: String?,
        window: SensorHistoryWindow,
        now: Date
    ) async throws -> [SensorHistorySample]
    func cameraLocalIP(did: String) async throws -> String?
    func cameraP2PVendor(did: String, appPublicKey: String) async throws -> MiCameraP2PVendor
}

extension MiCloudAPI {
    public func callAction(_ call: MiotActionCall) async throws -> JSONValue {
        try await action(call)
        return .null
    }
    public func sensorHistory(
        did: String,
        temperatureKey: String?,
        humidityKey: String?,
        window: SensorHistoryWindow,
        now: Date
    ) async throws -> [SensorHistorySample] {
        []
    }
    public func cameraLocalIP(did: String) async throws -> String? {
        nil
    }
    public func cameraP2PVendor(did: String, appPublicKey: String) async throws -> MiCameraP2PVendor {
        MiCameraP2PVendor(vendorName: "cs2", p2pId: nil, devicePublicKey: "", sign: "")
    }
}

// MARK: - Live Client

public actor MiCloudClient: MiCloudAPI {
    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "MiCloud")
    private let session: MiSession
    private let transport: any MiHTTPTransport
    private let userAgent: String
    public static let propChunkSize = 100
    private var resolvedHistoryRouteByMetric: [String: HistoryRoute] = [:]

    private struct HistoryRoute: Equatable, Sendable {
        enum Endpoint: Equatable, Sendable {
            case statistics
            case deviceData(group: String?)
        }
        var endpoint: Endpoint
        var key: String
    }

    public init(session: MiSession, transport: any MiHTTPTransport = URLSessionMiTransport()) {
        self.session = session
        self.transport = transport
        self.userAgent = Self.makeUserAgent()
    }

    static func makeUserAgent() -> String {
        let lower = Array("abcdefghijklmnopqrstuvwxyz")
        let upper = Array("ABCDE")
        let a = String((0..<18).map { _ in lower.randomElement()! })
        let b = String((0..<13).map { _ in upper.randomElement()! })
        return "\(a)-\(b) APP/com.xiaomi.mihome APPV/10.5.201"
    }

    /// Signed RC4 POST to `<apiBase>/<api>`; returns the decrypted `result` payload.
    public func request(_ api: String, data: JSONValue) async throws -> JSONValue {
        let path = "/" + api.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: session.apiBaseURL + path) else { throw MiCloudError.badResponse("URL") }
        let nonce = MiCloudCrypto.makeNonce()
        let signed = try MiCloudCrypto.signedNonce(ssecurity: session.ssecurity, nonce: nonce)
        let fields = try MiCloudCrypto.encryptParams(path: path, data: data.compactJSONString, ssecurity: session.ssecurity, nonce: nonce)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("PROTOCAL-HTTP2", forHTTPHeaderField: "x-xiaomi-protocal-flag-cli")
        req.setValue("ENCRYPT-RC4", forHTTPHeaderField: "MIOT-ENCRYPT-ALGORITHM")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        req.httpBody = Data(MiCloudCrypto.formURLEncode(fields).utf8)

        let (body, http) = try await transport.send(req)
        do {
            return try Self.decodeResponse(body, statusCode: http.statusCode, signedNonce: signed)
        } catch let error as MiCloudError {
            logger.error("\(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func cookieHeader() -> String {
        [
            ("userId", session.userId),
            ("serviceToken", session.serviceToken),
            ("yetAnotherServiceToken", session.serviceToken),
            ("locale", "zh_CN"),
            ("timezone", "GMT+08:00"),
            ("is_daylight", "0"),
            ("dst_offset", "0"),
            ("channel", "MI_APP_STORE"),
        ].map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    static func decodeResponse(_ body: Data, statusCode: Int, signedNonce: String) throws -> JSONValue {
        if statusCode == 401 || statusCode == 403 { throw MiCloudError.sessionExpired }
        // Errors come back as plain JSON; successes are base64(RC4(json)).
        if let plain = try? JSONDecoder().decode(JSONValue.self, from: body), case .object = plain {
            return try unwrapResult(plain)
        }
        guard statusCode == 200 else { throw MiCloudError.http(statusCode) }
        guard let text = String(data: body, encoding: .utf8),
              let decrypted = try? MiCloudCrypto.decryptResponse(text, signedNonce: signedNonce),
              let json = try? JSONDecoder().decode(JSONValue.self, from: decrypted) else {
            throw MiCloudError.badResponse("无法解密")
        }
        return try unwrapResult(json)
    }

    static func unwrapResult(_ json: JSONValue) throws -> JSONValue {
        let code = json["code"]?.intValue ?? 0
        let message = json["message"]?.stringValue ?? json["desc"]?.stringValue ?? ""
        if code == 0 { return json["result"] ?? .null }
        let lower = message.lowercased()
        if code == 2 || code == 3
            || lower.contains("auth err")
            || lower.contains("servicetoken_expired")
            || lower.contains("token expired")
            || lower.contains("invalid signature") {
            throw MiCloudError.sessionExpired
        }
        throw MiCloudError.api(code: code, message: message)
    }

    // MARK: Endpoints

    /// `v2/home/device_list_page` also returns the split keys of multi-key Mesh panels, which
    /// `home/device_list` omits even with `get_split_device`; fall back to the latter on failure.
    public func deviceList() async throws -> [MiDeviceRecord] {
        do {
            return try await deviceListPaged()
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            return try await legacyDeviceList()
        }
    }

    private func deviceListPaged() async throws -> [MiDeviceRecord] {
        var records: [MiDeviceRecord] = []
        var startDid = ""
        for _ in 0..<20 {
            var data: [String: JSONValue] = [
                "get_split_device": .bool(true),
                "support_smart_home": .bool(true),
                "limit": .number(200),
            ]
            if !startDid.isEmpty { data["start_did"] = .string(startDid) }
            let result = try await request("v2/home/device_list_page", data: .object(data))
            records += Self.parseDeviceList(result)
            let next = result["next_start_did"]?.idString ?? ""
            guard result["has_more"]?.boolValue == true, !next.isEmpty, next != startDid else { break }
            startDid = next
        }
        var seen: Set<String> = []
        return records.filter { seen.insert($0.did).inserted }
    }

    private func legacyDeviceList() async throws -> [MiDeviceRecord] {
        let result = try await request("home/device_list", data: .object([
            "getVirtualModel": .bool(true),
            "getHuamiDevices": .number(1),
            "get_split_device": .bool(false),
            "support_smart_home": .bool(true),
        ]))
        return Self.parseDeviceList(result)
    }

    static func parseDeviceList(_ result: JSONValue) -> [MiDeviceRecord] {
        (result["list"]?.arrayValue ?? []).compactMap { item in
            guard let did = item["did"]?.idString, let model = item["model"]?.stringValue else { return nil }
            let split = item["extra"]?["split"]
            return MiDeviceRecord(
                did: did,
                name: item["name"]?.stringValue ?? model,
                model: model,
                isOnline: item["isOnline"]?.boolValue ?? true,
                specType: item["spec_type"]?.stringValue,
                splitParentDid: split?["parentId"]?.idString,
                splitSiid: split?["moduleId"]?.intValue,
                localIp: item["localip"]?.stringValue
            )
        }
    }

    public func cameraLocalIP(did: String) async throws -> String? {
        let records = try await legacyDeviceList()
        return records.first(where: { $0.did == did || $0.miotDid == did })?.localIp
    }

    public func cameraP2PVendor(did: String, appPublicKey: String) async throws -> MiCameraP2PVendor {
        let result = try await request("v2/device/miss_get_vendor", data: .object([
            "did": .string(did),
            "app_pubkey": .string(appPublicKey),
            "support_vendors": .string("TUTK_CS2_MTP"),
        ]))
        let vendorObj = result["vendor"]
        let vendorId = vendorObj?["vendor"]?.intValue ?? 4
        let vendorName: String
        switch vendorId {
        case 1: vendorName = "tutk"
        case 4: vendorName = "cs2"
        default: vendorName = String(vendorId)
        }
        let p2pId = vendorObj?["vendor_params"]?["p2p_id"]?.stringValue
        let devicePublic = result["public_key"]?.stringValue ?? ""
        let sign = result["sign"]?.stringValue ?? ""
        return MiCameraP2PVendor(
            vendorName: vendorName,
            p2pId: p2pId,
            devicePublicKey: devicePublic,
            sign: sign
        )
    }

    public func homeRooms() async throws -> [MiRoom] {
        let merged: JSONValue
        do {
            merged = try await request("v2/homeroom/gethome_merged", data: .object([
                "fg": .bool(true), "fetch_share": .bool(true), "fetch_share_dev": .bool(true),
                "limit": .number(300), "app_ver": .number(7), "plat_form": .number(0),
            ]))
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            merged = try await request("v2/homeroom/gethome", data: .object([
                "fg": .bool(true), "fetch_share": .bool(true), "fetch_share_dev": .bool(true),
                "limit": .number(300), "app_ver": .number(7),
            ]))
        }
        return Self.parseRooms(merged)
    }

    static func parseRooms(_ result: JSONValue) -> [MiRoom] {
        var rooms: [MiRoom] = []
        for home in result["homelist"]?.arrayValue ?? [] {
            let homeId = home["id"]?.idString ?? ""
            let homeName = home["name"]?.stringValue ?? ""
            for room in home["roomlist"]?.arrayValue ?? [] {
                guard let id = room["id"]?.idString else { continue }
                rooms.append(MiRoom(
                    id: id,
                    name: room["name"]?.stringValue ?? "",
                    dids: (room["dids"]?.arrayValue ?? []).compactMap(\.idString),
                    homeId: homeId,
                    homeName: homeName
                ))
            }
            // Devices assigned to the home but no room; the empty name lands them in 全屋.
            let homeDids = (home["dids"]?.arrayValue ?? []).compactMap(\.idString)
            if !homeDids.isEmpty {
                rooms.append(MiRoom(id: "home_\(homeId)", name: "", dids: homeDids, homeId: homeId, homeName: homeName))
            }
        }
        return rooms
    }

    public func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        var values: [MiotPropKey: JSONValue] = [:]
        var start = 0
        while start < keys.count {
            let chunk = keys[start..<min(start + Self.propChunkSize, keys.count)]
            start += Self.propChunkSize
            let params: [JSONValue] = chunk.map {
                .object(["did": .string($0.did), "siid": .number(Double($0.siid)), "piid": .number(Double($0.piid))])
            }
            let result = try await request("miotspec/prop/get", data: .object(["params": .array(params)]))
            values.merge(Self.parsePropValues(result)) { _, new in new }
        }
        return values
    }

    static func parsePropValues(_ result: JSONValue) -> [MiotPropKey: JSONValue] {
        var values: [MiotPropKey: JSONValue] = [:]
        for item in result.arrayValue ?? [] {
            guard let did = item["did"]?.idString,
                  let siid = item["siid"]?.intValue,
                  let piid = item["piid"]?.intValue,
                  (item["code"]?.intValue ?? 0) == 0,
                  let value = item["value"] else { continue }
            values[MiotPropKey(did: did, siid: siid, piid: piid)] = value
        }
        return values
    }

    public func setProps(_ writes: [MiotPropWrite]) async throws {
        let params: [JSONValue] = writes.map {
            .object([
                "did": .string($0.did), "siid": .number(Double($0.siid)),
                "piid": .number(Double($0.piid)), "value": $0.value,
            ])
        }
        let result = try await request("miotspec/prop/set", data: .object(["params": .array(params)]))
        try Self.checkWriteCodes(result.arrayValue ?? [])
    }

    public func action(_ call: MiotActionCall) async throws {
        _ = try await callAction(call)
    }

    public func callAction(_ call: MiotActionCall) async throws -> JSONValue {
        let result = try await request("miotspec/action", data: .object(["params": .object([
            "did": .string(call.did), "siid": .number(Double(call.siid)),
            "aiid": .number(Double(call.aiid)), "in": .array(call.inputs),
        ])]))
        try Self.checkWriteCodes([result])
        return result
    }

    /// MIoT per-item codes: 0 = done, 1 = accepted (async); negatives are device/gateway errors such as -704042011 (offline).
    static func checkWriteCodes(_ items: [JSONValue]) throws {
        for item in items {
            let code = item["code"]?.intValue ?? 0
            if code < 0 {
                throw MiCloudError.api(code: code, message: "设备未响应或离线")
            }
        }
    }

    // MARK: - Sensor History (`v2/user/statistics` + `user/get_user_device_data`)

    public struct MetricSamplePoint: Equatable, Sendable {
        public let timestamp: Date
        public let value: Double
        public let minValue: Double
        public let maxValue: Double

        public init(timestamp: Date, value: Double, minValue: Double? = nil, maxValue: Double? = nil) {
            self.timestamp = timestamp
            self.value = value
            self.minValue = minValue ?? value
            self.maxValue = maxValue ?? value
        }
    }

    public func sensorHistory(
        did: String,
        temperatureKey: String?,
        humidityKey: String?,
        window: SensorHistoryWindow,
        now: Date
    ) async throws -> [SensorHistorySample] {
        let timeEnd = Int(now.timeIntervalSince1970)
        let spanSeconds = window == .last24Hours ? 25 * 3600 : 8 * 86400
        let timeStart = max(0, timeEnd - spanSeconds)

        let tempPoints = try await fetchMetricSeries(
            did: did,
            miotKey: temperatureKey,
            isTemperature: true,
            window: window,
            timeStart: timeStart,
            timeEnd: timeEnd
        )
        let humPoints = try await fetchMetricSeries(
            did: did,
            miotKey: humidityKey,
            isTemperature: false,
            window: window,
            timeStart: timeStart,
            timeEnd: timeEnd
        )
        return Self.combineMetricSeries(temperature: tempPoints, humidity: humPoints)
    }

    private func fetchMetricSeries(
        did: String,
        miotKey: String?,
        isTemperature: Bool,
        window: SensorHistoryWindow,
        timeStart: Int,
        timeEnd: Int
    ) async throws -> [MetricSamplePoint] {
        let cacheId = "\(did)|\(isTemperature ? "temp" : "hum")|\(window.rawValue)"
        if let cachedRoute = resolvedHistoryRouteByMetric[cacheId] {
            let pts = try await queryHistoryRoute(
                cachedRoute,
                did: did,
                isTemperature: isTemperature,
                window: window,
                timeStart: timeStart,
                timeEnd: timeEnd
            )
            if !pts.isEmpty { return pts }
        }

        let statCandidates = Self.candidateKeysForStatistics(miotKey: miotKey, isTemperature: isTemperature)
        for key in statCandidates {
            let route = HistoryRoute(endpoint: .statistics, key: key)
            let pts = try await queryHistoryRoute(
                route,
                did: did,
                isTemperature: isTemperature,
                window: window,
                timeStart: timeStart,
                timeEnd: timeEnd
            )
            if !pts.isEmpty {
                resolvedHistoryRouteByMetric[cacheId] = route
                return pts
            }
        }

        let dataCandidates = Self.candidateKeysForDeviceData(miotKey: miotKey, isTemperature: isTemperature)
        let groups: [String?] = [window == .last24Hours ? "hour" : "day", "raw"]
        for group in groups {
            for key in dataCandidates {
                let route = HistoryRoute(endpoint: .deviceData(group: group), key: key)
                let pts = try await queryHistoryRoute(
                    route,
                    did: did,
                    isTemperature: isTemperature,
                    window: window,
                    timeStart: timeStart,
                    timeEnd: timeEnd
                )
                if !pts.isEmpty {
                    resolvedHistoryRouteByMetric[cacheId] = route
                    return pts
                }
            }
        }
        return []
    }

    private func queryHistoryRoute(
        _ route: HistoryRoute,
        did: String,
        isTemperature: Bool,
        window: SensorHistoryWindow,
        timeStart: Int,
        timeEnd: Int
    ) async throws -> [MetricSamplePoint] {
        do {
            let result: JSONValue
            switch route.endpoint {
            case .statistics:
                let dataType = window == .last24Hours ? "stat_hour_v3" : "stat_day_v3"
                let limit = window == .last24Hours ? 48 : 14
                result = try await request("v2/user/statistics", data: .object([
                    "did": .string(did),
                    "key": .string(route.key),
                    "data_type": .string(dataType),
                    "time_start": .number(Double(timeStart)),
                    "time_end": .number(Double(timeEnd)),
                    "limit": .number(Double(limit)),
                ]))
            case .deviceData(let group):
                var payload: [String: JSONValue] = [
                    "uid": .string(session.userId),
                    "did": .string(did),
                    "type": .string("prop"),
                    "key": .string(route.key),
                    "time_start": .number(Double(timeStart)),
                    "time_end": .number(Double(timeEnd)),
                    "limit": .number(group == "raw" ? 200 : 48),
                ]
                if let group {
                    payload["group"] = .string(group)
                }
                result = try await request("user/get_user_device_data", data: .object(payload))
            }
            return Self.parseHistoryMetricPoints(result, key: route.key, isTemperature: isTemperature)
        } catch MiCloudError.sessionExpired {
            throw MiCloudError.sessionExpired
        } catch {
            return []
        }
    }

    static func candidateKeysForStatistics(miotKey: String?, isTemperature: Bool) -> [String] {
        var keys: [String] = []
        if let miotKey, !miotKey.isEmpty {
            keys.append(miotKey)
        } else {
            keys.append(isTemperature ? "2.1" : "2.2")
        }
        keys.append(isTemperature ? "4c01" : "4c08")
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    static func candidateKeysForDeviceData(miotKey: String?, isTemperature: Bool) -> [String] {
        var keys: [String] = []
        if let miotKey, !miotKey.isEmpty {
            keys.append(miotKey)
            keys.append("prop.\(miotKey)")
        }
        if isTemperature {
            keys += ["4c01", "4100", "1004", "temperature"]
        } else {
            keys += ["4c08", "4102", "1006", "humidity", "relative-humidity"]
        }
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    /// Parses Xiaomi Cloud `v2/user/statistics` or `user/get_user_device_data` responses into time-sorted points.
    public static func parseHistoryMetricPoints(
        _ result: JSONValue,
        key: String,
        isTemperature: Bool
    ) -> [MetricSamplePoint] {
        let items: [JSONValue]
        if let array = result.arrayValue {
            items = array
        } else if let nested = result["list"]?.arrayValue ?? result["data"]?.arrayValue ?? result["result"]?.arrayValue {
            items = nested
        } else {
            return []
        }

        var points: [MetricSamplePoint] = []
        points.reserveCapacity(items.count)

        for item in items {
            guard let rawTime = item["time"]?.doubleValue ?? item["timestamp"]?.doubleValue,
                  rawTime > 0,
                  let rawValue = item["value"] else { continue }
            let seconds = rawTime > 10_000_000_000 ? rawTime / 1000.0 : rawTime
            let decoded = decodeHistoryValues(rawValue, key: key, isTemperature: isTemperature)
            guard !decoded.isEmpty else { continue }
            let lo = decoded.min()!
            let hi = decoded.max()!
            let avg = ((decoded.reduce(0, +) / Double(decoded.count)) * 10).rounded() / 10
            points.append(MetricSamplePoint(
                timestamp: Date(timeIntervalSince1970: seconds),
                value: avg,
                minValue: lo,
                maxValue: hi
            ))
        }
        points.sort { $0.timestamp < $1.timestamp }
        return points
    }

    private struct ExtractedHistoryNumber {
        let value: Double
        /// `true` when the value was already converted from a hex representation (e.g. `Int16` tenths
        /// or `Float32` bytes) or parsed from a decimal string with a fractional point, so it must
        /// not be divided by 10 again.
        let isPreScaled: Bool
    }

    static func decodeHistoryValues(_ raw: JSONValue, key: String, isTemperature: Bool) -> [Double] {
        let extracted = extractRawNumbers(raw, key: key)
        let usesTenthsScale = ["4100", "4102", "1004", "1006"].contains(key.lowercased())
        return extracted.compactMap { item -> Double? in
            guard item.value.isFinite else { return nil }
            var adjusted = item.value
            if usesTenthsScale, !item.isPreScaled {
                adjusted /= 10.0
            }
            if isTemperature {
                return SensorHistory.sanitizeTemperature(adjusted)
            } else {
                return SensorHistory.sanitizeHumidity(adjusted)
            }
        }
    }

    private static func extractRawNumbers(_ raw: JSONValue, key: String) -> [ExtractedHistoryNumber] {
        switch raw {
        case .number(let d):
            return [ExtractedHistoryNumber(value: d, isPreScaled: d.rounded() != d)]
        case .array(let arr):
            return arr.flatMap { extractRawNumbers($0, key: key) }
        case .object(let obj):
            if let v = obj["avg"] ?? obj["value"] ?? obj["temp"] ?? obj["humidity"] {
                return extractRawNumbers(v, key: key)
            }
            return []
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !trimmed.isEmpty else { return [] }
            if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) || (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")),
               let data = trimmed.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return extractRawNumbers(parsed, key: key)
            }
            let lowerKey = key.lowercased()
            if (lowerKey == "4c01" || lowerKey == "4c08"),
               let floatVal = decodeLittleEndianFloat32Hex(trimmed) {
                return [ExtractedHistoryNumber(value: floatVal, isPreScaled: true)]
            }
            if ["4100", "4102", "1004", "1006"].contains(lowerKey),
               trimmed.range(of: ".", options: .literal) == nil,
               let int16Tenths = decodeLittleEndianInt16Hex(trimmed) {
                return [ExtractedHistoryNumber(value: int16Tenths, isPreScaled: true)]
            }
            if let d = Double(trimmed) {
                let hasDecimalPoint = trimmed.contains(".")
                return [ExtractedHistoryNumber(value: d, isPreScaled: hasDecimalPoint || d.rounded() != d)]
            }
            if let floatVal = decodeLittleEndianFloat32Hex(trimmed) {
                return [ExtractedHistoryNumber(value: floatVal, isPreScaled: true)]
            }
            return []
        case .bool, .null:
            return []
        }
    }

    /// Decodes an 8-character hex string (e.g. `"cdccbc41"` from MiBeacon v5 `0x4C01`/`0x4C08`) as a
    /// little-endian IEEE 754 `Float32`.
    static func decodeLittleEndianFloat32Hex(_ hex: String) -> Double? {
        guard hex.count == 8, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        var idx = hex.startIndex
        for _ in 0..<4 {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let f = Float(bitPattern: bits)
        guard f.isFinite else { return nil }
        return ((Double(f) * 10).rounded()) / 10
    }

    /// Decodes a 4-character hex string containing at least one a-f hex letter (or little-endian high byte `00`–`03`)
    /// as a little-endian `Int16` scaled by 0.1 (MiBeacon v2/v3 `0x1004`/`0x1006`).
    /// Excludes `"1000"` so a decimal 100.0% humidity reading (`1000` tenths) is not misread as `0x0010` (`1.6%`).
    static func decodeLittleEndianInt16Hex(_ hex: String) -> Double? {
        guard hex.count == 4, hex != "1000", hex.allSatisfy(\.isHexDigit) else { return nil }
        let hasHexLetter = hex.contains { ("a"..."f").contains($0.lowercased()) }
        let hasValidLittleEndianHighByte = hex.hasSuffix("00") || hex.hasSuffix("01") || hex.hasSuffix("02") || hex.hasSuffix("03")
        guard hasHexLetter || hasValidLittleEndianHighByte else { return nil }
        let b0 = UInt8(hex.prefix(2), radix: 16)
        let b1 = UInt8(hex.suffix(2), radix: 16)
        guard let b0, let b1 else { return nil }
        let raw = Int16(bitPattern: UInt16(b0) | (UInt16(b1) << 8))
        return Double(raw) / 10.0
    }

    static func combineMetricSeries(
        temperature: [MetricSamplePoint],
        humidity: [MetricSamplePoint]
    ) -> [SensorHistorySample] {
        var samples: [SensorHistorySample] = []
        samples.reserveCapacity(temperature.count + humidity.count)
        for pt in temperature {
            samples.append(SensorHistorySample(
                timestamp: pt.timestamp,
                temperature: pt.value,
                minTemperature: pt.minValue,
                maxTemperature: pt.maxValue
            ))
        }
        for pt in humidity {
            samples.append(SensorHistorySample(
                timestamp: pt.timestamp,
                humidity: pt.value,
                minHumidity: pt.minValue,
                maxHumidity: pt.maxValue
            ))
        }
        return samples
    }
}
