import Foundation

public enum MiotWrite: Equatable, Sendable {
    case setProps([MiotPropWrite])
    case action(MiotActionCall)

    public var did: String {
        switch self {
        case .setProps(let writes): return writes.first?.did ?? ""
        case .action(let call): return call.did
        }
    }
}

public enum MiotCommandError: LocalizedError, Equatable, Sendable {
    case invalidAddress(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let id): return "无法识别的米家设备地址：\(id)"
        case .unsupported(let what): return "该设备暂不支持此操作：\(what)"
        }
    }
}

/// Pure translation of the backend-neutral `DeviceCommand` into MIoT prop/set or action calls,
/// resolved by property/action short names inside the addressed service.
public enum MiotCommandMapper {
    public static func map(_ command: DeviceCommand, spec: MiotDeviceSpec) throws -> MiotWrite {
        let entityId = command.targetEntityId
        guard let (did, siid) = MiotAddress.parse(entityId) else { throw MiotCommandError.invalidAddress(entityId) }
        guard let service = spec.service(iid: siid) else { throw MiotCommandError.unsupported("siid \(siid)") }
        let ctx = Context(did: did, spec: spec, service: service)

        switch command {
        case .setLightPower(_, let isOn), .setClimatePower(_, let isOn, _), .setFanPower(_, let isOn):
            return .setProps([try ctx.write("on", .bool(isOn))])

        case .setLightBrightness(_, let percent):
            if percent <= 0 { return .setProps([try ctx.write("on", .bool(false))]) }
            let bri = try ctx.require("brightness")
            let raw: Double
            if let max = bri.property.rangeMax, max > 0, max != 100 {
                raw = Double(percent) / 100 * max
            } else {
                raw = Double(percent)
            }
            // HA's light.turn_on(brightness) also powers the light on; MIoT needs an explicit `on`.
            return .setProps(ctx.powerOnPrefix() + [ctx.write(bri, .number(raw))])

        case .setLightColorTemp(_, let kelvin):
            return .setProps(ctx.powerOnPrefix() + [try ctx.write("color-temperature", .number(Double(kelvin)))])

        case .setLightEffect(_, let effect):
            return .setProps(ctx.powerOnPrefix() + [try ctx.writeListValue("mode", description: effect)])

        case .setClimateMode(_, let hvacMode):
            if hvacMode == "off" { return .setProps([try ctx.write("on", .bool(false))]) }
            var writes = [try ctx.write("on", .bool(true))]
            if let mode = ctx.property("mode"),
               let item = mode.property.valueList?.first(where: { MiotSynthesizer.hvacMode(forDescription: $0.description) == hvacMode }) {
                writes.append(ctx.write(mode, .number(Double(item.value))))
            }
            return .setProps(writes)

        case .setClimateTemperature(_, let temperature):
            return .setProps([try ctx.write("target-temperature", .number(temperature))])

        case .setClimateFanMode(_, let fanMode):
            return .setProps([try ctx.writeListValue("fan-level", description: fanMode, searchDevice: true)])

        case .setFanPresetMode(_, let preset):
            if let w = try? ctx.writeListValue("mode", description: preset) { return .setProps([w]) }
            return .setProps([try ctx.writeListValue("fan-level", description: preset)])

        case .setFanOscillating(_, let oscillating):
            return .setProps([try ctx.write("horizontal-swing", .bool(oscillating))])

        case .setSwitch(_, let isOn):
            let name = ctx.property("on") != nil ? "on" : "physical-controls-locked"
            return .setProps([try ctx.write(name, .bool(isOn))])

        case .setSelectOption(_, let option):
            return .setProps([try ctx.writeListValue("mode", description: option)])

        case .vacuumAction(_, let action):
            let candidates: [String] = switch action {
            case .start: ["start-sweep", "start-clean", "start-sweep-mop", "start-mop"]
            case .pause: ["pause-sweeping", "pause", "stop-sweeping", "stop-clean"]
            case .returnToBase: ["start-charge", "stop-and-gocharge", "return-to-charge", "go-charging"]
            }
            return .action(try ctx.action(candidates))

        case .setClimateSwingMode, .setNumberValue, .mediaSetVolume, .mediaSelectSource,
             .pressButton, .sendNotifyMessage, .activateScene:
            throw MiotCommandError.unsupported(String(describing: command).components(separatedBy: "(").first ?? "")
        }
    }

    private struct Context {
        let did: String
        let spec: MiotDeviceSpec
        let service: MiotService

        struct Found {
            let service: MiotService
            let property: MiotProperty
        }

        func property(_ name: String, searchDevice: Bool = false) -> Found? {
            if let p = service.properties.first(where: { $0.shortName == name && $0.isWritable }) {
                return Found(service: service, property: p)
            }
            guard searchDevice else { return nil }
            // e.g. an AC whose fan-level lives in a separate fan-control service.
            let others = spec.services(named: "fan-control") + spec.services.filter { $0.iid != service.iid }
            for s in others {
                if let p = s.properties.first(where: { $0.shortName == name && $0.isWritable }) {
                    return Found(service: s, property: p)
                }
            }
            return nil
        }

        func require(_ name: String, searchDevice: Bool = false) throws -> Found {
            guard let f = property(name, searchDevice: searchDevice) else { throw MiotCommandError.unsupported(name) }
            return f
        }

        func write(_ name: String, _ value: JSONValue) throws -> MiotPropWrite {
            write(try require(name), value)
        }

        func write(_ found: Found, _ value: JSONValue) -> MiotPropWrite {
            MiotPropWrite(did: did, siid: found.service.iid, piid: found.property.iid, value: coerce(value, for: found.property))
        }

        func powerOnPrefix() -> [MiotPropWrite] {
            property("on").map { [write($0, .bool(true))] } ?? []
        }

        func writeListValue(_ name: String, description: String, searchDevice: Bool = false) throws -> MiotPropWrite {
            let found = try require(name, searchDevice: searchDevice)
            guard let item = found.property.valueList?.first(where: { $0.description.caseInsensitiveCompare(description) == .orderedSame }) else {
                throw MiotCommandError.unsupported("\(name)=\(description)")
            }
            return write(found, .number(Double(item.value)))
        }

        func action(_ candidates: [String]) throws -> MiotActionCall {
            let ordered = [service] + spec.services.filter { $0.iid != service.iid }
            for name in candidates {
                for s in ordered {
                    if let a = s.action(named: name) {
                        return MiotActionCall(did: did, siid: s.iid, aiid: a.iid)
                    }
                }
            }
            throw MiotCommandError.unsupported(candidates.first ?? "action")
        }

        /// Clamp to the spec's value-range and match the wire format (bool / integer / float).
        func coerce(_ value: JSONValue, for p: MiotProperty) -> JSONValue {
            if p.format == "bool" { return .bool(value.miotBool ?? false) }
            guard var n = value.doubleValue else { return value }
            if let lo = p.rangeMin, let hi = p.rangeMax { n = Swift.min(hi, Swift.max(lo, n)) }
            if p.isIntegerFormat {
                n = n.rounded()
            } else if let step = p.rangeStep, step > 0 {
                let base = p.rangeMin ?? 0
                n = base + ((n - base) / step).rounded() * step
            }
            return .number(n)
        }
    }
}

extension DeviceCommand {
    var targetEntityId: String {
        switch self {
        case .setLightPower(let id, _), .setLightBrightness(let id, _), .setLightColorTemp(let id, _),
             .setLightEffect(let id, _), .setClimatePower(let id, _, _), .setClimateMode(let id, _),
             .setClimateTemperature(let id, _), .setClimateFanMode(let id, _), .setClimateSwingMode(let id, _),
             .setFanPower(let id, _), .setFanPresetMode(let id, _), .setFanOscillating(let id, _),
             .setSwitch(let id, _), .setSelectOption(let id, _), .setNumberValue(let id, _),
             .vacuumAction(let id, _), .mediaSetVolume(let id, _), .mediaSelectSource(let id, _),
             .pressButton(let id), .sendNotifyMessage(let id, _), .activateScene(let id):
            return id
        }
    }
}
