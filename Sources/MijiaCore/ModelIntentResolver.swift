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
        let request = try makeRequest(utterance: utterance, catalog: catalog)
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AssistantError.httpStatus(http.statusCode)
        }
        let content = try Self.messageContent(from: data)
        return try Self.plan(fromModelContent: content, catalog: catalog, devices: devices, scenes: scenes)
    }

    // MARK: - Request

    func makeRequest(utterance: String, catalog: IntentCatalog) throws -> URLRequest {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
            throw AssistantError.invalidBaseURL(config.baseURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func systemPrompt(catalog: IntentCatalog) -> String {
        """
        你是智能家居指令解析器。把用户的中文指令转换为 JSON，只输出 JSON，不要解释。
        \(catalog.text)
        schema: {"actions":[{"device":"id","op":"power|brightness|color_temp|hvac_mode|temperature|scene","value":...}],"reply":"一句话中文回执"}
        规则：power 的 value 为 true/false；brightness 为 1-100（调暗用 20，调亮用 100）；color_temp 为开尔文；\
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

    private static func operation(named name: String, value: Any?) -> IntentOperation? {
        switch name.lowercased() {
        case "power":
            return bool(from: value).map(IntentOperation.power)
        case "brightness":
            return number(from: value).map { .brightness(Int($0.rounded())) }
        case "color_temp", "color_temperature":
            return number(from: value).map { .colorTemperature(Int($0.rounded())) }
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
