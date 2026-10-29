import Foundation
import Testing
@testable import MijiaCore

@Suite("SensorHistory & MiCloud History Parsing")
struct SensorHistoryTests {
    private static func fixedCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return cal
    }

    @Test("Records live sensor snapshots into hourly and daily buckets and persists them")
    @MainActor
    func recordsAndPersistsSnapshots() throws {
        let suiteName = "SensorHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cal = Self.fixedCalendar()
        let history = SensorHistory(defaults: defaults, calendar: cal)

        let base = Date(timeIntervalSince1970: 1_760_000_400)
        let sensorAt = { (temp: Double, hum: Double) in
            SmartDevice(
                id: "blt.3.sensor1",
                name: "主卧温湿度计",
                roomId: "bedroom",
                roomName: "卧室",
                model: "miaomiaoce.sensor_ht.t2",
                isOnline: true,
                kind: .sensor(SensorSpec(temperature: temp, humidity: hum))
            )
        }

        history.record(devices: [sensorAt(22.0, 60)], now: base.addingTimeInterval(-3600))
        history.record(devices: [sensorAt(23.2, 66)], now: base)
        history.record(devices: [sensorAt(22.6, 63)], now: base.addingTimeInterval(600))

        let points24h = history.points(forDevice: "blt.3.sensor1", window: .last24Hours, now: base.addingTimeInterval(600))
        #expect(points24h.count == 24)
        let latest = try #require(points24h.last)
        #expect(abs((latest.temperature ?? 0) - 22.9) < 0.05)
        #expect(abs((latest.minTemperature ?? 0) - 22.6) < 0.001)
        #expect(abs((latest.maxTemperature ?? 0) - 23.2) < 0.001)
        #expect(abs((latest.humidity ?? 0) - 64.5) < 0.05)

        let summary = try #require(history.summary(
            forDevice: "blt.3.sensor1",
            window: .last24Hours,
            metric: .temperature,
            now: base.addingTimeInterval(600)
        ))
        #expect(abs(summary.min - 22.0) < 0.001)
        #expect(abs(summary.max - 23.2) < 0.001)
        #expect(abs(summary.latest - 22.9) < 0.05)
        #expect(!history.hasCloudHistory(forDevice: "blt.3.sensor1"))

        let reloaded = SensorHistory(defaults: defaults, calendar: cal)
        let reloadedPoints = reloaded.points(forDevice: "blt.3.sensor1", window: .last24Hours, now: base.addingTimeInterval(600))
        #expect(reloadedPoints.filter { $0.temperature != nil || $0.humidity != nil }.count == 2)
    }

    @Test("Merges cloud history samples and respects fetch cooldown")
    @MainActor
    func mergesCloudSamplesAndCooldown() throws {
        let suiteName = "SensorHistoryTests.cloud.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cal = Self.fixedCalendar()
        let history = SensorHistory(defaults: defaults, calendar: cal)
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        #expect(history.shouldFetchCloud(deviceId: "blt.3.sensor1", window: .last24Hours, now: now))

        let cloudSamples = (0..<6).map { offset -> SensorHistorySample in
            let ts = now.addingTimeInterval(-Double(offset) * 3600)
            return SensorHistorySample(
                timestamp: ts,
                temperature: 22.0 + Double(offset) * 0.5,
                minTemperature: 21.8 + Double(offset) * 0.5,
                maxTemperature: 22.3 + Double(offset) * 0.5,
                humidity: 60.0 + Double(offset),
                minHumidity: 59.0 + Double(offset),
                maxHumidity: 61.0 + Double(offset)
            )
        }
        history.mergeCloudSamples(
            deviceId: "blt.3.sensor1",
            window: .last24Hours,
            samples: cloudSamples,
            now: now
        )

        #expect(history.hasCloudHistory(forDevice: "blt.3.sensor1"))
        #expect(!history.shouldFetchCloud(deviceId: "blt.3.sensor1", window: .last24Hours, now: now.addingTimeInterval(60)))
        #expect(history.shouldFetchCloud(deviceId: "blt.3.sensor1", window: .last24Hours, now: now.addingTimeInterval(301)))

        let points = history.points(forDevice: "blt.3.sensor1", window: .last24Hours, now: now)
        #expect(points.filter { $0.temperature != nil || $0.humidity != nil }.count == 6)
    }

    @Test("MiCloudClient.parseHistoryMetricPoints decodes stat_hour_v3 arrays and MiBeacon hex payloads")
    func parsesMiCloudHistoryPayloads() {
        let rawPayload: JSONValue = .array([
            // v2/user/statistics single value array string
            .object(["time": .number(1_760_000_000), "value": .string("[22.7]")]),
            // v2/user/statistics min/max array string
            .object(["time": .number(1_760_003_600), "value": .string("[21.4, 24.8]")]),
            // MiBeacon v5 little-endian IEEE 754 float32 hex for 23.6 ("cdccbc41")
            .object(["time": .number(1_760_007_200), "value": .string("\"cdccbc41\"")]),
            // Out-of-range invalid temperature should be ignored
            .object(["time": .number(1_760_010_800), "value": .string("[999.0]")]),
        ])

        let parsed = MiCloudClient.parseHistoryMetricPoints(rawPayload, key: "2.1", isTemperature: true)
        #expect(parsed.count == 3)
        #expect(abs(parsed[0].value - 22.7) < 0.001)
        #expect(abs(parsed[1].minValue - 21.4) < 0.001)
        #expect(abs(parsed[1].maxValue - 24.8) < 0.001)
        #expect(abs(parsed[2].value - 23.6) < 0.05)

        // MiBeacon v2/v3 tenths-scaled integer payload ("4100" / "1004" / "1006")
        let scaledPayload: JSONValue = .array([
            .object(["time": .number(1_760_000_000), "value": .string("[235]")]),
            .object(["time": .number(1_760_003_600), "value": .string("eb00")]), // 0x00eb = 235 -> 23.5°C
            .object(["time": .number(1_760_007_200), "value": .number(50)]),     // 50 tenths -> 5.0°C (not 50°C)
        ])
        let scaledParsed = MiCloudClient.parseHistoryMetricPoints(scaledPayload, key: "1004", isTemperature: true)
        #expect(scaledParsed.count == 3)
        #expect(abs(scaledParsed[0].value - 23.5) < 0.001)
        #expect(abs(scaledParsed[1].value - 23.5) < 0.001)
        #expect(abs(scaledParsed[2].value - 5.0) < 0.001)

        // Humidity hex "b603" (0x03b6 = 950 tenths = 95.0%) must be scaled once, not twice to 9.5%.
        let humPayload: JSONValue = .array([
            .object(["time": .number(1_760_000_000), "value": .string("b603")]),
        ])
        let humParsed = MiCloudClient.parseHistoryMetricPoints(humPayload, key: "1006", isTemperature: false)
        #expect(humParsed.count == 1)
        #expect(abs(humParsed[0].value - 95.0) < 0.001)
    }

    @Test("Aggregates multiple raw cloud samples in the same hour/day before replacing the bucket idempotently")
    @MainActor
    func aggregatesSameBucketCloudSamplesIdempotently() throws {
        let suiteName = "SensorHistoryTests.rawAgg.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cal = Self.fixedCalendar()
        let history = SensorHistory(defaults: defaults, calendar: cal)
        let hourBase = Date(timeIntervalSince1970: 1_760_000_400)
        let now = hourBase.addingTimeInterval(600)

        let rawSamples = [
            SensorHistorySample(timestamp: hourBase.addingTimeInterval(120), temperature: 20.0, humidity: 40.0),
            SensorHistorySample(timestamp: hourBase.addingTimeInterval(300), temperature: 30.0, humidity: 60.0),
        ]

        // Merge twice to verify idempotency as well as multi-sample aggregation within the same bucket.
        history.mergeCloudSamples(deviceId: "blt.3.sensor1", window: .last24Hours, samples: rawSamples, now: now)
        history.mergeCloudSamples(deviceId: "blt.3.sensor1", window: .last24Hours, samples: rawSamples, now: now)

        let pt24h = try #require(history.points(forDevice: "blt.3.sensor1", window: .last24Hours, now: now).last)
        #expect(abs((pt24h.temperature ?? 0) - 25.0) < 0.001)
        #expect(abs((pt24h.minTemperature ?? 0) - 20.0) < 0.001)
        #expect(abs((pt24h.maxTemperature ?? 0) - 30.0) < 0.001)
        #expect(abs((pt24h.humidity ?? 0) - 50.0) < 0.001)
        #expect(abs((pt24h.minHumidity ?? 0) - 40.0) < 0.001)
        #expect(abs((pt24h.maxHumidity ?? 0) - 60.0) < 0.001)

        history.mergeCloudSamples(deviceId: "blt.3.sensor1", window: .last7Days, samples: rawSamples, now: now)
        history.mergeCloudSamples(deviceId: "blt.3.sensor1", window: .last7Days, samples: rawSamples, now: now)

        let pt7d = try #require(history.points(forDevice: "blt.3.sensor1", window: .last7Days, now: now).last)
        #expect(abs((pt7d.temperature ?? 0) - 25.0) < 0.001)
        #expect(abs((pt7d.minTemperature ?? 0) - 20.0) < 0.001)
        #expect(abs((pt7d.maxTemperature ?? 0) - 30.0) < 0.001)
    }

    @Test("Scopes sensor history by source connection so identical entity IDs on different servers stay isolated")
    @MainActor
    func isolatesHistoryAcrossConnections() throws {
        let suiteName = "SensorHistoryTests.scope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cal = Self.fixedCalendar()
        let history = SensorHistory(defaults: defaults, calendar: cal, connectionScope: "ha:http://192.168.1.10:8123")
        let now = Date(timeIntervalSince1970: 1_760_000_400)

        let makeSensor = { (temp: Double) in
            SmartDevice(
                id: "sensor.temperature",
                name: "客厅温度计",
                roomId: "living",
                roomName: "客厅",
                model: "ha.sensor",
                isOnline: true,
                kind: .sensor(SensorSpec(temperature: temp, humidity: 50))
            )
        }

        history.record(devices: [makeSensor(21.5)], now: now)
        #expect(history.points(forDevice: "sensor.temperature", window: .last24Hours, now: now).last?.temperature == 21.5)

        // Switching to a second Home Assistant server isolates its `sensor.temperature` entity.
        history.setConnectionScope("ha:http://192.168.1.20:8123")
        #expect(history.points(forDevice: "sensor.temperature", window: .last24Hours, now: now).last?.temperature == nil)

        history.record(devices: [makeSensor(28.0)], now: now)
        #expect(history.points(forDevice: "sensor.temperature", window: .last24Hours, now: now).last?.temperature == 28.0)

        // Reloading from disk preserves both scopes independently.
        let reloadedFirst = SensorHistory(defaults: defaults, calendar: cal, connectionScope: "ha:http://192.168.1.10:8123")
        #expect(reloadedFirst.points(forDevice: "sensor.temperature", window: .last24Hours, now: now).last?.temperature == 21.5)
        let reloadedSecond = SensorHistory(defaults: defaults, calendar: cal, connectionScope: "ha:http://192.168.1.20:8123")
        #expect(reloadedSecond.points(forDevice: "sensor.temperature", window: .last24Hours, now: now).last?.temperature == 28.0)
    }

    @Test("MiotSynthesizer resolves temperature and humidity property keys from MIoT spec")
    func resolvesSensorPropertyKeys() throws {
        let specJSON = """
        {
          "type": "urn:miot-spec-v2:device:temperature-humidity-sensor:0000A00A:miaomiaoce-t2:1",
          "description": "Temperature Humidity Sensor",
          "services": [
            {
              "iid": 2,
              "type": "urn:miot-spec-v2:service:temperature-humidity-sensor:00007814:miaomiaoce-t2:1",
              "description": "Temperature Humidity Sensor",
              "properties": [
                {
                  "iid": 1,
                  "type": "urn:miot-spec-v2:property:temperature:00000020:miaomiaoce-t2:1",
                  "description": "Temperature",
                  "format": "float",
                  "access": ["read", "notify"],
                  "unit": "celsius"
                },
                {
                  "iid": 2,
                  "type": "urn:miot-spec-v2:property:relative-humidity:0000000C:miaomiaoce-t2:1",
                  "description": "Relative Humidity",
                  "format": "uint8",
                  "access": ["read", "notify"],
                  "unit": "percentage"
                }
              ]
            }
          ]
        }
        """
        let spec = try JSONDecoder().decode(MiotDeviceSpec.self, from: Data(specJSON.utf8))
        let rawDevice = MiDeviceRecord(
            did: "blt.3.sensor1",
            name: "主卧温湿度计",
            model: "miaomiaoce.sensor_ht.t2",
            isOnline: true
        )
        let keys = MiotSynthesizer.sensorPropertyKeys(for: rawDevice, spec: spec)
        #expect(keys.temperature == "2.1")
        #expect(keys.humidity == "2.2")
    }

    @Test("DemoHomeProvider synthesizes 24h and 7d sensor history curves")
    func demoProviderSynthesizesHistory() async {
        let provider = DemoHomeProvider()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let samples24h = await provider.fetchSensorHistory(
            deviceId: "demo_living_sensor",
            window: .last24Hours,
            now: now
        )
        #expect(samples24h.count == 24)
        #expect(samples24h.allSatisfy { $0.temperature != nil && $0.humidity != nil })

        let samples7d = await provider.fetchSensorHistory(
            deviceId: "demo_living_sensor",
            window: .last7Days,
            now: now
        )
        #expect(samples7d.count == 7)
        #expect(samples7d.allSatisfy { $0.minTemperature != nil && $0.maxTemperature != nil })
    }
}
