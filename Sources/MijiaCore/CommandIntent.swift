import Foundation

// MARK: - Assistant Intent Domain Types

public enum IntentOperation: Equatable, Sendable {
    case power(Bool)
    case brightness(Int)          // 1...100
    case colorTemperature(Int)    // kelvin
    case lightEffect(String)      // Day / Night (or device-supported effect)
    case hvacMode(String)         // cool/heat/dry/fan_only/auto/off
    case targetTemperature(Double)
    case activateScene            // target is a HomeScene id
    case fanSpeed(String)         // fan preset or air-conditioner fan mode; normalized to the device's own option
    case oscillation(Bool)        // fan swing (摇头)

    // Relative adjustments ("再暗一点", "调高两度"). IntentValidator.normalize resolves them against the
    // device's current state into .brightness / .targetTemperature, so nothing downstream ever sees them.
    case brightnessStep(Int)      // ± percent
    case temperatureStep(Double)  // ± °C

    public var isRelative: Bool {
        switch self {
        case .brightnessStep, .temperatureStep: return true
        default: return false
        }
    }
}

public struct DeviceIntent: Equatable, Sendable {
    public let targetId: String
    public let operation: IntentOperation

    public init(targetId: String, operation: IntentOperation) {
        self.targetId = targetId
        self.operation = operation
    }
}

public struct IntentPlan: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case local, model }

    public var intents: [DeviceIntent]
    public var reply: String
    public var source: Source
    public var suggestions: [AssistantSuggestion]

    public init(
        intents: [DeviceIntent],
        reply: String,
        source: Source,
        suggestions: [AssistantSuggestion] = []
    ) {
        self.intents = intents
        self.reply = reply
        self.source = source
        self.suggestions = suggestions
    }
}

public enum AssistantState: Equatable, Sendable {
    case idle
    case thinking
    case done(String)
    case failed(String)
}

// MARK: - Device Category Used by Both Resolvers

public enum IntentDeviceCategory: String, Equatable, Sendable, CaseIterable {
    case light, climate, heater, fan, plug, vacuum, speaker, tv, fridge, sensor

    private static let heaterNameHints = ["电暖", "暖气", "取暖", "暖风"]

    public init(_ device: SmartDevice) {
        switch device.kind {
        case .light: self = .light
        case .climate:
            let isHeater = device.model.contains("heater")
                || Self.heaterNameHints.contains(where: device.name.contains)
            self = isHeater ? .heater : .climate
        case .fan: self = .fan
        case .plug: self = .plug
        case .vacuum: self = .vacuum
        case .speaker: self = .speaker
        case .tv: self = .tv
        case .fridge: self = .fridge
        case .sensor: self = .sensor
        }
    }

    /// Categories whose state the assistant can change; the rest are omitted from prompts and plans.
    public var isAssistantControllable: Bool {
        switch self {
        case .light, .climate, .heater, .fan, .plug, .vacuum, .tv: return true
        case .speaker, .fridge, .sensor: return false
        }
    }
}

// MARK: - Boundary Validation Shared by Local Parser and Model Resolver

public enum IntentValidator {
    private static let hvacModeAliases: [String: String] = [
        "fan": "fan_only",
        "fanonly": "fan_only",
        "heat_cool": "auto"
    ]

    private static let lightEffectAliases: [String: String] = [
        "moonlight": "Night",
        "night": "Night",
        "月光": "Night",
        "月光模式": "Night",
        "夜灯": "Night",
        "夜灯模式": "Night",
        "daylight": "Day",
        "day": "Day",
        "日光": "Day",
        "日光模式": "Day"
    ]

    /// Returns the operation adjusted to the device's limits, or nil when the device cannot perform it.
    public static func normalize(_ operation: IntentOperation, for device: SmartDevice) -> IntentOperation? {
        switch (operation, device.kind) {
        case (.power, .light), (.power, .climate), (.power, .fan), (.power, .plug), (.power, .vacuum), (.power, .tv):
            return operation

        case (.brightness(let percent), .light):
            return .brightness(min(100, max(1, percent)))

        case (.colorTemperature(let kelvin), .light(let s)):
            guard kelvin > 0 else { return nil }
            return .colorTemperature(min(s.maxKelvin, max(s.minKelvin, kelvin)))

        case (.lightEffect(let raw), .light(let s)):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = lightEffectAliases[trimmed.lowercased()] ?? lightEffectAliases[trimmed] ?? trimmed
            guard let matched = s.availableEffects.first(where: {
                $0.caseInsensitiveCompare(canonical) == .orderedSame
            }) else {
                return nil
            }
            return .lightEffect(matched)

        case (.hvacMode(let raw), .climate(let s)):
            let lowered = raw.lowercased()
            let mode = hvacModeAliases[lowered] ?? lowered
            if mode == "off" || s.availableModes.isEmpty || s.availableModes.contains(mode) {
                return .hvacMode(mode)
            }
            // HA climate entities expose "heat_cool" where users say "auto".
            if mode == "auto", s.availableModes.contains("heat_cool") {
                return .hvacMode("heat_cool")
            }
            return nil

        case (.targetTemperature(let t), .climate(let s)):
            guard t.isFinite else { return nil }
            return .targetTemperature(min(s.maxTemp, max(s.minTemp, t)))

        case (.brightnessStep(let delta), .light(let s)):
            let base = s.isOn ? (s.brightnessPercent ?? 100) : 0
            return .brightness(min(100, max(1, base + delta)))

        case (.temperatureStep(let delta), .climate(let s)):
            guard delta.isFinite else { return nil }
            return .targetTemperature(min(s.maxTemp, max(s.minTemp, s.targetTemperature + delta)))

        case (.fanSpeed(let raw), .fan(let s)):
            return FanSpeedMatcher.match(raw, in: s.availablePresetModes).map(IntentOperation.fanSpeed)

        case (.fanSpeed(let raw), .climate(let s)):
            return FanSpeedMatcher.match(raw, in: s.availableFanModes).map(IntentOperation.fanSpeed)

        case (.oscillation, .fan(let s)) where s.isOscillating != nil:
            return operation

        default:
            return nil
        }
    }

    /// Keeps only intents whose target exists and whose operation is valid for it, clamping numeric values.
    public static func sanitize(
        _ intents: [DeviceIntent],
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> [DeviceIntent] {
        let deviceById = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sceneIds = Set(scenes.map(\.id))
        var result: [DeviceIntent] = []
        for intent in intents {
            if intent.operation == .activateScene {
                if sceneIds.contains(intent.targetId) { result.append(intent) }
                continue
            }
            guard let device = deviceById[intent.targetId],
                  let op = normalize(intent.operation, for: device) else { continue }
            let normalized = DeviceIntent(targetId: device.id, operation: op)
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }
}

// MARK: - Human-Readable Receipts

public enum IntentReply {
    public static func describe(
        _ intents: [DeviceIntent],
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> String {
        let nameById = Dictionary(
            devices.map { ($0.id, $0.name) } + scenes.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        var order: [IntentOperation] = []
        var targetsByOp: [String: [String]] = [:]
        for intent in intents {
            let key = String(describing: intent.operation)
            if targetsByOp[key] == nil { order.append(intent.operation) }
            targetsByOp[key, default: []].append(nameById[intent.targetId] ?? intent.targetId)
        }
        let clauses = order.map { op -> String in
            let names = targetsByOp[String(describing: op)] ?? []
            let joined = names.count > 3
                ? names.prefix(3).joined(separator: "、") + " 等 \(names.count) 台"
                : names.joined(separator: "、")
            switch op {
            case .power(true): return "打开\(joined)"
            case .power(false): return "关闭\(joined)"
            case .brightness(let b): return "\(joined)亮度调至 \(b)%"
            case .colorTemperature(let k): return "\(joined)色温调至 \(k)K"
            case .lightEffect(let e): return "\(joined)切换为\(SmartDevice.localizeEffect(e))模式"
            case .hvacMode(let m): return "\(joined)切换为\(SmartDevice.localizeHVACMode(m))"
            case .targetTemperature(let t): return "\(joined)设为 \(formatTemperature(t))°C"
            case .activateScene: return "执行场景「\(joined)」"
            case .fanSpeed(let v):
                let label = fanSpeedLabel(v)
                return "\(joined)风速调为\(label.first?.isNumber == true ? " " : "")\(label)"
            case .oscillation(let on): return "\(joined)\(on ? "开启" : "关闭")摇头"
            case .brightnessStep(let d): return "\(joined)亮度\(d >= 0 ? "调高" : "调低") \(abs(d))%"
            case .temperatureStep(let d): return "\(joined)温度\(d >= 0 ? "调高" : "调低") \(formatTemperature(abs(d)))°C"
            }
        }
        return clauses.isEmpty ? "" : "已" + clauses.joined(separator: "，")
    }

    /// "Level3" → "3 档"，"high" → "高档"；其余原样返回。
    public static func fanSpeedLabel(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("level"), let n = Int(lowered.dropFirst(5)) { return "\(n) 档" }
        let names = ["low": "低档", "medium": "中档", "middle": "中档", "mid": "中档", "high": "高档", "auto": "自动", "silent": "静音", "sleep": "睡眠"]
        return names[lowered] ?? raw
    }

    static func formatTemperature(_ t: Double) -> String {
        t.rounded() == t ? String(Int(t)) : String(format: "%.1f", t)
    }
}

// MARK: - Compact Catalog for the Model Prompt

/// Serializes controllable devices and scenes with short aliases (d1, s1) so the prompt stays small
/// and the model cannot echo back long HA registry ids with typos.
public struct IntentCatalog: Sendable {
    public let lines: [String]
    public let sceneLines: [String]
    public let criteriaByAlias: [String: String]
    private let realIdsByAlias: [String: [String]]

    public init(devices: [SmartDevice], scenes: [HomeScene]) {
        var lines: [String] = []
        var map: [String: [String]] = [:]
        var criteria: [String: String] = [:]
        var allLightIds: [String] = []
        var allDeviceIds: [String] = []
        var roomLights: [String: [String]] = [:]
        var index = 0
        for device in devices {
            let category = IntentDeviceCategory(device)
            guard category.isAssistantControllable else { continue }
            index += 1
            let alias = "d\(index)"
            let summary = Self.stateSummary(device)
            map[alias] = [device.id]
            allDeviceIds.append(device.id)
            if category == .light {
                allLightIds.append(device.id)
                if !device.roomName.isEmpty {
                    roomLights[device.roomName, default: []].append(device.id)
                }
            }
            criteria[alias] = "\(device.name) (\(device.roomName), \(category.rawValue), \(summary))"
            lines.append([alias, device.name, device.roomName, category.rawValue, summary].joined(separator: "|"))
        }
        for (room, ids) in roomLights where ids.count >= 2 {
            let alias = "room_lights:\(room)"
            map[alias] = ids
            criteria[alias] = "\(room)所有灯具 (\(ids.count)盏)"
        }
        if allLightIds.count >= 2 {
            map["all_lights"] = allLightIds
            criteria["all_lights"] = "全屋所有灯具 (\(allLightIds.count)盏)"
        }
        if allDeviceIds.count >= 2 {
            map["all_devices"] = allDeviceIds
            criteria["all_devices"] = "全屋所有可控设备 (\(allDeviceIds.count)台)"
        }
        var sceneLines: [String] = []
        for (offset, scene) in scenes.enumerated() {
            let alias = "s\(offset + 1)"
            map[alias] = [scene.id]
            criteria[alias] = "场景：\(scene.name)"
            sceneLines.append("\(alias)|\(scene.name)")
        }
        self.lines = lines
        self.sceneLines = sceneLines
        self.criteriaByAlias = criteria
        self.realIdsByAlias = map
    }

    public func realId(forAlias alias: String) -> String? {
        realIdsByAlias[alias.trimmingCharacters(in: .whitespacesAndNewlines)]?.first
    }

    public func realIds(forTargetChoice choice: String) -> [String] {
        realIdsByAlias[choice.trimmingCharacters(in: .whitespacesAndNewlines)] ?? []
    }

    public var text: String {
        var out = "设备(id|名称|房间|类型|当前状态):\n" + lines.joined(separator: "\n")
        if !sceneLines.isEmpty {
            out += "\n场景(id|名称):\n" + sceneLines.joined(separator: "\n")
        }
        return out
    }

    static func stateSummary(_ device: SmartDevice) -> String {
        guard device.isOnline else { return "离线" }
        switch device.kind {
        case .light(let s):
            let effectList = s.availableEffects.isEmpty ? "" : " 可用模式:\(s.availableEffects.joined(separator: "/"))"
            guard s.isOn else { return "关" + effectList }
            let bri = s.brightnessPercent.map { " 亮度\($0)%" } ?? ""
            let eff = s.currentEffect.map { " 当前:\($0)" } ?? ""
            return "开\(bri)\(eff)\(effectList)"
        case .climate(let s):
            let modes = s.availableModes.joined(separator: "/")
            let range = "\(IntentReply.formatTemperature(s.minTemp))-\(IntentReply.formatTemperature(s.maxTemp))°C"
            let current = (s.isOn && s.hvacMode != "off")
                ? "\(s.hvacMode) \(IntentReply.formatTemperature(s.targetTemperature))°C"
                : "关"
            let fan = s.availableFanModes.isEmpty ? "" : " 可选风速:\(s.availableFanModes.joined(separator: "/"))"
            return "\(current) 可用模式:\(modes) 温度范围:\(range)\(fan)"
        case .fan(let s):
            var out = s.isOn ? "开" : "关"
            if s.isOn, let preset = s.presetMode { out += " 风速:\(preset)" }
            if !s.availablePresetModes.isEmpty { out += " 可选风速:\(s.availablePresetModes.joined(separator: "/"))" }
            if s.isOscillating != nil { out += " 摇头:\(s.isOscillating == true ? "开" : "关")" }
            return out
        case .plug(let s): return s.isOn ? "开" : "关"
        case .vacuum(let s): return s.isCleaning ? "清扫中" : "待机"
        case .tv(let s):
            if s.state == "off" || s.state == "standby" { return "关" }
            let src = s.currentSource.map { " \($0)" } ?? ""
            return "开\(src) 音量\(s.volumePercent)%"
        case .speaker, .fridge, .sensor: return ""
        }
    }
}

// MARK: - Fan Speed Matching

/// Maps spoken speed words (高/中/低/自动, high/medium/low/auto) onto whatever option names the device
/// exposes ("Level1…3", "low/medium/high", "静音"…). Exact names win; otherwise rank among the plain
/// speed levels (first = low, middle = medium, last = high).
public enum FanSpeedMatcher {
    private enum Level { case low, medium, high, auto }

    private static let spoken: [(Level, [String])] = [
        (.auto, ["auto", "自动"]),
        (.high, ["high", "高", "大", "强", "max", "最大", "strong"]),
        (.medium, ["medium", "middle", "mid", "中"]),
        (.low, ["low", "低", "小", "弱", "min", "最小", "微"])
    ]
    private static let optionHints: [Level: [String]] = [
        .auto: ["auto", "自动"],
        .high: ["high", "strong", "高", "强"],
        .medium: ["medium", "middle", "mid", "中"],
        .low: ["low", "低", "弱"]
    ]
    /// Options that are modes rather than speed levels, so they never take part in rank matching.
    private static let nonLevelHints = ["auto", "自动", "sleep", "睡眠", "silent", "静音", "natural", "nature", "自然", "smart", "智能"]

    public static func match(_ raw: String, in options: [String]) -> String? {
        let wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !options.isEmpty else { return nil }
        if let exact = options.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return exact }

        let lowered = wanted.lowercased()
        guard let level = spoken.first(where: { $0.1.contains(where: { lowered == $0 || lowered.hasPrefix($0) }) })?.0 else {
            return nil
        }
        if let named = options.first(where: { opt in optionHints[level]!.contains { opt.lowercased().contains($0) } }) {
            return named
        }
        let levels = options.filter { opt in !nonLevelHints.contains { opt.lowercased().contains($0) } }
        guard !levels.isEmpty else { return nil }
        switch level {
        case .low: return levels.first
        case .high: return levels.last
        case .medium: return levels[levels.count / 2]
        case .auto: return nil
        }
    }
}
