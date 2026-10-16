import Foundation

// MARK: - Assistant Intent Domain Types

public enum IntentOperation: Equatable, Sendable {
    case power(Bool)
    case brightness(Int)          // 1...100
    case colorTemperature(Int)    // kelvin
    case hvacMode(String)         // cool/heat/dry/fan_only/auto/off
    case targetTemperature(Double)
    case activateScene            // target is a HomeScene id
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

    public init(intents: [DeviceIntent], reply: String, source: Source) {
        self.intents = intents
        self.reply = reply
        self.source = source
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
        case .light, .climate, .heater, .fan, .plug, .vacuum: return true
        case .speaker, .tv, .fridge, .sensor: return false
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

    /// Returns the operation adjusted to the device's limits, or nil when the device cannot perform it.
    public static func normalize(_ operation: IntentOperation, for device: SmartDevice) -> IntentOperation? {
        switch (operation, device.kind) {
        case (.power, .light), (.power, .climate), (.power, .fan), (.power, .plug), (.power, .vacuum):
            return operation

        case (.brightness(let percent), .light):
            return .brightness(min(100, max(1, percent)))

        case (.colorTemperature(let kelvin), .light(let s)):
            guard kelvin > 0 else { return nil }
            return .colorTemperature(min(s.maxKelvin, max(s.minKelvin, kelvin)))

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
            case .hvacMode(let m): return "\(joined)切换为\(SmartDevice.localizeHVACMode(m))"
            case .targetTemperature(let t): return "\(joined)设为 \(formatTemperature(t))°C"
            case .activateScene: return "执行场景「\(joined)」"
            }
        }
        return clauses.isEmpty ? "" : "已" + clauses.joined(separator: "，")
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
    private let realIdByAlias: [String: String]

    public init(devices: [SmartDevice], scenes: [HomeScene]) {
        var lines: [String] = []
        var map: [String: String] = [:]
        var index = 0
        for device in devices {
            let category = IntentDeviceCategory(device)
            guard category.isAssistantControllable else { continue }
            index += 1
            let alias = "d\(index)"
            map[alias] = device.id
            lines.append([alias, device.name, device.roomName, category.rawValue, Self.stateSummary(device)].joined(separator: "|"))
        }
        var sceneLines: [String] = []
        for (offset, scene) in scenes.enumerated() {
            let alias = "s\(offset + 1)"
            map[alias] = scene.id
            sceneLines.append("\(alias)|\(scene.name)")
        }
        self.lines = lines
        self.sceneLines = sceneLines
        self.realIdByAlias = map
    }

    public func realId(forAlias alias: String) -> String? {
        realIdByAlias[alias.trimmingCharacters(in: .whitespacesAndNewlines)]
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
            guard s.isOn else { return "关" }
            return s.brightnessPercent.map { "开 亮度\($0)%" } ?? "开"
        case .climate(let s):
            let modes = s.availableModes.joined(separator: "/")
            let range = "\(IntentReply.formatTemperature(s.minTemp))-\(IntentReply.formatTemperature(s.maxTemp))°C"
            let current = (s.isOn && s.hvacMode != "off")
                ? "\(s.hvacMode) \(IntentReply.formatTemperature(s.targetTemperature))°C"
                : "关"
            return "\(current) 可用模式:\(modes) 温度范围:\(range)"
        case .fan(let s): return s.isOn ? "开" : "关"
        case .plug(let s): return s.isOn ? "开" : "关"
        case .vacuum(let s): return s.isCleaning ? "清扫中" : "待机"
        case .speaker, .tv, .fridge, .sensor: return ""
        }
    }
}
