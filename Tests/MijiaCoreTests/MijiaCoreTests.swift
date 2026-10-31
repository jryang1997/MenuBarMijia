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
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.toggle.undo.\(UUID().uuidString)")

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

        for _ in 0..<200 {
            if !(await mock.executedCommands).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
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

        // Compact two-column tiles are the default (#64) and still toggle off
        #expect(store.isCompactGridMode == true)
        store.isCompactGridMode = false
        #expect(store.isCompactGridMode == false)
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
        L10n.$overrideTemperatureUnit.withValue(.celsius) {
            #expect(store.menuBarText == "24.8°C 52%")
        }

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

    @Test("Device aliases update HomeStore device names, work with voice/text commands, and preserve original Mi Home names")
    @MainActor
    func deviceAliasesUpdateStoreAndAssistantCommands() async throws {
        let splitSwitch = SmartDevice(
            id: "dev_split_2",
            name: "领普三键开关（中键）",
            roomId: "can_ting",
            roomName: "餐厅",
            model: "linp.switch.q33",
            isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "miot:100.s2:2:1", isOn: false, powerWatts: nil, childLockEntityId: nil))
        )
        let snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "can_ting", name: "餐厅")],
            devices: [splitSwitch]
        )
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.aliases.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        store.applyDeviceAliases(["dev_split_2": "餐边柜射灯"])
        #expect(store.devices.first?.name == "餐边柜射灯")
        #expect(store.originalDeviceName(for: "dev_split_2") == "领普三键开关（中键）")

        let plan = await store.runAssistantCommand("打开餐边柜射灯")
        #expect(plan?.intents.count == 1)
        #expect(store.devices.first?.isActiveOn == true)

        store.applyDeviceAliases([:])
        #expect(store.devices.first?.name == "领普三键开关（中键）")
    }

    @Test("Issue #97: Home Assistant and Mi Cloud cameras synthesize, map controls, exclude from All Off by default, and resolve live streams")
    @MainActor
    func cameraSynthesisControlsAndStreamResolution() async throws {
        let areas = [HAAreaEntry(area_id: "living", name: "客厅")]
        let devices = [
            HADeviceEntry(id: "dev_cam_1", area_id: "living", name: "客厅摄像机", model: "chuangmi.camera.81ac1")
        ]
        let entities = [
            HAEntityEntry(entity_id: "camera.living_cam", device_id: "dev_cam_1"),
            HAEntityEntry(entity_id: "switch.living_cam_power", device_id: "dev_cam_1"),
            HAEntityEntry(entity_id: "switch.living_cam_motion_detection", device_id: "dev_cam_1"),
            HAEntityEntry(entity_id: "select.living_cam_night_shot", device_id: "dev_cam_1")
        ]
        let states: [String: HAEntityState] = [
            "camera.living_cam": HAEntityState(
                entityId: "camera.living_cam",
                state: "streaming",
                attributes: ["access_token": .string("tok123")]
            ),
            "switch.living_cam_power": HAEntityState(entityId: "switch.living_cam_power", state: "on"),
            "switch.living_cam_motion_detection": HAEntityState(entityId: "switch.living_cam_motion_detection", state: "on"),
            "select.living_cam_night_shot": HAEntityState(
                entityId: "select.living_cam_night_shot",
                state: "Auto",
                attributes: ["options": .array([.string("Off"), .string("On"), .string("Auto")])]
            )
        ]

        let home = DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: states)
        let cam = try #require(home.devices.first(where: { $0.id == "dev_cam_1" }))
        guard case .camera(let spec) = cam.kind else {
            Issue.record("Expected .camera DeviceKind")
            return
        }
        #expect(spec.isOn == true)
        #expect(spec.nightShot == "Auto")
        #expect(spec.availableNightShots == ["Off", "On", "Auto"])
        #expect(spec.motionDetectionEntityId == "switch.living_cam_motion_detection")
        #expect(spec.isMotionDetectionOn == true)
        #expect(spec.streamEntityId == "camera.living_cam")
        #expect(spec.snapshotPath == "/api/camera_proxy/camera.living_cam?token=tok123")
        #expect(HomeStore.joinsAllOffByDefault(cam) == false)

        // Verify HA service mapping for composite power|select entityId and camera#motion
        let powerCall = HAWebSocketProvider.mapCommandToService(.setSwitch(entityId: spec.entityId, isOn: false))
        #expect(powerCall.domain == "switch")
        #expect(powerCall.service == "turn_off")
        #expect(powerCall.payload["entity_id"] as? String == "switch.living_cam_power")

        let nightCall = HAWebSocketProvider.mapCommandToService(.setSelectOption(entityId: spec.entityId, option: "On"))
        #expect(nightCall.domain == "select")
        #expect(nightCall.service == "select_option")
        #expect(nightCall.payload["entity_id"] as? String == "select.living_cam_night_shot")
        #expect(nightCall.payload["option"] as? String == "On")

        let motionCall = HAWebSocketProvider.mapCommandToService(.setSwitch(entityId: "camera.living_cam#motion", isOn: true))
        #expect(motionCall.domain == "camera")
        #expect(motionCall.service == "enable_motion_detection")
        #expect(motionCall.payload["entity_id"] as? String == "camera.living_cam")

        // Verify MiCloudProvider stream URL extraction from MIoT start-hls-stream action response
        let actionResult: JSONValue = .object([
            "code": .number(0),
            "out": .array([.string("https://stream.api.io.mi.com/live/cam1/index.m3u8")])
        ])
        #expect(MiCloudProvider.extractStreamURL(from: actionResult)?.absoluteString == "https://stream.api.io.mi.com/live/cam1/index.m3u8")

        // Verify HomeStore controls, live view callback, and custom stream URL resolution
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.camera.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        var openedCameraId: String?
        store.onOpenCameraLiveView = { openedCameraId = $0.id }
        store.openCameraLiveView("dev_cam_1")
        #expect(openedCameraId == "dev_cam_1")
        #expect(store.activeLiveCameraDeviceId == "dev_cam_1")

        store.setCameraNightShot("dev_cam_1", mode: "On")
        store.setCameraMotionDetection("dev_cam_1", enabled: false)
        var cmds: [DeviceCommand] = []
        for _ in 0..<50 {
            cmds = await mock.executedCommands
            if cmds.contains(.setSelectOption(entityId: spec.entityId, option: "On"))
                && cmds.contains(.setSwitch(entityId: "switch.living_cam_motion_detection", isOn: false))
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(cmds.contains(.setSelectOption(entityId: spec.entityId, option: "On")))
        #expect(cmds.contains(.setSwitch(entityId: "switch.living_cam_motion_detection", isOn: false)))

        store.setCameraCustomStreamURL("http://127.0.0.1:1984/api/stream.m3u8?src=living", for: "dev_cam_1")
        let resolved = try await store.resolveCameraStream(for: "dev_cam_1")
        #expect(resolved == .hls(URL(string: "http://127.0.0.1:1984/api/stream.m3u8?src=living")!))
    }

    @Test("Issue #98: Air purifier (zhimi.airp.rma3) synthesizes PM2.5, air quality, temperature/humidity, filter life, and maps speed slider to Favorite fan-level")
    @MainActor
    func airPurifierSynthesisAndControls() async throws {
        let areas = [HAAreaEntry(area_id: "study", name: "书房")]
        let devices = [
            HADeviceEntry(id: "dev_airp_1", area_id: "study", name: "米家空气净化器 4 Lite", model: "zhimi.airp.rma3")
        ]
        let entities = [
            HAEntityEntry(entity_id: "fan.study_airp", device_id: "dev_airp_1", area_id: "study"),
            HAEntityEntry(entity_id: "sensor.study_airp_pm2_5_density", device_id: "dev_airp_1", area_id: "study"),
            HAEntityEntry(entity_id: "sensor.study_airp_air_quality", device_id: "dev_airp_1", area_id: "study"),
            HAEntityEntry(entity_id: "sensor.study_airp_temperature", device_id: "dev_airp_1", area_id: "study"),
            HAEntityEntry(entity_id: "sensor.study_airp_relative_humidity", device_id: "dev_airp_1", area_id: "study"),
            HAEntityEntry(entity_id: "sensor.study_airp_filter_life_level", device_id: "dev_airp_1", area_id: "study")
        ]
        let states: [String: HAEntityState] = [
            "fan.study_airp": HAEntityState(
                entityId: "fan.study_airp",
                state: "on",
                attributes: [
                    "percentage": .number(50),
                    "preset_mode": .string("Auto"),
                    "preset_modes": .array([.string("Auto"), .string("Sleep"), .string("Favorite")])
                ]
            ),
            "sensor.study_airp_pm2_5_density": HAEntityState(entityId: "sensor.study_airp_pm2_5_density", state: "18"),
            "sensor.study_airp_air_quality": HAEntityState(entityId: "sensor.study_airp_air_quality", state: "Excellent"),
            "sensor.study_airp_temperature": HAEntityState(entityId: "sensor.study_airp_temperature", state: "24.5"),
            "sensor.study_airp_relative_humidity": HAEntityState(entityId: "sensor.study_airp_relative_humidity", state: "52"),
            "sensor.study_airp_filter_life_level": HAEntityState(entityId: "sensor.study_airp_filter_life_level", state: "86")
        ]

        let home = DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: states)
        let purifier = try #require(home.devices.first(where: { $0.id == "dev_airp_1" }))
        #expect(purifier.sfSymbolName == "aqi.medium")
        #expect(purifier.statusSubtitle.contains("PM2.5 18"))
        #expect(purifier.statusSubtitle.contains("52%"))
        guard case .fan(let spec) = purifier.kind else {
            Issue.record("Expected .fan(FanSpec) for air purifier")
            return
        }
        #expect(spec.pm25Density == 18)
        #expect(spec.airQuality == "Excellent")
        #expect(spec.temperature == 24.5)
        #expect(spec.humidity == 52)
        #expect(spec.filterLifePercent == 86)

        let pctCall = HAWebSocketProvider.mapCommandToService(.setFanPercentage(entityId: spec.entityId, percent: 80))
        #expect(pctCall.domain == "fan")
        #expect(pctCall.service == "set_percentage")
        #expect(pctCall.payload["percentage"] as? Int == 80)

        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.airp.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.setFanPercentage("dev_airp_1", percent: 80)
        if let updated = store.devices.first(where: { $0.id == "dev_airp_1" }),
           case .fan(let updatedSpec) = updated.kind {
            #expect(updatedSpec.percentage == 80)
            #expect(updatedSpec.presetMode == "Favorite")
        }
    }

    @Test("Issue #98 survey: secondary light services no longer claim hood/airer/bath-heater cards; video-doorbell controls map to camera")
    func miotServiceSelectionGuards() throws {
        func spec(_ type: String, _ services: [MiotService]) -> MiotDeviceSpec {
            MiotDeviceSpec(type: type, services: services)
        }
        func prop(_ name: String, _ access: [String], range: [Double]? = nil) -> MiotProperty {
            MiotProperty(
                iid: 1,
                type: "urn:miot-spec-v2:property:\(name):00000000:test:1",
                format: range == nil ? "bool" : "uint8",
                access: access,
                valueRange: range
            )
        }
        func service(_ iid: Int, _ name: String, _ props: [MiotProperty]) -> MiotService {
            MiotService(iid: iid, type: "urn:miot-spec-v2:service:\(name):00000000:test:1", properties: props)
        }

        // Hood carries a lamp: the lamp must not become the whole device card.
        let hood = spec("urn:miot-spec-v2:device:hood:0000A01B:viomi-c4:1", [
            service(2, "hood", [prop("on", ["read", "write"])]),
            service(6, "light", [prop("on", ["read", "write"])]),
        ])
        #expect(MiotSynthesizer.supportedServiceName(for: hood) == nil)

        // Ceiling fan: the fan service is the device, the light is the accessory.
        let ceilingFan = spec("urn:miot-spec-v2:device:ceiling-fan:0000A02C:test:1", [
            service(2, "fan", [prop("on", ["read", "write"]), prop("fan-level", ["read", "write"], range: [1, 100, 1])]),
            service(3, "light", [prop("on", ["read", "write"])]),
        ])
        #expect(MiotSynthesizer.supportedServiceName(for: ceilingFan) == "fan")

        // Video doorbell: the video-doorbell service exposes camera-style controls.
        let doorbell = spec("urn:miot-spec-v2:device:video-doorbell:0000A03A:xiaomi-4pro:1", [
            service(2, "video-doorbell", [prop("on", ["read", "write"]), prop("night-shot", ["read", "write"])]),
        ])
        #expect(MiotSynthesizer.supportedServiceName(for: doorbell) == "video-doorbell")

        // Real lights keep synthesizing as lights.
        let plainLight = spec("urn:miot-spec-v2:device:light:0000A001:yeelink-1:1", [
            service(2, "light", [prop("on", ["read", "write"]), prop("brightness", ["read", "write"], range: [1, 100, 1])]),
        ])
        #expect(MiotSynthesizer.supportedServiceName(for: plainLight) == "light")
    }

    @Test("Issue #103: menu-bar and environment readings include online climate and air-purifier temperatures while excluding offline devices")
    @MainActor
    func environmentReadingsIncludeClimateAndAirPurifierAndExcludeOffline() async throws {
        let areas = [
            HAAreaEntry(area_id: "living", name: "客厅"),
            HAAreaEntry(area_id: "study", name: "书房"),
            HAAreaEntry(area_id: "bed", name: "主卧"),
        ]
        let devices = [
            HADeviceEntry(id: "dev_ac_living", area_id: "living", name: "客厅空调", model: "xiaomi.aircondition.mc5"),
            HADeviceEntry(id: "dev_ac_offline", area_id: "bed", name: "主卧空调", model: "xiaomi.aircondition.mc5"),
            HADeviceEntry(id: "dev_airp_study", area_id: "study", name: "米家空气净化器 4 Lite", model: "zhimi.airp.rma3"),
        ]
        let entities = [
            HAEntityEntry(entity_id: "climate.living_ac", device_id: "dev_ac_living"),
            HAEntityEntry(entity_id: "climate.bed_ac", device_id: "dev_ac_offline"),
            HAEntityEntry(entity_id: "fan.study_airp", device_id: "dev_airp_study"),
            HAEntityEntry(entity_id: "sensor.study_airp_temperature", device_id: "dev_airp_study"),
            HAEntityEntry(entity_id: "sensor.study_airp_humidity", device_id: "dev_airp_study"),
        ]
        let states: [String: HAEntityState] = [
            "climate.living_ac": HAEntityState(
                entityId: "climate.living_ac",
                state: "cool",
                attributes: [
                    "temperature": .number(25),
                    "current_temperature": .number(26.8),
                ]
            ),
            "climate.bed_ac": HAEntityState(
                entityId: "climate.bed_ac",
                state: "unavailable",
                attributes: [
                    "temperature": .number(26),
                    "current_temperature": .number(28.0),
                ]
            ),
            "fan.study_airp": HAEntityState(entityId: "fan.study_airp", state: "on"),
            "sensor.study_airp_temperature": HAEntityState(
                entityId: "sensor.study_airp_temperature",
                state: "24.3",
                attributes: ["device_class": .string("temperature")]
            ),
            "sensor.study_airp_humidity": HAEntityState(
                entityId: "sensor.study_airp_humidity",
                state: "51",
                attributes: ["device_class": .string("humidity")]
            ),
        ]

        let home = DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: states)
        #expect(home.environmentReadings.map(\.id) == ["dev_airp_study", "dev_ac_living"])
        #expect(home.environmentReadings.map(\.label) == ["米家空气净化器 4 Lite", "客厅空调"])

        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.issue103.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let optionIds = store.availableMenuBarOptions.map(\.id)
        #expect(optionIds.contains("temp:dev_airp_study"))
        #expect(optionIds.contains("temp_hum:dev_airp_study"))
        #expect(optionIds.contains("temp:dev_ac_living"))
        #expect(!optionIds.contains("temp_hum:dev_ac_living"))
        #expect(!optionIds.contains("temp:dev_ac_offline"))

        L10n.$overrideTemperatureUnit.withValue(.celsius) {
            // Default auto:primary uses the first reading with a temperature (air purifier when no standalone sensor exists).
            #expect(store.menuBarText == "24.3°C")
            #expect(store.preferredEnvironmentReading?.id == "dev_airp_study")

            // Selecting the AC explicitly switches both menuBarText and preferredEnvironmentReading to the AC.
            store.menuBarTargetId = "temp:dev_ac_living"
            #expect(store.menuBarText == "26.8°C")
            #expect(store.preferredEnvironmentReading?.id == "dev_ac_living")

            // Selecting temp_hum on the air purifier shows both temperature and humidity.
            store.menuBarTargetId = "temp_hum:dev_airp_study"
            #expect(store.menuBarText == "24.3°C 51%")
        }
    }
}
