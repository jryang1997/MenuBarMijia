import Foundation
import os

// MARK: - Cloud Records

public struct MiDeviceRecord: Equatable, Sendable {
    public var did: String
    public var name: String
    public var model: String
    public var isOnline: Bool
    public var specType: String?

    public init(did: String, name: String, model: String, isOnline: Bool, specType: String? = nil) {
        self.did = did
        self.name = name
        self.model = model
        self.isOnline = isOnline
        self.specType = specType
    }
}

public struct MiRoom: Equatable, Sendable {
    public var id: String
    public var name: String
    public var dids: [String]

    public init(id: String, name: String, dids: [String]) {
        self.id = id
        self.name = name
        self.dids = dids
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

public enum MiCloudError: LocalizedError, Equatable, Sendable {
    case notLoggedIn
    case sessionExpired
    case http(Int)
    case api(code: Int, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "请在设置中扫码登录米家账号"
        case .sessionExpired: return "米家登录已过期，请重新扫码"
        case .http(let code): return "米家云服务 HTTP \(code)"
        case .api(let code, let message): return "米家云指令失败 (\(code))：\(message)"
        case .badResponse(let what): return "米家云响应异常：\(what)"
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
}

// MARK: - Live Client

public actor MiCloudClient: MiCloudAPI {
    private let logger = Logger(subsystem: "com.yangzhiyuan.MenuBarMijia", category: "MiCloud")
    private let session: MiSession
    private let transport: any MiHTTPTransport
    private let userAgent: String
    public static let propChunkSize = 100

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

    public func deviceList() async throws -> [MiDeviceRecord] {
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
            return MiDeviceRecord(
                did: did,
                name: item["name"]?.stringValue ?? model,
                model: model,
                isOnline: item["isOnline"]?.boolValue ?? true,
                specType: item["spec_type"]?.stringValue
            )
        }
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
            for room in home["roomlist"]?.arrayValue ?? [] {
                guard let id = room["id"]?.idString else { continue }
                rooms.append(MiRoom(
                    id: id,
                    name: room["name"]?.stringValue ?? "",
                    dids: (room["dids"]?.arrayValue ?? []).compactMap(\.idString)
                ))
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
        let result = try await request("miotspec/action", data: .object(["params": .object([
            "did": .string(call.did), "siid": .number(Double(call.siid)),
            "aiid": .number(Double(call.aiid)), "in": .array(call.inputs),
        ])]))
        try Self.checkWriteCodes([result])
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
}
