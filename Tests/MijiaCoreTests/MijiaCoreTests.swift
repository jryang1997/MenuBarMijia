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
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
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

    @Test("Slice 1: Scene synthesis and QuickAction execution with 5-second undo")
    @MainActor
    func scenesAndQuickActions() async throws {
        let areas = [HAAreaEntry(area_id: "ke_ting", name: "客厅")]
        let devices = [
            HADeviceEntry(id: "dev_light", area_id: "ke_ting", name: "吸顶灯", model: "yeelink.light.ceiling20"),
            HADeviceEntry(id: "dev_plug", area_id: "ke_ting", name: "咖啡机", model: "cuco.plug.v3")
        ]
        let entities = [
            HAEntityEntry(entity_id: "light.living", device_id: "dev_light", area_id: "ke_ting"),
            HAEntityEntry(entity_id: "switch.coffee", device_id: "dev_plug", area_id: "ke_ting"),
            HAEntityEntry(entity_id: "scene.movie_mode", area_id: "ke_ting", name: "观影模式")
        ]
        let states: [String: HAEntityState] = [
            "light.living": HAEntityState(
                entityId: "light.living",
                state: "on",
                attributes: ["brightness": .number(255), "color_temp_kelvin": .number(5000)]
            ),
            "switch.coffee": HAEntityState(
                entityId: "switch.coffee",
                state: "on",
                attributes: ["electric_power": .number(800)]
            ),
            "scene.movie_mode": HAEntityState(
                entityId: "scene.movie_mode",
                state: "scening",
                attributes: ["friendly_name": .string("观影模式")]
            )
        ]

        let snapshot = DeviceSynthesizer.synthesize(
            areas: areas,
            devices: devices,
            entities: entities,
            states: states
        )
        #expect(snapshot.scenes.count == 1)
        #expect(snapshot.scenes.first?.name == "观影模式")

        let mapped = HAWebSocketProvider.mapCommandToService(.activateScene(entityId: "scene.movie_mode"))
        #expect(mapped.domain == "scene")
        #expect(mapped.service == "turn_on")

        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.slice1.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Execute QuickAction.lightsOff -> turns off light, keeps coffee plug on
        store.executeQuickAction(.lightsOff)
        let lightAfterOff = try #require(store.devices.first(where: { $0.id == "dev_light" }))
        let plugAfterOff = try #require(store.devices.first(where: { $0.id == "dev_plug" }))
        #expect(lightAfterOff.isActiveOn == false)
        #expect(plugAfterOff.isActiveOn == true)
        #expect(store.undoBanner != nil)

        // Undo restores the light
        store.undoTurnAllOff()
        let lightRestored = try #require(store.devices.first(where: { $0.id == "dev_light" }))
        #expect(lightRestored.isActiveOn == true)

        // Execute QuickAction.softNightLight -> sets light to 15% and 2700K
        store.executeQuickAction(.softNightLight)
        let lightNight = try #require(store.devices.first(where: { $0.id == "dev_light" }))
        if case .light(let spec) = lightNight.kind {
            #expect(spec.isOn == true)
            #expect(spec.brightnessPercent == 15)
            #expect(spec.colorTempKelvin == 2700)
        } else {
            Issue.record("Expected light device")
        }
    }

    @Test("Slice 2: Keyboard navigation, quick number 1-9 toggle, drawer step, and room cycling")
    @MainActor
    func keyboardNavigationAndQuickIndex() async throws {
        let d1 = SmartDevice(
            id: "dev_1",
            name: "客厅吸顶灯",
            roomId: "ke_ting",
            roomName: "客厅",
            model: "yeelink.light.ceiling20",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.living", isOn: true, brightnessPercent: 50))
        )
        let d2 = SmartDevice(
            id: "dev_2",
            name: "书房空调",
            roomId: "shu_fang",
            roomName: "书房",
            model: "xiaomi.ac",
            isOnline: true,
            kind: .climate(ClimateSpec(entityId: "climate.study", isOn: true, hvacMode: "cool", availableModes: ["cool", "off"], targetTemperature: 25))
        )
        let snapshot = SynthesizedHome(
            rooms: [
                RoomArea(id: "ke_ting", name: "客厅", sortOrder: 1),
                RoomArea(id: "shu_fang", name: "书房", sortOrder: 2)
            ],
            devices: [d1, d2]
        )

        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.slice2.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        // 1. Quick index 1 toggles 1st device (dev_1) off
        store.selectQuickIndex(1)
        #expect(store.devices.first(where: { $0.id == "dev_1" })?.isActiveOn == false)

        // 2. Focus movement & Space/Enter toggle
        store.moveFocus(delta: 1) // focuses first device (dev_1)
        #expect(store.focusedDeviceId == "dev_1")
        store.toggleFocusedDevice() // turns dev_1 back on
        #expect(store.devices.first(where: { $0.id == "dev_1" })?.isActiveOn == true)

        // 3. Right arrow on unexpanded focused device expands its drawer; second right arrow steps brightness +10%
        store.adjustFocusedDevice(delta: 1)
        #expect(store.expandedDeviceId == "dev_1")
        store.adjustFocusedDevice(delta: 1)
        if case .light(let spec) = store.devices.first(where: { $0.id == "dev_1" })?.kind {
            #expect(spec.brightnessPercent == 60)
        } else {
            Issue.record("Expected light spec")
        }

        // 4. Tab cycles room filter: nil -> ke_ting -> shu_fang -> nil
        #expect(store.selectedRoomId == nil)
        store.cycleRoom(delta: 1)
        #expect(store.selectedRoomId == "ke_ting")
        store.cycleRoom(delta: 1)
        #expect(store.selectedRoomId == "shu_fang")
        store.cycleRoom(delta: 1)
        #expect(store.selectedRoomId == nil)
    }

    @Test("Slice 3: Custom favorite ordering, single-device hiding, and compact grid preference")
    @MainActor
    func viewPreferencesOrderingAndHiding() async throws {
        let devs = [
            SmartDevice(id: "dev_1", name: "设备1", roomId: "r1", roomName: "客厅", model: "m1", isOnline: true, kind: .light(LightSpec(entityId: "light.1", isOn: true))),
            SmartDevice(id: "dev_2", name: "设备2", roomId: "r1", roomName: "客厅", model: "m2", isOnline: true, kind: .light(LightSpec(entityId: "light.2", isOn: true))),
            SmartDevice(id: "dev_3", name: "设备3", roomId: "r1", roomName: "客厅", model: "m3", isOnline: true, kind: .light(LightSpec(entityId: "light.3", isOn: true)))
        ]
        let suiteName = "test.slice3.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: SynthesizedHome(rooms: [RoomArea(id: "r1", name: "客厅")], devices: devs))
        let store = HomeStore(provider: mock, defaultsSuiteName: suiteName)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.favoriteDevices.map(\.id) == ["dev_1", "dev_2", "dev_3"])

        // Move dev_3 up (-1)
        store.moveFavorite(deviceId: "dev_3", direction: -1)
        #expect(store.favoriteDevices.map(\.id) == ["dev_1", "dev_3", "dev_2"])

        // Hide dev_3 -> disappears from filteredDevices & favoriteDevices, appears in hiddenDevices
        store.hideDevice("dev_3")
        #expect(store.favoriteDevices.map(\.id) == ["dev_1", "dev_2"])
        #expect(store.hiddenDevices.map(\.id) == ["dev_3"])

        // Unhide dev_3 -> returns in its custom order position
        store.unhideDevice("dev_3")
        #expect(store.favoriteDevices.map(\.id) == ["dev_1", "dev_3", "dev_2"])
        #expect(store.hiddenDevices.isEmpty)

        // Toggle compact grid mode
        #expect(store.isCompactGridMode == false)
        store.isCompactGridMode = true
        #expect(store.isCompactGridMode == true)
    }

    @Test("Slice 4: Dynamic menu bar metrics (temp+humidity, total power) and SafetyAlert evaluation")
    @MainActor
    func dynamicMenuBarAndSafetyAlerts() async throws {
        let coffeePlug = SmartDevice(
            id: "dev_coffee",
            name: "咖啡机",
            roomId: "chu_fang",
            roomName: "厨房",
            model: "cuco.plug.v3",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "switch.coffee", isOn: true, powerWatts: 1150))
        )
        let studySensor = SmartDevice(
            id: "dev_sensor_study",
            name: "书房温湿度计",
            roomId: "shu_fang",
            roomName: "书房",
            model: "miaomiaoce.sensor_ht.t2",
            isOnline: true,
            kind: .sensor(SensorSpec(temperature: 24.8, humidity: 52.0, battery: 12))
        )
        let snapshot = SynthesizedHome(
            rooms: [
                RoomArea(id: "chu_fang", name: "厨房"),
                RoomArea(id: "shu_fang", name: "书房")
            ],
            devices: [coffeePlug, studySensor],
            environmentReadings: [
                EnvironmentReading(id: "dev_sensor_study", label: "书房", roomName: "书房", temperature: 24.8, humidity: 52.0, battery: 12)
            ]
        )

        let suiteName = "test.slice4.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, defaultsSuiteName: suiteName)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        // 1. Dynamic menu bar target: temp+humidity and total power
        store.menuBarTargetId = "temp_hum:dev_sensor_study"
        #expect(store.menuBarText == "24.8° 52%")

        store.menuBarTargetId = "power:total"
        #expect(store.totalPowerWatts == 1150)
        #expect(store.menuBarText == "1150W")

        // 2. SafetyAlert: Low battery (<15%) triggers immediately on first check, then cools down for 24h
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let initialAlerts = store.evaluateSafetyAlerts(now: t0)
        #expect(initialAlerts.contains(where: { $0.deviceId == "dev_sensor_study" && $0.title.contains("电量") }))

        let duplicateCheck = store.evaluateSafetyAlerts(now: t0.addingTimeInterval(60))
        #expect(duplicateCheck.isEmpty)

        // 3. SafetyAlert: Coffee plug running >= 45 minutes triggers actionable alert with turnOffCommand
        let after46Min = t0.addingTimeInterval(46 * 60)
        let longRunAlerts = store.evaluateSafetyAlerts(now: after46Min)
        let coffeeAlert = try #require(longRunAlerts.first(where: { $0.deviceId == "dev_coffee" }))
        #expect(coffeeAlert.turnOffCommand == .setSwitch(entityId: "switch.coffee", isOn: false))

        // 4. SafetyAlert: Starred device (dev_coffee) going offline triggers offline alert
        var offlineCoffee = coffeePlug
        offlineCoffee.isOnline = false
        await mock.updateSnapshot(
            SynthesizedHome(
                rooms: snapshot.rooms,
                devices: [offlineCoffee, studySensor],
                environmentReadings: snapshot.environmentReadings
            )
        )
        try await Task.sleep(for: .milliseconds(50))
        let offlineAlerts = store.evaluateSafetyAlerts(now: after46Min.addingTimeInterval(30))
        #expect(offlineAlerts.contains(where: { $0.deviceId == "dev_coffee" && $0.title.contains("离线") }))
    }
}
