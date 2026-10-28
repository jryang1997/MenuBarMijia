import Foundation
import Testing
@testable import MijiaCore

struct AssistantReceiptLocalizationTests {
    private let device = SmartDevice(
        id: "study", name: "书房灯", roomId: "study", roomName: "书房",
        model: "test.light", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: true))
    )

    private func reply(_ operation: IntentOperation) -> String {
        IntentReply.describe([DeviceIntent(targetId: device.id, operation: operation)], devices: [device], scenes: [])
    }

    @Test("Receipts translate fixed text while preserving user device names")
    func receiptLanguages() {
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(reply(.power(true)) == "已開啟书房灯")
            #expect(reply(.power(false)) == "已關閉书房灯")
            #expect(reply(.brightness(30)) == "已书房灯亮度調至 30%")
            #expect(reply(.fanSpeed("high")) == "已书房灯風速調為高檔")
            #expect(reply(.oscillation(false)) == "已书房灯關閉搖頭")
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(reply(.power(true)) == "已打开书房灯")
            #expect(reply(.brightness(30)) == "已书房灯亮度调至 30%")
            #expect(reply(.fanSpeed("Level3")) == "已书房灯风速调为 3 档")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(reply(.power(true)) == "Turned on 书房灯")
            #expect(reply(.brightness(30)) == "Set 书房灯 brightness to 30%")
            #expect(reply(.fanSpeed("Level3")) == "Set 书房灯 fan speed to Level 3")
        }
    }

    @Test("Absolute temperatures follow the display unit and temperature differences omit the offset")
    func temperatureReceipts() {
        L10n.$overrideLanguage.withValue(.en) {
            L10n.$overrideTemperatureUnit.withValue(.celsius) {
                #expect(reply(.targetTemperature(24)) == "Set 书房灯 to 24°C")
                #expect(reply(.temperatureStep(-2)) == "Decreased 书房灯 temp by 2°C")
            }
            L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
                #expect(reply(.targetTemperature(24)) == "Set 书房灯 to 75.2°F")
                #expect(reply(.temperatureStep(-2)) == "Decreased 书房灯 temp by 3.6°F")
            }
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
                #expect(reply(.targetTemperature(24)) == "已书房灯設為 75.2°F")
                #expect(reply(.temperatureStep(2)) == "已书房灯溫度調高 3.6°F")
            }
        }
    }

    @Test("Scene names retain literal text and operation labels translate")
    func sceneAndModeReceipts() {
        let scene = HomeScene(id: "movie", name: "观影", entityId: "scene.movie")
        L10n.$overrideLanguage.withValue(.en) {
            #expect(IntentReply.describe([DeviceIntent(targetId: scene.id, operation: .activateScene)], devices: [], scenes: [scene]) == "Activated scene \"观影\"")
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(IntentReply.describe([DeviceIntent(targetId: scene.id, operation: .activateScene)], devices: [], scenes: [scene]) == "已執行場景「观影」")
            #expect(reply(.colorTemperature(4000)) == "已书房灯色溫調至 4000K")
            #expect(reply(.brightnessStep(-10)) == "已书房灯亮度調低 10%")
            #expect(reply(.lightEffect("Night")) == "已书房灯切換為月光模式")
        }
    }

    @Test("Habit suggestions use translated action labels and display temperatures")
    func suggestionLanguages() {
        func title(_ operation: IntentOperation) -> String? {
            UserHabitMemory.suggestionTitle(for: DeviceIntent(targetId: device.id, operation: operation), devices: [device], scenes: [])
        }
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(title(.power(true)) == "開啟书房灯")
            #expect(title(.colorTemperature(4000)) == "书房灯·色溫4000K")
            #expect(title(.hvacMode("heat")) == "书房灯·制熱")
            #expect(title(.oscillation(true)) == "书房灯·搖頭")
            #expect(title(.fanSpeed("Level3")) == "书房灯·風速3 檔")
            L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
                #expect(title(.targetTemperature(24)) == "书房灯·75.2°F")
            }
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(title(.power(false)) == "Turn off 书房灯")
            L10n.$overrideTemperatureUnit.withValue(.celsius) {
                #expect(title(.targetTemperature(24)) == "书房灯 · 24°C")
            }
        }
    }
}
