import Foundation

/// Deterministic, zero-network parser for short Chinese home commands.
/// Every recognized phrase is consumed from the utterance; any leftover text means the
/// command has parts this parser does not understand, so it returns nil and the model takes over.
public enum LocalIntentParser {
    private static let consumed: Character = "\u{1F}"

    private static let powerVerbs: [String: Bool] = [
        "打开": true, "开启": true, "开": true,
        "关闭": false, "关掉": false, "关上": false, "熄灭": false, "熄掉": false, "关": false
    ]

    private static let brightnessWords: [String: Int] = [
        "调暗": 20, "变暗": 20, "最暗": 10,
        "调亮": 100, "变亮": 100, "最亮": 100
    ]

    private static let colorTemperatureWords: [String: Int] = [
        "暖光": 2700, "暖色": 2700, "黄光": 2700,
        "自然光": 4000,
        "白光": 6500, "冷光": 6500
    ]

    private static let lightEffectWords: [String: String] = [
        "月光模式": "Night", "月光灯": "Night", "月光": "Night",
        "夜灯模式": "Night", "夜灯": "Night",
        "日光模式": "Day", "日光灯": "Day", "日光": "Day"
    ]

    private static let hvacModeWords: [String: String] = [
        "制冷": "cool", "制热": "heat", "除湿": "dry", "送风": "fan_only", "自动": "auto"
    ]

    private static let scopeWords: Set<String> = ["全部", "所有", "全屋", "全家", "家里", "整个家"]

    private static let categoryWords: [String: IntentDeviceCategory] = [
        "灯": .light, "灯光": .light, "电灯": .light,
        "空调": .climate,
        "暖气": .heater, "电暖器": .heater, "电暖气": .heater, "取暖器": .heater, "暖风机": .heater,
        "风扇": .fan, "电风扇": .fan, "电扇": .fan,
        "插座": .plug,
        "扫地机": .vacuum, "扫地机器人": .vacuum
    ]

    /// Generic room words users say, mapped to room names they may correspond to in HA.
    private static let roomAliases: [String: [String]] = [
        "卧室": ["卧室", "主卧"], "主卧": ["主卧", "卧室"],
        "次卧": ["次卧", "小卧室"], "小卧室": ["小卧室", "次卧"],
        "客厅": ["客厅"], "书房": ["书房"], "厨房": ["厨房"], "阳台": ["阳台"], "餐厅": ["餐厅"],
        "卫生间": ["卫生间", "浴室"], "浴室": ["浴室", "卫生间"]
    ]

    private static let fillers: Set<String> = [
        "请", "帮我", "帮忙", "麻烦", "给我", "把", "将", "给", "一下", "一点", "一些",
        "吧", "了", "的", "呢", "啊", "呀", "都", "里", "模式",
        "调到", "调成", "调为", "调至", "设为", "设成", "设置为", "设置成", "设置", "调节", "调", "到", "为",
        "切换为", "切换到", "切到", "切为", "切成", "切换", "切", "改成", "改为"
    ]

    private static let sceneVerbs: Set<String> = ["执行", "启动", "打开", "开启", "激活", "切换到", "切换", "进入", "运行"]
    private static let sceneSuffixes = ["场景", "模式"]

    private static let ignorable = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "，。！？、；：,!?;:~～\"'“”‘’"))

    // MARK: - Entry Point

    public static func parse(_ utterance: String, devices: [SmartDevice], scenes: [HomeScene]) -> IntentPlan? {
        let text = String(String.UnicodeScalarView(utterance.unicodeScalars.filter { !ignorable.contains($0) }))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !text.isEmpty else { return nil }

        let sceneCore = strippedSceneText(text)
        if let scene = scenes.first(where: { strippedSceneText($0.name) == sceneCore }) {
            return scenePlan(scene)
        }
        if let plan = parseDeviceCommand(text, devices: devices, scenes: scenes) {
            return plan
        }
        let containing = scenes.filter { sceneCore.count >= 2 && strippedSceneText($0.name).contains(sceneCore) }
        if containing.count == 1, let scene = containing.first {
            return scenePlan(scene)
        }
        return nil
    }

    private static func scenePlan(_ scene: HomeScene) -> IntentPlan {
        IntentPlan(
            intents: [DeviceIntent(targetId: scene.id, operation: .activateScene)],
            reply: "已执行场景「\(scene.name)」",
            source: .local
        )
    }

    private static func strippedSceneText(_ raw: String) -> String {
        var s = raw
        for verb in sceneVerbs.sorted(by: { $0.count > $1.count }) where s.hasPrefix(verb) {
            s.removeFirst(verb.count)
            break
        }
        for suffix in sceneSuffixes where s.hasSuffix(suffix) && s.count > suffix.count {
            s.removeLast(suffix.count)
        }
        return s
    }

    // MARK: - Device Commands

    private static func parseDeviceCommand(_ text: String, devices: [SmartDevice], scenes: [HomeScene]) -> IntentPlan? {
        var rest = text
        var ops: [IntentOperation] = extractNumericOperations(&rest)

        // 1. Device names (full name such as 书房台灯, or name without room prefix such as 台灯)
        var explicitIds: [String] = []
        var nameGroups: [[String]] = []
        for (phrase, match) in devicePhrases(devices) where consume(phrase, from: &rest) {
            switch match {
            case .full(let ids): explicitIds.append(contentsOf: ids.filter { !explicitIds.contains($0) })
            case .base(let ids): nameGroups.append(ids)
            }
        }

        // 2. Rooms, scope, and category words
        let roomWords = Set(devices.map(\.roomName)).union(roomAliases.keys).filter { !$0.isEmpty }
        let matchedRooms = longestFirst(roomWords).filter { consume($0, from: &rest) }
        let hasScope = !longestFirst(scopeWords).filter { consume($0, from: &rest) }.isEmpty
        let categories = Set(longestFirst(Set(categoryWords.keys)).filter { consume($0, from: &rest) }.compactMap { categoryWords[$0] })

        // 3. Operation words
        for word in longestFirst(Set(lightEffectWords.keys)) where consume(word, from: &rest) {
            ops.append(.lightEffect(lightEffectWords[word]!))
        }
        for word in longestFirst(Set(brightnessWords.keys)) where consume(word, from: &rest) {
            ops.append(.brightness(brightnessWords[word]!))
        }
        for word in longestFirst(Set(colorTemperatureWords.keys)) where consume(word, from: &rest) {
            ops.append(.colorTemperature(colorTemperatureWords[word]!))
        }
        for word in longestFirst(Set(hvacModeWords.keys)) where consume(word, from: &rest) {
            ops.append(.hvacMode(hvacModeWords[word]!))
        }
        for word in longestFirst(Set(powerVerbs.keys)) where consume(word, from: &rest) {
            ops.append(.power(powerVerbs[word]!))
        }

        // 4. Fillers, then anything left over means we don't understand the utterance
        for word in longestFirst(fillers) {
            _ = consume(word, from: &rest)
        }
        guard rest.allSatisfy({ $0 == consumed }) else { return nil }

        guard let ops = reconcile(ops) else { return nil }

        let roomDeviceIds = Set(matchedRooms.flatMap { deviceIds(inRoom: $0, devices: devices) })
        let isTurningOff = ops == [.power(false)]
        var targetIds: [String]
        var mustAcceptAll: Set<String> = Set(explicitIds)

        if !explicitIds.isEmpty || !nameGroups.isEmpty {
            targetIds = explicitIds
            for group in nameGroups {
                let narrowed = matchedRooms.isEmpty ? group : group.filter(roomDeviceIds.contains)
                guard !narrowed.isEmpty, narrowed.count == 1 || hasScope else { return nil }
                targetIds.append(contentsOf: narrowed.filter { !targetIds.contains($0) })
                if narrowed.count == 1 { mustAcceptAll.formUnion(narrowed) }
            }
        } else {
            let implied = impliedCategories(for: ops)
            let wanted = categories.isEmpty ? implied : categories
            if wanted == nil && !isTurningOff { return nil }
            guard hasScope || !matchedRooms.isEmpty || wanted != nil else { return nil }

            let candidates = devices.filter { dev in
                let category = IntentDeviceCategory(dev)
                guard dev.isOnline, category.isAssistantControllable else { return false }
                if !matchedRooms.isEmpty && !roomDeviceIds.contains(dev.id) { return false }
                if let wanted, !wanted.contains(category) { return false }
                return true
            }
            // A bare category ("打开空调") is only unambiguous when the home has exactly one such device.
            if !hasScope && matchedRooms.isEmpty && candidates.count != 1 { return nil }
            targetIds = candidates.map(\.id)
        }

        let deviceById = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var intents: [DeviceIntent] = []
        for id in targetIds {
            guard let device = deviceById[id] else { return nil }
            let normalized = ops.compactMap { IntentValidator.normalize($0, for: device) }
            guard normalized.count == ops.count else {
                if mustAcceptAll.contains(id) { return nil }
                continue
            }
            intents.append(contentsOf: normalized.map { DeviceIntent(targetId: id, operation: $0) })
        }
        guard !intents.isEmpty else { return nil }

        return IntentPlan(
            intents: intents,
            reply: IntentReply.describe(intents, devices: devices, scenes: scenes),
            source: .local
        )
    }

    // MARK: - Helpers

    private enum PhraseMatch {
        case full([String])
        case base([String])
    }

    private static func devicePhrases(_ devices: [SmartDevice]) -> [(String, PhraseMatch)] {
        var full: [String: [String]] = [:]
        var base: [String: [String]] = [:]
        for dev in devices where !dev.name.isEmpty {
            full[dev.name, default: []].append(dev.id)
            if !dev.roomName.isEmpty, dev.name.hasPrefix(dev.roomName) {
                let stripped = String(dev.name.dropFirst(dev.roomName.count))
                if stripped.count >= 2 { base[stripped, default: []].append(dev.id) }
            }
        }
        var phrases: [(String, PhraseMatch)] = full.map { ($0.key, .full($0.value)) }
        phrases += base.filter { full[$0.key] == nil }.map { ($0.key, .base($0.value)) }
        return phrases.sorted { $0.0.count > $1.0.count }
    }

    private static func deviceIds(inRoom word: String, devices: [SmartDevice]) -> [String] {
        let exact = devices.filter { $0.roomName == word }
        if !exact.isEmpty { return exact.map(\.id) }
        let aliases = roomAliases[word] ?? [word]
        return devices
            .filter { dev in aliases.contains { dev.roomName.contains($0) } }
            .map(\.id)
    }

    private static func impliedCategories(for ops: [IntentOperation]) -> Set<IntentDeviceCategory>? {
        for op in ops {
            switch op {
            case .brightness, .colorTemperature, .lightEffect: return [.light]
            case .hvacMode, .targetTemperature: return [.climate, .heater]
            case .power, .activateScene: continue
            }
        }
        return nil
    }

    /// Orders operations for dispatch and rejects contradictory combinations.
    private static func reconcile(_ ops: [IntentOperation]) -> [IntentOperation]? {
        guard !ops.isEmpty else { return nil }
        var byRank: [Int: IntentOperation] = [:]
        for op in ops {
            let rank = dispatchRank(op)
            if let existing = byRank[rank], existing != op { return nil }
            byRank[rank] = op
        }
        if byRank[0] == .power(false), byRank.count > 1 { return nil }
        // HVAC mode, light effect, brightness, and color temperature already switch the device on.
        if byRank[0] == .power(true), byRank.keys.contains(where: { $0 == 1 || $0 == 3 || $0 == 4 || $0 == 5 }) {
            byRank[0] = nil
        }
        return byRank.keys.sorted().compactMap { byRank[$0] }
    }

    private static func dispatchRank(_ op: IntentOperation) -> Int {
        switch op {
        case .power: return 0
        case .hvacMode: return 1
        case .targetTemperature: return 2
        case .lightEffect: return 3
        case .brightness: return 4
        case .colorTemperature: return 5
        case .activateScene: return 6
        }
    }

    private static func longestFirst(_ words: Set<String>) -> [String] {
        words.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    /// Replaces every occurrence with a marker (not the empty string) so fragments on either side
    /// can't join into a phrase that was never said.
    private static func consume(_ phrase: String, from text: inout String) -> Bool {
        guard !phrase.isEmpty, text.contains(phrase) else { return false }
        text = text.replacingOccurrences(of: phrase, with: String(consumed))
        return true
    }

    private static func extractNumericOperations(_ text: inout String) -> [IntentOperation] {
        let patterns: [(String, (Double) -> IntentOperation)] = [
            (#"(\d{4})[kK]"#, { .colorTemperature(Int($0)) }),
            (#"亮度(?:调到|调至|调为|设为|设置为|到|为)?(\d{1,3})(?:%|％)?"#, { .brightness(Int($0)) }),
            (#"(\d{1,3})(?:%|％)"#, { .brightness(Int($0)) }),
            (#"(\d{1,2}(?:\.\d)?)(?:度|℃|°C|°)"#, { .targetTemperature($0) })
        ]
        var ops: [IntentOperation] = []
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                if let value = Double(ns.substring(with: match.range(at: 1))) {
                    ops.append(make(value))
                }
            }
            if !matches.isEmpty {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: String(consumed)
                )
            }
        }
        return ops
    }
}
