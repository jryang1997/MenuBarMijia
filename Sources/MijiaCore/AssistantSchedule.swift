import Foundation

// MARK: - Spoken Delays ("10 分钟后关灯")

/// Pulls a spoken delay off the front ("10分钟后关灯", "过两分钟关灯") or back ("关灯，30秒后") of a command.
/// The remainder is parsed like any other command, so delays work for both the local parser and the model.
public enum DelayPhrase {
    /// Longest accepted delay; anything later belongs in the Mi Home app's own automations.
    public static let maxDelay: TimeInterval = 24 * 3600

    private static let number = #"([0-9]+|[零一二两三四五六七八九十]+|半)"#
    private static let unit = #"(个半|个)?(秒钟|秒|分钟|分|小时|钟头)(半)?"#
    private static let leading = try! NSRegularExpression(pattern: #"^(过|等)?"# + number + #"\s*"# + unit + #"(以后|之后|后)?"#)
    private static let trailing = try! NSRegularExpression(pattern: #"[，,\s]*"# + number + #"\s*"# + unit + #"(以后|之后|后)$"#)
    private static let enLeading = try! NSRegularExpression(
        pattern: #"^(?:in|after)\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b[,\s]*"#,
        options: [.caseInsensitive]
    )
    private static let enTrailing = try! NSRegularExpression(
        pattern: #"[,\s]+(?:in|after)\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\s*$"#,
        options: [.caseInsensitive]
    )

    private static let cancelPhrases = ["取消定时", "取消倒计时", "定时取消", "定时都取消", "取消所有定时", "取消全部定时", "不要定时"]
    private static let enCancelPhrases = [
        "cancel timer", "cancel timers", "cancel all timers",
        "clear timer", "clear timers", "clear all timers",
        "stop timer", "stop timers", "stop all timers"
    ]

    public static func extract(_ utterance: String) -> (delay: TimeInterval, remainder: String)? {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let m = leading.firstMatch(in: text, range: full) {
            let hasPrefix = m.range(at: 1).location != NSNotFound
            let hasSuffix = m.range(at: 6).location != NSNotFound
            if hasPrefix || hasSuffix, let seconds = seconds(ns, m, numberGroup: 2) {
                return finish(seconds, ns.replacingCharacters(in: m.range, with: ""))
            }
        }
        if let m = trailing.firstMatch(in: text, range: full), let seconds = seconds(ns, m, numberGroup: 1) {
            return finish(seconds, ns.replacingCharacters(in: m.range, with: ""))
        }
        if let m = enLeading.firstMatch(in: text, range: full), let secs = enSeconds(ns, m) {
            return finish(secs, ns.replacingCharacters(in: m.range, with: ""))
        }
        if let m = enTrailing.firstMatch(in: text, range: full), let secs = enSeconds(ns, m) {
            return finish(secs, ns.replacingCharacters(in: m.range, with: ""))
        }
        return nil
    }

    public static func isCancel(_ utterance: String) -> Bool {
        let lower = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if enCancelPhrases.contains(where: { lower.contains($0) }) { return true }
        let compact = utterance.filter { !$0.isWhitespace && !"，。！？,.!?了吧".contains($0) }
        return cancelPhrases.contains { compact.contains($0) }
    }

    /// 30 → "30 秒后"，600 → "10 分钟后"，5400 → "1 小时 30 分钟后"。
    public static func describe(_ delay: TimeInterval) -> String {
        let total = Int(delay.rounded())
        if total < 60 { return L10n.format("%@ 秒后", "In %@s: ", String(total)) }
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours == 0 { return L10n.format("%@ 分钟后", "In %@m: ", String(minutes)) }
        return minutes == 0
            ? L10n.format("%@ 小时后", "In %@h: ", String(hours))
            : L10n.format("%@ 小时 %@ 分钟后", "In %@h %@m: ", String(hours), String(minutes))
    }

    private static func enSeconds(_ ns: NSString, _ m: NSTextCheckingResult) -> TimeInterval? {
        guard m.range(at: 1).location != NSNotFound, m.range(at: 2).location != NSNotFound,
              let val = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        if unit.hasPrefix("s") { return val }
        if unit.hasPrefix("m") { return val * 60 }
        return val * 3600
    }

    private static func finish(_ seconds: TimeInterval, _ rest: String) -> (TimeInterval, String)? {
        let remainder = rest.trimmingCharacters(in: CharacterSet(charactersIn: "，,。 ").union(.whitespaces))
        guard !remainder.isEmpty, seconds > 0, seconds <= maxDelay else { return nil }
        return (seconds, remainder)
    }

    /// Groups after `numberGroup`: 个半/个, unit, trailing 半.
    private static func seconds(_ ns: NSString, _ m: NSTextCheckingResult, numberGroup g: Int) -> TimeInterval? {
        func group(_ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        guard let rawNumber = group(g), let unitWord = group(g + 2) else { return nil }
        let unitSeconds: TimeInterval
        switch unitWord {
        case "秒", "秒钟": unitSeconds = 1
        case "分", "分钟": unitSeconds = 60
        default: unitSeconds = 3600
        }
        guard var value = rawNumber == "半" ? 0.5 : spokenNumber(rawNumber).map(Double.init) else { return nil }
        if group(g + 1) == "个半" || group(g + 3) == "半" { value += 0.5 }
        return value * unitSeconds
    }

    /// Arabic digits or Chinese numerals up to 99 (十五, 二十, 四十五).
    static func spokenNumber(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let chars = Array(s)
        if let tenIndex = chars.firstIndex(of: "十") {
            guard tenIndex <= 1, chars.count - tenIndex <= 2 else { return nil }
            let tens = tenIndex == 0 ? 1 : digits[chars[0]]
            let ones = tenIndex == chars.count - 1 ? 0 : digits[chars[tenIndex + 1]]
            guard let tens, let ones else { return nil }
            return tens * 10 + ones
        }
        guard chars.count == 1 else { return nil }
        return digits[chars[0]]
    }
}

// MARK: - Scheduled Commands

/// A resolved plan waiting to run. The plan is resolved when spoken, so a later network failure
/// can't stop the timer and the user hears exactly what will happen.
public struct ScheduledCommand: Codable, Identifiable, Equatable, Sendable {
    public static let storageKey = "assistant_scheduled_commands_v1"

    public let id: UUID
    /// "10 分钟后关闭书房吸顶灯"
    public let reply: String
    public let fireDate: Date
    public let plan: IntentPlan

    public init(id: UUID = UUID(), reply: String, fireDate: Date, plan: IntentPlan) {
        self.id = id
        self.reply = reply
        self.fireDate = fireDate
        self.plan = plan
    }

    public static func load(from defaults: UserDefaults) -> [ScheduledCommand] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ScheduledCommand].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.fireDate < $1.fireDate }
    }

    public static func save(_ commands: [ScheduledCommand], to defaults: UserDefaults) {
        if commands.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Spoken Undo ("撤销", "刚才那个撤销")

public enum UndoPhrase {
    private static let keywords = ["撤销", "撤回", "还原", "恢复原样", "恢复原状", "恢复刚才", "取消刚才", "刚才不算"]
    private static let enKeywords: Set<String> = ["undo", "revert", "undo that", "revert that", "cancel that"]

    /// Short utterances only, so a long command that merely mentions "还原" still reaches the parser.
    public static func isUndo(_ utterance: String) -> Bool {
        let lower = utterance.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？,.!? ").union(.whitespacesAndNewlines))
        if enKeywords.contains(lower) { return true }
        let compact = utterance.filter { !$0.isWhitespace && !"，。！？,.!?".contains($0) }
        guard compact.count <= 10, !DelayPhrase.isCancel(compact) else { return false }
        return keywords.contains { compact.contains($0) }
    }
}
