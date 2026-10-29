import CryptoKit
import Foundation
import Security

public struct QRLoginTicket: Equatable, Sendable {
    public let qrImageURL: URL
    public let loginURL: URL
    public let longPollURL: URL
    public let timeout: TimeInterval

    public init(qrImageURL: URL, loginURL: URL, longPollURL: URL, timeout: TimeInterval) {
        self.qrImageURL = qrImageURL
        self.loginURL = loginURL
        self.longPollURL = longPollURL
        self.timeout = timeout
    }
}

public struct MiSession: Codable, Equatable, Sendable {
    public var userId: String
    public var cUserId: String
    public var ssecurity: String
    public var serviceToken: String
    public var region: String

    public init(userId: String, cUserId: String, ssecurity: String, serviceToken: String, region: String = "cn") {
        self.userId = userId
        self.cUserId = cUserId
        self.ssecurity = ssecurity
        self.serviceToken = serviceToken
        self.region = region
    }

    /// `12****89` style mask so the UI can show which account is signed in without exposing the full id.
    public var maskedUserId: String {
        guard userId.count > 4 else { return String(repeating: "*", count: userId.count) }
        return "\(userId.prefix(2))****\(userId.suffix(2))"
    }

    /// Stable, non-reversible namespace identifier derived from the active session's region and full
    /// `userId`, so accounts sharing the same `maskedUserId` (e.g. `12345689` vs `12999989`) never
    /// collide while keeping the raw `userId` out of `UserDefaults`.
    public var historyScopeIdentifier: String {
        let normalizedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let effectiveRegion = normalizedRegion.isEmpty ? "cn" : normalizedRegion
        let digest = SHA256.hash(data: Data("\(effectiveRegion):\(userId)".utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "mi:\(effectiveRegion):\(hex)"
    }

    public var apiBaseURL: String {
        let r = region.lowercased()
        return r.isEmpty || r == "cn" ? "https://api.io.mi.com/app" : "https://\(r).api.io.mi.com/app"
    }
}

public enum MiLoginError: LocalizedError, Equatable, Sendable {
    case http(Int)
    case badResponse(String)
    case qrExpired
    case missingServiceToken

    public var errorDescription: String? {
        switch self {
        case .http(let code): return L10n.tr("小米账号服务返回 HTTP \(code)", "Xiaomi account service returned HTTP \(code)")
        case .badResponse(let what): return L10n.tr("小米账号服务响应异常：\(what)", "Invalid Xiaomi account response: \(what)")
        case .qrExpired: return L10n.tr("二维码已过期，请重新获取", "QR code expired; please refresh")
        case .missingServiceToken: return L10n.tr("登录成功但未拿到 serviceToken，请重试", "Signed in, but missing serviceToken; please retry")
        }
    }
}

/// Mi account QR login: get ticket → user scans in Mi Home → long-poll → exchange `location` for `serviceToken`.
public struct MiAccountLogin: Sendable {
    private let transport: any MiHTTPTransport
    private let redirectlessTransport: any MiHTTPTransport
    private let region: String
    private let pollRequestTimeout: TimeInterval

    public init(
        transport: any MiHTTPTransport = URLSessionMiTransport(),
        redirectlessTransport: (any MiHTTPTransport)? = nil,
        region: String = "cn",
        pollRequestTimeout: TimeInterval = 15
    ) {
        self.transport = transport
        self.redirectlessTransport = redirectlessTransport ?? URLSessionMiTransport(followRedirects: false)
        self.region = region
        self.pollRequestTimeout = pollRequestTimeout
    }

    public func start(now: Date = Date()) async throws -> QRLoginTicket {
        // `qs` is deliberately pre-encoded and then encoded again, exactly as the reference client sends it.
        let query = MiCloudCrypto.formURLEncode([
            ("_qrsize", "480"),
            ("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            ("callback", "https://sts.api.io.mi.com/sts"),
            ("_hasLogo", "false"),
            ("sid", "xiaomiio"),
            ("serviceParam", ""),
            ("_locale", "zh_CN"),
            ("_dc", String(Int64(now.timeIntervalSince1970 * 1000))),
        ])
        var req = URLRequest(url: URL(string: "https://account.xiaomi.com/longPolling/loginUrl?\(query)")!)
        req.httpMethod = "GET"
        let (data, http) = try await transport.send(req)
        guard http.statusCode == 200 else { throw MiLoginError.http(http.statusCode) }
        return try Self.parseTicket(data)
    }

    public static func parseTicket(_ data: Data) throws -> QRLoginTicket {
        guard let json = MiResponseText.parseJSON(data) else { throw MiLoginError.badResponse("非 JSON") }
        guard let qr = json["qr"]?.stringValue.flatMap(URL.init(string:)),
              let login = json["loginUrl"]?.stringValue.flatMap(URL.init(string:)),
              let lp = json["lp"]?.stringValue.flatMap(URL.init(string:)) else {
            let code = json["code"]?.idString ?? "?"
            throw MiLoginError.badResponse("缺少二维码字段 (code \(code))")
        }
        let timeout = json["timeout"]?.doubleValue ?? 300
        return QRLoginTicket(qrImageURL: qr, loginURL: login, longPollURL: lp, timeout: timeout)
    }

    /// Long-polls until the QR code is scanned and confirmed, then fetches the service token.
    /// Honors task cancellation (throws `CancellationError`).
    public func waitForScan(_ ticket: QRLoginTicket) async throws -> MiSession {
        let deadline = Date().addingTimeInterval(ticket.timeout)
        var scanned: ScanResult?
        while scanned == nil {
            try Task.checkCancellation()
            guard Date() < deadline else { throw MiLoginError.qrExpired }
            var req = URLRequest(url: ticket.longPollURL)
            req.timeoutInterval = pollRequestTimeout
            do {
                let (data, http) = try await transport.send(req)
                if http.statusCode == 200 {
                    scanned = try Self.parseScanResult(data)
                } else {
                    try await Task.sleep(for: .seconds(1))
                }
            } catch let error as URLError where error.code == .timedOut {
                continue
            }
        }
        let token = try await fetchServiceToken(location: scanned!.location)
        return MiSession(
            userId: scanned!.userId,
            cUserId: scanned!.cUserId,
            ssecurity: scanned!.ssecurity,
            serviceToken: token,
            region: region
        )
    }

    public struct ScanResult: Equatable, Sendable {
        public var userId: String
        public var cUserId: String
        public var ssecurity: String
        public var location: URL
    }

    public static func parseScanResult(_ data: Data) throws -> ScanResult {
        guard let json = MiResponseText.parseJSON(data) else { throw MiLoginError.badResponse("非 JSON") }
        guard let userId = json["userId"]?.idString,
              let ssecurity = json["ssecurity"]?.stringValue,
              let location = json["location"]?.stringValue.flatMap(URL.init(string:)) else {
            let code = json["code"]?.idString ?? "?"
            throw MiLoginError.badResponse("扫码结果缺少字段 (code \(code))")
        }
        return ScanResult(
            userId: userId,
            cUserId: json["cUserId"]?.idString ?? "",
            ssecurity: ssecurity,
            location: location
        )
    }

    private func fetchServiceToken(location: URL) async throws -> String {
        var url = location
        for _ in 0..<5 {
            var req = URLRequest(url: url)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let (_, http) = try await redirectlessTransport.send(req)
            if let token = Self.cookie(named: "serviceToken", in: http, url: url) {
                return token
            }
            guard (300...399).contains(http.statusCode),
                  let next = http.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0, relativeTo: url) }) else {
                break
            }
            url = next.absoluteURL
        }
        throw MiLoginError.missingServiceToken
    }

    static func cookie(named name: String, in response: HTTPURLResponse, url: URL) -> String? {
        var fields: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { fields[ks] = vs }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first { $0.name == name && !$0.value.isEmpty }?.value
    }
}

/// Keychain persistence for `MiSession` (service `com.jryang1997.MenuBarMijia`, account `mi_session`).
/// `.standard` stores the session only in the Keychain (#16); any other suite keeps a test-only copy in
/// `UserDefaults` so store tests never touch the real Keychain.
public enum MiSessionStore {
    static let keychainAccount = "mi_session"
    /// Test seam for non-`.standard` suites. ≤1.0.6 also wrote this key for `.standard`; startup migration moves
    /// that plaintext copy into the Keychain and deletes it (#16).
    public static let fallbackDefaultsKey = "mi_session_fallback_v1"
    /// The field name `JSONEncoder` writes for the account-level token that must not be persisted (#27).
    private static let passTokenField = Data("\"passToken\"".utf8)

    public static func load(defaults: UserDefaults = .standard) -> MiSession? {
        guard let data = storedData(defaults: defaults),
              let session = try? JSONDecoder().decode(MiSession.self, from: data) else { return nil }
        // A session saved by ≤1.0.6 still carries `passToken`; rewrite it without (#27, ADR-0004).
        if data.range(of: passTokenField) != nil, let stripped = try? JSONEncoder().encode(session) {
            store(stripped, defaults: defaults)
        }
        return session
    }

    @discardableResult
    public static func save(_ session: MiSession, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        return store(data, defaults: defaults)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: fallbackDefaultsKey)
        guard defaults === UserDefaults.standard else { return }
        KeychainHelper.deleteKeychainItem(account: keychainAccount)
    }

    /// Re-encodes a ≤1.0.6 `UserDefaults` session for the Keychain, dropping the `passToken` it carried
    /// (#27). Returns nil when the legacy data cannot be decoded.
    static func migratedData(fromLegacyDefaults data: Data) -> Data? {
        guard let session = try? JSONDecoder().decode(MiSession.self, from: data) else { return nil }
        return try? JSONEncoder().encode(session)
    }

    private static func storedData(defaults: UserDefaults) -> Data? {
        guard defaults === UserDefaults.standard else {
            return defaults.data(forKey: fallbackDefaultsKey)
        }
        return KeychainHelper.readKeychainData(account: keychainAccount)
    }

    /// `data` is already re-encoded through `MiSession`, so no `passToken` reaches the store.
    @discardableResult
    private static func store(_ data: Data, defaults: UserDefaults) -> Bool {
        guard defaults === UserDefaults.standard else {
            defaults.set(data, forKey: fallbackDefaultsKey)
            return true
        }
        // The vault item itself is `AfterFirstUnlockThisDeviceOnly`, so the session stays off backups.
        let written = KeychainHelper.writeKeychainData(data, account: keychainAccount)
        guard written else { return false }
        // The plaintext mirror is gone (#16): the Keychain is the only store.
        defaults.removeObject(forKey: fallbackDefaultsKey)
        return true
    }
}
