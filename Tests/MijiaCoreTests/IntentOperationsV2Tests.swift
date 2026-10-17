import Foundation
import Testing
@testable import MijiaCore

/// 方案 v1 第 2 步：相对调节（再暗一点 / 调高两度）、风扇档位与摇头。
struct IntentOperationsV2Tests {
    static let bedside = SmartDevice(
        id: "dev_bedside", name: "主卧床头灯", roomId: "zhu_wo", roomName: "主卧",
        model: "yeelink.light.bslamp2", isOnline: true,
        kind: .light(LightSpec(entityId: "light.bedside", isOn: true, brightnessPercent: 80))
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
            entityId: "climate.living_ac", isOn: true, hvacMode: "cool",
            availableModes: ["off", "cool", "heat"], targetTemperature: 26,
            minTemp: 16, maxTemp: 30,
            fanMode: "auto", availableFanModes: ["auto", "low", "medium", "high"]
        ))
    )
    static let fan = SmartDevice(
        id: "dev_fan", name: "客厅风扇", roomId: "ke_ting", roomName: "客厅",
        model: "dmaker.fan.p5", isOnline: true,
        kind: .fan(FanSpec(
            entityId: "fan.living", isOn: true, presetMode: "Level1",
            availablePresetModes: ["Level1", "Level2", "Level3"], isOscillating: false
        ))
    )
    static let devices = [bedside, studyDesk, livingAC, fan]

    static func parse(_ text: String) -> IntentPlan? {
        LocalIntentParser.parse(text, devices: devices, scenes: [])
    }

    // MARK: - 相对亮度

    @Test("床头灯暗一点 lowers brightness by 20 from the current level")
    func dimmerByStep() throws {
        let plan = try #require(Self.parse("床头灯暗一点"))
        #expect(plan.intents == [DeviceIntent(targetId: "dev_bedside", operation: .brightness(60))])
        #expect(plan.reply == "已主卧床头灯亮度调至 60%")
    }

    @Test("再暗一点 without a target picks all lights that are currently on")
    func dimmerTargetsTheLitLight() throws {
        let plan = try #require(Self.parse("再暗一点"))
        #expect(plan.intents == [DeviceIntent(targetId: "dev_bedside", operation: .brightness(60))])
        let brighter = try #require(Self.parse("亮一点"))
        #expect(brighter.intents == [DeviceIntent(targetId: "dev_bedside", operation: .brightness(100))])

        // When multiple lights are currently on, "再暗一点" dims all active lights without touching off lights.
        let activeDesk = SmartDevice(
            id: "dev_study_desk", name: "书房台灯", roomId: "shu_fang", roomName: "书房",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.study_desk", isOn: true, brightnessPercent: 50))
        )
        let extraOffLight = SmartDevice(
            id: "dev_hall", name: "玄关灯", roomId: "xuan_guan", roomName: "玄关",
            model: "yeelink.light.ceiling1", isOnline: true,
            kind: .light(LightSpec(entityId: "light.hall", isOn: false, brightnessPercent: 100))
        )
        let multiOnDevices = [Self.bedside, activeDesk, extraOffLight, Self.livingAC, Self.fan]
        let multiPlan = try #require(LocalIntentParser.parse("再暗一点", devices: multiOnDevices, scenes: []))
        #expect(multiPlan.intents == [
            DeviceIntent(targetId: "dev_bedside", operation: .brightness(60)),
            DeviceIntent(targetId: "dev_study_desk", operation: .brightness(30))
        ])
    }

    @Test("Brightness steps clamp to 1...100 and start from 0 when the light is off")
    func brightnessStepClamps() {
        #expect(IntentValidator.normalize(.brightnessStep(-200), for: Self.bedside) == .brightness(1))
        #expect(IntentValidator.normalize(.brightnessStep(30), for: Self.studyDesk) == .brightness(30))
        #expect(IntentValidator.normalize(.brightnessStep(10), for: Self.livingAC) == nil)
    }

    // MARK: - 相对温度

    @Test("空调调高两度 / 温度低一点 adjust the target temperature relatively")
    func temperatureSteps() throws {
        let up = try #require(Self.parse("空调调高两度"))
        #expect(up.intents == [DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(28))])
        #expect(up.reply == "已客厅空调设为 28°C")
        let down = try #require(Self.parse("空调温度低一点"))
        #expect(down.intents == [DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(25))])
        let clamp = IntentValidator.normalize(.temperatureStep(10), for: Self.livingAC)
        #expect(clamp == .targetTemperature(30))
    }

    // MARK: - 风扇档位与摇头

    @Test("Fan speed words map onto the device's own preset list by rank")
    func fanSpeedByRank() throws {
        #expect(IntentValidator.normalize(.fanSpeed("high"), for: Self.fan) == .fanSpeed("Level3"))
        #expect(IntentValidator.normalize(.fanSpeed("低"), for: Self.fan) == .fanSpeed("Level1"))
        #expect(IntentValidator.normalize(.fanSpeed("medium"), for: Self.fan) == .fanSpeed("Level2"))
        #expect(IntentValidator.normalize(.fanSpeed("Level2"), for: Self.fan) == .fanSpeed("Level2"))
        #expect(IntentValidator.normalize(.fanSpeed("high"), for: Self.livingAC) == .fanSpeed("high"))
        #expect(IntentValidator.normalize(.fanSpeed("自动"), for: Self.livingAC) == .fanSpeed("auto"))
        #expect(IntentValidator.normalize(.fanSpeed("turbo"), for: Self.fan) == nil)

        let plan = try #require(Self.parse("风扇调到高档"))
        #expect(plan.intents == [DeviceIntent(targetId: "dev_fan", operation: .fanSpeed("Level3"))])
        #expect(plan.reply == "已客厅风扇风速调为 3 档")
        let ac = try #require(Self.parse("空调风速调低"))
        #expect(ac.intents == [DeviceIntent(targetId: "dev_living_ac", operation: .fanSpeed("low"))])
    }

    @Test("风扇摇头 / 停止摇头 toggle oscillation")
    func oscillation() throws {
        let on = try #require(Self.parse("风扇摇头"))
        #expect(on.intents == [DeviceIntent(targetId: "dev_fan", operation: .oscillation(true))])
        #expect(on.reply == "已客厅风扇开启摇头")
        let off = try #require(Self.parse("风扇停止摇头"))
        #expect(off.intents == [DeviceIntent(targetId: "dev_fan", operation: .oscillation(false))])
    }

    // MARK: - 大模型输出

    @Test("Model actions brightness_step / temperature_step / fan_speed / oscillation are understood")
    func modelOperations() throws {
        let catalog = IntentCatalog(devices: Self.devices, scenes: [])
        let json = """
        {"actions":[{"device":"d1","op":"brightness_step","value":-20},
        {"device":"d3","op":"temperature_step","value":-1},
        {"device":"d4","op":"fan_speed","value":"high"},
        {"device":"d4","op":"oscillation","value":true}],"reply":"好的"}
        """
        let plan = try ModelIntentResolver.plan(fromModelContent: json, catalog: catalog, devices: Self.devices, scenes: [])
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_bedside", operation: .brightness(60)),
            DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(25)),
            DeviceIntent(targetId: "dev_fan", operation: .fanSpeed("Level3")),
            DeviceIntent(targetId: "dev_fan", operation: .oscillation(true))
        ])
        #expect(ModelIntentResolver.systemPrompt(catalog: catalog).contains("brightness_step"))

        // Jev /v1/systemone also supports relative step, fan speed, and oscillation choices
        let systemOneData = try JSONSerialization.data(withJSONObject: [
            "answers": [
                "target": ["choice": "d4", "confidence": 0.96],
                "op": ["choice": "fan_high", "confidence": 0.94],
                "temp": ["choice": "none", "confidence": 0.99],
                "dev_d1": ["choice": "bri_down_20", "confidence": 0.88]
            ]
        ])
        let jevPlan = try ModelIntentResolver.planFromSystemOne(
            data: systemOneData,
            catalog: catalog,
            devices: Self.devices,
            scenes: []
        )
        #expect(jevPlan.intents == [
            DeviceIntent(targetId: "dev_fan", operation: .fanSpeed("Level3")),
            DeviceIntent(targetId: "dev_bedside", operation: .brightness(60))
        ])
    }

    // MARK: - 执行

    @Test("runAssistantCommand dispatches fan speed and oscillation commands")
    @MainActor
    func dispatchFanCommands() async throws {
        let provider = MockHomeProvider(snapshot: SynthesizedHome(devices: Self.devices, scenes: []))
        let store = HomeStore(provider: provider, defaultsSuiteName: "test.v2.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await store.runAssistantCommand("风扇调到高档")
        _ = await store.runAssistantCommand("风扇摇头")
        let sent = await provider.executedCommands
        #expect(sent.contains(.setFanPresetMode(entityId: "fan.living", presetMode: "Level3")))
        #expect(sent.contains(.setFanOscillating(entityId: "fan.living", oscillating: true)))
    }
}
