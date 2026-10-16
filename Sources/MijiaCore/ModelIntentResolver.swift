import Foundation

public enum AssistantError: LocalizedError, Equatable, Sendable {
    case invalidBaseURL(String)
    case httpStatus(Int)
    case emptyResponse
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url): return "AI 服务地址无效：\(url)"
        case .httpStatus(let code): return "AI 服务返回错误 (\(code))"
        case .emptyResponse: return "AI 没有返回内容"
        case .malformedResponse: return "AI 返回的内容无法解析"
        }
    }
}

/// LLM fallback for utterances the LocalIntentParser cannot resolve, via an OpenAI-compatible
/// `/chat/completions` endpoint.
public struct ModelIntentResolver: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let config: AssistantConfig
    private let transport: Transport

    private static let session: URLSession = {
        // Bypass system proxies: the default endpoint is a localhost router.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 10
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    public init(config: AssistantConfig, transport: Transport? = nil) {
        self.config = config
        self.transport = transport ?? { request in try await Self.session.data(for: request) }
    }

    public func resolve(
        _ utterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        context: AssistantContext = AssistantContext()
    ) async throws -> IntentPlan {
        let catalog = IntentCatalog(devices: devices, scenes: scenes)
        if Self.isSystemOneModel(config.model) {
            let request = try makeSystemOneRequest(
                utterance: utterance,
                catalog: catalog,
                devices: devices,
                context: context
            )
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AssistantError.httpStatus(http.statusCode)
            }
            return try Self.planFromSystemOne(data: data, catalog: catalog, devices: devices, scenes: scenes)
        }
        let request = try makeRequest(utterance: utterance, catalog: catalog, context: context)
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AssistantError.httpStatus(http.statusCode)
        }
        let content = try Self.messageContent(from: data)
        return try Self.plan(fromModelContent: content, catalog: catalog, devices: devices, scenes: scenes)
    }

    /// Proactive zero-input inference using Jev System One: evaluates current time, indoor sensor readings,
    /// active devices, and personal habit memory to recommend top actions with calibrated probabilities.
    public func recommendProactiveSuggestions(
        devices: [SmartDevice],
        scenes: [HomeScene],
        context: AssistantContext
    ) async throws -> [AssistantSuggestion] {
        let catalog = IntentCatalog(devices: devices, scenes: scenes)
        let request = try makeProactiveSystemOneRequest(catalog: catalog, devices: devices, context: context)
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AssistantError.httpStatus(http.statusCode)
        }
        return try Self.proactiveSuggestionsFromSystemOne(data: data, catalog: catalog, devices: devices, scenes: scenes)
    }

    /// System One protocol (`/v1/systemone`) backs TypeSafe Jev (`~typesafe/jev-latest`),
    /// Cloudflare Clef (`@cf/cloudflare/clef-flash`), and Bailian decision (`qwen-decision`).
    public static func isSystemOneModel(_ model: String) -> Bool {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("jev-router") { return false }
        return lower.contains("jev") || lower.contains("clef") || lower.contains("decision")
    }

    // MARK: - Request

    func makeRequest(
        utterance: String,
        catalog: IntentCatalog,
        context: AssistantContext = AssistantContext()
    ) throws -> URLRequest {
        let url = try endpointURL(path: "/chat/completions")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveAPIKey()
        // Local routers accept any bearer value but some reject a missing header.
        request.setValue("Bearer \(key.isEmpty ? "local" : key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(catalog: catalog, context: context)],
                ["role": "user", "content": utterance]
            ],
            "temperature": 0,
            "max_tokens": 800,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeSystemOneRequest(
        utterance: String,
        catalog: IntentCatalog,
        devices: [SmartDevice] = [],
        context: AssistantContext = AssistantContext()
    ) throws -> URLRequest {
        let url = try endpointURL(path: "/systemone")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveAPIKey()
        request.setValue("Bearer \(key.isEmpty ? "local" : key)", forHTTPHeaderField: "Authorization")

        let resolvedModel = resolvedSystemOneModel(for: url)

        var targetCriteria = catalog.criteriaByAlias
        targetCriteria["none"] = "无匹配设备或场景"
        let opCriteria: [String: String] = [
            "power_on": "打开设备电源",
            "power_off": "关闭设备电源",
            "effect_night": "切换月光/夜灯模式 (Night)",
            "effect_day": "切换日光模式 (Day)",
            "bri_20": "调暗灯光 (亮度 20%)",
            "bri_50": "中等亮度 (亮度 50%)",
            "bri_100": "调亮/最亮灯光 (亮度 100%)",
            "ct_2700": "暖光/黄光 (色温 2700K)",
            "ct_4000": "自然光 (色温 4000K)",
            "ct_6500": "白光/冷光 (色温 6500K)",
            "hvac_cool": "空调制冷模式",
            "hvac_heat": "空调制热模式",
            "hvac_dry": "空调除湿模式",
            "hvac_fan": "空调送风模式",
            "hvac_auto": "空调自动模式",
            "temp": "仅调节空调温度",
            "scene": "执行智能场景"
        ]
        let tempCriteria: [String: String] = [
            "none": "不指定具体温度",
            "18": "18°C", "19": "19°C", "20": "20°C", "21": "21°C", "22": "22°C",
            "23": "23°C", "24": "24°C", "25": "25°C", "26": "26°C", "27": "27°C", "28": "28°C"
        ]

        var questions: [String: Any] = [
            "target": [
                "type": "choice",
                "instructions": "Select the primary target device, room light group, or scene id for the command",
                "criteria": targetCriteria
            ],
            "op": [
                "type": "choice",
                "instructions": "Select the primary operation to perform on the target",
                "criteria": opCriteria
            ],
            "temp": [
                "type": "choice",
                "instructions": "If the command sets an air-conditioner temperature, select the degree in Celsius; otherwise none",
                "criteria": tempCriteria
            ]
        ]

        // Add per-device parallel decision heads (up to 10 controllable devices) so Jev can simultaneously
        // orchestrate multiple devices for ambient commands ("准备写代码，有点热") and surface secondary probabilities.
        for (alias, device) in Self.controllableDevicesWithAliases(devices: devices).prefix(10) {
            questions["dev_\(alias)"] = [
                "type": "choice",
                "instructions": "What action should be taken on \(device.name) (room: \(device.roomName)) for this command? Choose none if unrelated.",
                "criteria": Self.deviceSpecificCriteria(for: device)
            ]
        }

        var stateDict: [String: Any] = [
            "catalog": catalog.text,
            "command": utterance
        ]
        if !context.timeSummary.isEmpty { stateDict["time"] = context.timeSummary }
        if !context.environmentSummary.isEmpty { stateDict["environment"] = context.environmentSummary }
        if !context.activeDevicesSummary.isEmpty { stateDict["active_devices"] = context.activeDevicesSummary }
        if !context.habitSummary.isEmpty { stateDict["user_habits"] = context.habitSummary }

        let body: [String: Any] = [
            "model": resolvedModel,
            "state": stateDict,
            "questions": questions
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeProactiveSystemOneRequest(
        catalog: IntentCatalog,
        devices: [SmartDevice],
        context: AssistantContext
    ) throws -> URLRequest {
        let url = try endpointURL(path: "/systemone")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveAPIKey()
        request.setValue("Bearer \(key.isEmpty ? "local" : key)", forHTTPHeaderField: "Authorization")

        let resolvedModel = resolvedSystemOneModel(for: url)
        var questions: [String: Any] = [:]
        for (alias, device) in Self.controllableDevicesWithAliases(devices: devices).prefix(10) {
            questions["dev_\(alias)"] = [
                "type": "choice",
                "instructions": "Given the current time, indoor temperature/humidity, active devices, and user habits, what proactive adjustment would the user most likely want right now for \(device.name) (\(device.roomName))? Select none if current state is already ideal.",
                "criteria": Self.deviceSpecificCriteria(for: device)
            ]
        }

        let stateDict: [String: Any] = [
            "catalog": catalog.text,
            "time": context.timeSummary,
            "environment": context.environmentSummary,
            "active_devices": context.activeDevicesSummary,
            "user_habits": context.habitSummary
        ]

        let body: [String: Any] = [
            "model": resolvedModel,
            "state": stateDict,
            "questions": questions
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func resolvedSystemOneModel(for url: URL) -> String {
        let trimmedModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.host()?.contains("openrouter.ai") == true,
           trimmedModel.lowercased().contains("jev"),
           !trimmedModel.hasPrefix("~") {
            return "~typesafe/jev-latest"
        }
        return trimmedModel
    }

    private func effectiveAPIKey() -> String {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return key }
        return AssistantConfig.loadCodexBarOpenRouterKey() ?? ""
    }

    private func endpointURL(path: String) throws -> URL {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.scheme?.hasPrefix("http") == true else {
            throw AssistantError.invalidBaseURL(config.baseURL)
        }
        return url
    }

    static func systemPrompt(catalog: IntentCatalog, context: AssistantContext = AssistantContext()) -> String {
        var contextBlock = ""
        if !context.environmentSummary.isEmpty || !context.habitSummary.isEmpty {
            contextBlock = "\n当前环境与习惯：\(context.timeSummary) \(context.environmentSummary) \(context.habitSummary)\n"
        }
        return """
        你是智能家居指令解析器。把用户的中文指令转换为 JSON，只输出 JSON，不要解释。\(contextBlock)
        \(catalog.text)
        schema: {"actions":[{"device":"id","op":"power|brightness|color_temp|effect|hvac_mode|temperature|scene","value":...}],"reply":"一句话中文回执"}
        规则：power 的 value 为 true/false；brightness 为 1-100（调暗用 20，调亮用 100）；color_temp 为开尔文；\
        effect 取 Day（日光模式）或 Night（月光/夜灯模式），且必须是该灯具的可用模式；\
        hvac_mode 取 cool/heat/dry/fan_only/auto/off 且必须是该设备的可用模式；temperature 为摄氏度数字；\
        scene 的 device 填场景 id，value 填 null。只能使用上面列出的 id。\
        无法执行时 actions 为空数组，并在 reply 中简短说明原因。
        """
    }

    // MARK: - Response Boundary

    static func messageContent(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AssistantError.malformedResponse
        }
        let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { throw AssistantError.emptyResponse }
        return content
    }

    /// Parses model output into typed intents, dropping unknown targets and invalid operations.
    static func plan(
        fromModelContent content: String,
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) throws -> IntentPlan {
        guard let jsonText = firstJSONObject(in: content),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.malformedResponse
        }
        let actions = object["actions"] as? [[String: Any]] ?? []
        let raw: [DeviceIntent] = actions.compactMap { action in
            guard let alias = action["device"] as? String,
                  let targetId = catalog.realId(forAlias: alias),
                  let opName = action["op"] as? String,
                  let op = operation(named: opName, value: action["value"]) else { return nil }
            return DeviceIntent(targetId: targetId, operation: op)
        }
        let intents = IntentValidator.sanitize(raw, devices: devices, scenes: scenes)
        let modelReply = (object["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reply = modelReply.isEmpty ? IntentReply.describe(intents, devices: devices, scenes: scenes) : modelReply
        return IntentPlan(intents: intents, reply: reply, source: .model)
    }

    static func planFromSystemOne(
        data: Data,
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) throws -> IntentPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else {
            throw AssistantError.malformedResponse
        }
        let targetChoice = (answers["target"] as? [String: Any])?["choice"] as? String ?? "none"
        let opChoice = (answers["op"] as? [String: Any])?["choice"] as? String ?? ""
        let tempChoice = (answers["temp"] as? [String: Any])?["choice"] as? String ?? "none"

        var raw: [DeviceIntent] = []

        // 1. Primary target + op + temp head (supports single device, room light groups,all_lights, and scenes)
        let targetIds = catalog.realIds(forTargetChoice: targetChoice)
        if targetChoice != "none", !targetIds.isEmpty {
            var ops: [IntentOperation] = []
            if let primaryOp = systemOneOperation(for: opChoice) {
                ops.append(primaryOp)
            }
            if tempChoice != "none", let degree = Double(tempChoice) {
                ops.append(.targetTemperature(degree))
            }
            for id in targetIds {
                for op in ops {
                    raw.append(DeviceIntent(targetId: id, operation: op))
                }
            }
        }

        // 2. Per-device parallel decision heads (dev_d1, dev_d2, ...) for multi-device ambient orchestration
        //    and probability-ranked follow-up suggestions.
        var candidateSuggestions: [(prob: Double, suggestion: AssistantSuggestion)] = []
        let aliasDevices = controllableDevicesWithAliases(devices: devices)

        let hasPrimaryTarget = targetChoice != "none" && !targetIds.isEmpty

        for (alias, device) in aliasDevices {
            guard let answer = answers["dev_\(alias)"] as? [String: Any] else { continue }
            let choice = answer["choice"] as? String ?? "none"
            let probs = answer["probabilities"] as? [String: Any] ?? [:]
            let choiceProb = number(from: probs[choice]) ?? (number(from: answer["confidence"]) ?? 0.6)

            // Auto-execute when:
            // - no primary single target was chosen and this device head chose an action, OR
            // - this device is part of the primary target group, OR
            // - this device head has very high probability (>= 0.80) for a distinct action (e.g., AC cooling while turning on study light)
            //   and isn't a fallback power_on when the primary op was a specific light effect.
            let isFallbackPowerOnForEffect = (opChoice.hasPrefix("effect_") && choice == "power_on" && !targetIds.contains(device.id))
            let shouldAutoExecute = choice != "none"
                && !isFallbackPowerOnForEffect
                && (!hasPrimaryTarget || targetIds.contains(device.id) || choiceProb >= 0.80)

            if shouldAutoExecute {
                let deviceOps = systemOneDeviceOperations(for: choice)
                for op in deviceOps {
                    raw.append(DeviceIntent(targetId: device.id, operation: op))
                }
            } else {
                let candidate: (String, Double)?
                if choice != "none" {
                    candidate = (choice, choiceProb)
                } else {
                    candidate = bestNonNoneProbability(in: probs)
                }
                if let (runnerUpChoice, runnerUpProb) = candidate, runnerUpProb >= 0.20 {
                    let ops = IntentValidator.sanitize(
                        systemOneDeviceOperations(for: runnerUpChoice).map { DeviceIntent(targetId: device.id, operation: $0) },
                        devices: devices,
                        scenes: scenes
                    )
                    if let first = ops.first,
                       let title = UserHabitMemory.suggestionTitle(for: first, devices: devices, scenes: scenes) {
                        let pct = max(20, min(99, Int((runnerUpProb * 100).rounded())))
                        candidateSuggestions.append((
                            runnerUpProb,
                            AssistantSuggestion(
                                id: "jev:\(device.id):\(runnerUpChoice)",
                                title: title,
                                confidencePercent: pct,
                                intents: ops
                            )
                        ))
                    }
                }
            }
        }

        let intents = IntentValidator.sanitize(raw, devices: devices, scenes: scenes)
        let executedTargetIds = Set(intents.map(\.targetId))
        let filteredSuggestions = candidateSuggestions
            .filter { item in !item.suggestion.intents.allSatisfy { executedTargetIds.contains($0.targetId) } }
            .sorted { $0.prob > $1.prob }
            .prefix(3)
            .map(\.suggestion)

        let reply = IntentReply.describe(intents, devices: devices, scenes: scenes)
        return IntentPlan(
            intents: intents,
            reply: reply,
            source: .model,
            suggestions: Array(filteredSuggestions)
        )
    }

    static func proactiveSuggestionsFromSystemOne(
        data: Data,
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) throws -> [AssistantSuggestion] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else {
            throw AssistantError.malformedResponse
        }

        var scored: [(prob: Double, suggestion: AssistantSuggestion)] = []
        for (alias, device) in controllableDevicesWithAliases(devices: devices) {
            guard let answer = answers["dev_\(alias)"] as? [String: Any] else { continue }
            let probs = answer["probabilities"] as? [String: Any] ?? [:]
            let topChoice = answer["choice"] as? String ?? "none"

            let chosenKey: String
            let chosenProb: Double
            if topChoice != "none" {
                chosenKey = topChoice
                chosenProb = number(from: probs[topChoice]) ?? (number(from: answer["confidence"]) ?? 0.65)
            } else if let (runnerUp, prob) = bestNonNoneProbability(in: probs), prob >= 0.18 {
                chosenKey = runnerUp
                chosenProb = prob
            } else {
                continue
            }

            let ops = IntentValidator.sanitize(
                systemOneDeviceOperations(for: chosenKey).map { DeviceIntent(targetId: device.id, operation: $0) },
                devices: devices,
                scenes: scenes
            )
            guard let primary = ops.first,
                  let title = UserHabitMemory.suggestionTitle(for: primary, devices: devices, scenes: scenes) else {
                continue
            }
            let pct = max(18, min(99, Int((chosenProb * 100).rounded())))
            scored.append((
                chosenProb,
                AssistantSuggestion(
                    id: "proactive:\(device.id):\(chosenKey)",
                    title: title,
                    confidencePercent: pct,
                    intents: ops
                )
            ))
        }

        return scored
            .sorted { $0.prob > $1.prob }
            .prefix(3)
            .map(\.suggestion)
    }

    private static func controllableDevicesWithAliases(devices: [SmartDevice]) -> [(alias: String, device: SmartDevice)] {
        var result: [(String, SmartDevice)] = []
        var idx = 0
        for device in devices {
            let category = IntentDeviceCategory(device)
            guard category.isAssistantControllable else { continue }
            idx += 1
            result.append(("d\(idx)", device))
        }
        return result
    }

    private static func deviceSpecificCriteria(for device: SmartDevice) -> [String: String] {
        var criteria: [String: String] = [
            "none": "保持不变，不操作\(device.name)",
            "power_on": "打开\(device.name)",
            "power_off": "关闭\(device.name)"
        ]
        switch device.kind {
        case .light(let spec):
            if spec.availableEffects.contains(where: { $0.caseInsensitiveCompare("Day") == .orderedSame }) {
                criteria["effect_day"] = "切换为日光模式（专注照明）"
            }
            if spec.availableEffects.contains(where: { $0.caseInsensitiveCompare("Night") == .orderedSame }) {
                criteria["effect_night"] = "切换为月光/夜灯模式（柔和助眠）"
            }
            criteria["bri_20"] = "调暗灯光 (20%)"
            criteria["bri_100"] = "调亮灯光 (100%)"
        case .climate(let spec):
            if spec.availableModes.contains("cool") {
                criteria["cool_24"] = "开启制冷 24°C（快速降温）"
                criteria["cool_25"] = "开启制冷 25°C"
                criteria["cool_26"] = "开启制冷 26°C（舒适恒温）"
            }
            if spec.availableModes.contains("heat") {
                criteria["heat_22"] = "开启制热 22°C"
                criteria["heat_24"] = "开启制热 24°C"
            }
            if spec.availableModes.contains("dry") {
                criteria["hvac_dry"] = "开启除湿模式"
            }
        default:
            break
        }
        return criteria
    }

    private static func systemOneDeviceOperations(for choice: String) -> [IntentOperation] {
        switch choice {
        case "cool_24": return [.hvacMode("cool"), .targetTemperature(24)]
        case "cool_25": return [.hvacMode("cool"), .targetTemperature(25)]
        case "cool_26": return [.hvacMode("cool"), .targetTemperature(26)]
        case "heat_22": return [.hvacMode("heat"), .targetTemperature(22)]
        case "heat_24": return [.hvacMode("heat"), .targetTemperature(24)]
        default:
            if let op = systemOneOperation(for: choice) {
                return [op]
            }
            return []
        }
    }

    private static func bestNonNoneProbability(in probabilities: [String: Any]) -> (String, Double)? {
        var bestKey: String?
        var bestProb: Double = 0
        for (key, rawVal) in probabilities where key != "none" {
            if let p = number(from: rawVal), p > bestProb {
                bestProb = p
                bestKey = key
            }
        }
        guard let key = bestKey else { return nil }
        return (key, bestProb)
    }

    private static func systemOneOperation(for choice: String) -> IntentOperation? {
        switch choice {
        case "power_on": return .power(true)
        case "power_off": return .power(false)
        case "effect_night": return .lightEffect("Night")
        case "effect_day": return .lightEffect("Day")
        case "bri_20": return .brightness(20)
        case "bri_50": return .brightness(50)
        case "bri_100": return .brightness(100)
        case "ct_2700": return .colorTemperature(2700)
        case "ct_4000": return .colorTemperature(4000)
        case "ct_6500": return .colorTemperature(6500)
        case "hvac_cool": return .hvacMode("cool")
        case "hvac_heat": return .hvacMode("heat")
        case "hvac_dry": return .hvacMode("dry")
        case "hvac_fan": return .hvacMode("fan_only")
        case "hvac_auto": return .hvacMode("auto")
        case "scene": return .activateScene
        default: return nil
        }
    }

    private static func operation(named name: String, value: Any?) -> IntentOperation? {
        switch name.lowercased() {
        case "power":
            return bool(from: value).map(IntentOperation.power)
        case "brightness":
            return number(from: value).map { .brightness(Int($0.rounded())) }
        case "color_temp", "color_temperature":
            return number(from: value).map { .colorTemperature(Int($0.rounded())) }
        case "effect", "light_effect":
            return (value as? String).map(IntentOperation.lightEffect)
        case "hvac_mode", "mode":
            return (value as? String).map(IntentOperation.hvacMode)
        case "temperature", "target_temperature":
            return number(from: value).map(IntentOperation.targetTemperature)
        case "scene":
            return .activateScene
        default:
            return nil
        }
    }

    private static func bool(from value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let s as String:
            switch s.lowercased() {
            case "true", "on", "1", "开": return true
            case "false", "off", "0", "关": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: CharacterSet(charactersIn: " %°CcKk")))
        default: return nil
        }
    }

    /// Extracts the first balanced `{...}` object, tolerating ```json fences and surrounding prose.
    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
