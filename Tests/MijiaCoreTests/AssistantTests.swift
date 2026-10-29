import Foundation
import Testing
@testable import MijiaCore

struct AssistantTests {
    // MARK: - Fixture

    static let studyCeiling = SmartDevice(
        id: "dev_study_ceiling", name: "书房吸顶灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(
            entityId: "light.study_ceiling",
            isOn: false,
            availableEffects: ["Day", "Night"]
        ))
    )
    static let studyDesk = SmartDevice(
        id: "dev_study_desk", name: "书房台灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study_desk", isOn: false))
    )
    static let livingAC = SmartDevice(
        id: "dev_living_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
        model: "xiaomi.aircondition.mt0", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.living_ac", isOn: false, hvacMode: "off",
            availableModes: ["off", "cool", "heat", "dry", "fan_only", "auto"],
            targetTemperature: 24
        ))
    )
    static let bedsideLamp = SmartDevice(
        id: "dev_bedside", name: "主卧床头灯", roomId: "zhu_wo", roomName: "主卧",
        model: "yeelink.light.bslamp2", isOnline: true,
        kind: .light(LightSpec(entityId: "light.bedside", isOn: true, brightnessPercent: 80))
    )
    static let guestHeater = SmartDevice(
        id: "dev_guest_heater", name: "次卧电暖器", roomId: "ci_wo", roomName: "次卧",
        model: "zhimi.heater.za2", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.guest_heater", isOn: false, hvacMode: "off",
            availableModes: ["off", "heat"], targetTemperature: 20
        ))
    )
    static let devices = [studyCeiling, studyDesk, livingAC, bedsideLamp, guestHeater]
    static let scenes = [
        HomeScene(id: "scene_home", name: "回家模式", entityId: "scene.home"),
        HomeScene(id: "scene_sleep", name: "睡眠模式", entityId: "scene.sleep")
    ]

    static func parse(_ text: String) -> IntentPlan? {
        LocalIntentParser.parse(text, devices: devices, scenes: scenes)
    }

    // MARK: - LocalIntentParser

    @Test("打开书房灯 turns on both study lights")
    func studyLightsOn() throws {
        let plan = try #require(Self.parse("打开书房灯"))
        #expect(plan.source == .local)
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .power(true)),
            DeviceIntent(targetId: "dev_study_desk", operation: .power(true))
        ])
        #expect(plan.reply == "已打开书房吸顶灯、书房台灯")
    }

    @Test("书房灯月光模式 switches the study ceiling light to Night effect instead of dimming")
    func studyMoonlightEffect() throws {
        let plan = try #require(Self.parse("书房灯月光模式"))
        #expect(plan.source == .local)
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night"))
        ])
        #expect(plan.reply == "已书房吸顶灯切换为月光模式")

        let dayPlan = try #require(Self.parse("把书房吸顶灯切换为日光模式"))
        #expect(dayPlan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Day"))
        ])
        #expect(dayPlan.reply == "已书房吸顶灯切换为日光模式")

        // A desk lamp without availableEffects cannot accept Night mode when explicitly named.
        #expect(Self.parse("书房台灯月光模式") == nil)
    }

    @Test("关掉所有的灯 turns off every light")
    func allLightsOff() throws {
        let plan = try #require(Self.parse("关掉所有的灯"))
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .power(false)),
            DeviceIntent(targetId: "dev_study_desk", operation: .power(false)),
            DeviceIntent(targetId: "dev_bedside", operation: .power(false))
        ])
    }

    @Test("Climate temperature and mode commands")
    func climateCommands() throws {
        #expect(Self.parse("客厅空调调到26度")?.intents == [
            DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(26))
        ])
        #expect(Self.parse("客厅空调制冷")?.intents == [
            DeviceIntent(targetId: "dev_living_ac", operation: .hvacMode("cool"))
        ])
        #expect(Self.parse("把客厅空调调到26度制冷")?.intents == [
            DeviceIntent(targetId: "dev_living_ac", operation: .hvacMode("cool")),
            DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(26))
        ])
    }

    @Test("Brightness, kind words, scenes")
    func miscCommands() {
        // "调暗" is an absolute dim level; "调暗一点" is relative to the current 80%.
        #expect(Self.parse("主卧灯调暗")?.intents == [
            DeviceIntent(targetId: "dev_bedside", operation: .brightness(20))
        ])
        #expect(Self.parse("主卧灯调暗一点")?.intents == [
            DeviceIntent(targetId: "dev_bedside", operation: .brightness(60))
        ])
        #expect(Self.parse("书房台灯亮度50%")?.intents == [
            DeviceIntent(targetId: "dev_study_desk", operation: .brightness(50))
        ])
        // 空调 excludes heaters, so the home has exactly one and it's unambiguous.
        #expect(Self.parse("打开空调")?.intents == [
            DeviceIntent(targetId: "dev_living_ac", operation: .power(true))
        ])
        #expect(Self.parse("关闭电暖器")?.intents == [
            DeviceIntent(targetId: "dev_guest_heater", operation: .power(false))
        ])
        // 卧室 tolerantly maps to 主卧
        #expect(Self.parse("关掉卧室的灯")?.intents == [
            DeviceIntent(targetId: "dev_bedside", operation: .power(false))
        ])
        #expect(Self.parse("执行回家模式")?.intents == [
            DeviceIntent(targetId: "scene_home", operation: .activateScene)
        ])
    }

    @Test("Unsure utterances fall through to the model")
    func unsureReturnsNil() {
        #expect(Self.parse("我要睡觉了") == nil)
        #expect(Self.parse("打开") == nil)
        #expect(Self.parse("打开灯") == nil)                 // 3 lights, no room: ambiguous
        #expect(Self.parse("打开书房灯关掉客厅空调") == nil)   // contradictory power verbs
        #expect(Self.parse("客厅空调调亮") == nil)            // brightness invalid for climate
        #expect(Self.parse("打开厨房灯") == nil)              // no such room
    }

    // MARK: - ModelIntentResolver

    @Test("Model resolver strips fences, maps aliases, drops unknown and invalid intents")
    func modelResolverBoundary() async throws {
        let content = """
        好的：
        ```json
        {"actions":[
          {"device":"d1","op":"effect","value":"Night"},
          {"device":"d99","op":"power","value":true},
          {"device":"d3","op":"brightness","value":50},
          {"device":"d3","op":"temperature","value":40},
          {"device":"s2","op":"scene","value":null}
        ],"reply":"好的，已为你处理 {书房}"}
        ```
        """
        let envelope: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        let responseData = try JSONSerialization.data(withJSONObject: envelope)

        let resolver = ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://api.example.com/v1/", model: "test-model", apiKey: "test-key"),
            transport: { request in
                #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
                #expect(request.httpMethod == "POST")
                let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                #expect(body["model"] as? String == "test-model")
                #expect(body["max_tokens"] as? Int == 800)
                #expect(body["temperature"] as? Int == 0)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (responseData, response)
            }
        )

        let plan = try await resolver.resolve("随便", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.source == .model)
        #expect(plan.reply == "好的，已为你处理 {书房}")
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night")),
            DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(30)),
            DeviceIntent(targetId: "scene_sleep", operation: .activateScene)
        ])
    }

    @Test("AssistantConfig defaults to OpenRouter without API key and ModelIntentResolver rejects missing key")
    func assistantDefaultConfigAndMissingKey() async throws {
        let suite = "test.assistant.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let loaded = AssistantConfig.load(from: defaults, includeAmbientKey: false)
        #expect(loaded.baseURL == AssistantConfig.defaultBaseURL)
        #expect(loaded.model == AssistantConfig.defaultModel)
        #expect(loaded.hasAPIKey == false)
        #expect(loaded.isLoopbackEndpoint == false)

        let unconfiguredResolver = ModelIntentResolver(
            config: AssistantConfig(baseURL: AssistantConfig.defaultBaseURL, model: AssistantConfig.defaultModel, apiKey: "")
        )
        await #expect(throws: AssistantError.missingAPIKey) {
            try await unconfiguredResolver.resolve("准备写代码", devices: Self.devices, scenes: Self.scenes)
        }
        #expect(AssistantError.userMessage(for: AssistantError.missingAPIKey).contains("API Key"))
    }

    @Test("AssistantConfig loads OpenRouter key from CodexBar config file")
    func codexBarOpenRouterKeyLoading() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fakeConfig = """
        {
          "version": 1,
          "providers": [
            { "id": "codex", "enabled": true },
            { "id": "openrouter", "enabled": true, "apiKey": "test-or-key-placeholder" }
          ]
        }
        """
        try fakeConfig.write(to: tempURL, atomically: true, encoding: .utf8)
        let loaded = AssistantConfig.loadCodexBarOpenRouterKey(configURL: tempURL)
        #expect(loaded == "test-or-key-placeholder")
    }

    @Test("Model resolver uses /v1/systemone with ~typesafe/jev-latest and decodes multi-question intents")
    func modelResolverSystemOneJev() async throws {
        let systemOnePayload: [String: Any] = [
            "answers": [
                "target": ["choice": "room_lights:书房", "confidence": 0.99],
                "op": ["choice": "effect_night", "confidence": 0.97],
                "temp": ["choice": "none", "confidence": 0.99]
            ]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: systemOnePayload)

        let resolver = ModelIntentResolver(
            config: AssistantConfig(
                baseURL: "https://openrouter.ai/api/v1",
                model: "typesafe/jev-latest",
                apiKey: "test-token"
            ),
            transport: { request in
                #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/systemone")
                let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                // OpenRouter requires the leading ~ for unlisted System One models
                #expect(body["model"] as? String == "~typesafe/jev-latest")
                let questions = try #require(body["questions"] as? [String: Any])
                #expect(questions["target"] != nil)
                #expect(questions["op"] != nil)
                #expect(questions["temp"] != nil)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (responseData, response)
            }
        )

        let plan = try await resolver.resolve("书房来点柔和月光", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.source == .model)
        // Only studyCeiling supports the Night effect; studyDesk is filtered out cleanly by IntentCatalog
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night"))
        ])
        #expect(plan.reply == "已书房吸顶灯切换为月光模式")

        // Verify AC mode + temperature combined from System One answers
        let acPayload: [String: Any] = [
            "answers": [
                "target": ["choice": "d3", "confidence": 1.0],
                "op": ["choice": "hvac_cool", "confidence": 0.99],
                "temp": ["choice": "24", "confidence": 1.0]
            ]
        ]
        let acData = try JSONSerialization.data(withJSONObject: acPayload)
        let acResolver = ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://openrouter.ai/api/v1", model: "~typesafe/jev-latest", apiKey: "test-token"),
            transport: { request in
                (acData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let acPlan = try await acResolver.resolve("太热了，客厅空调开24度", devices: Self.devices, scenes: Self.scenes)
        #expect(acPlan.intents == [
            DeviceIntent(targetId: "dev_living_ac", operation: .hvacMode("cool")),
            DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(24))
        ])

        // Verify multi-device parallel Jev decisions + secondary probability suggestion extraction
        let parallelPayload: [String: Any] = [
            "answers": [
                "target": ["choice": "none", "confidence": 0.5],
                "op": ["choice": "power_on", "confidence": 0.5],
                "temp": ["choice": "none", "confidence": 0.99],
                "dev_d1": [
                    "choice": "effect_day",
                    "probabilities": ["effect_day": 0.62, "none": 0.29],
                    "confidence": 0.52
                ],
                "dev_d2": [
                    "choice": "none",
                    "probabilities": ["none": 0.56, "power_on": 0.36],
                    "confidence": 0.41
                ],
                "dev_d3": [
                    "choice": "cool_25",
                    "probabilities": ["cool_25": 0.99, "none": 0.01],
                    "confidence": 0.99
                ]
            ]
        ]
        let parallelData = try JSONSerialization.data(withJSONObject: parallelPayload)
        let parallelResolver = ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://openrouter.ai/api/v1", model: "~typesafe/jev-latest", apiKey: "test-token"),
            transport: { request in
                (parallelData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let parallelPlan = try await parallelResolver.resolve(
            "准备在书房写代码，有点热",
            devices: Self.devices,
            scenes: Self.scenes,
            context: AssistantContext(timeSummary: "夜晚 22:30", environmentSummary: "书房 28.4°C", habitSummary: "夜晚常开日光模式")
        )
        // Only the 99% head runs by itself; the 62% guess waits for a tap (#21).
        #expect(parallelPlan.intents == [
            DeviceIntent(targetId: "dev_living_ac", operation: .hvacMode("cool")),
            DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(25))
        ])
        #expect(parallelPlan.suggestions == [
            AssistantSuggestion(
                id: "jev:dev_study_ceiling:effect_day",
                title: "书房吸顶灯·日光模式",
                confidencePercent: 62,
                intents: [DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Day"))]
            ),
            AssistantSuggestion(
                id: "jev:dev_study_desk:power_on",
                title: "打开书房台灯",
                confidencePercent: 36,
                intents: [DeviceIntent(targetId: "dev_study_desk", operation: .power(true))]
            )
        ])
        #expect(parallelPlan.reply.hasSuffix("；下面的建议要点一下才执行"))
    }

    @Test("UserHabitMemory learns time-bucket habits, personal phrases, and filters already-active states")
    func userHabitMemoryLearning() {
        var memory = UserHabitMemory()
        // TimeBucket reads the machine's local time, so build 21:30 in the local zone too.
        let calendar = Calendar.current
        let eveningDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 21, minute: 30))!

        memory.record(
            utterance: "老规矩写代码",
            intents: [
                DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night")),
                DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(25))
            ],
            devices: Self.devices,
            scenes: Self.scenes,
            now: eveningDate
        )

        let summary = memory.promptSummary(for: eveningDate, devices: Self.devices, scenes: Self.scenes)
        #expect(summary.contains("夜晚常做："))
        #expect(summary.contains("书房吸顶灯·月光模式"))
        #expect(summary.contains("「老规矩写代码」"))

        let suggestions = L10n.$overrideTemperatureUnit.withValue(.celsius) {
            memory.topSuggestions(for: eveningDate, devices: Self.devices, scenes: Self.scenes)
        }
        #expect(suggestions.map(\.title) == ["书房吸顶灯·月光模式", "客厅空调·25°C"])
        let fahrenheitSuggestions = L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
            memory.topSuggestions(for: eveningDate, devices: Self.devices, scenes: Self.scenes)
        }
        #expect(fahrenheitSuggestions.map(\.title) == ["书房吸顶灯·月光模式", "客厅空调·77°F"])
        #expect(fahrenheitSuggestions.map(\.intents) == suggestions.map(\.intents))
    }

    @Test("Model resolver surfaces HTTP errors and empty content")
    func modelResolverErrors() async {
        let failing = ModelIntentResolver(config: AssistantConfig(model: "glm-5.1"), transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: AssistantError.httpStatus(502)) {
            try await failing.resolve("x", devices: Self.devices, scenes: Self.scenes)
        }

        let empty = ModelIntentResolver(config: AssistantConfig(model: "glm-5.1"), transport: { request in
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": ""]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: AssistantError.emptyResponse) {
            try await empty.resolve("x", devices: Self.devices, scenes: Self.scenes)
        }
    }

    // MARK: - HomeStore integration

    @MainActor
    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: Self.devices, scenes: Self.scenes))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.assistant.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, mock)
    }

    @Test("runAssistantCommand dispatches local plans with optimistic state and undo")
    @MainActor
    func storeRunsLocalPlan() async throws {
        let (store, mock) = try await makeStore()

        let plan = try #require(await store.runAssistantCommand("打开书房灯"))
        #expect(plan.source == .local)
        let executed = await mock.executedCommands
        #expect(executed.count == 2)
        #expect(executed.contains(.setLightPower(entityId: "light.study_ceiling", isOn: true)))
        #expect(executed.contains(.setLightPower(entityId: "light.study_desk", isOn: true)))
        #expect(store.assistantState == .done("已打开书房吸顶灯、书房台灯"))
        #expect(store.undoBanner?.restoreCommands.count == 2)
        let studyActive = store.devices.filter { $0.roomName == "书房" }.map(\.isActiveOn)
        #expect(studyActive == [true, true])

        _ = await store.runAssistantCommand("书房灯月光模式")
        let afterMoonlight = await mock.executedCommands
        #expect(afterMoonlight.last == .setLightEffect(entityId: "light.study_ceiling", effect: "Night"))
        if case .light(let ceilingSpec)? = store.devices.first(where: { $0.id == "dev_study_ceiling" })?.kind {
            #expect(ceilingSpec.isOn == true)
            #expect(ceilingSpec.currentEffect == "Night")
        } else {
            Issue.record("Expected study ceiling light spec")
        }

        _ = await store.runAssistantCommand("把客厅空调调到26度制冷")
        let afterClimate = await mock.executedCommands
        #expect(Array(afterClimate.dropFirst(3)) == [
            .setClimateMode(entityId: "climate.living_ac", hvacMode: "cool"),
            .setClimateTemperature(entityId: "climate.living_ac", temperature: 26)
        ])
    }

    @Test("runAssistantCommand falls back to the model when the local parser can't resolve")
    @MainActor
    func storeFallsBackToModel() async throws {
        let (store, mock) = try await makeStore()
        let content = #"{"actions":[{"device":"s2","op":"scene","value":null},{"device":"d4","op":"power","value":false}],"reply":"晚安"}"#
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(model: "glm-5.1"), transport: { request in
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let plan = try #require(await store.runAssistantCommand("我要睡觉了"))
        #expect(plan.source == .model)
        let executed = await mock.executedCommands
        #expect(executed.count == 2)
        #expect(executed.contains(.activateScene(entityId: "scene.sleep")))
        #expect(executed.contains(.setLightPower(entityId: "light.bedside", isOn: false)))
        #expect(store.assistantState == .done("晚安"))
    }

    @Test("runAssistantCommand records a local execution receipt")
    @MainActor
    func storeRecordsLocalReceipt() async throws {
        let (store, _) = try await makeStore()
        _ = await store.runAssistantCommand("打开书房灯")
        let receipt = try #require(store.lastAssistantReceipt)
        #expect(receipt.route == .localRule)
        #expect(receipt.elapsedMilliseconds >= 0)
        #expect(receipt.usedHabitContext == false)
    }

    @Test("runAssistantCommand records a model execution receipt")
    @MainActor
    func storeRecordsModelReceipt() async throws {
        let (store, mock) = try await makeStore()
        let content = #"{"actions":[{"device":"s2","op":"scene","value":null},{"device":"d4","op":"power","value":false}],"reply":"晚安"}"#
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(model: "glm-5.1"), transport: { request in
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        _ = await store.runAssistantCommand("我要睡觉了")
        let receipt = try #require(store.lastAssistantReceipt)
        #expect(receipt.route == .aiModel)
        #expect(receipt.elapsedMilliseconds >= 0)
        #expect(receipt.usedHabitContext == false)
        let executed = await mock.executedCommands
        #expect(executed.count == 2)
    }

    @Test("A model command that receives habit context marks the receipt")
    @MainActor
    func storeRecordsHabitContext() async throws {
        let (store, _) = try await makeStore()
        store.isHabitLearningEnabled = true
        var memory = store.userHabitMemory
        memory.record(
            utterance: "我要睡觉了",
            intents: [DeviceIntent(targetId: "dev_bedside", operation: .power(false))],
            devices: store.devices,
            scenes: store.scenes
        )
        store.userHabitMemory = memory
        let content = #"{"actions":[{"device":"s2","op":"scene","value":null},{"device":"d4","op":"power","value":false}],"reply":"晚安"}"#
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(model: "glm-5.1"), transport: { request in
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        _ = await store.runAssistantCommand("我要睡觉了")
        let receipt = try #require(store.lastAssistantReceipt)
        #expect(receipt.route == .aiModel)
        #expect(receipt.usedHabitContext == true)
        #expect(receipt.habitSummary?.isEmpty == false)
    }

    @Test("The receipt clears when the assistant reply resets")
    @MainActor
    func receiptClearsOnIdle() async throws {
        let (store, _) = try await makeStore()
        _ = await store.runAssistantCommand("打开书房灯")
        #expect(store.lastAssistantReceipt != nil)
        store.dismissAssistantBar()
        #expect(store.lastAssistantReceipt == nil)
    }

    @Test("runAssistantCommand rolls back and reports failure when the provider rejects")
    @MainActor
    func storeRollsBackOnFailure() async throws {
        let (store, mock) = try await makeStore()
        await mock.setShouldFail(true)
        _ = await store.runAssistantCommand("关掉主卧床头灯")
        #expect(store.assistantState == .failed("主卧床头灯 未响应"))
        #expect(store.devices.first(where: { $0.id == "dev_bedside" })?.isActiveOn == true)
    }

    @Test("Native TypeSafe Jev strips ~typesafe/ prefix and normalizes bare api.typesafe.ai endpoint")
    func nativeTypeSafeJevResolver() async throws {
        let systemOnePayload: [String: Any] = [
            "answers": [
                "target": ["choice": "d1", "confidence": 0.99],
                "op": ["choice": "effect_night", "confidence": 0.98],
                "temp": ["choice": "none", "confidence": 1.0]
            ]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: systemOnePayload)

        let resolver = ModelIntentResolver(
            config: AssistantConfig(
                baseURL: "https://api.typesafe.ai",
                model: "~typesafe/jev-latest",
                apiKey: "Bearer ts-native-key-123"
            ),
            transport: { request in
                #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ts-native-key-123")
                let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                #expect(body["model"] as? String == "jev-latest")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (responseData, response)
            }
        )

        let plan = try await resolver.resolve("书房柔和一点", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night"))
        ])
    }

    @Test("DeepSeek and OpenAI-compatible models resolve chat intents, strip <think> blocks, and support proactive suggestions")
    func deepSeekChatAndProactiveResolver() async throws {
        let reasoningContent = """
        <think>
        用户说屋里有点热，准备看书，应该考虑 {dev_study_ceiling} 和 {dev_living_ac}。
        </think>
        ```json
        {
          "actions": [
            {"device": "room_lights:书房", "op": "power", "value": true},
            {"device": "客厅空调", "op": "hvac_mode", "value": "cool"},
            {"device": "d3", "op": "temperature", "value": "25°C"}
          ],
          "suggestions": [
            {"device": "d4", "op": "power", "value": false, "confidence": 82}
          ],
          "reply": "已开启书房灯光并将客厅空调调至 25°C 制冷"
        }
        ```
        """
        let chatEnvelope: [String: Any] = ["choices": [["message": ["role": "assistant", "content": reasoningContent]]]]
        let chatData = try JSONSerialization.data(withJSONObject: chatEnvelope)

        let resolver = ModelIntentResolver(
            config: AssistantConfig(
                baseURL: "https://api.deepseek.com",
                model: "deepseek-reasoner",
                apiKey: "sk-deepseek-user-key"
            ),
            transport: { request in
                #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-deepseek-user-key")
                let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                #expect(body["model"] as? String == "deepseek-reasoner")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (chatData, response)
            }
        )

        let plan = try await resolver.resolve("准备看书，有点热", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .power(true)),
            DeviceIntent(targetId: "dev_study_desk", operation: .power(true)),
            DeviceIntent(targetId: "dev_living_ac", operation: .hvacMode("cool")),
            DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(25))
        ])
        #expect(plan.suggestions == [
            AssistantSuggestion(
                id: "chat:dev_bedside:0",
                title: "关闭主卧床头灯",
                confidencePercent: 82,
                intents: [DeviceIntent(targetId: "dev_bedside", operation: .power(false))]
            )
        ])

        // Proactive suggestions on DeepSeek must call /chat/completions instead of /systemone
        let proactiveContent = #"{"suggestions":[{"device":"d1","op":"effect","value":"Night","confidence":91}]}"#
        let proactiveEnvelope: [String: Any] = ["choices": [["message": ["role": "assistant", "content": proactiveContent]]]]
        let proactiveData = try JSONSerialization.data(withJSONObject: proactiveEnvelope)

        let proactiveResolver = ModelIntentResolver(
            config: AssistantConfig(
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat",
                apiKey: "sk-deepseek-user-key"
            ),
            transport: { request in
                #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (proactiveData, response)
            }
        )

        let suggestions = try await proactiveResolver.recommendProactiveSuggestions(
            devices: Self.devices,
            scenes: Self.scenes,
            context: AssistantContext(timeSummary: "深夜 23:40", environmentSummary: "书房 26.0°C")
        )
        #expect(suggestions == [
            AssistantSuggestion(
                id: "chat:dev_study_ceiling:0",
                title: "书房吸顶灯·月光模式",
                confidencePercent: 91,
                intents: [DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night"))]
            )
        ])
    }

    @Test("AssistantProviderPreset infers providers and isolates provider keys in CodexBar")
    func providerPresetAndCodexBarIsolation() throws {
        #expect(AssistantProviderPreset.allCases.map(\.rawValue) == [
            "openrouter_jev",
            "native_jev",
            "deepseek",
            "siliconflow",
            "dashscope",
            "zhipu_glm",
            "moonshot_kimi",
            "openai",
            "gemini",
            "groq",
            "ollama",
            "custom"
        ])
        #expect(AssistantProviderPreset.infer(baseURL: "https://openrouter.ai/api/v1") == .openRouterJev)
        #expect(AssistantProviderPreset.infer(baseURL: "https://api.typesafe.ai/v1") == .nativeJev)
        #expect(AssistantProviderPreset.infer(baseURL: "https://api.deepseek.com/v1") == .deepSeek)
        #expect(AssistantProviderPreset.infer(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1") == .dashScope)
        #expect(AssistantProviderPreset.infer(baseURL: "https://open.bigmodel.cn/api/paas/v4") == .zhipuGLM)
        #expect(AssistantProviderPreset.infer(baseURL: "https://api.moonshot.cn/v1") == .moonshotKimi)
        #expect(AssistantProviderPreset.infer(baseURL: "https://api.groq.com/openai/v1") == .groq)
        #expect(AssistantProviderPreset.infer(baseURL: "http://localhost:11434/v1") == .ollama)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-multi-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fakeConfig = """
        {
          "version": 1,
          "providers": [
            { "id": "openrouter", "enabled": true, "apiKey": "sk-or-test" },
            { "id": "typesafe", "enabled": true, "apiKey": "ts-native-test" }
          ]
        }
        """
        try fakeConfig.write(to: tempURL, atomically: true, encoding: .utf8)

        #expect(AssistantConfig.loadAmbientAPIKey(forBaseURL: "https://openrouter.ai/api/v1", configURL: tempURL) == "sk-or-test")
        #expect(AssistantConfig.loadAmbientAPIKey(forBaseURL: "https://api.typesafe.ai/v1", configURL: tempURL) == "ts-native-test")
        // DeepSeek is not in the fake CodexBar config, so it must NOT leak the OpenRouter key
        #expect(AssistantConfig.loadAmbientAPIKey(forBaseURL: "https://api.deepseek.com/v1", configURL: tempURL) == nil)
    }

    @Test("Explicitly saved localhost:3425 and 127.0.0.1:3425 custom endpoints survive save/load round-trip and share effective config between Test AI and command execution")
    @MainActor
    func customPort3425RoundTripAndProviderKeyIsolation() async throws {
        let suite = "test.assistant.port3425.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Seed an OpenRouter key in the same defaults suite to ensure custom endpoints never resolve OpenRouter's key.
        AssistantConfig(
            baseURL: "https://openrouter.ai/api/v1",
            model: "~typesafe/jev-latest",
            apiKey: "sk-or-wrong-provider-key"
        ).save(to: defaults)

        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: Self.devices, scenes: Self.scenes))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        for customURL in ["http://127.0.0.1:3425/v1", "http://localhost:3425/v1"] {
            var observedURLs: [String] = []
            var observedAuths: [String] = []
            var observedModels: [String] = []

            store.assistantTransportOverride = { request in
                let urlString = request.url?.absoluteString ?? ""
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let model = body?["model"] as? String ?? ""
                await MainActor.run {
                    observedURLs.append(urlString)
                    observedAuths.append(auth)
                    observedModels.append(model)
                }
                let content = #"{"actions":[{"device":"d1","op":"power","value":true}],"reply":"已打开书房灯"}"#
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

            let draft = AssistantConfig(
                baseURL: customURL,
                model: "local-custom-model",
                apiKey: "sk-local-3425-key"
            )

            // 1. Test AI persists and verifies via the reloaded store.assistantConfig
            let testResult = await store.verifyAssistantConfig(draft)
            #expect(testResult.isSuccess == true)

            // 2. Reopening settings / restarting app loads the exact custom endpoint, model, and custom provider key
            let reloaded = AssistantConfig.load(from: defaults, includeAmbientKey: false)
            #expect(reloaded.baseURL == customURL)
            #expect(reloaded.model == "local-custom-model")
            #expect(reloaded.preset == .custom)
            #expect(reloaded.apiKey == "sk-local-3425-key")
            #expect(reloaded.isLoopbackEndpoint == true)
            #expect(store.assistantConfig.baseURL == customURL)
            #expect(store.assistantConfig.model == "local-custom-model")
            #expect(store.assistantConfig.apiKey == "sk-local-3425-key")
            #expect(AssistantConfig.userStoredAPIKey(forBaseURL: customURL, defaults: defaults) == "sk-local-3425-key")

            // 3. Running an AI-fallback command uses the exact same endpoint, model, and credentials as Test AI
            let plan = try #require(await store.runAssistantCommand("我要睡觉了"))
            #expect(plan.source == .model)
            #expect(observedURLs == ["\(customURL)/chat/completions", "\(customURL)/chat/completions"])
            #expect(observedAuths == ["Bearer sk-local-3425-key", "Bearer sk-local-3425-key"])
            #expect(observedModels == ["local-custom-model", "local-custom-model"])
        }
    }

    // MARK: - Live (opt-in)

    @Test("ModelIntentResolver resolves against live OpenRouter ~typesafe/jev-latest when ASSISTANT_RUN_LIVE_TEST=1")
    func liveModelResolver() async throws {
        guard ProcessInfo.processInfo.environment["ASSISTANT_RUN_LIVE_TEST"] == "1" else { return }
        let key = try #require(AssistantConfig.loadCodexBarOpenRouterKey())
        let resolver = ModelIntentResolver(config: AssistantConfig(apiKey: key))
        let clock = ContinuousClock()
        let start = clock.now
        let plan = try await resolver.resolve("书房来点柔和月光", devices: Self.devices, scenes: Self.scenes)
        let elapsed = clock.now - start
        print("ASSISTANT_LIVE_JEV latency=\(elapsed) intents=\(plan.intents) reply=\(plan.reply)")
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night"))
        ])
    }
}
