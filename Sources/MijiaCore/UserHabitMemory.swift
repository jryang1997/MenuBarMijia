import Foundation

// MARK: - Ambient Context & Personal Habit Memory for Jev System One

public struct AssistantContext: Equatable, Sendable {
    public var timeSummary: String
    public var environmentSummary: String
    public var activeDevicesSummary: String
    public var habitSummary: String

    public init(
        timeSummary: String = "",
        environmentSummary: String = "",
        activeDevicesSummary: String = "",
        habitSummary: String = ""
    ) {
        self.timeSummary = timeSummary
        self.environmentSummary = environmentSummary
        self.activeDevicesSummary = activeDevicesSummary
        self.habitSummary = habitSummary
    }
}

public struct AssistantSuggestion: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let confidencePercent: Int?
    public let intents: [DeviceIntent]

    public init(id: String, title: String, confidencePercent: Int? = nil, intents: [DeviceIntent]) {
        self.id = id
        self.title = title
        self.confidencePercent = confidencePercent
        self.intents = intents
    }
}

public struct UserHabitMemory: Codable, Equatable, Sendable {
    public enum TimeBucket: String, Codable, CaseIterable, Sendable {
        case morning = "清晨"      // 06:00 - 10:59
        case midday = "午间"       // 11:00 - 13:59
        case afternoon = "下午"    // 14:00 - 17:59
        case evening = "夜晚"      // 18:00 - 22:59
        case lateNight = "深夜"    // 23:00 - 05:59

        public static func from(date: Date, calendar: Calendar = .current) -> TimeBucket {
            let hour = calendar.component(.hour, from: date)
            switch hour {
            case 6..<11: return .morning
            case 11..<14: return .midday
            case 14..<18: return .afternoon
            case 18..<23: return .evening
            default: return .lateNight
            }
        }
    }

    public struct PhraseMemory: Codable, Equatable, Sendable {
        public var phrase: String
        public var bucket: TimeBucket
        public var summary: String
        public var count: Int
    }

    public struct HabitEntry: Codable, Equatable, Sendable {
        public var bucket: TimeBucket
        public var targetId: String
        public var operationKey: String
        public var count: Int
    }

    private static let storageKey = "assistant_user_habit_memory_v1"
    private static let maxEntries = 60
    private static let maxPhrases = 15

    public private(set) var entries: [HabitEntry] = []
    public private(set) var phrases: [PhraseMemory] = []

    public init(entries: [HabitEntry] = [], phrases: [PhraseMemory] = []) {
        self.entries = entries
        self.phrases = phrases
    }

    public static func load(from defaults: UserDefaults) -> UserHabitMemory {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(UserHabitMemory.self, from: data) else {
            return UserHabitMemory()
        }
        return decoded
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public mutating func record(
        utterance: String?,
        intents: [DeviceIntent],
        devices: [SmartDevice],
        scenes: [HomeScene],
        now: Date = Date()
    ) {
        guard !intents.isEmpty else { return }
        let bucket = TimeBucket.from(date: now)

        for intent in intents {
            guard let opKey = Self.encodeOperation(intent.operation) else { continue }
            if let idx = entries.firstIndex(where: {
                $0.bucket == bucket && $0.targetId == intent.targetId && $0.operationKey == opKey
            }) {
                entries[idx].count += 1
            } else {
                entries.append(HabitEntry(bucket: bucket, targetId: intent.targetId, operationKey: opKey, count: 1))
            }
        }

        entries.sort { $0.count > $1.count }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        if let raw = utterance?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let actionSummary = Self.describe(intents: intents, devices: devices, scenes: scenes)
            if !actionSummary.isEmpty {
                if let idx = phrases.firstIndex(where: { $0.phrase == raw }) {
                    phrases[idx].count += 1
                    phrases[idx].bucket = bucket
                    phrases[idx].summary = actionSummary
                } else {
                    phrases.insert(
                        PhraseMemory(phrase: raw, bucket: bucket, summary: actionSummary, count: 1),
                        at: 0
                    )
                }
                phrases.sort { $0.count > $1.count }
                if phrases.count > Self.maxPhrases {
                    phrases = Array(phrases.prefix(Self.maxPhrases))
                }
            }
        }
    }

    /// Returns personalized one-click habit suggestions for the current time bucket whose target isn't already in that state.
    public func topSuggestions(
        for now: Date = Date(),
        devices: [SmartDevice],
        scenes: [HomeScene],
        limit: Int = 3
    ) -> [AssistantSuggestion] {
        let bucket = TimeBucket.from(date: now)
        let bucketEntries = entries.filter { $0.bucket == bucket }
        let candidates = bucketEntries.isEmpty ? entries : bucketEntries

        var results: [AssistantSuggestion] = []
        var seenTargets: Set<String> = []

        for entry in candidates {
            guard !seenTargets.contains(entry.targetId),
                  let op = Self.decodeOperation(entry.operationKey) else { continue }
            let intent = DeviceIntent(targetId: entry.targetId, operation: op)
            guard Self.isActionable(intent, devices: devices, scenes: scenes),
                  let title = Self.suggestionTitle(for: intent, devices: devices, scenes: scenes) else {
                continue
            }
            seenTargets.insert(entry.targetId)
            results.append(
                AssistantSuggestion(
                    id: "habit:\(entry.bucket.rawValue):\(entry.targetId):\(entry.operationKey)",
                    title: title,
                    confidencePercent: nil,
                    intents: [intent]
                )
            )
            if results.count >= limit { break }
        }
        return results
    }

    /// Compact natural-language summary of the user's habits injected into Jev's `state.user_habits`.
    public func promptSummary(
        for now: Date = Date(),
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> String {
        let bucket = TimeBucket.from(date: now)
        var parts: [String] = []

        let topForBucket = entries
            .filter { $0.bucket == bucket }
            .prefix(4)
            .compactMap { entry -> String? in
                guard let op = Self.decodeOperation(entry.operationKey),
                      let label = Self.suggestionTitle(
                        for: DeviceIntent(targetId: entry.targetId, operation: op),
                        devices: devices,
                        scenes: scenes
                      ) else { return nil }
                return "\(label)(\(entry.count)次)"
            }
        if !topForBucket.isEmpty {
            parts.append("\(bucket.rawValue)常做：\(topForBucket.joined(separator: "、"))")
        }

        let topPhrases = phrases.prefix(4).map { "「\($0.phrase)」→\($0.summary)" }
        if !topPhrases.isEmpty {
            parts.append("个人口头禅：\(topPhrases.joined(separator: "；"))")
        }

        return parts.joined(separator: "。")
    }

    // MARK: - Encoding & Filtering Helpers

    static func encodeOperation(_ op: IntentOperation) -> String? {
        switch op {
        case .power(let on): return on ? "power:on" : "power:off"
        case .lightEffect(let effect): return "effect:\(effect)"
        case .brightness(let pct): return "brightness:\(pct)"
        case .colorTemperature(let k): return "ct:\(k)"
        case .hvacMode(let mode): return "hvac:\(mode)"
        case .targetTemperature(let t): return "temp:\(Int(t.rounded()))"
        case .activateScene: return "scene:activate"
        case .fanSpeed(let v): return "fan:\(v)"
        case .oscillation(let on): return on ? "swing:on" : "swing:off"
        case .brightnessStep, .temperatureStep: return nil
        }
    }

    static func decodeOperation(_ key: String) -> IntentOperation? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch (parts[0], parts[1]) {
        case ("power", "on"): return .power(true)
        case ("power", "off"): return .power(false)
        case ("effect", let effect): return .lightEffect(effect)
        case ("brightness", let v): return Int(v).map(IntentOperation.brightness)
        case ("ct", let v): return Int(v).map(IntentOperation.colorTemperature)
        case ("hvac", let mode): return .hvacMode(mode)
        case ("temp", let v): return Double(v).map(IntentOperation.targetTemperature)
        case ("scene", "activate"): return .activateScene
        case ("fan", let v): return .fanSpeed(v)
        case ("swing", "on"): return .oscillation(true)
        case ("swing", "off"): return .oscillation(false)
        default: return nil
        }
    }

    private static func isActionable(
        _ intent: DeviceIntent,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> Bool {
        if case .activateScene = intent.operation {
            return scenes.contains { $0.id == intent.targetId }
        }
        guard let dev = devices.first(where: { $0.id == intent.targetId && $0.isOnline }) else {
            return false
        }
        switch intent.operation {
        case .power(let on):
            return dev.isActiveOn != on
        case .lightEffect(let effect):
            guard case .light(let spec) = dev.kind else { return false }
            return !spec.isOn || spec.currentEffect?.caseInsensitiveCompare(effect) != .orderedSame
        case .brightness(let pct):
            guard case .light(let spec) = dev.kind else { return false }
            return !spec.isOn || abs((spec.brightnessPercent ?? 0) - pct) >= 10
        case .colorTemperature:
            return true
        case .hvacMode(let mode):
            guard case .climate(let spec) = dev.kind else { return false }
            return !spec.isOn || spec.hvacMode != mode
        case .targetTemperature(let temp):
            guard case .climate(let spec) = dev.kind else { return false }
            return !spec.isOn || abs(spec.targetTemperature - temp) >= 0.5
        case .activateScene:
            return true
        case .fanSpeed(let v):
            switch dev.kind {
            case .fan(let spec): return !spec.isOn || spec.presetMode != v
            case .climate(let spec): return spec.fanMode != v
            default: return false
            }
        case .oscillation(let on):
            guard case .fan(let spec) = dev.kind else { return false }
            return !spec.isOn || spec.isOscillating != on
        case .brightnessStep, .temperatureStep:
            return false
        }
    }

    public static func suggestionTitle(
        for intent: DeviceIntent,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> String? {
        if case .activateScene = intent.operation {
            guard let scene = scenes.first(where: { $0.id == intent.targetId }) else { return nil }
            return scene.name
        }
        guard let dev = devices.first(where: { $0.id == intent.targetId }) else { return nil }
        switch intent.operation {
        case .power(true): return "打开\(dev.name)"
        case .power(false): return "关闭\(dev.name)"
        case .lightEffect(let effect):
            let label = effect.lowercased() == "night" ? "月光模式" : (effect.lowercased() == "day" ? "日光模式" : effect)
            return "\(dev.name)·\(label)"
        case .brightness(let pct): return "\(dev.name)·亮度\(pct)%"
        case .colorTemperature(let k): return "\(dev.name)·色温\(k)K"
        case .hvacMode(let mode):
            let cn = ["cool": "制冷", "heat": "制热", "dry": "除湿", "fan_only": "送风", "auto": "自动", "off": "关闭"][mode] ?? mode
            return "\(dev.name)·\(cn)"
        case .targetTemperature(let t): return "\(dev.name)·\(Int(t.rounded()))°C"
        case .activateScene: return nil
        case .fanSpeed(let v): return "\(dev.name)·风速\(IntentReply.fanSpeedLabel(v))"
        case .oscillation(let on): return "\(dev.name)·\(on ? "摇头" : "停止摇头")"
        case .brightnessStep, .temperatureStep: return nil
        }
    }

    private static func describe(
        intents: [DeviceIntent],
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> String {
        intents.compactMap { suggestionTitle(for: $0, devices: devices, scenes: scenes) }
            .joined(separator: "+")
    }
}
