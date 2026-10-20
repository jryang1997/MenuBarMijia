import Foundation

struct HAHomeSnapshot {
    enum ReadError: LocalizedError {
        case rejected
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .rejected: "HA 未允许读取设备或注册表，请检查访问令牌的账号权限"
            case .invalidResponse: "HA 返回的设备或注册表数据格式无效，请检查 HA 版本和连接地址"
            }
        }
    }

    private var areas: [HAAreaEntry] = []
    private var devices: [HADeviceEntry] = []
    private var entities: [HAEntityEntry] = []
    private var states: [String: HAEntityState] = [:]
    private var pendingInitialResults: Set<Int> = [1, 2, 3, 4]

    mutating func receive(_ message: [String: JSONValue]) throws -> SynthesizedHome? {
        if message["type"]?.stringValue == "result", let id = message["id"]?.intValue {
            guard (1...4).contains(id) || (1000...9999).contains(id) else { return nil }
            guard message["success"]?.boolValue == true else { throw ReadError.rejected }
            guard let result = message["result"] else { throw ReadError.invalidResponse }
            switch id {
            case 1:
                areas = try decode([HAAreaEntry].self, from: result)
            case 2:
                devices = try decode([HADeviceEntry].self, from: result)
            case 3:
                entities = try decode([HAEntityEntry].self, from: result)
            case 4, 1000...9999:
                guard case .array(let entries) = result else { throw ReadError.invalidResponse }
                var nextStates: [String: HAEntityState] = [:]
                for value in entries {
                    guard let state = Self.parseState(value) else { throw ReadError.invalidResponse }
                    nextStates[state.entityId] = state
                }
                states = nextStates
            default:
                return nil
            }
            pendingInitialResults.remove(id)
        } else if message["type"]?.stringValue == "event",
                  case .object(let event) = message["event"],
                  event["event_type"]?.stringValue == "state_changed",
                  case .object(let data) = event["data"],
                  let newState = data["new_state"],
                  let state = Self.parseState(newState) {
            states[state.entityId] = state
        } else {
            return nil
        }
        guard pendingInitialResults.isEmpty else { return nil }
        return DeviceSynthesizer.synthesize(areas: areas, devices: devices, entities: entities, states: states)
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ReadError.invalidResponse
        }
    }

    private static func parseState(_ value: JSONValue) -> HAEntityState? {
        guard case .object(let object) = value,
              let entityId = object["entity_id"]?.stringValue,
              let state = object["state"]?.stringValue else { return nil }
        let attributes: [String: JSONValue]
        if case .object(let values) = object["attributes"] {
            attributes = values
        } else {
            attributes = [:]
        }
        return HAEntityState(entityId: entityId, state: state, attributes: attributes)
    }
}
