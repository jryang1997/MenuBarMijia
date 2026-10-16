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

    public func resolve(_ utterance: String, devices: [SmartDevice], scenes: [HomeScene]) async throws -> IntentPlan {
        let catalog = IntentCatalog(devices: devices, scenes: scenes)
        if Self.isSystemOneModel(config.model) {
            let request = try makeSystemOneRequest(utterance: utterance, catalog: catalog)
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AssistantError.httpStatus(http.statusCode)
            }
            return try Self.planFromSystemOne(data: data, catalog: catalog, devices: devices, scenes: scenes)
        }
        let request = try makeRequest(utterance: utterance, catalog: catalog)
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AssistantError.httpStatus(http.statusCode)
        }
        let content = try Self.messageContent(from: data)
        return try Self.plan(fromModelContent: content, catalog: catalog, devices: devices, scenes: scenes)
    }

    /// System One protocol (`/v1/systemone`) backs TypeSafe Jev (`~typesafe/jev-latest`),
    /// Cloudflare Clef (`@cf/cloudflare/clef-flash`), and Bailian decision (`qwen-decision`).
    public static func isSystemOneModel(_ model: String) -> Bool {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("jev-router") { return false }
        return lower.contains("jev") || lower.contains("clef") || lower.contains("decision")
    }

    // MARK: - Request

    func makeRequest(utterance: String, catalog: IntentCatalog) throws -> URLRequest {
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
                ["role": "system", "content": Self.systemPrompt(catalog: catalog)],
                ["role": "user", "content": utterance]
            ],
            "temperature": 0,
            "max_tokens": 800,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeSystemOneRequest(utterance: String, catalog: IntentCatalog) throws -> URLRequest {
        let url = try endpointURL(path: "/systemone")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveAPIKey()
        request.setValue("Bearer \(key.isEmpty ? "local" : key)", forHTTPHeaderField: "Authorization")

        let resolvedModel: String
        let trimmedModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.host()?.contains("openrouter.ai") == true,
           trimmedModel.lowercased().contains("jev"),
           !trimmedModel.hasPrefix("~") {
            resolvedModel = "~typesafe/jev-latest"
        } else {
            resolvedModel = trimmedModel
        }

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
        let body: [String: Any] = [
            "model": resolvedModel,
            "state": [
                "catalog": catalog.text,
                "command": utterance
            ],
            "questions": [
                "target": [
                    "type": "choice",
                    "instructions": "Select the target device, room light group, or scene id for command",
                    "criteria": targetCriteria
                ],
                "op": [
                    "type": "choice",
                    "instructions": "Select the operation to perform on the target",
                    "criteria": opCriteria
                ],
                "temp": [
                    "type": "choice",
                    "instructions": "If the command sets an air-conditioner temperature, select the degree in Celsius; otherwise none",
                    "criteria": tempCriteria
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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

    static func systemPrompt(catalog: IntentCatalog) -> String {
        """
        你是智能家居指令解析器。把用户的中文指令转换为 JSON，只输出 JSON，不要解释。
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

        let targetIds = catalog.realIds(forTargetChoice: targetChoice)
        guard targetChoice != "none", !targetIds.isEmpty else {
            return IntentPlan(intents: [], reply: "未识别到可执行的设备指令", source: .model)
        }

        var ops: [IntentOperation] = []
        if let primaryOp = systemOneOperation(for: opChoice) {
            ops.append(primaryOp)
        }
        if tempChoice != "none", let degree = Double(tempChoice) {
            ops.append(.targetTemperature(degree))
        }
        guard !ops.isEmpty else {
            return IntentPlan(intents: [], reply: "未识别到可执行的设备指令", source: .model)
        }

        let raw = targetIds.flatMap { id in
            ops.map { DeviceIntent(targetId: id, operation: $0) }
        }
        let intents = IntentValidator.sanitize(raw, devices: devices, scenes: scenes)
        let reply = IntentReply.describe(intents, devices: devices, scenes: scenes)
        return IntentPlan(intents: intents, reply: reply, source: .model)
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
