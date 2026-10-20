import Foundation

// MARK: - Raw Home Assistant Registry & State DTOs

public struct HAAreaEntry: Codable, Equatable, Sendable {
    public let area_id: String
    public let name: String

    public init(area_id: String, name: String) {
        self.area_id = area_id
        self.name = name
    }
}

public struct HADeviceEntry: Codable, Equatable, Sendable {
    public let id: String
    public let area_id: String?
    public let name: String?
    public let name_by_user: String?
    public let manufacturer: String?
    public let model: String?
    public let disabled_by: String?

    public init(
        id: String,
        area_id: String? = nil,
        name: String? = nil,
        name_by_user: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        disabled_by: String? = nil
    ) {
        self.id = id
        self.area_id = area_id
        self.name = name
        self.name_by_user = name_by_user
        self.manufacturer = manufacturer
        self.model = model
        self.disabled_by = disabled_by
    }
}

public struct HAEntityEntry: Codable, Equatable, Sendable {
    public let entity_id: String
    public let device_id: String?
    public let area_id: String?
    public let name: String?
    public let original_name: String?
    public let platform: String?
    public let entity_category: String?
    public let disabled_by: String?
    public let hidden_by: String?

    public init(
        entity_id: String,
        device_id: String? = nil,
        area_id: String? = nil,
        name: String? = nil,
        original_name: String? = nil,
        platform: String? = nil,
        entity_category: String? = nil,
        disabled_by: String? = nil,
        hidden_by: String? = nil
    ) {
        self.entity_id = entity_id
        self.device_id = device_id
        self.area_id = area_id
        self.name = name
        self.original_name = original_name
        self.platform = platform
        self.entity_category = entity_category
        self.disabled_by = disabled_by
        self.hidden_by = hidden_by
    }
}

public struct HAEntityState: Equatable, Sendable {
    public let entityId: String
    public var state: String
    public var attributes: [String: JSONValue]

    public init(entityId: String, state: String, attributes: [String: JSONValue] = [:]) {
        self.entityId = entityId
        self.state = state
        self.attributes = attributes
    }

    public var isAvailable: Bool {
        state != "unavailable" && state != "unknown"
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int? {
        if let d = doubleValue { return Int(d.rounded()) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var stringArrayValue: [String] {
        guard case .array(let items) = self else { return [] }
        return items.compactMap(\.stringValue)
    }
}

// MARK: - Synthesized Home Snapshot

public struct SynthesizedHome: Equatable, Sendable {
    public var rooms: [RoomArea]
    public var devices: [SmartDevice]
    public var environmentReadings: [EnvironmentReading]
    public var scenes: [HomeScene]

    public init(
        rooms: [RoomArea] = [],
        devices: [SmartDevice] = [],
        environmentReadings: [EnvironmentReading] = [],
        scenes: [HomeScene] = []
    ) {
        self.rooms = rooms
        self.devices = devices
        self.environmentReadings = environmentReadings
        self.scenes = scenes
    }
}

// MARK: - Deep Synthesizer Module

public enum DeviceSynthesizer {
    private static let roomOrderMap: [String: Int] = [
        "客厅": 1,
        "书房": 2,
        "卧室": 3,
        "主卧": 3,
        "小卧室": 4,
        "次卧": 4,
        "厨房": 5,
        "阳台": 6
    ]

    public static func synthesize(
        areas: [HAAreaEntry],
        devices: [HADeviceEntry],
        entities: [HAEntityEntry],
        states: [String: HAEntityState]
    ) -> SynthesizedHome {
        let areaNameById = Dictionary(uniqueKeysWithValues: areas.map { ($0.area_id, $0.name) })

        // Group active entities by device_id
        var entitiesByDevice: [String: [HAEntityEntry]] = [:]

        for entity in entities {
            guard entity.disabled_by == nil, entity.hidden_by == nil else { continue }
            if let devId = entity.device_id {
                entitiesByDevice[devId, default: []].append(entity)
            }
        }

        var smartDevices: [SmartDevice] = []
        var envReadings: [EnvironmentReading] = []

        for dev in devices {
            guard dev.disabled_by == nil else { continue }
            guard let devEntities = entitiesByDevice[dev.id], !devEntities.isEmpty else { continue }

            let model = dev.model ?? ""
            // Skip duplicate DLNA/AppleTV discovery or pure gateway indicator devices
            if model == "hyperDLNA" || model.hasPrefix("Apple TV") || model.hasPrefix("lumi.gateway") {
                continue
            }

            let rawAreaId = dev.area_id ?? devEntities.compactMap(\.area_id).first ?? "other"
            let rawRoomName = areaNameById[rawAreaId] ?? "全屋"
            let roomName = normalizeRoomName(rawRoomName)
            let roomId = normalizedRoomId(for: roomName, fallback: rawAreaId)

            let rawDeviceName = dev.name_by_user ?? dev.name ?? "智能设备"
            let cleanName = cleanDeviceName(rawDeviceName, roomName: roomName, model: model)

            if let built = buildSmartDevice(
                deviceId: dev.id,
                name: cleanName,
                roomId: roomId,
                roomName: roomName,
                model: model,
                entities: devEntities,
                states: states
            ) {
                smartDevices.append(built)
            }
        }

        let registeredDeviceIds = Set(devices.map(\.id))
        let entityById = Dictionary(uniqueKeysWithValues: entities.map { ($0.entity_id, $0) })
        for (eid, state) in states {
            guard eid.hasPrefix("light.") || eid.hasPrefix("climate.")
                    || eid.hasPrefix("fan.") || eid.hasPrefix("vacuum.")
                    || eid.hasPrefix("switch.") || eid.hasPrefix("media_player.")
                    || eid.hasPrefix("sensor.") else { continue }
            let entity = entityById[eid]
            guard entity?.disabled_by == nil, entity?.hidden_by == nil else { continue }
            if let deviceId = entity?.device_id, registeredDeviceIds.contains(deviceId) { continue }

            let areaId = entity?.area_id ?? "other"
            let roomName = normalizeRoomName(areaNameById[areaId] ?? "全屋")
            let name = entity?.name ?? state.attributes["friendly_name"]?.stringValue
                ?? entity?.original_name ?? eid
            if let built = buildSmartDevice(
                deviceId: eid,
                name: cleanDeviceName(name, roomName: roomName, model: ""),
                roomId: normalizedRoomId(for: roomName, fallback: areaId),
                roomName: roomName,
                model: "",
                entities: [entity ?? HAEntityEntry(entity_id: eid)],
                states: states
            ) {
                smartDevices.append(built)
            }
        }

        for device in smartDevices {
            if case .sensor(let sensor) = device.kind,
               sensor.temperature != nil || sensor.humidity != nil {
                let label = device.name.replacingOccurrences(of: "温湿度计", with: "")
                    .trimmingCharacters(in: .whitespaces)
                envReadings.append(EnvironmentReading(
                    id: device.id,
                    label: label.isEmpty ? device.roomName : label,
                    roomName: device.roomName,
                    temperature: sensor.temperature,
                    humidity: sensor.humidity,
                    battery: sensor.battery
                ))
            }
        }

        // Synthesize HA scenes and scripts
        var synthesizedScenes: [HomeScene] = []
        var seenSceneEntityIds: Set<String> = []
        let appendScene = { (eid: String, rawTitle: String) in
            let cleanTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            synthesizedScenes.append(
                HomeScene(
                    id: eid,
                    name: cleanTitle,
                    entityId: eid,
                    iconName: sceneSymbol(for: cleanTitle)
                )
            )
        }
        for entity in entities {
            let eid = entity.entity_id
            guard eid.hasPrefix("scene.") || eid.hasPrefix("script.") else { continue }
            seenSceneEntityIds.insert(eid)
            guard entity.disabled_by == nil && entity.hidden_by == nil else { continue }
            if let st = states[eid], !st.isAvailable { continue }
            let friendly = states[eid]?.attributes["friendly_name"]?.stringValue
                ?? entity.name
                ?? entity.original_name
                ?? eid
            appendScene(eid, friendly)
        }
        for (eid, st) in states where (eid.hasPrefix("scene.") || eid.hasPrefix("script.")) && !seenSceneEntityIds.contains(eid) && st.isAvailable {
            let friendly = st.attributes["friendly_name"]?.stringValue ?? eid
            appendScene(eid, friendly)
        }
        synthesizedScenes.sort { $0.name < $1.name }

        return assembleHome(devices: smartDevices, readings: envReadings, scenes: synthesizedScenes)
    }

    /// Shared tail of every backend's synthesis: derive the room list and apply the panel sort order.
    static func assembleHome(
        devices smartDevices: [SmartDevice],
        readings envReadings: [EnvironmentReading],
        scenes synthesizedScenes: [HomeScene]
    ) -> SynthesizedHome {
        // Build deduplicated room list from active smartDevices
        var roomDict: [String: RoomArea] = [:]
        for d in smartDevices {
            if roomDict[d.roomId] == nil {
                roomDict[d.roomId] = RoomArea(
                    id: d.roomId,
                    name: d.roomName,
                    sortOrder: roomOrderMap[d.roomName] ?? 50
                )
            }
        }
        let sortedRooms = roomDict.values.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name < $1.name
        }

        // Sort devices: Online first -> Kind priority -> Room order -> Name
        let sortedDevices = smartDevices.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
            let pa = kindPriority(a.kind)
            let pb = kindPriority(b.kind)
            if pa != pb { return pa < pb }
            let ra = roomOrderMap[a.roomName] ?? 50
            let rb = roomOrderMap[b.roomName] ?? 50
            if ra != rb { return ra < rb }
            return a.name < b.name
        }

        let sortedReadings = envReadings.sorted { a, b in
            if a.label == "主卧" { return true }
            if b.label == "主卧" { return false }
            return a.label < b.label
        }

        return SynthesizedHome(
            rooms: sortedRooms,
            devices: sortedDevices,
            environmentReadings: sortedReadings,
            scenes: synthesizedScenes
        )
    }

    private static func sceneSymbol(for name: String) -> String {
        if name.contains("观影") || name.contains("影院") || name.contains("电视") { return "tv.fill" }
        if name.contains("睡眠") || name.contains("晚安") || name.contains("夜") { return "moon.stars.fill" }
        if name.contains("离家") || name.contains("外出") { return "figure.walk.departure" }
        if name.contains("回家") || name.contains("欢迎") { return "house.fill" }
        if name.contains("阅读") || name.contains("工作") { return "book.fill" }
        return "sparkles"
    }

    // MARK: - Device Builders

    private static func buildSmartDevice(
        deviceId: String,
        name: String,
        roomId: String,
        roomName: String,
        model: String,
        entities: [HAEntityEntry],
        states: [String: HAEntityState]
    ) -> SmartDevice? {
        let eids = entities.map(\.entity_id)

        // 1. Climate (AC / Baseboard Heater)
        if let climateId = eids.first(where: { $0.hasPrefix("climate.") }),
           let st = states[climateId] {
            let spec = parseClimateSpec(entityId: climateId, state: st)
            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .climate(spec)
            )
        }

        // 2. Primary Light (excluding indicator lights)
        let primaryLights = entities.filter { ent in
            ent.entity_id.hasPrefix("light.")
                && ent.entity_category != "config"
                && !ent.entity_id.hasSuffix("_indicator_light")
        }
        if let lightEnt = primaryLights.first,
           let st = states[lightEnt.entity_id] {
            let isOn = (st.state == "on")
            let rawBri = st.attributes["brightness"]?.doubleValue
            let briPct = rawBri.map { max(1, min(100, Int(($0 / 255.0 * 100.0).rounded()))) }
            let kelvin = st.attributes["color_temp_kelvin"]?.intValue
            let minK = st.attributes["min_color_temp_kelvin"]?.intValue ?? 2700
            let maxK = st.attributes["max_color_temp_kelvin"]?.intValue ?? 6500
            let effect = st.attributes["effect"]?.stringValue
            let effects = st.attributes["effect_list"]?.stringArrayValue ?? []

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .light(
                    LightSpec(
                        entityId: lightEnt.entity_id,
                        isOn: isOn,
                        brightnessPercent: briPct,
                        colorTempKelvin: kelvin,
                        minKelvin: minK,
                        maxKelvin: maxK,
                        currentEffect: effect,
                        availableEffects: effects
                    )
                )
            )
        }

        // 3. Fan
        if let fanId = eids.first(where: { $0.hasPrefix("fan.") }),
           let st = states[fanId] {
            let isOn = (st.state == "on")
            let pct = st.attributes["percentage"]?.intValue
            let preset = st.attributes["preset_mode"]?.stringValue
            let presets = st.attributes["preset_modes"]?.stringArrayValue ?? []
            let osc = st.attributes["oscillating"]?.boolValue

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .fan(
                    FanSpec(
                        entityId: fanId,
                        isOn: isOn,
                        percentage: pct,
                        presetMode: preset,
                        availablePresetModes: presets,
                        isOscillating: osc
                    )
                )
            )
        }

        // 4. Vacuum
        if let vacId = eids.first(where: { $0.hasPrefix("vacuum.") }),
           let st = states[vacId] {
            let batId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("battery_level") })
            let bat = batId.flatMap { states[$0]?.state }.flatMap { Int(Double($0) ?? -1) }
            let modeId = eids.first(where: { $0.hasPrefix("select.") && $0.contains("mode") })
            let modeState = modeId.flatMap { states[$0] }
            let currentMode = (modeState?.isAvailable == true) ? modeState?.state : nil
            let modes = modeState?.attributes["options"]?.stringArrayValue ?? []

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .vacuum(
                    VacuumSpec(
                        entityId: vacId,
                        status: st.state,
                        battery: (bat ?? -1) >= 0 ? bat : nil,
                        modeEntityId: modeId,
                        currentMode: currentMode,
                        availableModes: modes
                    )
                )
            )
        }

        // 5. Smart Refrigerator (midjd6.fridge.*)
        if model.contains("fridge") || eids.contains(where: { $0.contains("midjd6") }) {
            let modeId = eids.first(where: { $0.hasPrefix("select.") && $0.contains("mode") })
            let modeSt = modeId.flatMap { states[$0] }
            let curMode = modeSt?.state ?? "手动"
            let modes = modeSt?.attributes["options"]?.stringArrayValue ?? ["手动", "智能", "速冷", "速冻", "假日"]

            let fridgeTempId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("temperature_p_3") })
            let freezerTempId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("temperature_p_4") })
            let fridgeTargetId = eids.first(where: { $0.hasPrefix("number.") && $0.contains("target_temperature_p_3") })
            let freezerTargetId = eids.first(where: { $0.hasPrefix("number.") && $0.contains("target_temperature_p_4") })

            let fCur = fridgeTempId.flatMap { states[$0]?.state }.flatMap(Double.init)
            let zCur = freezerTempId.flatMap { states[$0]?.state }.flatMap(Double.init)
            let fTgt = fridgeTargetId.flatMap { states[$0]?.state }.flatMap(Double.init) ?? 4
            let zTgt = freezerTargetId.flatMap { states[$0]?.state }.flatMap(Double.init) ?? -18
            let online = (modeSt?.isAvailable == true) || (fCur != nil)

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: online,
                kind: .fridge(
                    FridgeSpec(
                        modeEntityId: modeId,
                        currentMode: curMode,
                        availableModes: modes,
                        fridgeCurrentTemp: fCur,
                        fridgeTargetTemp: fTgt,
                        fridgeTargetEntityId: fridgeTargetId,
                        freezerCurrentTemp: zCur,
                        freezerTargetTemp: zTgt,
                        freezerTargetEntityId: freezerTargetId
                    )
                )
            )
        }

        let tempId = eids.first { eid in
            guard eid.hasPrefix("sensor.") else { return false }
            if let deviceClass = states[eid]?.attributes["device_class"]?.stringValue {
                return deviceClass == "temperature"
            }
            return eid.contains("temperature")
        }
        let humId = eids.first { eid in
            guard eid.hasPrefix("sensor.") else { return false }
            if let deviceClass = states[eid]?.attributes["device_class"]?.stringValue {
                return deviceClass == "humidity"
            }
            return eid.contains("humidity")
        }
        let batId = eids.first { eid in
            guard eid.hasPrefix("sensor.") else { return false }
            if let deviceClass = states[eid]?.attributes["device_class"]?.stringValue {
                return deviceClass == "battery"
            }
            return eid.contains("battery_level")
        }
        let primarySwitches = entities.filter { entity in
            guard entity.entity_id.hasPrefix("switch."),
                  entity.entity_category != "config", entity.entity_category != "diagnostic" else { return false }
            if states[entity.entity_id]?.attributes["device_class"]?.stringValue == "outlet" { return true }
            let objectId = entity.entity_id.dropFirst("switch.".count)
            return objectId.firstMatch(of: #/(?:^|_)(?:physical_controls_locked|child_lock|indicator|mute|sleep_mode)(?:_|$)/#) == nil
        }
        let outletSwitch = primarySwitches.first {
            states[$0.entity_id]?.attributes["device_class"]?.stringValue == "outlet"
        }
        if model.contains("plug") || eids.contains(where: { $0.hasPrefix("switch.cuco") })
            || (!primarySwitches.isEmpty && (outletSwitch != nil || (tempId == nil && humId == nil))
                && !eids.contains(where: { $0.hasPrefix("media_player.") })) {
            guard let swId = outletSwitch?.entity_id
                    ?? primarySwitches.first(where: { $0.entity_id.contains("_on_") })?.entity_id
                    ?? primarySwitches.first?.entity_id,
                  let st = states[swId] else { return nil }

            let powerId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("electric_power") })
            let energyId = eids.first(where: { $0.hasPrefix("sensor.") && $0.contains("power_consumption") })
            let lockId = eids.first(where: { $0.hasPrefix("switch.") && $0.contains("physical_controls_locked") })

            let watts = powerId.flatMap { states[$0]?.state }.flatMap(Double.init)
            let kwh = energyId.flatMap { states[$0]?.state }.flatMap(Double.init)
            let locked = lockId.flatMap { states[$0]?.state == "on" } ?? false

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: st.isAvailable,
                kind: .plug(
                    PlugSpec(
                        switchEntityId: swId,
                        isOn: st.state == "on",
                        powerWatts: watts,
                        energyKwh: kwh,
                        childLockEntityId: lockId,
                        isChildLocked: locked
                    )
                )
            )
        }

        // 7. Smart Speaker / TV (media_player.*)
        if let mediaId = eids.first(where: { $0.hasPrefix("media_player.") }),
           let st = states[mediaId] {
            let volDouble = st.attributes["volume_level"]?.doubleValue ?? 0.2
            let volPct = Int((volDouble * 100.0).rounded())
            let devClass = st.attributes["device_class"]?.stringValue ?? ""

            if devClass == "tv" || model.contains("tv") {
                let src = st.attributes["source"]?.stringValue
                let srcs = st.attributes["source_list"]?.stringArrayValue ?? []
                let turnOnBtn = eids.first(where: { $0.hasPrefix("button.") && $0.contains("turn_on") })
                return SmartDevice(
                    id: deviceId,
                    name: name,
                    roomId: roomId,
                    roomName: roomName,
                    model: model,
                    isOnline: st.isAvailable,
                    kind: .tv(
                        TVSpec(
                            mediaEntityId: mediaId,
                            state: st.state,
                            volumePercent: volPct,
                            currentSource: src,
                            availableSources: srcs,
                            turnOnButtonId: turnOnBtn
                        )
                    )
                )
            } else {
                let muteSw = eids.first(where: { $0.hasPrefix("switch.") && $0.contains("mute") })
                let sleepSw = eids.first(where: { $0.hasPrefix("switch.") && $0.contains("sleep_mode") })
                let ttsNotify = eids.first(where: { $0.hasPrefix("notify.") && $0.contains("play_text") })
                let dirNotify = eids.first(where: { $0.hasPrefix("notify.") && $0.contains("execute_text_directive") })
                let playMusicBtn = eids.first(where: { $0.hasPrefix("button.") && $0.contains("play_music") })
                let stopAlarmBtn = eids.first(where: { $0.hasPrefix("button.") && $0.contains("stop_alarm") })

                let isMuted = muteSw.flatMap { states[$0]?.state == "on" }
                    ?? st.attributes["is_volume_muted"]?.boolValue
                    ?? false
                let isSleep = sleepSw.flatMap { states[$0]?.state == "on" } ?? false

                return SmartDevice(
                    id: deviceId,
                    name: name,
                    roomId: roomId,
                    roomName: roomName,
                    model: model,
                    isOnline: st.isAvailable,
                    kind: .speaker(
                        SpeakerSpec(
                            mediaEntityId: mediaId,
                            state: st.state,
                            volumePercent: volPct,
                            isMuted: isMuted,
                            muteSwitchEntityId: muteSw,
                            sleepModeEntityId: sleepSw,
                            isSleepMode: isSleep,
                            ttsNotifyEntityId: ttsNotify,
                            directiveNotifyEntityId: dirNotify,
                            playMusicButtonId: playMusicBtn,
                            stopAlarmButtonId: stopAlarmBtn
                        )
                    )
                )
            }
        }

        if tempId != nil || humId != nil {
            let tempSt = tempId.flatMap { states[$0] }
            let humSt = humId.flatMap { states[$0] }
            let batSt = batId.flatMap { states[$0] }

            let tVal = tempSt.flatMap { Double($0.state) }
            let hVal = humSt.flatMap { Double($0.state) }
            let bVal = batSt.flatMap { Double($0.state) }.map { Int($0.rounded()) }
            let online = (tempSt?.isAvailable == true) || (humSt?.isAvailable == true)

            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: online,
                kind: .sensor(
                    SensorSpec(
                        temperature: tVal,
                        humidity: hVal,
                        battery: bVal
                    )
                )
            )
        }

        if model.contains("lock") {
            let batSt = batId.flatMap { states[$0] }
            let bVal = batSt.flatMap { Double($0.state) }.map { Int($0.rounded()) }
            let online = batSt?.isAvailable == true
            return SmartDevice(
                id: deviceId,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: online,
                kind: .sensor(
                    SensorSpec(
                        battery: bVal,
                        statusText: "守护中"
                    )
                )
            )
        }

        return nil
    }

    private static func parseClimateSpec(entityId: String, state st: HAEntityState) -> ClimateSpec {
        let isOn = st.isAvailable && st.state != "off"
        let modes = st.attributes["hvac_modes"]?.stringArrayValue ?? ["cool", "heat", "dry", "fan_only", "off"]
        let target = st.attributes["temperature"]?.doubleValue
            ?? st.attributes["target_temp_low"]?.doubleValue
            ?? 26.0
        let current = st.attributes["current_temperature"]?.doubleValue
        let minT = st.attributes["min_temp"]?.doubleValue ?? 16.0
        let maxT = st.attributes["max_temp"]?.doubleValue ?? 30.0
        let step = st.attributes["target_temp_step"]?.doubleValue ?? 1.0
        let fanMode = st.attributes["fan_mode"]?.stringValue
        let fanModes = st.attributes["fan_modes"]?.stringArrayValue ?? []
        let swingMode = st.attributes["swing_mode"]?.stringValue
        let swingModes = st.attributes["swing_modes"]?.stringArrayValue ?? []

        return ClimateSpec(
            entityId: entityId,
            isOn: isOn,
            hvacMode: st.state,
            availableModes: modes,
            targetTemperature: target,
            currentTemperature: current,
            minTemp: minT,
            maxTemp: maxT,
            step: step,
            fanMode: fanMode,
            availableFanModes: fanModes,
            swingMode: swingMode,
            availableSwingModes: swingModes
        )
    }

    // MARK: - Naming & Normalization Helpers

    public static func normalizeRoomName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "默认房间" { return "全屋" }
        if trimmed == "小卧室" { return "次卧" }
        return trimmed
    }

    static func normalizedRoomId(for roomName: String, fallback: String) -> String {
        switch roomName {
        case "客厅": return "ke_ting"
        case "书房": return "shu_fang"
        case "卧室", "主卧": return "wo_shi"
        case "次卧", "小卧室": return "xiao_wo_shi"
        case "厨房": return "chu_fang"
        case "阳台": return "yang_tai"
        default: return fallback
        }
    }

    public static func cleanDeviceName(_ raw: String, roomName: String, model: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip verbose duplicate suffixes appended by Home Assistant entity naming
        for suffix in ["  灯", "  电暖器", "  风扇", "  音箱", "  电视", "  开关 开关"] {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Prefix generic ceiling light names with their room name for clarity
        if s == "吸顶灯" && roomName != "全屋" {
            return "\(roomName)吸顶灯"
        }
        // Shorten verbose official Xiaomi product model names for compact cards
        if s.hasPrefix("米家互联网对开门冰箱") {
            return "对开门冰箱"
        }
        if s.contains("直流变频循环扇") {
            return "变频循环扇"
        }
        if s.hasPrefix("米家踢脚线电暖器") {
            return "踢脚线电暖器"
        }
        if s.hasPrefix("Yeelight LED 彩光灯带") {
            return roomName != "全屋" ? "\(roomName)彩光灯带" : "彩光灯带"
        }
        return s
    }

    private static func kindPriority(_ kind: DeviceKind) -> Int {
        switch kind {
        case .climate: return 1
        case .light: return 2
        case .plug: return 3
        case .fan: return 4
        case .vacuum: return 5
        case .fridge: return 6
        case .speaker: return 7
        case .tv: return 8
        case .sensor: return 9
        }
    }
}
