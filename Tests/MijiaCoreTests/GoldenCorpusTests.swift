import Foundation
import Testing
@testable import MijiaCore

struct GoldenCorpusTests {
    private struct Corpus: Decodable {
        let devices: [CorpusDevice]
        let intentCases: [IntentCase]
        let delayCases: [DelayCase]
        let cancelCases: [CancelCase]
        let undoCases: [UndoCase]
    }

    private struct CorpusDevice: Decodable {
        let id: String
        let name: String
        let roomId: String
        let roomName: String
        let model: String
        let isOnline: Bool
        let kind: CorpusKind

        func toSmartDevice() -> SmartDevice {
            SmartDevice(
                id: id,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: model,
                isOnline: isOnline,
                kind: kind.toDeviceKind()
            )
        }
    }

    private enum CorpusKind: Decodable {
        case light(LightPayload)
        case climate(ClimatePayload)
        case fan(FanPayload)
        case plug(PlugPayload)
        case vacuum(VacuumPayload)
        case sensor(SensorPayload)

        private enum CodingKeys: String, CodingKey { case kind }

        struct LightPayload: Decodable {
            let entityId: String
            let isOn: Bool
            let brightnessPercent: Int?
            let colorTempKelvin: Int?
            let minKelvin: Int
            let maxKelvin: Int
            let currentEffect: String?
            let availableEffects: [String]
        }

        struct ClimatePayload: Decodable {
            let entityId: String
            let isOn: Bool
            let hvacMode: String
            let availableModes: [String]
            let targetTemperature: Double
            let currentTemperature: Double?
            let minTemp: Double
            let maxTemp: Double
            let step: Double
            let fanMode: String?
            let availableFanModes: [String]
            let swingMode: String?
            let availableSwingModes: [String]?
        }

        struct FanPayload: Decodable {
            let entityId: String
            let isOn: Bool
            let percentage: Int?
            let presetMode: String?
            let availablePresetModes: [String]
            let isOscillating: Bool?
        }

        struct PlugPayload: Decodable {
            let switchEntityId: String
            let isOn: Bool
            let powerWatts: Double?
            let energyKwh: Double?
            let childLockEntityId: String?
            let isChildLocked: Bool
        }

        struct VacuumPayload: Decodable {
            let entityId: String
            let status: String
            let battery: Int?
            let modeEntityId: String?
            let currentMode: String?
            let availableModes: [String]
        }

        struct SensorPayload: Decodable {
            let temperature: Double?
            let humidity: Double?
            let battery: Int?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "light":
                self = .light(try LightPayload(from: decoder))
            case "climate":
                self = .climate(try ClimatePayload(from: decoder))
            case "fan":
                self = .fan(try FanPayload(from: decoder))
            case "plug":
                self = .plug(try PlugPayload(from: decoder))
            case "vacuum":
                self = .vacuum(try VacuumPayload(from: decoder))
            case "sensor":
                self = .sensor(try SensorPayload(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Unknown device kind in golden corpus: \(kind)"
                )
            }
        }

        func toDeviceKind() -> DeviceKind {
            switch self {
            case .light(let p):
                return .light(
                    LightSpec(
                        entityId: p.entityId,
                        isOn: p.isOn,
                        brightnessPercent: p.brightnessPercent,
                        colorTempKelvin: p.colorTempKelvin,
                        minKelvin: p.minKelvin,
                        maxKelvin: p.maxKelvin,
                        currentEffect: p.currentEffect,
                        availableEffects: p.availableEffects
                    )
                )
            case .climate(let p):
                return .climate(
                    ClimateSpec(
                        entityId: p.entityId,
                        isOn: p.isOn,
                        hvacMode: p.hvacMode,
                        availableModes: p.availableModes,
                        targetTemperature: p.targetTemperature,
                        currentTemperature: p.currentTemperature,
                        minTemp: p.minTemp,
                        maxTemp: p.maxTemp,
                        step: p.step,
                        fanMode: p.fanMode,
                        availableFanModes: p.availableFanModes,
                        swingMode: p.swingMode,
                        availableSwingModes: p.availableSwingModes ?? []
                    )
                )
            case .fan(let p):
                return .fan(
                    FanSpec(
                        entityId: p.entityId,
                        isOn: p.isOn,
                        percentage: p.percentage,
                        presetMode: p.presetMode,
                        availablePresetModes: p.availablePresetModes,
                        isOscillating: p.isOscillating
                    )
                )
            case .plug(let p):
                return .plug(
                    PlugSpec(
                        switchEntityId: p.switchEntityId,
                        isOn: p.isOn,
                        powerWatts: p.powerWatts,
                        energyKwh: p.energyKwh,
                        childLockEntityId: p.childLockEntityId,
                        isChildLocked: p.isChildLocked
                    )
                )
            case .vacuum(let p):
                return .vacuum(
                    VacuumSpec(
                        entityId: p.entityId,
                        status: p.status,
                        battery: p.battery,
                        modeEntityId: p.modeEntityId,
                        currentMode: p.currentMode,
                        availableModes: p.availableModes
                    )
                )
            case .sensor(let p):
                return .sensor(
                    SensorSpec(
                        temperature: p.temperature,
                        humidity: p.humidity,
                        battery: p.battery
                    )
                )
            }
        }
    }

    private enum ExpectedValue: Decodable, Equatable {
        case bool(Bool)
        case number(Double)
        case string(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else {
                self = .string(try c.decode(String.self))
            }
        }
    }

    private struct ExpectedIntent: Decodable, Equatable {
        let targetId: String
        let kind: String
        let value: ExpectedValue
    }

    private struct IntentCase: Decodable {
        let utterance: String
        let expected: [ExpectedIntent]?
    }

    private struct DelayCase: Decodable {
        let utterance: String
        let seconds: TimeInterval?
        let remainder: String?
    }

    private struct CancelCase: Decodable {
        let utterance: String
        let isCancel: Bool
    }

    private struct UndoCase: Decodable {
        let utterance: String
        let isUndo: Bool
    }

    private static func encodeIntent(_ intent: DeviceIntent) -> ExpectedIntent {
        switch intent.operation {
        case .power(let on):
            return ExpectedIntent(targetId: intent.targetId, kind: "power", value: .bool(on))
        case .brightness(let pct):
            return ExpectedIntent(targetId: intent.targetId, kind: "brightness", value: .number(Double(pct)))
        case .colorTemperature(let k):
            return ExpectedIntent(targetId: intent.targetId, kind: "colorTemperature", value: .number(Double(k)))
        case .lightEffect(let eff):
            return ExpectedIntent(targetId: intent.targetId, kind: "lightEffect", value: .string(eff))
        case .hvacMode(let mode):
            return ExpectedIntent(targetId: intent.targetId, kind: "hvacMode", value: .string(mode))
        case .targetTemperature(let t):
            return ExpectedIntent(targetId: intent.targetId, kind: "targetTemperature", value: .number(t))
        case .fanSpeed(let s):
            return ExpectedIntent(targetId: intent.targetId, kind: "fanSpeed", value: .string(s))
        case .oscillation(let on):
            return ExpectedIntent(targetId: intent.targetId, kind: "oscillation", value: .bool(on))
        case .activateScene:
            return ExpectedIntent(targetId: intent.targetId, kind: "activateScene", value: .bool(true))
        case .brightnessStep(let d):
            return ExpectedIntent(targetId: intent.targetId, kind: "brightnessStep", value: .number(Double(d)))
        case .temperatureStep(let d):
            return ExpectedIntent(targetId: intent.targetId, kind: "temperatureStep", value: .number(d))
        }
    }

    private struct MiotCorpus: Decodable {
        let specs: [String: MiotDeviceSpec]
        let devices: [MiotDeviceEntry]
        let rooms: [MiotRoomEntry]
        let values: [MiotValueEntry]
        let expectedKinds: [String: CorpusKind]
        let expectedEnvironmentReadings: [MiotReadingEntry]
        let expectedRequiredProps: [String: [MiotKeyEntry]]
        let commandCases: [MiotCommandCase]
    }

    private struct MiotReadingEntry: Decodable {
        let id: String
        let label: String
        let roomName: String
        let temperature: Double?
        let humidity: Double?
        let battery: Int?

        func toEnvironmentReading() -> EnvironmentReading {
            EnvironmentReading(
                id: id,
                label: label,
                roomName: roomName,
                temperature: temperature,
                humidity: humidity,
                battery: battery
            )
        }
    }

    private struct MiotDeviceEntry: Decodable {
        let did: String
        let name: String
        let model: String
        let isOnline: Bool
        let splitParentDid: String?
        let splitSiid: Int?
    }

    private struct MiotRoomEntry: Decodable {
        let id: String
        let name: String
        let dids: [String]
    }

    private struct MiotValueEntry: Decodable {
        let did: String
        let siid: Int
        let piid: Int
        let value: JSONValue
    }

    private struct MiotKeyEntry: Decodable, Equatable {
        let did: String
        let siid: Int
        let piid: Int
    }

    private struct MiotCommandPayload: Decodable {
        let kind: String
        let entityId: String
        let isOn: Bool?
        let percent: Int?
        let kelvin: Int?
        let effect: String?
        let hvacMode: String?
        let temperature: Double?
        let fanMode: String?
        let presetMode: String?
        let oscillating: Bool?
        let action: String?

        func toDeviceCommand() throws -> DeviceCommand {
            switch kind {
            case "setLightPower":
                return .setLightPower(entityId: entityId, isOn: isOn ?? false)
            case "setLightBrightness":
                return .setLightBrightness(entityId: entityId, percent: percent ?? 0)
            case "setLightColorTemp":
                return .setLightColorTemp(entityId: entityId, kelvin: kelvin ?? 4000)
            case "setLightEffect":
                return .setLightEffect(entityId: entityId, effect: effect ?? "")
            case "setClimateMode":
                return .setClimateMode(entityId: entityId, hvacMode: hvacMode ?? "off")
            case "setClimateTemperature":
                return .setClimateTemperature(entityId: entityId, temperature: temperature ?? 26)
            case "setClimateFanMode":
                return .setClimateFanMode(entityId: entityId, fanMode: fanMode ?? "")
            case "setFanPresetMode":
                return .setFanPresetMode(entityId: entityId, presetMode: presetMode ?? "")
            case "setFanOscillating":
                return .setFanOscillating(entityId: entityId, oscillating: oscillating ?? false)
            case "setSwitch":
                return .setSwitch(entityId: entityId, isOn: isOn ?? false)
            case "vacuumAction":
                let vAction: VacuumAction = switch action {
                case "start": .start
                case "pause": .pause
                default: .returnToBase
                }
                return .vacuumAction(entityId: entityId, action: vAction)
            default:
                throw CocoaError(.coderInvalidValue)
            }
        }
    }

    private struct MiotExpectedWrite: Decodable {
        let kind: String
        let writes: [MiotValueEntry]?
        let call: MiotExpectedAction?

        func toMiotWrite() -> MiotWrite {
            if kind == "action", let c = call {
                return .action(MiotActionCall(did: c.did, siid: c.siid, aiid: c.aiid, inputs: c.inputs))
            }
            let props = (writes ?? []).map {
                MiotPropWrite(did: $0.did, siid: $0.siid, piid: $0.piid, value: $0.value)
            }
            return .setProps(props)
        }
    }

    private struct MiotExpectedAction: Decodable {
        let did: String
        let siid: Int
        let aiid: Int
        let inputs: [JSONValue]
    }

    private struct MiotCommandCase: Decodable {
        let model: String
        let command: MiotCommandPayload
        let expected: MiotExpectedWrite
    }

    private struct RegionCorpus: Decodable {
        let regions: [String]
    }

    private struct AIRequestCorpus: Decodable {
        let utterance: String
        let context: AIRequestContext
        let devices: [CorpusDevice]
        let scenes: [AIRequestScene]
        let expected: AIRequestExpected
    }

    private struct AIRequestContext: Decodable {
        let timeSummary: String
        let environmentSummary: String
        let activeDevicesSummary: String
        let habitSummary: String

        func toAssistantContext() -> AssistantContext {
            AssistantContext(
                timeSummary: timeSummary,
                environmentSummary: environmentSummary,
                activeDevicesSummary: activeDevicesSummary,
                habitSummary: habitSummary
            )
        }
    }

    private struct AIRequestScene: Decodable {
        let id: String
        let name: String
        let entityId: String

        func toHomeScene() -> HomeScene {
            HomeScene(id: id, name: name, entityId: entityId)
        }
    }

    private struct AICatalogDeviceLine: Decodable, Equatable {
        let alias: String
        let name: String
        let room: String
        let category: String
    }

    private struct AICatalogSceneLine: Decodable, Equatable {
        let alias: String
        let name: String
    }

    private struct AIRequestExpected: Decodable {
        let stateKeys: [String]
        let questionsKeys: [String]
        let targetAliases: [String]
        let catalogDeviceLines: [AICatalogDeviceLine]
        let catalogSceneLines: [AICatalogSceneLine]
        let decisionHeadCriteriaKeys: [String: [String]]
    }

    private static func locateGoldenFixture(_ relativePath: String = "Tests/Fixtures/intent_golden.json") throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("Cross-platform golden JSON corpus matches MijiaCore LocalIntentParser, DelayPhrase, and UndoPhrase")
    func goldenCorpusParity() throws {
        let fixtureURL = try Self.locateGoldenFixture("Tests/Fixtures/intent_golden.json")
        let data = try Data(contentsOf: fixtureURL)
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        let devices = corpus.devices.map { $0.toSmartDevice() }

        for item in corpus.intentCases {
            if let expected = item.expected {
                let plan = try #require(LocalIntentParser.parse(item.utterance, devices: devices, scenes: []), "\(item.utterance)")
                let actual = plan.intents.map(Self.encodeIntent)
                #expect(actual == expected, "\(item.utterance)")
            } else {
                #expect(LocalIntentParser.parse(item.utterance, devices: devices, scenes: []) == nil, "\(item.utterance)")
            }
        }

        for item in corpus.delayCases {
            if let seconds = item.seconds, let remainder = item.remainder {
                let got = try #require(DelayPhrase.extract(item.utterance), "\(item.utterance)")
                #expect(got.delay == seconds, "\(item.utterance)")
                #expect(got.remainder == remainder, "\(item.utterance)")
            } else {
                #expect(DelayPhrase.extract(item.utterance) == nil, "\(item.utterance)")
            }
        }

        for item in corpus.cancelCases {
            #expect(DelayPhrase.isCancel(item.utterance) == item.isCancel, "\(item.utterance)")
        }

        for item in corpus.undoCases {
            #expect(UndoPhrase.isUndo(item.utterance) == item.isUndo, "\(item.utterance)")
        }
    }

    @Test("Cross-platform MIoT golden JSON corpus matches MijiaCore MiotSynthesizer and MiotCommandMapper")
    func miotGoldenCorpusParity() throws {
        let fixtureURL = try Self.locateGoldenFixture("Tests/Fixtures/miot_golden.json")
        let data = try Data(contentsOf: fixtureURL)
        let corpus = try JSONDecoder().decode(MiotCorpus.self, from: data)

        let records = corpus.devices.map {
            MiDeviceRecord(
                did: $0.did,
                name: $0.name,
                model: $0.model,
                isOnline: $0.isOnline,
                splitParentDid: $0.splitParentDid,
                splitSiid: $0.splitSiid
            )
        }
        let rooms = corpus.rooms.map {
            MiRoom(id: $0.id, name: $0.name, dids: $0.dids)
        }
        var values: [MiotPropKey: JSONValue] = [:]
        for v in corpus.values {
            values[MiotPropKey(did: v.did, siid: v.siid, piid: v.piid)] = v.value
        }

        let home = MiotSynthesizer.synthesize(
            devices: records,
            rooms: rooms,
            specs: corpus.specs,
            values: values
        )

        #expect(home.devices.count == corpus.expectedKinds.count)
        for (did, expectedKind) in corpus.expectedKinds {
            let dev = try #require(home.devices.first(where: { $0.id == did }), "Missing device \(did)")
            #expect(dev.kind == expectedKind.toDeviceKind(), "Mismatch on \(did)")
        }
        #expect(home.environmentReadings == corpus.expectedEnvironmentReadings.map { $0.toEnvironmentReading() })

        for record in records {
            let spec = try #require(corpus.specs[record.model])
            let expectedProps = try #require(corpus.expectedRequiredProps[record.did]).map {
                MiotPropKey(did: $0.did, siid: $0.siid, piid: $0.piid)
            }
            let actualProps = MiotSynthesizer.requiredProps(for: record, spec: spec)
            #expect(actualProps == expectedProps, "requiredProps mismatch on \(record.did)")
        }

        for item in corpus.commandCases {
            let spec = try #require(corpus.specs[item.model], "Missing spec \(item.model)")
            let cmd = try item.command.toDeviceCommand()
            let actualWrite = try MiotCommandMapper.map(cmd, spec: spec)
            #expect(actualWrite == item.expected.toMiotWrite(), "\(item.model) \(item.command.kind)")
        }
    }

    // MARK: - Issue #37: cloud region list shared with the Windows login screen

    @Test("Cross-platform region golden JSON corpus matches MiCloudRegion.allCases order (#37)")
    func regionGoldenCorpusParity() throws {
        let fixtureURL = try Self.locateGoldenFixture("Tests/Fixtures/region_golden.json")
        let corpus = try JSONDecoder().decode(RegionCorpus.self, from: Data(contentsOf: fixtureURL))

        // The array order is the login dropdown order, so it must match exactly, not just as a set:
        // Windows (windows/tests/core.test.ts) asserts MI_CLOUD_REGIONS against the same array.
        #expect(MiCloudRegion.allCases.map(\.rawValue) == corpus.regions)
        for code in corpus.regions {
            #expect(MiCloudRegion(rawValue: code) != nil, "shared corpus region \(code) is unknown to MiCloudRegion")
        }
        #expect(Set(corpus.regions).count == corpus.regions.count, "region corpus must not repeat a server")
    }

    // MARK: - Issue #38: Jev /v1/systemone request structure shared with Windows

    @Test("Cross-platform Jev SystemOne request corpus matches MijiaCore ModelIntentResolver (#38)")
    func systemOneRequestGoldenCorpusParity() throws {
        let fixtureURL = try Self.locateGoldenFixture("Tests/Fixtures/ai_request_golden.json")
        let corpus = try JSONDecoder().decode(AIRequestCorpus.self, from: Data(contentsOf: fixtureURL))
        let devices = corpus.devices.map { $0.toSmartDevice() }
        let scenes = corpus.scenes.map { $0.toHomeScene() }

        let resolver = ModelIntentResolver(
            config: AssistantConfig(
                baseURL: "https://openrouter.ai/api/v1",
                model: "~typesafe/jev-latest",
                apiKey: "test-token"
            )
        )
        #expect(ModelIntentResolver.isSystemOneModel(resolver.config.model))

        let catalog = IntentCatalog(devices: devices, scenes: scenes)
        let request = try resolver.makeSystemOneRequest(
            utterance: corpus.utterance,
            catalog: catalog,
            devices: devices,
            context: corpus.context.toAssistantContext()
        )
        let bodyData = try #require(request.httpBody, "System One request must carry a body")
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let state = try #require(body["state"] as? [String: Any])
        let questions = try #require(body["questions"] as? [String: Any])
        #expect(body["model"] as? String == "~typesafe/jev-latest")

        // Swift dictionaries (and JSONSerialization) do not promise key order, so the ordered
        // expectation is checked where this implementation builds order itself (catalog lines
        // below). Key sets are compared for the JSON objects; the Windows test compares the same
        // corpus with insertion order because its objects preserve it.
        #expect(Set(state.keys) == Set(corpus.expected.stateKeys), "state keys drifted from the shared corpus")
        #expect(state["command"] as? String == corpus.utterance)
        #expect(state["time"] as? String == corpus.context.timeSummary)
        #expect(state["environment"] as? String == corpus.context.environmentSummary)
        #expect(state["active_devices"] as? String == corpus.context.activeDevicesSummary)
        #expect(state["user_habits"] as? String == corpus.context.habitSummary)

        func criteriaKeys(of question: String) throws -> Set<String> {
            let payload = try #require(questions[question] as? [String: Any], "missing question \(question)")
            let criteria = try #require(payload["criteria"] as? [String: Any], "\(question) has no criteria")
            return Set(criteria.keys)
        }

        // One decision head per controllable device, never truncated at 10 (#33): the corpus has
        // 13 devices, 12 controllable, and the trailing sensor must not get a head of its own.
        #expect(Set(questions.keys) == Set(corpus.expected.questionsKeys), "question keys drifted from the shared corpus")
        #expect(questions.count == 3 + 12)
        #expect(questions["dev_d10"] != nil)
        #expect(questions["dev_d11"] != nil)
        #expect(questions["dev_d12"] != nil, "the 12th controllable device must keep its head (#33)")
        #expect(questions["dev_d13"] == nil, "the sensor is not controllable and must not get a decision head")

        let targetKeys = try criteriaKeys(of: "target")
        #expect(targetKeys == Set(corpus.expected.targetAliases), "target aliases drifted from the shared corpus")
        #expect(targetKeys.count == corpus.expected.targetAliases.count)
        #expect(targetKeys.contains("none"))

        for (head, expectedKeys) in corpus.expected.decisionHeadCriteriaKeys {
            let actualKeys = try criteriaKeys(of: head)
            #expect(actualKeys == Set(expectedKeys), "\(head) criteria drifted from the shared corpus")
        }

        // Each head must describe the same device its catalog alias does: alias numbering is
        // computed once in IntentCatalog and again in the head builder, so a drift between the two
        // would point `dev_dN` at the wrong device without changing any key.
        for line in corpus.expected.catalogDeviceLines {
            let payload = try #require(questions["dev_\(line.alias)"] as? [String: Any], "missing head for \(line.alias)")
            let instructions = try #require(payload["instructions"] as? String, "\(line.alias) has no instructions")
            #expect(instructions.contains(line.name), "\(line.alias) head must name \(line.name)")
            #expect(instructions.contains(line.room), "\(line.alias) head must name room \(line.room)")
        }

        // The catalog is a plain string, so its section and line order are deterministic and are
        // compared in full for the four skeleton fields; the trailing state summary is free text
        // (device-specific wording) and is only required to be present.
        let catalogText = try #require(state["catalog"] as? String)
        let sceneMarker = "\n场景(id|名称):\n"
        let sections = catalogText.components(separatedBy: sceneMarker)
        #expect(sections.count == 2, "catalog must carry both a device section and a scene section")
        let deviceSection = try #require(sections.first)
        let sceneSection = try #require(sections.dropFirst().first, "catalog must carry a scene section")

        var deviceLines = deviceSection.components(separatedBy: "\n")
        deviceLines.removeFirst() // header line: 设备(id|名称|房间|类型|当前状态):
        let parsedDevices = deviceLines.filter { !$0.isEmpty }.map { (line: String) -> (parsed: AICatalogDeviceLine, summary: String) in
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            let parsed = AICatalogDeviceLine(
                alias: parts.count > 0 ? parts[0] : "",
                name: parts.count > 1 ? parts[1] : "",
                room: parts.count > 2 ? parts[2] : "",
                category: parts.count > 3 ? parts[3] : ""
            )
            return (parsed: parsed, summary: parts.count > 4 ? parts[4] : "")
        }
        #expect(parsedDevices.map { $0.parsed } == corpus.expected.catalogDeviceLines)
        #expect(parsedDevices.allSatisfy { !$0.summary.isEmpty }, "every catalog device line needs a state summary")

        let parsedScenes = sceneSection.components(separatedBy: "\n").filter { !$0.isEmpty }.map { (line: String) -> AICatalogSceneLine in
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return AICatalogSceneLine(alias: parts.count > 0 ? parts[0] : "", name: parts.count > 1 ? parts[1] : "")
        }
        #expect(parsedScenes == corpus.expected.catalogSceneLines)

        // Same empty-context rule as Windows: the ambient keys are omitted, not sent blank.
        let bareRequest = try resolver.makeSystemOneRequest(
            utterance: corpus.utterance,
            catalog: catalog,
            devices: devices
        )
        let bareData = try #require(bareRequest.httpBody)
        let bareBody = try #require(JSONSerialization.jsonObject(with: bareData) as? [String: Any])
        let bareState = try #require(bareBody["state"] as? [String: Any])
        #expect(Set(bareState.keys) == Set(["catalog", "command"]), "empty context must omit the ambient summaries")
        let bareQuestions = try #require(bareBody["questions"] as? [String: Any])
        #expect(Set(bareQuestions.keys) == Set(corpus.expected.questionsKeys))
    }
}
