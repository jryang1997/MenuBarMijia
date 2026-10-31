import Foundation

// MARK: - Mock Provider for Testing & Instant Previews

public actor MockHomeProvider: HomeProvider {
    private var snapshot: SynthesizedHome
    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    public private(set) var executedCommands: [DeviceCommand] = []
    /// Every polling context the store sent, in order (#26).
    public private(set) var pollingContexts: [PollingContext] = []
    public var shouldFailCommands: Bool = false

    public init(snapshot: SynthesizedHome = .init()) {
        self.snapshot = snapshot
    }

    public func setShouldFail(_ fail: Bool) {
        self.shouldFailCommands = fail
    }

    public func setPollingContext(_ context: PollingContext) async {
        pollingContexts.append(context)
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { cont in
            Task {
                await self.register(cont)
            }
        }
    }

    private func register(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        self.continuation = cont
        cont.yield(.statusChanged(.connected))
        cont.yield(.snapshotUpdated(snapshot))
    }

    public func execute(_ command: DeviceCommand) async throws {
        if shouldFailCommands {
            throw HomeProviderError.serviceCallFailed(500, "模拟网络失败")
        }
        executedCommands.append(command)
    }

    public func refreshNow() async {
        continuation?.yield(.snapshotUpdated(snapshot))
    }

    public func updateSnapshot(_ next: SynthesizedHome) {
        self.snapshot = next
        continuation?.yield(.snapshotUpdated(next))
    }

    private var sensorHistoryByDevice: [String: [SensorHistorySample]] = [:]

    public func setSensorHistory(_ samples: [SensorHistorySample], forDevice deviceId: String) {
        sensorHistoryByDevice[deviceId] = samples
    }

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        sensorHistoryByDevice[deviceId] ?? []
    }

    private var cameraStreamByDevice: [String: CameraStreamSource] = [:]

    public func setCameraStream(_ source: CameraStreamSource, forDevice deviceId: String) {
        cameraStreamByDevice[deviceId] = source
    }

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        if shouldFailCommands {
            throw HomeProviderError.serviceCallFailed(500, "模拟网络失败")
        }
        if let source = cameraStreamByDevice[device.id] {
            return source
        }
        return .demo(deviceId: device.id)
    }
}

// MARK: - Demo Mode (#47)

/// A complete virtual home for trying the panel without a Xiaomi account or Home Assistant.
/// Commands are applied to an in-memory snapshot and pushed back; nothing ever leaves the process.
public actor DemoHomeProvider: HomeProvider {
    private var snapshot: SynthesizedHome
    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    public private(set) var executedCommands: [DeviceCommand] = []

    public init() {
        self.snapshot = Self.defaultHome()
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { cont in
            Task {
                await self.register(cont)
            }
        }
    }

    private func register(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        self.continuation = cont
        cont.yield(.statusChanged(.connected))
        cont.yield(.snapshotUpdated(snapshot))
    }

    public func execute(_ command: DeviceCommand) async throws {
        executedCommands.append(command)
        snapshot = Self.applying(command, to: snapshot)
        continuation?.yield(.snapshotUpdated(snapshot))
    }

    public func refreshNow() async {
        continuation?.yield(.snapshotUpdated(snapshot))
    }

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        guard case .camera = device.kind else {
            throw HomeProviderError.serviceCallFailed(400, L10n.tr("非摄像头设备", "Not a camera device"))
        }
        return .demo(deviceId: device.id)
    }

    // MARK: Virtual Home

    public static func defaultHome(includeCamera: Bool = true) -> SynthesizedHome {
        let rooms = [
            RoomArea(id: "living_room", name: L10n.tr("客厅", "Living Room"), sortOrder: 0),
            RoomArea(id: "bedroom", name: L10n.tr("卧室", "Bedroom"), sortOrder: 1),
            RoomArea(id: "study", name: L10n.tr("书房", "Study"), sortOrder: 2)
        ]
        let living = rooms[0].name
        let bedroom = rooms[1].name
        let study = rooms[2].name

        var devices: [SmartDevice] = [
            SmartDevice(
                id: "demo_living_light",
                name: L10n.tr("客厅吸顶灯", "Living Room Ceiling"),
                roomId: rooms[0].id,
                roomName: living,
                model: "demo.light.ceiling",
                isOnline: true,
                kind: .light(LightSpec(
                    entityId: "light.demo_living_ceiling",
                    isOn: true,
                    brightnessPercent: 80,
                    colorTempKelvin: 4200,
                    availableEffects: ["Day", "Night"]
                ))
            ),
            SmartDevice(
                id: "demo_living_climate",
                name: L10n.tr("客厅空调", "Living Room AC"),
                roomId: rooms[0].id,
                roomName: living,
                model: "demo.climate.ac",
                isOnline: true,
                kind: .climate(ClimateSpec(
                    entityId: "climate.demo_living",
                    isOn: false,
                    hvacMode: "off",
                    availableModes: ["off", "cool", "heat", "dry", "fan_only", "auto"],
                    targetTemperature: 26,
                    currentTemperature: 27.5,
                    availableFanModes: ["low", "medium", "high", "auto"]
                ))
            ),
            SmartDevice(
                id: "demo_living_plug",
                name: L10n.tr("电视柜插座", "TV Stand Plug"),
                roomId: rooms[0].id,
                roomName: living,
                model: "demo.plug",
                isOnline: true,
                kind: .plug(PlugSpec(
                    switchEntityId: "switch.demo_living_plug",
                    isOn: true,
                    powerWatts: 42,
                    energyKwh: 1.8
                ))
            ),
            SmartDevice(
                id: "demo_living_sensor",
                name: L10n.tr("客厅温湿度计", "Living Room Sensor"),
                roomId: rooms[0].id,
                roomName: living,
                model: "demo.sensor",
                isOnline: true,
                kind: .sensor(SensorSpec(temperature: 25.8, humidity: 58, battery: 92))
            ),
            SmartDevice(
                id: "demo_living_tv",
                name: L10n.tr("客厅电视", "Living Room TV"),
                roomId: rooms[0].id,
                roomName: living,
                model: "demo.tv",
                isOnline: true,
                kind: .tv(TVSpec(
                    mediaEntityId: "media_player.demo_living_tv",
                    state: "on",
                    volumePercent: 22,
                    currentSource: "HDMI 1",
                    availableSources: ["HDMI 1", "HDMI 2", "Netflix"]
                ))
            ),
            SmartDevice(
                id: "demo_bedroom_light",
                name: L10n.tr("床头灯", "Bedside Lamp"),
                roomId: rooms[1].id,
                roomName: bedroom,
                model: "demo.light.lamp",
                isOnline: true,
                kind: .light(LightSpec(
                    entityId: "light.demo_bedside",
                    isOn: false,
                    brightnessPercent: 40,
                    colorTempKelvin: 3000
                ))
            ),
            SmartDevice(
                id: "demo_bedroom_climate",
                name: L10n.tr("卧室空调", "Bedroom AC"),
                roomId: rooms[1].id,
                roomName: bedroom,
                model: "demo.climate.ac",
                isOnline: true,
                kind: .climate(ClimateSpec(
                    entityId: "climate.demo_bedroom",
                    isOn: false,
                    hvacMode: "off",
                    availableModes: ["off", "cool", "heat", "auto"],
                    targetTemperature: 25,
                    currentTemperature: 24.6
                ))
            ),
            SmartDevice(
                id: "demo_bedroom_plug",
                name: L10n.tr("加湿器插座", "Humidifier Plug"),
                roomId: rooms[1].id,
                roomName: bedroom,
                model: "demo.plug",
                isOnline: true,
                kind: .plug(PlugSpec(
                    switchEntityId: "switch.demo_bedroom_plug",
                    isOn: true,
                    powerWatts: 18
                ))
            ),
            SmartDevice(
                id: "demo_bedroom_sensor",
                name: L10n.tr("卧室温湿度计", "Bedroom Sensor"),
                roomId: rooms[1].id,
                roomName: bedroom,
                model: "demo.sensor",
                isOnline: true,
                kind: .sensor(SensorSpec(temperature: 24.2, humidity: 55, battery: 76))
            ),
            SmartDevice(
                id: "demo_study_light",
                name: L10n.tr("书房台灯", "Study Desk Lamp"),
                roomId: rooms[2].id,
                roomName: study,
                model: "demo.light.lamp",
                isOnline: true,
                kind: .light(LightSpec(
                    entityId: "light.demo_study_lamp",
                    isOn: false,
                    brightnessPercent: 60,
                    colorTempKelvin: 5000
                ))
            ),
            SmartDevice(
                id: "demo_study_climate",
                name: L10n.tr("书房空调", "Study AC"),
                roomId: rooms[2].id,
                roomName: study,
                model: "demo.climate.ac",
                isOnline: true,
                kind: .climate(ClimateSpec(
                    entityId: "climate.demo_study",
                    isOn: false,
                    hvacMode: "off",
                    availableModes: ["off", "cool", "heat", "auto"],
                    targetTemperature: 26,
                    currentTemperature: 26.4
                ))
            ),
            SmartDevice(
                id: "demo_study_plug",
                name: L10n.tr("桌面插座", "Desk Plug"),
                roomId: rooms[2].id,
                roomName: study,
                model: "demo.plug",
                isOnline: true,
                kind: .plug(PlugSpec(
                    switchEntityId: "switch.demo_study_plug",
                    isOn: false,
                    powerWatts: 0
                ))
            ),
            SmartDevice(
                id: "demo_study_sensor",
                name: L10n.tr("书房温湿度计", "Study Sensor"),
                roomId: rooms[2].id,
                roomName: study,
                model: "demo.sensor",
                isOnline: true,
                kind: .sensor(SensorSpec(temperature: 26.4, humidity: 50, battery: 88))
            )
        ]
        if includeCamera {
            devices.append(
                SmartDevice(
                    id: "demo_living_camera",
                    name: L10n.tr("客厅摄像机", "Living Room Camera"),
                    roomId: rooms[0].id,
                    roomName: living,
                    model: "chuangmi.camera.81ac1",
                    isOnline: true,
                    kind: .camera(CameraSpec(
                        entityId: "camera.demo_living_camera",
                        isOn: true,
                        nightShot: "Auto",
                        availableNightShots: ["Off", "On", "Auto"],
                        motionDetectionEntityId: "switch.demo_living_camera_motion",
                        isMotionDetectionOn: true,
                        streamEntityId: "camera.demo_living_camera"
                    ))
                )
            )
        }

        let readings = [
            EnvironmentReading(
                id: "demo_living_sensor",
                label: L10n.tr("客厅温湿度计", "Living Room Sensor"),
                roomName: living,
                temperature: 25.8,
                humidity: 58,
                battery: 92
            ),
            EnvironmentReading(
                id: "demo_bedroom_sensor",
                label: L10n.tr("卧室温湿度计", "Bedroom Sensor"),
                roomName: bedroom,
                temperature: 24.2,
                humidity: 55,
                battery: 76
            ),
            EnvironmentReading(
                id: "demo_study_sensor",
                label: L10n.tr("书房温湿度计", "Study Sensor"),
                roomName: study,
                temperature: 26.4,
                humidity: 50,
                battery: 88
            )
        ]

        let scenes = [
            HomeScene(
                id: "demo_scene_home",
                name: L10n.tr("回家模式", "Welcome Home"),
                entityId: "scene.demo_home",
                iconName: "house.fill"
            ),
            HomeScene(
                id: "demo_scene_movie",
                name: L10n.tr("观影模式", "Movie Night"),
                entityId: "scene.demo_movie",
                iconName: "tv.fill"
            )
        ]

        return SynthesizedHome(rooms: rooms, devices: devices, environmentReadings: readings, scenes: scenes)
    }

    /// Applies a command to the virtual devices so the demo panel reflects what was clicked.
    static func applying(_ command: DeviceCommand, to home: SynthesizedHome) -> SynthesizedHome {
        var next = home
        for idx in next.devices.indices {
            switch next.devices[idx].kind {
            case .light(var spec):
                switch command {
                case .setLightPower(let entityId, let isOn) where entityId == spec.entityId:
                    spec.isOn = isOn
                case .setLightBrightness(let entityId, let percent) where entityId == spec.entityId:
                    spec.isOn = percent > 0
                    spec.brightnessPercent = percent
                case .setLightColorTemp(let entityId, let kelvin) where entityId == spec.entityId:
                    spec.isOn = true
                    spec.colorTempKelvin = kelvin
                    spec.currentEffect = nil
                case .setLightEffect(let entityId, let effect) where entityId == spec.entityId:
                    spec.isOn = true
                    spec.currentEffect = effect
                default:
                    continue
                }
                next.devices[idx].kind = .light(spec)

            case .climate(var spec):
                switch command {
                case .setClimatePower(let entityId, let isOn, let fallbackMode) where entityId == spec.entityId:
                    spec.isOn = isOn
                    spec.hvacMode = isOn ? fallbackMode : "off"
                case .setClimateMode(let entityId, let hvacMode) where entityId == spec.entityId:
                    spec.hvacMode = hvacMode
                    spec.isOn = hvacMode != "off"
                case .setClimateTemperature(let entityId, let temperature) where entityId == spec.entityId:
                    spec.targetTemperature = temperature
                case .setClimateFanMode(let entityId, let fanMode) where entityId == spec.entityId:
                    spec.fanMode = fanMode
                case .setClimateSwingMode(let entityId, let swingMode) where entityId == spec.entityId:
                    spec.swingMode = swingMode
                default:
                    continue
                }
                next.devices[idx].kind = .climate(spec)


            case .fan(var spec):
                switch command {
                case .setFanPower(let entityId, let isOn) where entityId == spec.entityId:
                    spec.isOn = isOn
                case .setFanPercentage(let entityId, let percent) where entityId == spec.entityId:
                    spec.isOn = percent > 0
                    spec.percentage = percent
                case .setFanPresetMode(let entityId, let preset) where entityId == spec.entityId:
                    spec.isOn = true
                    spec.presetMode = preset
                case .setFanOscillating(let entityId, let oscillating) where entityId == spec.entityId:
                    spec.isOscillating = oscillating
                default:
                    continue
                }
                next.devices[idx].kind = .fan(spec)
            case .plug(var spec):
                if case .setSwitch(let entityId, let isOn) = command, entityId == spec.switchEntityId {
                    spec.isOn = isOn
                    next.devices[idx].kind = .plug(spec)
                }

            case .tv(var spec):
                switch command {
                case .setSwitch(let entityId, let isOn) where entityId == spec.mediaEntityId:
                    spec.state = isOn ? "on" : "standby"
                case .mediaSelectSource(let entityId, let source) where entityId == spec.mediaEntityId:
                    spec.currentSource = source
                case .mediaSetVolume(let entityId, let volumeLevel) where entityId == spec.mediaEntityId:
                    spec.volumePercent = Int((volumeLevel * 100).rounded())
                default:
                    continue
                }
                next.devices[idx].kind = .tv(spec)


            case .camera(var spec):
                switch command {
                case .setSwitch(let entityId, let isOn) where entityId == spec.entityId:
                    spec.isOn = isOn
                case .setSwitch(let entityId, let isOn) where entityId == spec.motionDetectionEntityId:
                    spec.isMotionDetectionOn = isOn
                case .setSelectOption(let entityId, let option) where entityId == spec.entityId:
                    spec.nightShot = option
                default:
                    continue
                }
                next.devices[idx].kind = .camera(spec)
            default:
                continue
            }
        }
        return next
    }

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        guard let dev = snapshot.devices.first(where: { $0.id == deviceId }),
              case .sensor(let spec) = dev.kind else {
            return []
        }
        return Self.syntheticSamples(
            deviceId: deviceId,
            baseTemp: spec.temperature ?? 24.5,
            baseHum: spec.humidity ?? 55.0,
            window: window,
            now: now
        )
    }

    static func syntheticSamples(
        deviceId: String,
        baseTemp: Double,
        baseHum: Double,
        window: SensorHistoryWindow,
        now: Date
    ) -> [SensorHistorySample] {
        let phase = Double(abs(deviceId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 12) * 0.5
        let cal = Calendar.current
        switch window {
        case .last24Hours:
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
            let curHour = cal.date(from: comps) ?? now
            return (0..<24).compactMap { offset -> SensorHistorySample? in
                let deltaHours = offset - 23
                guard let slot = cal.date(byAdding: .hour, value: deltaHours, to: curHour) else { return nil }
                let hourOfDay = Double(cal.component(.hour, from: slot))
                let wave = sin((hourOfDay - 6.0 + phase) / 24.0 * 2.0 * .pi)
                let isCurrent = deltaHours == 0
                let t = isCurrent ? baseTemp : ((baseTemp + wave * 1.6) * 10).rounded() / 10
                let h = isCurrent ? baseHum : min(95, max(20, ((baseHum - wave * 5.5) * 10).rounded() / 10))
                return SensorHistorySample(timestamp: slot, temperature: t, humidity: h)
            }
        case .last7Days:
            let today = cal.startOfDay(for: now)
            return (0..<7).compactMap { offset -> SensorHistorySample? in
                let deltaDays = offset - 6
                guard let slot = cal.date(byAdding: .day, value: deltaDays, to: today) else { return nil }
                let wave = sin(Double(offset) * 0.95 + phase)
                let tAvg = ((baseTemp + wave * 1.2) * 10).rounded() / 10
                let hAvg = min(95, max(20, ((baseHum - wave * 4.5) * 10).rounded() / 10))
                return SensorHistorySample(
                    timestamp: slot,
                    temperature: tAvg,
                    minTemperature: ((tAvg - 1.4) * 10).rounded() / 10,
                    maxTemperature: ((tAvg + 1.5) * 10).rounded() / 10,
                    humidity: hAvg,
                    minHumidity: max(15, ((hAvg - 5.0) * 10).rounded() / 10),
                    maxHumidity: min(98, ((hAvg + 5.0) * 10).rounded() / 10)
                )
            }
        }
    }
}
