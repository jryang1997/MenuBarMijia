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
        #expect(MiSession(userId: scan.userId, cUserId: "", ssecurity: "", serviceToken: "").maskedUserId == "12****90")
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
        #expect(session == MiSession(userId: "42", cUserId: "c", ssecurity: "c3M=", serviceToken: "tok123", region: "cn"))
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

// MARK: - MIoT Fixtures (trimmed from miot-spec.org instance JSON, fetched 2026-10-16)

enum MiotFixtures {
    static let ceiling22 = #"{"type":"urn:miot-spec-v2:device:light:0000A001:yeelink-ceiling22:2","description":"Light","services":[{"iid":2,"type":"urn:miot-spec-v2:service:light:00007802:yeelink-ceiling22:1","description":"Light","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:yeelink-ceiling22:1","description":"Switch Status","format":"bool","access":["read","write","notify"]},{"iid":2,"type":"urn:miot-spec-v2:property:brightness:0000000D:yeelink-ceiling22:1","description":"Brightness","format":"uint8","access":["read","write","notify"],"value-range":[1,100,1],"unit":"percentage"},{"iid":3,"type":"urn:miot-spec-v2:property:color-temperature:0000000F:yeelink-ceiling22:1","description":"Color Temperature","format":"uint32","access":["read","write","notify"],"value-range":[2600,6100,1],"unit":"kelvin"},{"iid":4,"type":"urn:miot-spec-v2:property:mode:00000008:yeelink-ceiling22:1","description":"Mode","format":"uint8","access":["read","write","notify"],"value-list":[{"value":1,"description":"Day"},{"value":2,"description":"Night"}]}],"actions":[{"iid":1,"type":"urn:miot-spec-v2:action:toggle:00002811:yeelink-ceiling22:1","description":"Toggle"},{"iid":2,"type":"urn:miot-spec-v2:action:start-flicker-mode:000028E4:yeelink-ceiling22:2","description":"Start Flicker Mode"}]}]}"#

    static let airConditionerMt0 = #"{"type":"urn:miot-spec-v2:device:air-conditioner:0000A004:xiaomi-mt0:2","description":"Air Conditioner","services":[{"iid":2,"type":"urn:miot-spec-v2:service:air-conditioner:0000780F:xiaomi-mt0:1","description":"Air Conditioner","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:xiaomi-mt0:1","description":"Switch Status","format":"bool","access":["read","write","notify"]},{"iid":2,"type":"urn:miot-spec-v2:property:mode:00000008:xiaomi-mt0:1","description":"Mode","format":"uint8","access":["read","write","notify"],"value-list":[{"value":2,"description":"Cool"},{"value":3,"description":"Dry"},{"value":4,"description":"Fan"},{"value":5,"description":"Heat"},{"value":6,"description":"Off"}]},{"iid":4,"type":"urn:miot-spec-v2:property:target-temperature:00000021:xiaomi-mt0:1","description":"Target Temperature","format":"float","access":["read","write","notify"],"value-range":[16,31,0.5],"unit":"celsius"}]},{"iid":3,"type":"urn:miot-spec-v2:service:fan-control:00007809:xiaomi-mt0:1","description":"Fan Control","properties":[{"iid":2,"type":"urn:miot-spec-v2:property:fan-level:00000016:xiaomi-mt0:1","description":"Fan Level","format":"uint8","access":["read","write","notify"],"value-list":[{"value":0,"description":"Auto"},{"value":1,"description":"Level1"},{"value":2,"description":"Level2"},{"value":3,"description":"Level3"},{"value":4,"description":"Level4"},{"value":5,"description":"Level5"},{"value":6,"description":"Level6"},{"value":7,"description":"Level7"}]}]},{"iid":4,"type":"urn:miot-spec-v2:service:environment:0000780A:xiaomi-mt0:1","description":"Environment","properties":[{"iid":7,"type":"urn:miot-spec-v2:property:temperature:00000020:xiaomi-mt0:1","description":"Temperature","format":"float","access":["read","notify"],"value-range":[-30,100,0.1],"unit":"celsius"},{"iid":9,"type":"urn:miot-spec-v2:property:relative-humidity:0000000C:xiaomi-mt0:1","description":"Relative Humidity","format":"uint8","access":["read","notify"],"value-range":[0,100,1],"unit":"percentage"}]}]}"#

    static let outletCucoV3 = #"{"type":"urn:miot-spec-v2:device:outlet:0000A002:cuco-v3:2","description":"Outlet","services":[{"iid":2,"type":"urn:miot-spec-v2:service:switch:0000780C:cuco-v3:1","description":"Switch","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:cuco-v3:1","description":"Switch Status","format":"bool","access":["read","write","notify"]}],"actions":[{"iid":1,"type":"urn:miot-spec-v2:action:toggle:00002811:cuco-v3:1","description":"Toggle"}]},{"iid":7,"type":"urn:miot-spec-v2:service:physical-controls-locked:00007807:cuco-v3:1","description":"Physical Control Locked","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:physical-controls-locked:0000001D:cuco-v3:1","description":"Physical Control Locked","format":"bool","access":["read","write","notify"]}]},{"iid":11,"type":"urn:miot-spec-v2:service:power-consumption:0000780E:cuco-v3:1","description":"Power Consumption","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:power-consumption:0000002F:cuco-v3:1","description":"Power Consumption","format":"uint16","access":["read","notify"],"value-range":[0,65535,1]},{"iid":2,"type":"urn:miot-spec-v2:property:electric-power:00000066:cuco-v3:1","description":"Electric Power","format":"float","access":["read","notify"],"value-range":[0,10000,1],"unit":"watt"}]},{"iid":13,"type":"urn:miot-spec-v2:service:indicator-light:00007803:cuco-v3:1","description":"Indicator Light","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:cuco-v3:1","description":"Switch Status","format":"bool","access":["read","write","notify"]}]}]}"#

    static let gateway = #"{"type":"urn:miot-spec-v2:device:gateway:0000A019:lumi-mgl03:1","services":[{"iid":3,"type":"urn:miot-spec-v2:service:gateway:0000782D:lumi-mgl03:1","properties":[]}]}"#

    static func decode(_ json: String) -> MiotDeviceSpec {
        try! JSONDecoder().decode(MiotDeviceSpec.self, from: Data(json.utf8))
    }

    static let specs: [String: MiotDeviceSpec] = [
        "yeelink.light.ceiling22": decode(ceiling22),
        "xiaomi.aircondition.mt0": decode(airConditionerMt0),
        "cuco.plug.v3": decode(outletCucoV3),
        "lumi.gateway.mgl03": decode(gateway),
    ]

    static func key(_ did: String, _ siid: Int, _ piid: Int) -> MiotPropKey {
        MiotPropKey(did: did, siid: siid, piid: piid)
    }

    static let lightRecord = MiDeviceRecord(did: "123", name: "吸顶灯", model: "yeelink.light.ceiling22", isOnline: true)
    static let lightValues: [MiotPropKey: JSONValue] = [
        key("123", 2, 1): .bool(true),
        key("123", 2, 2): .number(80),
        key("123", 2, 3): .number(4000),
        key("123", 2, 4): .number(2),
    ]
    static let expectedLight = SmartDevice(
        id: "123",
        name: "书房吸顶灯",
        roomId: "shu_fang",
        roomName: "书房",
        model: "yeelink.light.ceiling22",
        isOnline: true,
        kind: .light(LightSpec(
            entityId: "miot:123:2",
            isOn: true,
            brightnessPercent: 80,
            colorTempKelvin: 4000,
            minKelvin: 2600,
            maxKelvin: 6100,
            currentEffect: "Night",
            availableEffects: ["Day", "Night"]
        ))
    )
}

struct MiotSynthesizerTests {
    @Test("yeelink.light.ceiling22 becomes a LightSpec addressed miot:<did>:<siid>")
    func lightFromSpec() {
        let home = MiotSynthesizer.synthesize(
            devices: [MiotFixtures.lightRecord],
            rooms: [MiRoom(id: "r1", name: "书房", dids: ["123"])],
            specs: MiotFixtures.specs,
            values: MiotFixtures.lightValues
        )
        #expect(home.devices == [MiotFixtures.expectedLight])
        #expect(home.rooms == [RoomArea(id: "shu_fang", name: "书房", sortOrder: 0)])
        #expect(MiotSynthesizer.requiredProps(for: MiotFixtures.lightRecord, spec: MiotFixtures.specs["yeelink.light.ceiling22"]!) == [
            MiotFixtures.key("123", 2, 1), MiotFixtures.key("123", 2, 2),
            MiotFixtures.key("123", 2, 3), MiotFixtures.key("123", 2, 4),
        ])
    }

    @Test("Air conditioner maps modes to HA vocabulary, reads room temp and fan levels from sibling services")
    func climateFromSpec() {
        let record = MiDeviceRecord(did: "456", name: "空调", model: "xiaomi.aircondition.mt0", isOnline: true)
        let values: [MiotPropKey: JSONValue] = [
            MiotFixtures.key("456", 2, 1): .bool(true),
            MiotFixtures.key("456", 2, 2): .number(2),
            MiotFixtures.key("456", 2, 4): .number(26.5),
            MiotFixtures.key("456", 3, 2): .number(0),
            MiotFixtures.key("456", 4, 7): .number(27.3),
        ]
        let home = MiotSynthesizer.synthesize(devices: [record], rooms: [], specs: MiotFixtures.specs, values: values)
        #expect(home.devices.count == 1)
        #expect(home.devices.first?.roomName == "全屋")
        #expect(home.devices.first?.kind == .climate(ClimateSpec(
            entityId: "miot:456:2",
            isOn: true,
            hvacMode: "cool",
            availableModes: ["cool", "dry", "fan_only", "heat", "off"],
            targetTemperature: 26.5,
            currentTemperature: 27.3,
            minTemp: 16,
            maxTemp: 31,
            step: 0.5,
            fanMode: "Auto",
            availableFanModes: ["Auto", "Level1", "Level2", "Level3", "Level4", "Level5", "Level6", "Level7"]
        )))

        var off = values
        off[MiotFixtures.key("456", 2, 1)] = .bool(false)
        let offHome = MiotSynthesizer.synthesize(devices: [record], rooms: [], specs: MiotFixtures.specs, values: off)
        if case .climate(let s) = offHome.devices.first?.kind {
            #expect(s.hvacMode == "off")
            #expect(!s.isOn)
        } else {
            Issue.record("expected climate")
        }
    }

    @Test("cuco.plug.v3 outlet becomes a PlugSpec with power and child lock; indicator light is ignored")
    func plugFromSpec() {
        let record = MiDeviceRecord(did: "789", name: "咖啡机", model: "cuco.plug.v3", isOnline: true)
        let values: [MiotPropKey: JSONValue] = [
            MiotFixtures.key("789", 2, 1): .bool(true),
            MiotFixtures.key("789", 11, 2): .number(1210),
            MiotFixtures.key("789", 7, 1): .bool(true),
            MiotFixtures.key("789", 13, 1): .bool(false),
        ]
        let home = MiotSynthesizer.synthesize(devices: [record], rooms: [], specs: MiotFixtures.specs, values: values)
        #expect(home.devices.first?.kind == .plug(PlugSpec(
            switchEntityId: "miot:789:2",
            isOn: true,
            powerWatts: 1210,
            childLockEntityId: "miot:789:7",
            isChildLocked: true
        )))
        #expect(MiotSynthesizer.requiredProps(for: record, spec: MiotFixtures.specs["cuco.plug.v3"]!) == [
            MiotFixtures.key("789", 2, 1), MiotFixtures.key("789", 11, 2), MiotFixtures.key("789", 7, 1),
        ])
    }

    @Test("Plug cumulative energy maps explicit MIoT kWh, 0.01kWh, and Wh counters while ignoring untagged integers (#62)")
    func plugEnergyFromSpec() {
        let onProp = MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:test:1", format: "bool", access: ["read", "write"])
        let switchService = MiotService(iid: 2, type: "urn:miot-spec-v2:service:switch:0000780C:test:1", properties: [onProp])

        let centiKwhSpec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:outlet:0000A002:cuco-v3:2", services: [
            switchService,
            MiotService(iid: 11, type: "urn:miot-spec-v2:service:power-consumption:0000780E:cuco-v3:1", properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:power-consumption:0000002F:cuco-v3:1", format: "uint16", access: ["read"], comment: "耗电量（单位:0,01Kwh）"),
            ]),
        ])
        let floatKwhSpec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:outlet:0000A002:xiaomi-2pro:1", services: [
            switchService,
            MiotService(iid: 3, type: "urn:miot-spec-v2:service:power-consumption:0000780E:xiaomi-2pro:1", properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:power-consumption:0000002F:xiaomi-2pro:1", format: "float", access: ["read"], unit: "kWh"),
            ]),
        ])
        let whSpec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:outlet:0000A002:wh-plug:1", services: [
            switchService,
            MiotService(iid: 3, type: "urn:miot-spec-v2:service:power-consumption:0000780E:wh-plug:1", properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:power-consumption:0000002F:wh-plug:1", format: "uint32", access: ["read"], unit: "watt-hour"),
            ]),
        ])
        let unitScaledSpec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:outlet:0000A002:unit-plug:1", services: [
            switchService,
            MiotService(iid: 3, type: "urn:miot-spec-v2:service:power-consumption:0000780E:unit-plug:1", properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:power-consumption:0000002F:unit-plug:1", format: "uint32", access: ["read"], unit: "0.01kWh"),
            ]),
        ])
        let unsupportedDeciSpec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:outlet:0000A002:deci-plug:1", services: [
            switchService,
            MiotService(iid: 3, type: "urn:miot-spec-v2:service:power-consumption:0000780E:deci-plug:1", properties: [
                MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:power-consumption:0000002F:deci-plug:1", format: "uint32", access: ["read"], unit: "0.1kWh", comment: "单位:0.1kWh"),
            ]),
        ])

        let home = MiotSynthesizer.synthesize(
            devices: [
                MiDeviceRecord(did: "p1", name: "插座A", model: "cuco.v3", isOnline: true),
                MiDeviceRecord(did: "p2", name: "插座B", model: "xiaomi.2pro", isOnline: true),
                MiDeviceRecord(did: "p3", name: "插座C", model: "wh.plug", isOnline: true),
                MiDeviceRecord(did: "p4", name: "插座D", model: "unit.plug", isOnline: true),
                MiDeviceRecord(did: "p5", name: "插座E", model: "deci.plug", isOnline: true),
            ],
            rooms: [],
            specs: [
                "cuco.v3": centiKwhSpec,
                "xiaomi.2pro": floatKwhSpec,
                "wh.plug": whSpec,
                "unit.plug": unitScaledSpec,
                "deci.plug": unsupportedDeciSpec,
            ],
            values: [
                MiotFixtures.key("p1", 2, 1): .bool(true),
                MiotFixtures.key("p1", 11, 1): .number(246),
                MiotFixtures.key("p2", 2, 1): .bool(true),
                MiotFixtures.key("p2", 3, 1): .number(3.75),
                MiotFixtures.key("p3", 2, 1): .bool(false),
                MiotFixtures.key("p3", 3, 1): .number(1500),
                MiotFixtures.key("p4", 2, 1): .bool(true),
                MiotFixtures.key("p4", 3, 1): .number(512),
                MiotFixtures.key("p5", 2, 1): .bool(true),
                MiotFixtures.key("p5", 3, 1): .number(512),
            ]
        )
        let byId = Dictionary(uniqueKeysWithValues: home.devices.map { ($0.id, $0) })
        if case .plug(let a) = byId["p1"]?.kind { #expect(a.energyKwh == 2.46) } else { Issue.record("expected plug p1") }
        if case .plug(let b) = byId["p2"]?.kind { #expect(b.energyKwh == 3.75) } else { Issue.record("expected plug p2") }
        if case .plug(let c) = byId["p3"]?.kind { #expect(c.energyKwh == 1.5) } else { Issue.record("expected plug p3") }
        if case .plug(let d) = byId["p4"]?.kind { #expect(d.energyKwh == 5.12) } else { Issue.record("expected plug p4") }
        if case .plug(let e) = byId["p5"]?.kind { #expect(e.energyKwh == nil) } else { Issue.record("expected plug p5") }
    }

    @Test("Split keys of a multi-key Mesh panel become separate plugs addressed at the parent did")
    func splitPanelKeys() throws {
        let onProp = MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:lemesh-sw2f12:1", format: "bool", access: ["read", "write", "notify"])
        let spec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:switch:0000A003:lemesh-sw2f12:1", services: [
            MiotService(iid: 2, type: "urn:miot-spec-v2:service:switch:0000780C:lemesh-sw2f12:1", properties: [onProp]),
            MiotService(iid: 3, type: "urn:miot-spec-v2:service:switch:0000780C:lemesh-sw2f12:1", properties: [onProp]),
        ])
        let model = "lemesh.switch.sw2f12"
        let parent = MiDeviceRecord(did: "100", name: "二键开关", model: model, isOnline: true)
        let key2 = MiDeviceRecord(did: "100.s2", name: "筒灯", model: model, isOnline: true, splitParentDid: "100", splitSiid: 2)
        let key3 = MiDeviceRecord(did: "100.s3", name: "氛围灯", model: model, isOnline: true, splitParentDid: "100", splitSiid: 3)
        let home = MiotSynthesizer.synthesize(
            devices: [parent, key2, key3],
            rooms: [MiRoom(id: "r1", name: "主卧", dids: ["100.s2", "100.s3"])],
            specs: [model: spec],
            values: [MiotFixtures.key("100", 2, 1): .bool(false), MiotFixtures.key("100", 3, 1): .bool(true)]
        )
        #expect(home.devices.map(\.id).sorted() == ["100.s2", "100.s3"])
        let ambient = try #require(home.devices.first { $0.id == "100.s3" })
        #expect(ambient.roomName == "主卧")
        if case .plug(let p) = ambient.kind {
            #expect(p.switchEntityId == "miot:100:3")
            #expect(p.isOn)
        } else {
            Issue.record("expected plug")
        }
        #expect(MiotSynthesizer.requiredProps(for: key3, spec: spec) == [MiotFixtures.key("100", 3, 1)])
    }

    @Test("device_list_page split metadata is parsed from extra.split")
    func parseSplitRecord() {
        let result: JSONValue = .object(["list": .array([.object([
            "did": .string("100.s3"), "name": .string("氛围灯"), "model": .string("lemesh.switch.sw2f12"),
            "isOnline": .bool(true),
            "extra": .object(["split": .object(["parentId": .string("100"), "moduleId": .number(3)])]),
        ])])])
        #expect(MiCloudClient.parseDeviceList(result) == [
            MiDeviceRecord(did: "100.s3", name: "氛围灯", model: "lemesh.switch.sw2f12", isOnline: true, splitParentDid: "100", splitSiid: 3),
        ])
    }

    @Test("Devices without a spec or with an unsupported type are skipped")
    func unknownSkipped() {
        let home = MiotSynthesizer.synthesize(
            devices: [
                MiDeviceRecord(did: "1", name: "网关", model: "lumi.gateway.mgl03", isOnline: true),
                MiDeviceRecord(did: "2", name: "未知", model: "acme.thing.v1", isOnline: true),
            ],
            rooms: [],
            specs: MiotFixtures.specs,
            values: [:]
        )
        #expect(home.devices.isEmpty)
        #expect(MiotSynthesizer.supportedServiceName(for: MiotFixtures.specs["lumi.gateway.mgl03"]!) == nil)
    }
}

struct MiotCommandMapperTests {
    let light = MiotFixtures.specs["yeelink.light.ceiling22"]!
    let ac = MiotFixtures.specs["xiaomi.aircondition.mt0"]!
    let plug = MiotFixtures.specs["cuco.plug.v3"]!

    @Test("Brightness writes on + piid 2 with the literal percent")
    func brightness() throws {
        let write = try MiotCommandMapper.map(.setLightBrightness(entityId: "miot:123:2", percent: 40), spec: light)
        #expect(write == .setProps([
            MiotPropWrite(did: "123", siid: 2, piid: 1, value: .bool(true)),
            MiotPropWrite(did: "123", siid: 2, piid: 2, value: .number(40)),
        ]))
        #expect(try MiotCommandMapper.map(.setLightPower(entityId: "miot:123:2", isOn: false), spec: light)
            == .setProps([MiotPropWrite(did: "123", siid: 2, piid: 1, value: .bool(false))]))
    }

    @Test("Effect maps by value-list description; colour temperature clamps to the value-range")
    func effectAndColorTemp() throws {
        #expect(try MiotCommandMapper.map(.setLightEffect(entityId: "miot:123:2", effect: "Night"), spec: light) == .setProps([
            MiotPropWrite(did: "123", siid: 2, piid: 1, value: .bool(true)),
            MiotPropWrite(did: "123", siid: 2, piid: 4, value: .number(2)),
        ]))
        #expect(try MiotCommandMapper.map(.setLightColorTemp(entityId: "miot:123:2", kelvin: 9000), spec: light) == .setProps([
            MiotPropWrite(did: "123", siid: 2, piid: 1, value: .bool(true)),
            MiotPropWrite(did: "123", siid: 2, piid: 3, value: .number(6100)),
        ]))
        #expect(try MiotCommandMapper.map(.setLightColorTemp(entityId: "miot:123:2", kelvin: 1000), spec: light) == .setProps([
            MiotPropWrite(did: "123", siid: 2, piid: 1, value: .bool(true)),
            MiotPropWrite(did: "123", siid: 2, piid: 3, value: .number(2600)),
        ]))
        #expect(throws: MiotCommandError.unsupported("mode=Party")) {
            try MiotCommandMapper.map(.setLightEffect(entityId: "miot:123:2", effect: "Party"), spec: light)
        }
    }

    @Test("Climate mode, temperature step rounding and fan level in a sibling service")
    func climate() throws {
        #expect(try MiotCommandMapper.map(.setClimateMode(entityId: "miot:456:2", hvacMode: "heat"), spec: ac) == .setProps([
            MiotPropWrite(did: "456", siid: 2, piid: 1, value: .bool(true)),
            MiotPropWrite(did: "456", siid: 2, piid: 2, value: .number(5)),
        ]))
        #expect(try MiotCommandMapper.map(.setClimateMode(entityId: "miot:456:2", hvacMode: "off"), spec: ac)
            == .setProps([MiotPropWrite(did: "456", siid: 2, piid: 1, value: .bool(false))]))
        #expect(try MiotCommandMapper.map(.setClimateTemperature(entityId: "miot:456:2", temperature: 26.3), spec: ac)
            == .setProps([MiotPropWrite(did: "456", siid: 2, piid: 4, value: .number(26.5))]))
        #expect(try MiotCommandMapper.map(.setClimateFanMode(entityId: "miot:456:2", fanMode: "Level3"), spec: ac)
            == .setProps([MiotPropWrite(did: "456", siid: 3, piid: 2, value: .number(3))]))
    }

    @Test("setSwitch targets on or the child-lock property by service address")
    func plugSwitches() throws {
        #expect(try MiotCommandMapper.map(.setSwitch(entityId: "miot:789:2", isOn: false), spec: plug)
            == .setProps([MiotPropWrite(did: "789", siid: 2, piid: 1, value: .bool(false))]))
        #expect(try MiotCommandMapper.map(.setSwitch(entityId: "miot:789:7", isOn: true), spec: plug)
            == .setProps([MiotPropWrite(did: "789", siid: 7, piid: 1, value: .bool(true))]))
    }

    @Test("Vacuum actions resolve by action short name across services")
    func vacuum() throws {
        let spec = MiotDeviceSpec(type: "urn:miot-spec-v2:device:vacuum:0000A006:roborock-a15:1", services: [
            MiotService(iid: 2, type: "urn:miot-spec-v2:service:vacuum:00007810:roborock-a15:1", actions: [
                MiotAction(iid: 1, type: "urn:miot-spec-v2:action:start-sweep:00002804:roborock-a15:1"),
                MiotAction(iid: 2, type: "urn:miot-spec-v2:action:stop-sweeping:00002805:roborock-a15:1"),
            ]),
            MiotService(iid: 3, type: "urn:miot-spec-v2:service:battery:00007805:roborock-a15:1", actions: [
                MiotAction(iid: 1, type: "urn:miot-spec-v2:action:start-charge:00002802:roborock-a15:1"),
            ]),
        ])
        #expect(try MiotCommandMapper.map(.vacuumAction(entityId: "miot:9:2", action: .start), spec: spec)
            == .action(MiotActionCall(did: "9", siid: 2, aiid: 1)))
        #expect(try MiotCommandMapper.map(.vacuumAction(entityId: "miot:9:2", action: .pause), spec: spec)
            == .action(MiotActionCall(did: "9", siid: 2, aiid: 2)))
        #expect(try MiotCommandMapper.map(.vacuumAction(entityId: "miot:9:2", action: .returnToBase), spec: spec)
            == .action(MiotActionCall(did: "9", siid: 3, aiid: 1)))
    }

    @Test("Unsupported commands and foreign addresses throw typed errors")
    func errors() {
        #expect(throws: MiotCommandError.invalidAddress("light.study")) {
            try MiotCommandMapper.map(.setLightPower(entityId: "light.study", isOn: true), spec: light)
        }
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.setNumberValue(entityId: "miot:123:2", value: 1), spec: light)
        }
        #expect(MiotAddress.parse("miot:blt.3.abc:2")! == ("blt.3.abc", 2))
    }
}

// MARK: - Provider & Client With Stubs

actor StubMiCloudAPI: MiCloudAPI {
    var devices: [MiDeviceRecord]
    var rooms: [MiRoom]
    var values: [MiotPropKey: JSONValue]
    var failure: MiCloudError?
    private(set) var setPropsCalls: [[MiotPropWrite]] = []
    private(set) var getPropsCalls: [[MiotPropKey]] = []

    init(devices: [MiDeviceRecord], rooms: [MiRoom], values: [MiotPropKey: JSONValue], failure: MiCloudError? = nil) {
        self.devices = devices
        self.rooms = rooms
        self.values = values
        self.failure = failure
    }

    func setValue(_ key: MiotPropKey, _ value: JSONValue) { values[key] = value }

    private(set) var deviceListCalls = 0

    func deviceList() async throws -> [MiDeviceRecord] {
        deviceListCalls += 1
        if let failure { throw failure }
        return devices
    }

    func homeRooms() async throws -> [MiRoom] { rooms }

    func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] {
        getPropsCalls.append(keys)
        return values.filter { keys.contains($0.key) }
    }

    func setProps(_ writes: [MiotPropWrite]) async throws {
        setPropsCalls.append(writes)
        for w in writes { values[MiotPropKey(did: w.did, siid: w.siid, piid: w.piid)] = w.value }
    }

    func action(_ call: MiotActionCall) async throws {}
}

struct StubSpecSource: MiotSpecSource {
    func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
        MiotFixtures.specs[model]
    }
}

actor EventLog {
    private(set) var events: [HomeProviderEvent] = []
    func append(_ e: HomeProviderEvent) { events.append(e) }

    var snapshots: [SynthesizedHome] {
        events.compactMap { if case .snapshotUpdated(let h) = $0 { return h } else { return nil } }
    }

    var statuses: [ConnectionStatus] {
        events.compactMap { if case .statusChanged(let s) = $0 { return s } else { return nil } }
    }

    /// Polls until `predicate` holds or ~3 s pass.
    func wait(until predicate: @Sendable (EventLog) async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate(self) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private func consume(_ provider: some HomeProvider) -> (EventLog, Task<Void, Never>) {
    let log = EventLog()
    let stream = provider.events()
    let task = Task { for await e in stream { await log.append(e) } }
    return (log, task)
}

private let fakeSession = MiSession(userId: "42", cUserId: "c", ssecurity: Vectors.ssecurity, serviceToken: "tok")

struct MiCloudProviderTests {
    @Test("Device list + props produce one snapshot with the synthesized light; execute writes and re-polls")
    func snapshotAndExecute() async throws {
        let api = StubMiCloudAPI(
            devices: [MiotFixtures.lightRecord, MiDeviceRecord(did: "1", name: "网关", model: "lumi.gateway.mgl03", isOnline: true)],
            rooms: [MiRoom(id: "r1", name: "书房", dids: ["123"])],
            values: MiotFixtures.lightValues
        )
        let provider = MiCloudProvider(
            sessionLoader: { fakeSession },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            followUpDelay: .milliseconds(10)
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        #expect(await log.snapshots.first?.devices == [MiotFixtures.expectedLight])
        #expect(await log.statuses.prefix(2) == [.connecting, .connected])
        #expect(await api.getPropsCalls.first?.count == 4)

        try await provider.execute(.setLightPower(entityId: "miot:123:2", isOn: false))
        #expect(await api.setPropsCalls == [[MiotPropWrite(did: "123", siid: 2, piid: 1, value: .bool(false))]])
        #expect(await log.wait { await $0.snapshots.count >= 2 })
        if case .light(let s) = await log.snapshots.last?.devices.first?.kind {
            #expect(s.isOn == false)
        } else {
            Issue.record("expected light after follow-up poll")
        }
        await provider.shutdown()
    }

    @Test("Concurrent multi-model spec loading preserves all model keys across async suspension points (Issue #2 regression)")
    func concurrentMultiModelSpecLoading() async throws {
        struct DelayedMultiSpecSource: MiotSpecSource {
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? {
                try await Task.sleep(for: .milliseconds(2))
                if model.hasSuffix(".fail") {
                    throw MiCloudError.http(503)
                }
                if model.hasPrefix("yeelink.light.model") {
                    return MiotFixtures.specs["yeelink.light.ceiling22"]
                }
                return nil
            }
        }

        var devices: [MiDeviceRecord] = []
        var values: [MiotPropKey: JSONValue] = [:]
        for i in 0..<20 {
            let did = "did-\(i)"
            devices.append(MiDeviceRecord(did: did, name: "灯\(i)", model: "yeelink.light.model\(i)", isOnline: true))
            values[MiotPropKey(did: did, siid: 2, piid: 1)] = .bool(true)
            values[MiotPropKey(did: did, siid: 2, piid: 2)] = .number(50)
            values[MiotPropKey(did: did, siid: 2, piid: 3)] = .number(4000)
            values[MiotPropKey(did: did, siid: 2, piid: 4)] = .number(0)
        }
        devices.append(MiDeviceRecord(did: "gw-1", name: "网关", model: "lumi.gateway.mgl03", isOnline: true))
        devices.append(MiDeviceRecord(did: "err-1", name: "异常设备", model: "custom.device.fail", isOnline: true))

        let api = StubMiCloudAPI(devices: devices, rooms: [], values: values)
        let provider = MiCloudProvider(
            sessionLoader: { fakeSession },
            apiFactory: { _ in api },
            specSource: DelayedMultiSpecSource(),
            pollInterval: .seconds(60)
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        let synthesized = await log.snapshots.first?.devices ?? []
        #expect(synthesized.count == 20)
        await provider.shutdown()
    }

    @Test("No saved session reports a login prompt; expired session reports re-scan")
    func sessionStates() async {
        let noSession = MiCloudProvider(sessionLoader: { nil }, specSource: StubSpecSource())
        let (log1, t1) = consume(noSession)
        defer { t1.cancel() }
        #expect(await log1.wait { await $0.statuses.contains(.disconnected("请在设置中扫码登录米家账号")) })

        let api = StubMiCloudAPI(devices: [], rooms: [], values: [:], failure: .sessionExpired)
        let expired = MiCloudProvider(sessionLoader: { fakeSession }, apiFactory: { _ in api }, specSource: StubSpecSource())
        let (log2, t2) = consume(expired)
        defer { t2.cancel() }
        #expect(await log2.wait { await $0.statuses.contains(.disconnected("米家登录已过期，请重新扫码")) })
    }

    @MainActor
    @Test("HomeStore persists homeBackend, formats serverHostSummary for both modes, and handles login/logout")
    func backendSwitchingAndSummary() {
        let suite = "com.jryang1997.MenuBarMijia.backend-test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        store.serverURLString = "http://192.168.50.35:8123"
        #expect(store.homeBackend == .homeAssistant)
        #expect(store.serverHostSummary == "192.168.50.35")

        store.switchBackend(.xiaomiCloud)
        #expect(store.homeBackend == .xiaomiCloud)
        #expect(store.serverHostSummary == "米家云端 (未登录)")

        let reloaded = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(reloaded.homeBackend == .xiaomiCloud)

        let session = MiSession(
            userId: "1234567890",
            cUserId: "cu",
            ssecurity: Vectors.ssecurity,
            serviceToken: "tok"
        )
        store.completeMiLogin(session)
        #expect(store.homeBackend == .xiaomiCloud)
        #expect(store.miSessionMaskedUserId == "12****90")
        #expect(store.serverHostSummary == "米家云端 (12****90)")
        #expect(store.toastNotice?.message == "已登录米家账号 (12****90)")

        store.logoutMiAccount()
        #expect(store.miSessionMaskedUserId == nil)
        #expect(store.serverHostSummary == "米家云端 (未登录)")
        #expect(store.toastNotice?.message == "已退出米家账号")

        store.switchBackend(.homeAssistant)
        #expect(store.homeBackend == .homeAssistant)
        #expect(store.serverHostSummary == "192.168.50.35")
    }
}

struct MiCloudClientTests {
    @Test("Client sends signed RC4 form with cookies and decrypts the encrypted response")
    func encryptedRoundTrip() async throws {
        let transport = ScriptedTransport { req in
            let form = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            var fields: [String: String] = [:]
            for pair in form.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            let signed = try MiCloudCrypto.signedNonce(ssecurity: Vectors.ssecurity, nonce: fields["_nonce"] ?? "")
            let data = String(data: try MiCloudCrypto.decryptResponse(fields["data"] ?? "", signedNonce: signed), encoding: .utf8) ?? ""
            guard req.url?.absoluteString == "https://api.io.mi.com/app/miotspec/prop/get",
                  data == #"{"params":[{"did":"123","piid":1,"siid":2}]}"#,
                  req.value(forHTTPHeaderField: "Cookie")?.contains("serviceToken=tok") == true,
                  req.value(forHTTPHeaderField: "MIOT-ENCRYPT-ALGORITHM") == "ENCRYPT-RC4" else {
                return (400, [:], #"{"code":-1,"message":"bad request in stub"}"#)
            }
            let reply = #"{"code":0,"message":"ok","result":[{"did":"123","siid":2,"piid":1,"value":true,"code":0}]}"#
            return (200, [:], try MiCloudCrypto.encrypt(reply, signedNonce: signed))
        }
        let client = MiCloudClient(session: fakeSession, transport: transport)
        let values = try await client.getProps([MiotFixtures.key("123", 2, 1)])
        #expect(values == [MiotFixtures.key("123", 2, 1): .bool(true)])
    }

    @Test("Room list parsing flattens homelist.roomlist")
    func rooms() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"homelist":[{"id":"h1","roomlist":[{"id":"r1","name":"客厅","dids":["1","2"]},{"id":2,"name":"卧室","dids":[]}]}]}"#.utf8))
        #expect(MiCloudClient.parseRooms(json) == [
            MiRoom(id: "r1", name: "客厅", dids: ["1", "2"], homeId: "h1"),
            MiRoom(id: "2", name: "卧室", dids: [], homeId: "h1"),
        ])
    }

    @Test("Each home becomes a HomeOption; room-less home devices land in an unnamed room")
    func homes() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"homelist":[{"id":"h1","name":"东澜府","dids":["1","9"],"roomlist":[{"id":"r1","name":"客厅","dids":["1","2"]}]},{"id":"h2","name":"果果家","roomlist":[{"id":"r2","name":"卧室","dids":["3"]}]}]}"#.utf8))
        let rooms = MiCloudClient.parseRooms(json)
        #expect(rooms.last(where: { $0.homeId == "h1" }) == MiRoom(id: "home_h1", name: "", dids: ["1", "9"], homeId: "h1", homeName: "东澜府"))
        #expect(MiCloudProvider.homeOptions(from: rooms) == [
            HomeOption(id: "h1", name: "东澜府", deviceCount: 3),
            HomeOption(id: "h2", name: "果果家", deviceCount: 1),
        ])
    }

    @Test("Split switch keys without power or child-lock hide detail drawer and use switch/light SF Symbols")
    func switchKeyPresentation() {
        let downlightKey = SmartDevice(
            id: "1109223163.s2",
            name: "筒灯",
            roomId: "living_room",
            roomName: "客厅",
            model: "lemesh.switch.sw2f12",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:1109223163:2", isOn: true))
        )
        #expect(downlightKey.hasDetailDrawer == false)
        #expect(downlightKey.sfSymbolName == "lightbulb.fill")

        let wallSwitchKey = SmartDevice(
            id: "1109223163.s3",
            name: "玄关开关",
            roomId: "living_room",
            roomName: "客厅",
            model: "lemesh.switch.sw2f12",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:1109223163:3", isOn: false))
        )
        #expect(wallSwitchKey.hasDetailDrawer == false)
        #expect(wallSwitchKey.sfSymbolName == "lightswitch.off")

        let smartPlug = SmartDevice(
            id: "did_plug",
            name: "桌面插座",
            roomId: "study",
            roomName: "书房",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:did_plug:2", isOn: true, powerWatts: 42.0))
        )
        #expect(smartPlug.hasDetailDrawer == true)
        #expect(smartPlug.sfSymbolName == "powerplug.fill")
    }
}
