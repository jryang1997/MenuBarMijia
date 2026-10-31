import Foundation

/// Decides which actions proposed by an AI model may run by themselves and which wait for a tap
/// as suggestion chips (#21). Kept separate from parsing so the rules are easy to test and to read.
public enum ModelActionPolicy {
    /// System One answers below this probability only become suggestions.
    public static let autoRunThreshold = 0.8
    /// Below this a runner-up inferred from a declined device ("none") is not even offered as a chip.
    /// An answer the model picked explicitly is always offered below the auto-run threshold (#21).
    public static let suggestionFloor = 0.2

    /// Probability of the chosen option: `probabilities[choice]`, else `confidence`, else 0 —
    /// a missing number means "not sure", never a default pass.
    public static func probability(of answer: [String: Any]?, choice: String) -> Double {
        guard let answer else { return 0 }
        if let probs = answer["probabilities"] as? [String: Any], let value = number(probs[choice]) {
            return value
        }
        return number(answer["confidence"]) ?? 0
    }

    /// Switching on a heater, switching any plug, or starting a vacuum needs a tap even when the model is sure:
    /// a wrong guess there can be unsafe or costly. Turning a heater off is always allowed.
    public static func needsConfirmation(_ intent: DeviceIntent, devices: [SmartDevice]) -> Bool {
        guard let device = devices.first(where: { $0.id == intent.targetId }) else { return false }
        switch IntentDeviceCategory(device) {
        case .heater:
            switch intent.operation {
            case .power(false): return false
            case .hvacMode(let mode): return mode != "off"
            default: return true
            }
        case .plug, .camera:
            if case .power = intent.operation { return true }
            return false
        case .vacuum:
            return intent.operation == .power(true)
        default:
            return false
        }
    }

    /// Splits model intents into those that run now and those that wait for confirmation.
    public static func partition(_ intents: [DeviceIntent], devices: [SmartDevice]) -> (run: [DeviceIntent], confirm: [DeviceIntent]) {
        var run: [DeviceIntent] = []
        var confirm: [DeviceIntent] = []
        for intent in intents {
            if needsConfirmation(intent, devices: devices) {
                confirm.append(intent)
            } else {
                run.append(intent)
            }
        }
        return (run, confirm)
    }

    /// Chips for intents that wait for a tap: one per device, or one for the whole group when
    /// `grouped` is set. `probability` nil (or ≤ 0, i.e. the model gave no number) hides the badge.
    public static func confirmationChips(
        for intents: [DeviceIntent],
        probability: Double?,
        idPrefix: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        grouped: Bool = false
    ) -> [AssistantSuggestion] {
        let percent = probability.flatMap { $0 > 0 ? max(20, min(99, Int(($0 * 100).rounded()))) : nil }
        func chip(id: String, title: String, group: [DeviceIntent]) -> AssistantSuggestion {
            AssistantSuggestion(id: id, title: title, confidencePercent: percent, intents: group)
        }
        if grouped {
            guard let first = intents.first,
                  let title = UserHabitMemory.suggestionTitle(for: first, devices: devices, scenes: scenes) else {
                return []
            }
            let targetCount = Set(intents.map(\.targetId)).count
            let fullTitle = targetCount > 1 ? title + L10n.tr(" 等 \(targetCount) 台", " +\(targetCount - 1)") : title
            return [chip(id: idPrefix, title: fullTitle, group: intents)]
        }
        var order: [String] = []
        var byTarget: [String: [DeviceIntent]] = [:]
        for intent in intents {
            if byTarget[intent.targetId] == nil { order.append(intent.targetId) }
            byTarget[intent.targetId, default: []].append(intent)
        }
        return order.compactMap { targetId in
            let group = byTarget[targetId] ?? []
            guard let first = group.first,
                  let title = UserHabitMemory.suggestionTitle(for: first, devices: devices, scenes: scenes) else {
                return nil
            }
            return chip(id: "\(idPrefix):\(targetId)", title: title, group: group)
        }
    }

    /// What the command bar says when some or all actions wait for a tap.
    public static func confirmationReply(ranReply: String?) -> String {
        guard let ranReply, !ranReply.isEmpty else {
            return L10n.tr("没把握直接执行，点下面的建议再执行", "Not sure enough to run this. Tap a suggestion below to run it")
        }
        return ranReply + L10n.tr("；下面的建议要点一下才执行", "; tap a suggestion below to run it")
    }

    /// Reads 0.85, "0.85", "85" and "85%" all as 0.85, clamped to 0...1.
    private static func number(_ raw: Any?) -> Double? {
        var value: Double?
        switch raw {
        case let number as NSNumber:
            value = number.doubleValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("%") {
                value = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)).map { $0 / 100 }
            } else {
                value = Double(trimmed)
            }
        default:
            value = nil
        }
        guard var result = value, result.isFinite else { return nil }
        if result > 1 { result /= 100 }
        return min(max(result, 0), 1)
    }
}
