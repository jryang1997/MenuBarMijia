import Foundation
import Testing
@testable import MijiaCore

struct MijiaCoreTests {
    @Test("DeviceSynthesizer merges multi-entity devices and filters indicator noise")
    func synthesizerMergesAndFilters() {
        let areas = [
            HAAreaEntry(area_id: "wo_shi", name: "卧室"),
            HAAreaEntry(area_id: "shu_fang", name: "书房"),
            HAAreaEntry(area_id: "chu_fang", name: "厨房")
        ]

        let devices = [
            HADeviceEntry(id: "dev_light_study", area_id: "shu_fang", name: "吸顶灯", model: "yeelink.light.ceiling20"),
            HADeviceEntry(id: "dev_plug_coffee", area_id: "chu_fang", name: "咖啡机", model: "cuco.plug.v3"),
            HADeviceEntry(id: "dev_sensor_bed", area_id: "wo_shi", name: "主卧温湿度计", model: "miaomiaoce.sensor_ht.t2"),
            HADeviceEntry(id: "dev_gateway", area_id: "chu_fang", name: "网关", model: "lumi.gateway.mgl03")
        ]

        let entities = [
            HAEntityEntry(entity_id: "light.study_ceiling", device_id: "dev_light_study", area_id: "shu_fang"),
            HAEntityEntry(entity_id: "switch.cuco_on_p_2_1", device_id: "dev_plug_coffee", area_id: "chu_fang"),
            HAEntityEntry(entity_id: "light.cuco_s_13_indicator_light", device_id: "dev_plug_coffee", entity_category: "config"),
            HAEntityEntry(entity_id: "sensor.cuco_electric_power", device_id: "dev_plug_coffee"),
            HAEntityEntry(entity_id: "sensor.bed_temperature", device_id: "dev_sensor_bed"),
            HAEntityEntry(entity_id: "sensor.bed_relative_humidity", device_id: "dev_sensor_bed"),
            HAEntityEntry(entity_id: "light.gateway_indicator_light", device_id: "dev_gateway", entity_category: "config")
        ]

        let states: [String: HAEntityState] = [
            "light.study_ceiling": HAEntityState(
                entityId: "light.study_ceiling",
                state: "on",
                attributes: [
                    "brightness": .number(204),
                    "color_temp_kelvin": .number(4500),
                    "effect_list": .array([.string("Day"), .string("Night")])
                ]
            ),
            "switch.cuco_on_p_2_1": HAEntityState(entityId: "switch.cuco_on_p_2_1", state: "on"),
            "light.cuco_s_13_indicator_light": HAEntityState(entityId: "light.cuco_s_13_indicator_light", state: "on"),
            "sensor.cuco_electric_power": HAEntityState(entityId: "sensor.cuco_electric_power", state: "1150"),
            "sensor.bed_temperature": HAEntityState(entityId: "sensor.bed_temperature", state: "26.6"),
            "sensor.bed_relative_humidity": HAEntityState(entityId: "sensor.bed_relative_humidity", state: "57.1"),
            "light.gateway_indicator_light": HAEntityState(entityId: "light.gateway_indicator_light", state: "on")
        ]

        let home = DeviceSynthesizer.synthesize(
            areas: areas,
            devices: devices,
            entities: entities,
            states: states
        )

        // Gateway indicator device must be excluded
        #expect(home.devices.count == 3)
        #expect(home.environmentReadings.count == 1)
        #expect(home.environmentReadings.first?.temperature == 26.6)
        #expect(home.environmentReadings.first?.humidity == 57.1)

        // Study light name should be disambiguated to "书房吸顶灯"
        let studyLight = home.devices.first(where: { $0.id == "dev_light_study" })
        #expect(studyLight?.name == "书房吸顶灯")
        if case .light(let spec) = studyLight?.kind {
            #expect(spec.isOn == true)
            #expect(spec.brightnessPercent == 80)
            #expect(spec.colorTempKelvin == 4500)
        } else {
            Issue.record("Expected studyLight to be .light")
        }

        // Coffee plug should be synthesized as .plug (not .light from its indicator light)
        let coffee = home.devices.first(where: { $0.id == "dev_plug_coffee" })
        if case .plug(let spec) = coffee?.kind {
            #expect(spec.isOn == true)
            #expect(spec.powerWatts == 1150)
        } else {
            Issue.record("Expected coffee machine to be .plug")
        }
    }

    @Test("HomeStore optimistic toggle, turnAllOff, and undo")
    @MainActor
    func optimisticToggleAndUndo() async throws {
        let lightDevice = SmartDevice(
            id: "dev_1",
            name: "主卧吸顶灯",
            roomId: "wo_shi",
            roomName: "卧室",
            model: "yeelink.light.ceiling13",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.bed", isOn: false))
        )
        let snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "wo_shi", name: "卧室", sortOrder: 1)],
            devices: [lightDevice],
            environmentReadings: [EnvironmentReading(id: "env1", label: "主卧", roomName: "卧室", temperature: 26.6, humidity: 57.0)]
        )

        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock)

        // Allow initial stream event to arrive
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.devices.count == 1)
        #expect(store.activeDeviceCount == 0)

        // 1. Optimistic toggle ON
        let current = try #require(store.devices.first)
        store.togglePrimary(current)
        #expect(store.activeDeviceCount == 1)

        try await Task.sleep(for: .milliseconds(40))
        let cmds = await mock.executedCommands
        #expect(cmds.last == .setLightPower(entityId: "light.bed", isOn: true))

        // 2. Turn all off + Undo
        store.turnAllOff()
        #expect(store.activeDeviceCount == 0)
        #expect(store.undoBanner != nil)

        store.undoTurnAllOff()
        #expect(store.activeDeviceCount == 1)
        #expect(store.undoBanner == nil)
    }

    @Test("HAWebSocketProvider connects to live NAS when HA_RUN_LIVE_TEST=1 is set")
    func liveNASConnectionAndSynthesis() async throws {
        guard ProcessInfo.processInfo.environment["HA_RUN_LIVE_TEST"] == "1" else {
            return
        }
        let token = KeychainHelper.loadToken()
        guard !token.isEmpty else {
            return
        }
        let serverURL = ProcessInfo.processInfo.environment["HA_SERVER_URL"]
            ?? UserDefaults.standard.string(forKey: "ha_server_url")
            ?? KeychainHelper.defaultNASURL

        let provider = HAWebSocketProvider(
            baseURLString: serverURL,
            token: token
        )
        var receivedHome: SynthesizedHome?
        for await event in provider.events() {
            switch event {
            case .statusChanged(let status):
                if case .disconnected = status {
                    return
                }
            case .snapshotUpdated(let home):
                receivedHome = home
                break
            }
            if receivedHome != nil { break }
        }
        let home = try #require(receivedHome)
        #expect(!home.devices.isEmpty)
    }
}
