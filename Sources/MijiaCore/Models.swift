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
    public var pm25Density: Int?
    public var airQuality: String?
    public var temperature: Double?
    public var humidity: Double?
    public var filterLifePercent: Int?

    public init(
        entityId: String,
        isOn: Bool,
        percentage: Int? = nil,
        presetMode: String? = nil,
        availablePresetModes: [String] = [],
        isOscillating: Bool? = nil,
        pm25Density: Int? = nil,
        airQuality: String? = nil,
        temperature: Double? = nil,
        humidity: Double? = nil,
        filterLifePercent: Int? = nil
    ) {
        self.entityId = entityId
        self.isOn = isOn
        self.percentage = percentage
        self.presetMode = presetMode
        self.availablePresetModes = availablePresetModes
        self.isOscillating = isOscillating
        self.pm25Density = pm25Density
        self.airQuality = airQuality
        self.temperature = temperature
        self.humidity = humidity
        self.filterLifePercent = filterLifePercent
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
    public var isMuted: Bool
    public var isScreenOff: Bool
    public var isPairingPromptActive: Bool
    public var currentSource: String?
    public var availableSources: [String]
    public var turnOnButtonId: String?

    public init(
        mediaEntityId: String,
        state: String,
        volumePercent: Int,
        isMuted: Bool = false,
        isScreenOff: Bool = false,
        isPairingPromptActive: Bool = false,
        currentSource: String? = nil,
        availableSources: [String] = [],
        turnOnButtonId: String? = nil
    ) {
        self.mediaEntityId = mediaEntityId
        self.state = state
        self.volumePercent = volumePercent
        self.isMuted = isMuted
        self.isScreenOff = isScreenOff
        self.isPairingPromptActive = isPairingPromptActive
        self.currentSource = currentSource
        self.availableSources = availableSources
        self.turnOnButtonId = turnOnButtonId
    }
}

public struct CameraSpec: Equatable, Sendable {
    public var entityId: String
    public var isOn: Bool
    public var nightShot: String?
    public var availableNightShots: [String]
    public var motionDetectionEntityId: String?
    public var isMotionDetectionOn: Bool?
    public var streamEntityId: String?
    public var snapshotPath: String?

    public init(
        entityId: String,
        isOn: Bool,
        nightShot: String? = nil,
        availableNightShots: [String] = [],
        motionDetectionEntityId: String? = nil,
        isMotionDetectionOn: Bool? = nil,
        streamEntityId: String? = nil,
        snapshotPath: String? = nil
    ) {
        self.entityId = entityId
        self.isOn = isOn
        self.nightShot = nightShot
        self.availableNightShots = availableNightShots
        self.motionDetectionEntityId = motionDetectionEntityId
        self.isMotionDetectionOn = isMotionDetectionOn
        self.streamEntityId = streamEntityId
        self.snapshotPath = snapshotPath
    }
}

public enum CameraStreamSource: Equatable, Sendable {
    case hls(URL)
    /// Progressive fragmented MP4 (H.264/H.265) decoded natively; `mjpegFallback` is played
    /// if native decoding cannot start (#97).
    case liveMP4(URL, mjpegFallback: URL?)
    case mjpeg(URL)
    case snapshot(URL)
    case demo(deviceId: String)
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
    case camera(CameraSpec)
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
        case .light, .climate, .fan, .plug, .vacuum, .tv, .camera:
            return true
        case .speaker, .fridge, .sensor:
            return false
        }
    }

    /// Whether this device currently counts as "actively turned on" (lights, AC, heater, fan, plug, vacuum cleaning, TV on)
    public var isActiveOn: Bool {
        guard isOnline else { return false }
        switch kind {
        case .light(let s): return s.isOn
        case .climate(let s): return s.isOn && s.hvacMode != "off"
        case .fan(let s): return s.isOn
        case .plug(let s): return s.isOn
        case .vacuum(let s): return s.isCleaning
        case .speaker(let s): return s.state == "playing"
        case .tv(let s): return s.state != "off" && s.state != "standby"
        case .camera(let s): return s.isOn
        case .fridge, .sensor: return false
        }
    }

    /// Whether this device has an expandable secondary control drawer
    public var hasDetailDrawer: Bool {
        switch kind {
        case .light, .climate, .fan, .fridge, .vacuum, .speaker, .tv, .camera:
            return true
        case .plug(let s):
            return s.powerWatts != nil || s.energyKwh != nil || s.childLockEntityId != nil
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
        case .fan(let s):
            if model.contains("airp") || model.contains("purifier") || name.contains("净化")
                || s.pm25Density != nil || s.airQuality != nil || s.filterLifePercent != nil {
                return "aqi.medium"
            }
            return "fan.floor.fill"
        case .plug(let s):
            if name.contains("咖啡") {
                return s.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill"
            }
            if name.contains("灯") {
                return s.isOn ? "lightbulb.fill" : "lightbulb"
            }
            if model.contains(".switch.") {
                return s.isOn ? "lightswitch.on.fill" : "lightswitch.off"
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
        case .camera(let s):
            return s.isOn ? "web.camera.fill" : "web.camera"
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
        guard isOnline else { return L10n.tr("离线 · 未通电", "Offline · Unplugged") }
        switch kind {
        case .light(let s):
            if !s.isOn { return L10n.tr("已关闭", "Off") }
            var parts: [String] = []
            if let b = s.brightnessPercent, b > 0 {
                parts.append("\(b)%")
            } else {
                parts.append(L10n.tr("已开启", "On"))
            }
            if let effect = s.currentEffect, !effect.isEmpty {
                parts.append(Self.localizeEffect(effect))
            } else if let k = s.colorTempKelvin {
                parts.append("\(k)K")
            }
            return parts.joined(separator: " · ")

        case .climate(let s):
            if !s.isOn || s.hvacMode == "off" { return L10n.tr("已关闭", "Off") }
            let modeLabel = Self.localizeHVACMode(s.hvacMode)
            // Stored and stepped in Celsius; only the digits shown follow the display unit (#52).
            let tempStr = L10n.temperature(s.targetTemperature)
            if let cur = s.currentTemperature {
                return L10n.tr(
                    "\(modeLabel) \(tempStr) · 室温 \(L10n.temperature(cur))",
                    "\(modeLabel) \(tempStr) · Room \(L10n.temperature(cur))"
                )
            }
            return "\(modeLabel) · \(tempStr)"

        case .fan(let s):
            var envParts: [String] = []
            if let pm25 = s.pm25Density {
                if let aq = Self.localizeAirQuality(s.airQuality, pm25: pm25) {
                    envParts.append("PM2.5 \(pm25) \(aq)")
                } else {
                    envParts.append("PM2.5 \(pm25)")
                }
            } else if let aq = Self.localizeAirQuality(s.airQuality, pm25: nil) {
                envParts.append(aq)
            }
            if let t = s.temperature, let h = s.humidity {
                envParts.append("\(L10n.temperature(t, fractionDigits: 0)) \(Int(h.rounded()))%")
            } else if let t = s.temperature {
                envParts.append(L10n.temperature(t, fractionDigits: 1))
            } else if let h = s.humidity {
                envParts.append("\(Int(h.rounded()))%")
            }
            if !s.isOn {
                if envParts.isEmpty { return L10n.tr("已关闭", "Off") }
                return ([L10n.tr("已关闭", "Off")] + envParts).joined(separator: " · ")
            }
            var parts: [String] = []
            if let mode = s.presetMode { parts.append(Self.localizeFanPreset(mode)) }
            if let pct = s.percentage { parts.append("\(pct)%") }
            if parts.isEmpty { parts.append(L10n.tr("运行中", "Running")) }
            parts.append(contentsOf: envParts)
            return parts.joined(separator: " · ")

        case .plug(let s):
            if !s.isOn { return L10n.tr("已关闭", "Off") }
            if let w = s.powerWatts {
                if w >= 1 {
                    return L10n.tr(
                        String(format: "开启 · %.0fW", w),
                        String(format: "On · %.0fW", w)
                    )
                } else {
                    return L10n.tr("开启 · 待机 0W", "On · Standby 0W")
                }
            }
            return L10n.tr("已开启", "On")

        case .fridge(let s):
            let cStr = s.fridgeCurrentTemp.map { L10n.format("冷藏 %@", "Fridge %@", L10n.temperature($0)) }
                ?? L10n.tr("冷藏 --", "Fridge --")
            let fStr = s.freezerCurrentTemp.map { L10n.format("冷冻 %@", "Freezer %@", L10n.temperature($0)) }
                ?? L10n.tr("冷冻 --", "Freezer --")
            return "\(cStr) · \(fStr)"

        case .vacuum(let s):
            let st: String = switch s.status {
            case "cleaning", "on": L10n.tr("清扫中", "Cleaning")
            case "returning": L10n.tr("回充途中", "Returning")
            case "paused": L10n.tr("已暂停", "Paused")
            case "docked": L10n.tr("充电待机", "Docked")
            default: L10n.tr("待机", "Standby")
            }
            if let bat = s.battery {
                return "\(st) · \(bat)%"
            }
            return st

        case .speaker(let s):
            let playStr = s.state == "playing" ? L10n.tr("播放中", "Playing") : L10n.tr("待机", "Standby")
            let volStr = s.isMuted ? L10n.tr("已静音", "Muted") : L10n.tr("音量 \(s.volumePercent)%", "Vol \(s.volumePercent)%")
            return "\(playStr) · \(volStr)"

        case .tv(let s):
            if s.isPairingPromptActive {
                return L10n.tr("请在电视上点击「允许」配对", "Accept pairing prompt on TV")
            }
            if s.state == "off" || s.state == "standby" {
                return L10n.tr("已关机 · 可唤醒", "Standby · Ready to Wake")
            }
            var parts: [String] = []
            if let src = s.currentSource, !src.isEmpty {
                parts.append(src)
            } else {
                parts.append(L10n.tr("在线", "Online"))
            }
            if s.isScreenOff {
                parts.append(L10n.tr("已熄屏", "Screen Off"))
            }
            parts.append(s.isMuted ? L10n.tr("已静音", "Muted") : L10n.tr("音量 \(s.volumePercent)%", "Vol \(s.volumePercent)%"))
            return parts.joined(separator: " · ")

        case .camera(let s):
            if !s.isOn { return L10n.tr("休眠中 · 点击唤醒", "Sleeping · Click to Wake") }
            var parts: [String] = [L10n.tr("监控中", "Monitoring")]
            if let night = s.nightShot, !night.isEmpty {
                parts.append(Self.localizeNightShot(night))
            }
            if s.isMotionDetectionOn == true {
                parts.append(L10n.tr("侦测开", "Motion On"))
            }
            parts.append(L10n.tr("点击看画面", "Live View"))
            return parts.joined(separator: " · ")

        case .sensor(let s):
            if let t = s.temperature, let h = s.humidity {
                return "\(L10n.temperature(t, fractionDigits: 1)) · \(String(format: "%.0f%%", h))"
            }
            if let text = s.statusText {
                if let bat = s.battery {
                    return L10n.tr("\(text) · 电量 \(bat)%", "\(text) · Battery \(bat)%")
                }
                return text
            }
            return L10n.tr("在线", "Online")
        }
    }

    public static func localizeEffect(_ effect: String) -> String {
        switch effect {
        case "Day": return L10n.tr("日光", "Daylight")
        case "Night": return L10n.tr("月光", "Moonlight")
        case "None": return L10n.tr("无", "None")
        case "Warmth": return L10n.tr("温馨", "Warmth")
        case "Tv", "TV": return L10n.tr("观影", "TV")
        case "Reading": return L10n.tr("阅读", "Reading")
        case "Computer": return L10n.tr("电脑", "Computer")
        case "Hospitality": return L10n.tr("会客", "Hospitality")
        case "Entertainment": return L10n.tr("娱乐", "Entertainment")
        case "Wakeup": return L10n.tr("起床", "Wake Up")
        case "Dusk": return L10n.tr("黄昏", "Dusk")
        case "Sleep": return L10n.tr("睡眠", "Sleep")
        default: return effect
        }
    }

    public static func localizeHVACMode(_ mode: String) -> String {
        switch mode {
        case "cool": return L10n.tr("制冷", "Cool")
        case "heat": return L10n.tr("制热", "Heat")
        case "dry": return L10n.tr("除湿", "Dry")
        case "fan_only": return L10n.tr("送风", "Fan")
        case "auto", "heat_cool": return L10n.tr("自动", "Auto")
        case "off": return L10n.tr("关闭", "Off")
        default: return mode
        }
    }

    public static func localizeFanPreset(_ mode: String) -> String {
        switch mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto", "automatic": return L10n.tr("自动", "Auto")
        case "sleep": return L10n.tr("睡眠", "Sleep")
        case "favorite", "favourite": return L10n.tr("最爱", "Favorite")
        case "manual", "none": return L10n.tr("手动", "Manual")
        case "silent": return L10n.tr("静音", "Silent")
        default: return mode
        }
    }

    public static func localizeAirQuality(_ raw: String?, pm25: Int?) -> String? {
        if let raw, !raw.isEmpty {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "excellent", "空气优", "优": return L10n.tr("优", "Excellent")
            case "good", "空气良", "良": return L10n.tr("良", "Good")
            case "moderate", "轻度污染": return L10n.tr("轻度污染", "Moderate")
            case "poor", "中度污染": return L10n.tr("中度污染", "Poor")
            case "heavy pollution", "heavy", "重度污染": return L10n.tr("重度污染", "Heavy")
            case "hazardous", "严重污染": return L10n.tr("严重污染", "Hazardous")
            default: return raw
            }
        }
        guard let pm25 else { return nil }
        switch pm25 {
        case ...35: return L10n.tr("优", "Excellent")
        case ...75: return L10n.tr("良", "Good")
        case ...115: return L10n.tr("轻度污染", "Moderate")
        case ...150: return L10n.tr("中度污染", "Poor")
        case ...250: return L10n.tr("重度污染", "Heavy")
        default: return L10n.tr("严重污染", "Hazardous")
        }
    }

    public static func localizeNightShot(_ mode: String) -> String {
        switch mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "close": return L10n.tr("夜视关", "Night Off")
        case "on", "open": return L10n.tr("夜视开", "Night On")
        case "auto", "automatic": return L10n.tr("自动夜视", "Auto Night")
        case "auto full color", "smart full color", "auto smart full color":
            return L10n.tr("智能全彩", "Smart Color")
        case "on full color", "full color":
            return L10n.tr("全彩夜视", "Full Color")
        default: return mode
        }
    }
}

// MARK: - Scene & QuickAction Domain Types

public struct HomeScene: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var entityId: String
    public var iconName: String

    public init(id: String, name: String, entityId: String, iconName: String = "sparkles") {
        self.id = id
        self.name = name
        self.entityId = entityId
        self.iconName = iconName
    }
}

public enum QuickAction: String, CaseIterable, Identifiable, Equatable, Sendable {
    case lightsOff = "lightsOff"
    case softNightLight = "softNightLight"
    case climateSleepOff = "climateSleepOff"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lightsOff: return L10n.tr("全屋关灯", "All Lights Off")
        case .softNightLight: return L10n.tr("柔和夜灯", "Soft Night Light")
        case .climateSleepOff: return L10n.tr("关温控风扇", "Sleep Climate Off")
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .lightsOff: return "lightbulb.slash.fill"
        case .softNightLight: return "moon.stars.fill"
        case .climateSleepOff: return "wind.snow"
        }
    }

    /// Quick actions own their visual family explicitly; no symbol parsing.
    public var visualCategory: SceneVisualCategory {
        switch self {
        case .lightsOff: return .light
        case .softNightLight: return .night
        case .climateSleepOff: return .climate
        }
    }
}

/// Scene visual family, one level above colour: models own the semantics, the UI maps it to tints.
public enum SceneVisualCategory: String, Sendable {
    case night
    case climate
    case water
    case heat
    case media
    case light

    /// Keyword map for externally supplied scene icons: Home Assistant sends arbitrary symbol
    /// names, so the family has to be inferred somewhere centralised and testable.
    public init(iconSymbol: String) {
        let symbol = iconSymbol.lowercased()
        if symbol.contains("moon") || symbol.contains("zzz") || symbol.contains("night") {
            self = .night
        } else if symbol.contains("snow") || symbol.contains("wind") || symbol.contains("therm") || symbol.contains("fan") {
            self = .climate
        } else if symbol.contains("drop") || symbol.contains("humid") || symbol.contains("water") {
            self = .water
        } else if symbol.contains("flame") || symbol.contains("heat") {
            self = .heat
        } else if symbol.contains("tv") || symbol.contains("play") || symbol.contains("film")
            || symbol.contains("music") || symbol.contains("speaker") {
            self = .media
        } else {
            self = .light
        }
    }
}

extension HomeScene {
    public var visualCategory: SceneVisualCategory {
        SceneVisualCategory(iconSymbol: iconName)
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
    case setFanPercentage(entityId: String, percent: Int)
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
    case activateScene(entityId: String)
}

public enum VacuumAction: String, Equatable, Sendable {
    case start = "start"
    case pause = "pause"
    case returnToBase = "return_to_base"
}

// MARK: - Menu Bar Metrics & Safety Alerts

public struct MenuBarMetricOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct SafetyAlert: Identifiable, Equatable, Sendable {
    public let id: String
    public let deviceId: String
    public var title: String
    public var body: String
    public var turnOffCommand: DeviceCommand?

    public init(
        id: String,
        deviceId: String,
        title: String,
        body: String,
        turnOffCommand: DeviceCommand? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.title = title
        self.body = body
        self.turnOffCommand = turnOffCommand
    }
}
