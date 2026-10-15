import Foundation

// MARK: - Room & Environment Summary

public struct RoomArea: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var sortOrder: Int

    public init(id: String, name: String, sortOrder: Int = 99) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

public struct EnvironmentReading: Identifiable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var roomName: String
    public var temperature: Double?
    public var humidity: Double?
    public var battery: Int?

    public init(
        id: String,
        label: String,
        roomName: String,
        temperature: Double?,
        humidity: Double?,
        battery: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.roomName = roomName
        self.temperature = temperature
        self.humidity = humidity
        self.battery = battery
    }
}

// MARK: - Device Specifications (Value Types)

public struct LightSpec: Equatable, Sendable {
    public var entityId: String
    public var isOn: Bool
    public var brightnessPercent: Int?
    public var colorTempKelvin: Int?
    public var minKelvin: Int
    public var maxKelvin: Int
    public var currentEffect: String?
    public var availableEffects: [String]

    public init(
        entityId: String,
        isOn: Bool,
        brightnessPercent: Int? = nil,
        colorTempKelvin: Int? = nil,
        minKelvin: Int = 2700,
        maxKelvin: Int = 6500,
        currentEffect: String? = nil,
        availableEffects: [String] = []
    ) {
        self.entityId = entityId
        self.isOn = isOn
        self.brightnessPercent = brightnessPercent
        self.colorTempKelvin = colorTempKelvin
        self.minKelvin = minKelvin
        self.maxKelvin = maxKelvin
        self.currentEffect = currentEffect
        self.availableEffects = availableEffects
    }
}

public struct ClimateSpec: Equatable, Sendable {
    public var entityId: String
    public var isOn: Bool
    public var hvacMode: String
    public var availableModes: [String]
    public var targetTemperature: Double
    public var currentTemperature: Double?
    public var minTemp: Double
    public var maxTemp: Double
    public var step: Double
    public var fanMode: String?
    public var availableFanModes: [String]
    public var swingMode: String?
    public var availableSwingModes: [String]

    public init(
        entityId: String,
        isOn: Bool,
        hvacMode: String,
        availableModes: [String],
        targetTemperature: Double,
        currentTemperature: Double? = nil,
        minTemp: Double = 16,
        maxTemp: Double = 30,
        step: Double = 1,
        fanMode: String? = nil,
        availableFanModes: [String] = [],
        swingMode: String? = nil,
        availableSwingModes: [String] = []
    ) {
        self.entityId = entityId
        self.isOn = isOn
        self.hvacMode = hvacMode
        self.availableModes = availableModes
        self.targetTemperature = targetTemperature
        self.currentTemperature = currentTemperature
        self.minTemp = minTemp
        self.maxTemp = maxTemp
        self.step = step
        self.fanMode = fanMode
        self.availableFanModes = availableFanModes
        self.swingMode = swingMode
        self.availableSwingModes = availableSwingModes
    }
}

public struct FanSpec: Equatable, Sendable {
    public var entityId: String
    public var isOn: Bool
    public var percentage: Int?
    public var presetMode: String?
    public var availablePresetModes: [String]
    public var isOscillating: Bool?

    public init(
        entityId: String,
        isOn: Bool,
        percentage: Int? = nil,
        presetMode: String? = nil,
        availablePresetModes: [String] = [],
        isOscillating: Bool? = nil
    ) {
        self.entityId = entityId
        self.isOn = isOn
        self.percentage = percentage
        self.presetMode = presetMode
        self.availablePresetModes = availablePresetModes
        self.isOscillating = isOscillating
    }
}

public struct PlugSpec: Equatable, Sendable {
    public var switchEntityId: String
    public var isOn: Bool
    public var powerWatts: Double?
    public var energyKwh: Double?
    public var childLockEntityId: String?
    public var isChildLocked: Bool

    public init(
        switchEntityId: String,
        isOn: Bool,
        powerWatts: Double? = nil,
        energyKwh: Double? = nil,
        childLockEntityId: String? = nil,
        isChildLocked: Bool = false
    ) {
        self.switchEntityId = switchEntityId
        self.isOn = isOn
        self.powerWatts = powerWatts
        self.energyKwh = energyKwh
        self.childLockEntityId = childLockEntityId
        self.isChildLocked = isChildLocked
    }
}

public struct FridgeSpec: Equatable, Sendable {
    public var modeEntityId: String?
    public var currentMode: String
    public var availableModes: [String]
    public var fridgeCurrentTemp: Double?
    public var fridgeTargetTemp: Double
    public var fridgeTargetEntityId: String?
    public var freezerCurrentTemp: Double?
    public var freezerTargetTemp: Double
    public var freezerTargetEntityId: String?

    public init(
        modeEntityId: String?,
        currentMode: String,
        availableModes: [String],
        fridgeCurrentTemp: Double?,
        fridgeTargetTemp: Double,
        fridgeTargetEntityId: String?,
        freezerCurrentTemp: Double?,
        freezerTargetTemp: Double,
        freezerTargetEntityId: String?
    ) {
        self.modeEntityId = modeEntityId
        self.currentMode = currentMode
        self.availableModes = availableModes
        self.fridgeCurrentTemp = fridgeCurrentTemp
        self.fridgeTargetTemp = fridgeTargetTemp
        self.fridgeTargetEntityId = fridgeTargetEntityId
        self.freezerCurrentTemp = freezerCurrentTemp
        self.freezerTargetTemp = freezerTargetTemp
        self.freezerTargetEntityId = freezerTargetEntityId
    }
}

public struct VacuumSpec: Equatable, Sendable {
    public var entityId: String
    public var status: String // "docked", "cleaning", "returning", "paused", "idle"
    public var battery: Int?
    public var modeEntityId: String?
    public var currentMode: String?
    public var availableModes: [String]

    public init(
        entityId: String,
        status: String,
        battery: Int? = nil,
        modeEntityId: String? = nil,
        currentMode: String? = nil,
        availableModes: [String] = []
    ) {
        self.entityId = entityId
        self.status = status
        self.battery = battery
        self.modeEntityId = modeEntityId
        self.currentMode = currentMode
        self.availableModes = availableModes
    }

    public var isCleaning: Bool {
        status == "cleaning" || status == "on"
    }
}

public struct SpeakerSpec: Equatable, Sendable {
    public var mediaEntityId: String
    public var state: String // "idle", "playing", "paused"
    public var volumePercent: Int
    public var isMuted: Bool
    public var muteSwitchEntityId: String?
    public var sleepModeEntityId: String?
    public var isSleepMode: Bool
    public var ttsNotifyEntityId: String?
    public var directiveNotifyEntityId: String?
    public var playMusicButtonId: String?
    public var stopAlarmButtonId: String?

    public init(
        mediaEntityId: String,
        state: String,
        volumePercent: Int,
        isMuted: Bool = false,
        muteSwitchEntityId: String? = nil,
        sleepModeEntityId: String? = nil,
        isSleepMode: Bool = false,
        ttsNotifyEntityId: String? = nil,
        directiveNotifyEntityId: String? = nil,
        playMusicButtonId: String? = nil,
        stopAlarmButtonId: String? = nil
    ) {
        self.mediaEntityId = mediaEntityId
        self.state = state
        self.volumePercent = volumePercent
        self.isMuted = isMuted
        self.muteSwitchEntityId = muteSwitchEntityId
        self.sleepModeEntityId = sleepModeEntityId
        self.isSleepMode = isSleepMode
        self.ttsNotifyEntityId = ttsNotifyEntityId
        self.directiveNotifyEntityId = directiveNotifyEntityId
        self.playMusicButtonId = playMusicButtonId
        self.stopAlarmButtonId = stopAlarmButtonId
    }
}

public struct TVSpec: Equatable, Sendable {
    public var mediaEntityId: String
    public var state: String
    public var volumePercent: Int
    public var currentSource: String?
    public var availableSources: [String]
    public var turnOnButtonId: String?

    public init(
        mediaEntityId: String,
        state: String,
        volumePercent: Int,
        currentSource: String? = nil,
        availableSources: [String] = [],
        turnOnButtonId: String? = nil
    ) {
        self.mediaEntityId = mediaEntityId
        self.state = state
        self.volumePercent = volumePercent
        self.currentSource = currentSource
        self.availableSources = availableSources
        self.turnOnButtonId = turnOnButtonId
    }
}

public struct SensorSpec: Equatable, Sendable {
    public var temperature: Double?
    public var humidity: Double?
    public var battery: Int?
    public var statusText: String?

    public init(
        temperature: Double? = nil,
        humidity: Double? = nil,
        battery: Int? = nil,
        statusText: String? = nil
    ) {
        self.temperature = temperature
        self.humidity = humidity
        self.battery = battery
        self.statusText = statusText
    }
}

public enum DeviceKind: Equatable, Sendable {
    case light(LightSpec)
    case climate(ClimateSpec)
    case fan(FanSpec)
    case plug(PlugSpec)
    case fridge(FridgeSpec)
    case vacuum(VacuumSpec)
    case speaker(SpeakerSpec)
    case tv(TVSpec)
    case sensor(SensorSpec)
}

// MARK: - Unified SmartDevice

public struct SmartDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var roomId: String
    public var roomName: String
    public var model: String
    public var isOnline: Bool
    public var kind: DeviceKind

    public init(
        id: String,
        name: String,
        roomId: String,
        roomName: String,
        model: String,
        isOnline: Bool,
        kind: DeviceKind
    ) {
        self.id = id
        self.name = name
        self.roomId = roomId
        self.roomName = roomName
        self.model = model
        self.isOnline = isOnline
        self.kind = kind
    }

    /// Whether this device can be toggled on/off with a single primary click
    public var isPrimaryToggleable: Bool {
        switch kind {
        case .light, .climate, .fan, .plug, .vacuum:
            return true
        case .speaker, .tv, .fridge, .sensor:
            return false
        }
    }

    /// Whether this device currently counts as "actively turned on" (lights, AC, heater, fan, plug, vacuum cleaning)
    public var isActiveOn: Bool {
        guard isOnline else { return false }
        switch kind {
        case .light(let s): return s.isOn
        case .climate(let s): return s.isOn && s.hvacMode != "off"
        case .fan(let s): return s.isOn
        case .plug(let s): return s.isOn
        case .vacuum(let s): return s.isCleaning
        case .speaker(let s): return s.state == "playing"
        case .tv, .fridge, .sensor: return false
        }
    }

    /// Whether this device has an expandable secondary control drawer
    public var hasDetailDrawer: Bool {
        switch kind {
        case .light, .climate, .fan, .plug, .fridge, .vacuum, .speaker, .tv:
            return true
        case .sensor:
            return false
        }
    }

    public var sfSymbolName: String {
        switch kind {
        case .light(let s):
            if model.contains("strip") {
                return s.isOn ? "light.strip.2.fill" : "light.strip.2"
            }
            return s.isOn ? "lightbulb.fill" : "lightbulb"
        case .climate(let s):
            if model.contains("heater") {
                return s.isOn ? "heater.vertical.fill" : "heater.vertical"
            }
            return s.isOn ? "snowflake" : "air.conditioner.horizontal"
        case .fan:
            return "fan.floor.fill"
        case .plug(let s):
            if name.contains("咖啡") {
                return s.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill"
            }
            return s.isOn ? "powerplug.fill" : "powerplug"
        case .fridge:
            return "refrigerator.fill"
        case .vacuum:
            return "humidifier.and.droplets.fill" // clean appliance icon fallback handled in view
        case .speaker(let s):
            return s.isMuted ? "hifispeaker.slash.fill" : "hifispeaker.fill"
        case .tv:
            return "tv.fill"
        case .sensor(let s):
            if name.contains("门锁") {
                return "lock.shield.fill"
            }
            if s.temperature != nil {
                return "thermometer.medium"
            }
            return "sensor.fill"
        }
    }

    public var statusSubtitle: String {
        guard isOnline else { return "离线 · 未通电" }
        switch kind {
        case .light(let s):
            if !s.isOn { return "已关闭" }
            var parts: [String] = []
            if let b = s.brightnessPercent, b > 0 {
                parts.append("\(b)%")
            } else {
                parts.append("已开启")
            }
            if let effect = s.currentEffect, !effect.isEmpty {
                parts.append(Self.localizeEffect(effect))
            } else if let k = s.colorTempKelvin {
                parts.append("\(k)K")
            }
            return parts.joined(separator: " · ")

        case .climate(let s):
            if !s.isOn || s.hvacMode == "off" { return "已关闭" }
            let modeLabel = Self.localizeHVACMode(s.hvacMode)
            let tempStr = String(format: "%.0f°C", s.targetTemperature)
            if let cur = s.currentTemperature {
                return "\(modeLabel) \(tempStr) · 室温 \(String(format: "%.0f°", cur))"
            }
            return "\(modeLabel) · \(tempStr)"

        case .fan(let s):
            if !s.isOn { return "已关闭" }
            var parts: [String] = []
            if let mode = s.presetMode { parts.append(mode) }
            if let pct = s.percentage { parts.append("\(pct)%") }
            if parts.isEmpty { parts.append("运行中") }
            return parts.joined(separator: " · ")

        case .plug(let s):
            if !s.isOn { return "已关闭" }
            if let w = s.powerWatts {
                if w >= 1 {
                    return String(format: "开启 · %.0fW", w)
                } else {
                    return "开启 · 待机 0W"
                }
            }
            return "已开启"

        case .fridge(let s):
            let cStr = s.fridgeCurrentTemp.map { String(format: "冷藏 %.0f°", $0) } ?? "冷藏 --"
            let fStr = s.freezerCurrentTemp.map { String(format: "冷冻 %.0f°", $0) } ?? "冷冻 --"
            return "\(cStr) · \(fStr)"

        case .vacuum(let s):
            let st: String = switch s.status {
            case "cleaning", "on": "清扫中"
            case "returning": "回充途中"
            case "paused": "已暂停"
            case "docked": "充电待机"
            default: "待机"
            }
            if let bat = s.battery {
                return "\(st) · \(bat)%"
            }
            return st

        case .speaker(let s):
            let playStr = s.state == "playing" ? "播放中" : "待机"
            let volStr = s.isMuted ? "已静音" : "音量 \(s.volumePercent)%"
            return "\(playStr) · \(volStr)"

        case .tv(let s):
            let st = (s.state == "off" || s.state == "standby") ? "待机" : "在线"
            return "\(st) · 音量 \(s.volumePercent)%"

        case .sensor(let s):
            if let t = s.temperature, let h = s.humidity {
                return String(format: "%.1f°C · %.0f%%", t, h)
            }
            if let text = s.statusText {
                if let bat = s.battery {
                    return "\(text) · 电量 \(bat)%"
                }
                return text
            }
            return "在线"
        }
    }

    public static func localizeEffect(_ effect: String) -> String {
        switch effect {
        case "Day": return "日光"
        case "Night": return "月光"
        default: return effect
        }
    }

    public static func localizeHVACMode(_ mode: String) -> String {
        switch mode {
        case "cool": return "制冷"
        case "heat": return "制热"
        case "dry": return "除湿"
        case "fan_only": return "送风"
        case "auto", "heat_cool": return "自动"
        case "off": return "关闭"
        default: return mode
        }
    }
}

// MARK: - Commands Dispatched Over the Seam

public enum DeviceCommand: Equatable, Sendable {
    case setLightPower(entityId: String, isOn: Bool)
    case setLightBrightness(entityId: String, percent: Int)
    case setLightColorTemp(entityId: String, kelvin: Int)
    case setLightEffect(entityId: String, effect: String)

    case setClimatePower(entityId: String, isOn: Bool, fallbackMode: String)
    case setClimateMode(entityId: String, hvacMode: String)
    case setClimateTemperature(entityId: String, temperature: Double)
    case setClimateFanMode(entityId: String, fanMode: String)
    case setClimateSwingMode(entityId: String, swingMode: String)

    case setFanPower(entityId: String, isOn: Bool)
    case setFanPresetMode(entityId: String, presetMode: String)
    case setFanOscillating(entityId: String, oscillating: Bool)

    case setSwitch(entityId: String, isOn: Bool)
    case setSelectOption(entityId: String, option: String)
    case setNumberValue(entityId: String, value: Double)

    case vacuumAction(entityId: String, action: VacuumAction)
    case mediaSetVolume(entityId: String, volumeLevel: Double)
    case mediaSelectSource(entityId: String, source: String)
    case pressButton(entityId: String)
    case sendNotifyMessage(entityId: String, message: String)
}

public enum VacuumAction: String, Equatable, Sendable {
    case start = "start"
    case pause = "pause"
    case returnToBase = "return_to_base"
}
