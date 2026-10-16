import Foundation
import Testing
@testable import MijiaCore

// Vectors produced by a pure-Python RC4 + hashlib reimplementation of the reference client
// (scratch/vectors.py), so the Swift crypto is checked against an independent implementation.
private enum Vectors {
    static let ssecurity = "AQIDBAUGBwgJCgsMDQ4PEA=="
    static let nonce = "oLHC0+T1BhcBuoFA"
    static let signedNonce = "stUjEBQF1H9IaiRGtgWr8jmxbmJs3Xg11OVxJJfJqUI="
    static let path = "/home/device_list"
    static let data = #"{"getVirtualModel":true,"getHuamiDevices":1}"#
    static let rc4HashPlain = "+wnR7pbXbANBJTdJEKPTx32/8jc="
    static let encData = "zQrgJvr34Xp4b97kO7lmB2GNcU1GhZGWLZUbXNz8fHxrLnNVOUaIiX1/Sl4="
    static let encRc4Hash = "nV/pEbnR6lBuW/HKPIJmKEjkG21Mw8aVN5gdFQ=="
    static let signature = "p4PJO1KloBVLQOZqU31Nl4ZPq4s="
    static let respPlain = #"{"code":0,"message":"ok","result":{"list":[{"did":"123","name":"灯","model":"yeelink.light.ceiling22","isOnline":true}]}}"#
    static let respCipher = "zQrkLOrEqjI8Np3lE6VxA2rKaQMWn5+YI9AMTef8cWUgUG0BPEyejn1/IFij2TGz+h6YR3qdIdDNGAZ38HVVeV7I/xFX7t70RZzHM/zsDtMelQgGK0XRgzlsFk4++2JAP/M/aXlqdpyZpKwhzYQ/MJ7bXSF2VIsJkgg="
}

struct MiCloudCryptoTests {
    @Test("RC4 without drop matches the classic Key/Plaintext vector")
    func rc4ClassicVector() {
        var rc4 = MiCloudCrypto.RC4(key: Array("Key".utf8), drop: 0)
        let out = rc4.process(Array("Plaintext".utf8))
        #expect(out.map { String(format: "%02x", $0) }.joined() == "bbf316e8d940af0ad3")
    }

    @Test("Nonce packs 8 random bytes plus big-endian minute counter")
    func nonceLayout() {
        let date = Date(timeIntervalSince1970: 29_000_000 * 60)
        let nonce = MiCloudCrypto.makeNonce(now: date, randomBytes: [0xA0, 0xB1, 0xC2, 0xD3, 0xE4, 0xF5, 0x06, 0x17])
        #expect(nonce == Vectors.nonce)
    }

    @Test("signed_nonce, rc4_hash__, encrypted fields and signature match the Python reference")
    func encryptParamsMatchReference() throws {
        #expect(try MiCloudCrypto.signedNonce(ssecurity: Vectors.ssecurity, nonce: Vectors.nonce) == Vectors.signedNonce)
        #expect(MiCloudCrypto.sha1Signature(path: Vectors.path, params: [("data", Vectors.data)], signedNonce: Vectors.signedNonce) == Vectors.rc4HashPlain)

        let fields = try MiCloudCrypto.encryptParams(path: Vectors.path, data: Vectors.data, ssecurity: Vectors.ssecurity, nonce: Vectors.nonce)
        #expect(fields.map(\.0) == ["data", "rc4_hash__", "signature", "ssecurity", "_nonce"])
        #expect(fields[0].1 == Vectors.encData)
        #expect(fields[1].1 == Vectors.encRc4Hash)
        #expect(fields[2].1 == Vectors.signature)
        #expect(fields[3].1 == Vectors.ssecurity)
        #expect(fields[4].1 == Vectors.nonce)
    }

    @Test("Response decryption recovers the reference plaintext")
    func decryptResponse() throws {
        let plain = try MiCloudCrypto.decryptResponse(Vectors.respCipher, signedNonce: Vectors.signedNonce)
        #expect(String(data: plain, encoding: .utf8) == Vectors.respPlain)

        let result = try MiCloudClient.decodeResponse(Data(Vectors.respCipher.utf8), statusCode: 200, signedNonce: Vectors.signedNonce)
        let devices = MiCloudClient.parseDeviceList(result)
        #expect(devices == [MiDeviceRecord(did: "123", name: "灯", model: "yeelink.light.ceiling22", isOnline: true)])
    }

    @Test("Form encoding escapes base64 + / = characters")
    func formEncoding() {
        #expect(MiCloudCrypto.formURLEncode([("a", "x+y/z="), ("b", "1 2")]) == "a=x%2By%2Fz%3D&b=1%202")
    }

    @Test("Plain JSON auth errors surface as sessionExpired; other codes as api errors")
    func plainErrorClassification() {
        let expired = Data(#"{"code":3,"message":"auth err"}"#.utf8)
        #expect(throws: MiCloudError.sessionExpired) {
            try MiCloudClient.decodeResponse(expired, statusCode: 200, signedNonce: Vectors.signedNonce)
        }
        let tokenExpired = Data(#"{"code":-1,"message":"SERVICETOKEN_EXPIRED"}"#.utf8)
        #expect(throws: MiCloudError.sessionExpired) {
            try MiCloudClient.decodeResponse(tokenExpired, statusCode: 200, signedNonce: Vectors.signedNonce)
        }
        let other = Data(#"{"code":-8,"message":"data type not valid"}"#.utf8)
        #expect(throws: MiCloudError.api(code: -8, message: "data type not valid")) {
            try MiCloudClient.decodeResponse(other, statusCode: 200, signedNonce: Vectors.signedNonce)
        }
    }

    @Test("Compact JSON writes integral numbers without a fraction")
    func compactJSON() {
        let v: JSONValue = .object(["params": .array([.object(["did": .string("1"), "siid": .number(2), "value": .number(26.5), "on": .bool(true)])])])
        #expect(v.compactJSONString == #"{"params":[{"did":"1","on":true,"siid":2,"value":26.5}]}"#)
    }
}

struct MiAccountLoginTests {
    @Test("Ticket parsing strips the &&&START&&& prefix")
    func parseTicket() throws {
        let body = #"&&&START&&&{"loginUrl":"https://account.xiaomi.com/longPolling/login?ticket=abc","qr":"https://account.xiaomi.com/longPolling/qr?ticket=abc","lp":"https://lp.account.xiaomi.com/lp/s?d=x","timeout":"300","code":0}"#
        let ticket = try MiAccountLogin.parseTicket(Data(body.utf8))
        #expect(ticket.qrImageURL.absoluteString == "https://account.xiaomi.com/longPolling/qr?ticket=abc")
        #expect(ticket.loginURL.absoluteString == "https://account.xiaomi.com/longPolling/login?ticket=abc")
        #expect(ticket.longPollURL.absoluteString == "https://lp.account.xiaomi.com/lp/s?d=x")
        #expect(ticket.timeout == 300)
    }

    @Test("Scan result parsing accepts numeric userId and the START prefix")
    func parseScan() throws {
        let body = #"&&&START&&&{"userId":1234567890,"ssecurity":"c3NlYw==","cUserId":"cu-1","passToken":"pt","location":"https://sts.api.io.mi.com/sts?d=1","code":0}"#
        let scan = try MiAccountLogin.parseScanResult(Data(body.utf8))
        #expect(scan.userId == "1234567890")
        #expect(scan.ssecurity == "c3NlYw==")
        #expect(scan.cUserId == "cu-1")
        #expect(scan.location.absoluteString == "https://sts.api.io.mi.com/sts?d=1")
        #expect(MiSession(userId: scan.userId, cUserId: "", ssecurity: "", serviceToken: "", passToken: "").maskedUserId == "12****90")
    }

    @Test("Full scan flow: long-poll timeout retried, then serviceToken read from Set-Cookie")
    func waitForScanFlow() async throws {
        let polls = ScriptedTransport.Counter()
        let transport = ScriptedTransport { req in
            let url = req.url!.absoluteString
            if url.hasPrefix("https://lp.example") {
                if polls.increment() == 1 { throw URLError(.timedOut) }
                return (200, [:], #"&&&START&&&{"userId":42,"ssecurity":"c3M=","cUserId":"c","passToken":"p","location":"https://sts.example/sts?x=1"}"#)
            }
            if url.hasPrefix("https://sts.example") {
                return (200, ["Set-Cookie": "serviceToken=tok123; path=/; domain=.example"], "ok")
            }
            return (404, [:], "")
        }
        let login = MiAccountLogin(transport: transport, redirectlessTransport: transport)
        let ticket = QRLoginTicket(
            qrImageURL: URL(string: "https://qr.example")!,
            loginURL: URL(string: "https://login.example")!,
            longPollURL: URL(string: "https://lp.example/poll")!,
            timeout: 30
        )
        let session = try await login.waitForScan(ticket)
        #expect(session == MiSession(userId: "42", cUserId: "c", ssecurity: "c3M=", serviceToken: "tok123", passToken: "p", region: "cn"))
    }

    @Test(
        "Live: Xiaomi returns a QR login ticket",
        .enabled(if: ProcessInfo.processInfo.environment["MI_RUN_LIVE_QR"] == "1")
    )
    func liveTicket() async throws {
        let ticket = try await MiAccountLogin().start()
        #expect(!ticket.qrImageURL.absoluteString.isEmpty)
        #expect(!ticket.longPollURL.absoluteString.isEmpty)
        #expect(ticket.timeout > 0)
        print("LIVE_QR ok host=\(ticket.qrImageURL.host() ?? "?") lpHost=\(ticket.longPollURL.host() ?? "?") timeout=\(ticket.timeout)")
    }
}

// MARK: - Test Doubles

final class ScriptedTransport: MiHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], String)
    private let handler: Handler
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, headers, body) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.withLock { value += 1; return value } }
    }
}
