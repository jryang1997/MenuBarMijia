import Foundation
import Testing
@testable import MijiaCore

struct LocalizationTests {
    // MARK: - Fixtures

    /// The shipped resource tables, located relative to this file so the tests read the real files
    /// that `Package.swift` copies into the app (#52).
    static var shippedTablesDirectory: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Sources/MijiaCore/Resources/Localizations")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// A throwaway directory of tables used to prove a *new* language needs no Swift change.
    static func withTemporaryTables<T>(
        _ files: [String: String],
        _ body: (URL) throws -> T
    ) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("L10nTables.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, json) in files {
            try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return try L10n.$overrideTranslationDirectory.withValue(dir) { try body(dir) }
    }

    static let frenchTable = """
    {
      "id": "fr",
      "nativeName": "Français",
      "speechLocale": "fr-FR",
      "order": 20,
      "strings": {
        "已关闭": "Éteint",
        "跟随系统": "Système",
        "已同步 * 台真实米家设备": "J'ai synchronisé * appareils",
        "亮度 %@": "Luminosité %@"
      }
    }
    """

    // MARK: - Language detection

    @Test("AppLanguage detects Chinese vs English system locales")
    func systemLanguageDetection() {
        let tables = Self.shippedTablesDirectory
        L10n.$overrideTranslationDirectory.withValue(tables) {
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["zh-Hans-CN", "en-US"]) == .zhHans)
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["zh-Hant-HK"]) == .zhHant)
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["zh-TW"]) == .zhHant)
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["en-US", "zh-Hans"]) == .en)
            #expect(AppLanguage.detectSystemLanguage(preferredLanguages: ["fr-FR"]) == .en)
            #expect(AppLanguagePreference.system.resolved(preferredLanguages: ["en-GB"]) == .en)
            #expect(AppLanguagePreference.zhHans.resolved(preferredLanguages: ["en-US"]) == .zhHans)
            #expect(AppLanguagePreference.en.resolved(preferredLanguages: ["zh-Hans"]) == .en)
            #expect(AppLanguagePreference(rawValue: "zh-Hant")?.resolved(preferredLanguages: ["en-US"]) == .zhHant)
        }
    }

    @Test("Language tags are canonicalised and unsupported preferences fall back")
    func tagCanonicalisation() {
        #expect(AppLanguage(rawValue: "zh_hant_tw").rawValue == "zh-Hant-TW")
        #expect(AppLanguage(rawValue: "EN").rawValue == "en")
        #expect(AppLanguage(rawValue: "  ").rawValue == "en")
        #expect(AppLanguage.zhHant.isChinese)
        #expect(!AppLanguage.en.isChinese)
        #expect(AppLanguagePreference(rawValue: "system") == .system)
        #expect(AppLanguagePreference(rawValue: "not a tag") == nil)
        // A saved tag whose table is missing is kept, so reinstalling the table restores the choice.
        #expect(AppLanguagePreference(rawValue: "ja-JP")?.rawValue == "ja-JP")
        #expect(AppLanguagePreference(rawValue: "ja-JP")?.resolved(preferredLanguages: ["en-US"]) == .en)
    }

    // MARK: - Resources

    @Test("Packaged tables are found without a source-directory override")
    func packagedTablesAreDiscovered() {
        #expect(L10n.availableLanguages.contains(.zhHant))
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(L10n.tr("已关闭", "Off") == "已關閉")
        }
    }

    @Test("Shipped tables are found and listed without Swift cases")
    func shippedTablesAreDiscovered() throws {
        let dir = Self.shippedTablesDirectory
        let tableURL = dir.appendingPathComponent("zh-Hant.json")
        #expect(FileManager.default.fileExists(atPath: tableURL.path))

        let data = try Data(contentsOf: tableURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["id"] as? String == "zh-Hant")
        #expect(json["nativeName"] as? String == "繁體中文")
        let strings = try #require(json["strings"] as? [String: String])
        #expect(strings.count > 500, "the table should cover the inline tr() call sites")
        // Spot-check that the table really translates rather than echoing Simplified Chinese.
        #expect(strings["已关闭"] == "已關閉")
        #expect(strings["跟随系统"] == "跟隨系統")
        #expect(strings["当前室温 %@"] == "當前室溫 %@")

        L10n.$overrideTranslationDirectory.withValue(dir) {
            #expect(L10n.availableLanguages.contains(.zhHant))
            #expect(L10n.availableLanguages.prefix(2) == [.zhHans, .en])
            #expect(L10n.nativeName(for: .zhHant) == "繁體中文")
            #expect(L10n.speechLocaleIdentifier(for: .zhHant) == "zh-TW")
            L10n.$overrideLanguage.withValue(.zhHans) {
                #expect(L10n.tr("已关闭", "Off") == "已关闭")
            }
            L10n.$overrideLanguage.withValue(.en) {
                #expect(L10n.tr("已关闭", "Off") == "Off")
            }
        }
    }

    @Test("Adding a language is a resource file, not a Swift change")
    func newLanguageFromResourceOnly() throws {
        try Self.withTemporaryTables(["fr.json": Self.frenchTable]) { _ in
            #expect(L10n.availableLanguages.contains(AppLanguage(rawValue: "fr")))
            #expect(AppLanguagePreference.allCases.contains(AppLanguagePreference(rawValue: "fr")!))
            #expect(AppLanguagePreference(rawValue: "fr")?.resolved(preferredLanguages: ["en-US"]) == AppLanguage(rawValue: "fr"))
            #expect(AppLanguagePreference(rawValue: "fr-CA")?.resolved(preferredLanguages: ["en-US"]) == AppLanguage(rawValue: "fr"))
            #expect(L10n.nativeName(for: AppLanguage(rawValue: "fr")) == "Français")
            #expect(L10n.speechLocaleIdentifier(for: AppLanguage(rawValue: "fr")) == "fr-FR")

            L10n.$overrideLanguage.withValue(AppLanguage(rawValue: "fr")) {
                #expect(L10n.tr("已关闭", "Off") == "Éteint")
                #expect(L10n.tr("跟随系统", "System Default") == "Système")
                // A string the table does not carry falls back to English, never to an empty label.
                #expect(L10n.tr("打开设置", "Open Settings") == "Open Settings")
                // `*` patterns absorb the interpolated part.
                #expect(L10n.tr("已同步 5 台真实米家设备", "Synced 5 devices") == "J'ai synchronisé 5 appareils")
                // Positional `%@` is filled from the arguments, not `String(format:)`.
                #expect(L10n.format("亮度 %@", "Brightness %@", "60") == "Luminosité 60")
            }
        }
    }

    @Test("Chinese tables fall back to Simplified Chinese, not English")
    func chineseFallback() throws {
        try Self.withTemporaryTables([
            "zh-Hant.json": """
            { "id": "zh-Hant", "nativeName": "繁體中文", "speechLocale": "zh-TW",
              "strings": { "已关闭": "已關閉" } }
            """
        ]) { _ in
            L10n.$overrideLanguage.withValue(.zhHant) {
                #expect(L10n.tr("已关闭", "Off") == "已關閉")
                // Missing from the Traditional table: Chinese text, not the English one.
                #expect(L10n.tr("打开设置", "Open Settings") == "打开设置")
            }
        }
    }

    @Test("Malformed or empty tables are ignored instead of breaking the picker")
    func malformedTablesIgnored() throws {
        try Self.withTemporaryTables([
            "broken.json": "{ not json",
            "empty.json": #"{ "id": "de", "strings": {} }"#,
            "notes.txt": "ignored",
        ]) { _ in
            let languages = L10n.availableLanguages
            #expect(languages.prefix(2) == [.zhHans, .en])
            #expect(languages.contains(AppLanguage(rawValue: "de")))
            #expect(!languages.contains(AppLanguage(rawValue: "broken")))
            L10n.$overrideLanguage.withValue(AppLanguage(rawValue: "de")) {
                #expect(L10n.tr("已关闭", "Off") == "Off")
            }
        }
    }

    @Test("Translation directories are discovered through the documented bundle names")
    func directoryDiscovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("L10nBundle.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root
            .appendingPathComponent("MenuBarMijia_MijiaCore.bundle/Contents/Resources/Localizations")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try #"{ "id": "nl", "strings": { "已关闭": "Uit" } }"#
            .write(to: nested.appendingPathComponent("nl.json"), atomically: true, encoding: .utf8)

        let candidates = [
            root.appendingPathComponent("MenuBarMijia_MijiaCore.bundle/Contents/Resources/Localizations"),
            root.appendingPathComponent("MenuBarMijia_MijiaCore.bundle/Localizations"),
        ]
        #expect(L10n.firstTranslationDirectory(in: candidates)?.path == nested.path)
        var visited: [URL] = []
        let lazyCandidates = candidates.lazy.map { candidate in
            visited.append(candidate)
            return candidate
        }
        #expect(L10n.firstTranslationDirectory(in: lazyCandidates)?.path == nested.path)
        #expect(visited == [candidates[0]])
        // A base directory with no tables at all yields nothing rather than a wrong path.
        #expect(L10n.firstTranslationDirectory(in: [root.appendingPathComponent("Missing")]) == nil)
        // Package-specific names are recognised (`<Package>_MijiaCore.bundle|.resources`).
        #expect(L10n.resourceDirectoryNames(in: root).contains("MenuBarMijia_MijiaCore.bundle"))
    }

    @Test("Numeric runs collapse so one table entry serves every value")
    func numericNormalisation() {
        #expect(L10n.normalizedNumbers("已同步 12 台设备") == "已同步 # 台设备")
        #expect(L10n.normalizedNumbers("室温 26.5°C") == "室温 #°C")
        #expect(L10n.normalizedNumbers("当前设定 25°C，请确认") == "当前设定 #°C，请确认")
        #expect(L10n.normalizedNumbers("没有数字") == "没有数字")
        #expect(L10n.captures(pattern: "已同步 * 台设备", against: "已同步 12 台设备") == ["12"])
        #expect(L10n.captures(pattern: "已同步 * 台设备", against: "别的句子") == nil)
        #expect(L10n.fill("亮度 *%（*）", with: ["60", "书房"]) == "亮度 60%（书房）")
    }

    @Test("Traditional Chinese timer descriptions use the shipped resource table")
    func traditionalTimerDescriptions() {
        L10n.$overrideLanguage.withValue(.zhHant) {
            #expect(DelayPhrase.describe(30) == "30 秒後")
            #expect(DelayPhrase.describe(600) == "10 分鐘後")
            #expect(DelayPhrase.describe(3600) == "1 小時後")
            #expect(DelayPhrase.describe(5400) == "1 小時 30 分鐘後")
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(DelayPhrase.describe(30) == "30 秒后")
            #expect(DelayPhrase.describe(600) == "10 分钟后")
            #expect(DelayPhrase.describe(3600) == "1 小时后")
            #expect(DelayPhrase.describe(5400) == "1 小时 30 分钟后")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(DelayPhrase.describe(30) == "In 30s: ")
            #expect(DelayPhrase.describe(600) == "In 10m: ")
            #expect(DelayPhrase.describe(3600) == "In 1h: ")
            #expect(DelayPhrase.describe(5400) == "In 1h 30m: ")
        }
    }

    // MARK: - Temperature units

    @Test(
        "Display unit follows the system region, never the stored value",
        arguments: zip(
            [
                "en-US", "en_US", "zh-Hans-CN", "zh-Hant-TW", "de-DE",
                "my-MM", "en", "en-u-ca-gregory", "en-US@calendar=gregorian",
            ],
            [
                TemperatureUnit.fahrenheit, .fahrenheit, .celsius, .celsius, .celsius,
                .fahrenheit, .celsius, .celsius, .fahrenheit,
            ]
        )
    )
    func unitFromLocale(identifier: String, expected: TemperatureUnit) {
        #expect(TemperatureUnit.resolved(localeIdentifier: identifier) == expected)
        #expect(TemperatureUnitPreference.system.resolved(localeIdentifier: identifier) == expected)
        #expect(TemperatureUnitPreference.celsius.resolved(localeIdentifier: identifier) == .celsius)
        #expect(TemperatureUnitPreference.fahrenheit.resolved(localeIdentifier: identifier) == .fahrenheit)
    }

    @Test("Celsius values render in the display unit without touching the stored value")
    func temperatureFormatting() {
        L10n.$overrideTemperatureUnit.withValue(.celsius) {
            #expect(L10n.temperature(24) == "24°C")
            #expect(L10n.temperature(26.5, fractionDigits: 1) == "26.5°C")
            #expect(L10n.temperatureValue(26.5, fractionDigits: 1) == "26.5")
            #expect(L10n.temperatureSymbol == "°C")
            #expect(L10n.temperatureNumber(24) == 24)
        }
        L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
            #expect(L10n.temperature(0) == "32°F")
            #expect(L10n.temperature(100) == "212°F")
            #expect(L10n.temperature(24) == "75°F")
            #expect(L10n.temperatureSymbol == "°F")
            // Round-tripping a Fahrenheit reading must return the original Celsius value.
            #expect(abs(L10n.celsiusValue(displayValue: 77) - 25) < 0.0001)
            #expect(abs(L10n.celsiusValue(displayValue: L10n.temperatureNumber(21.5)) - 21.5) < 0.0001)
        }
    }

    @Test("Thermostat steps stay Celsius in the core and 1°F per tap in Fahrenheit")
    func temperatureSteps() {
        L10n.$overrideTemperatureUnit.withValue(.celsius) {
            #expect(L10n.celsiusStep(0.5) == 0.5)
            #expect(L10n.celsiusDelta(displayDelta: 2) == 2)
        }
        L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
            #expect(abs(L10n.celsiusStep(0.5) - 5.0 / 9.0) < 0.0001)
            #expect(abs(L10n.celsiusDelta(displayDelta: 1) - 5.0 / 9.0) < 0.0001)
            // A step keeps the delta a whole Fahrenheit degree, even though the core is Celsius.
            let start = 24.0
            let stepped = start + L10n.celsiusStep(0.5)
            #expect(abs((L10n.temperatureNumber(stepped) - L10n.temperatureNumber(start)) - 1) < 0.0001)
        }
    }

    @Test("The unit preference persists and is read back")
    func temperaturePreferencePersistence() throws {
        let suiteName = "LocalizationTests.units.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TemperatureUnitPreference.stored(in: defaults) == .system)
        TemperatureUnitPreference.fahrenheit.store(in: defaults)
        #expect(defaults.string(forKey: TemperatureUnitPreference.storageKey) == "fahrenheit")
        #expect(TemperatureUnitPreference.stored(in: defaults) == .fahrenheit)
        // An unknown stored value degrades to the system choice instead of crashing.
        defaults.set("kelvin", forKey: TemperatureUnitPreference.storageKey)
        #expect(TemperatureUnitPreference.stored(in: defaults) == .system)

        defaults.removeObject(forKey: TemperatureUnitPreference.storageKey)
        #expect(TemperatureUnitPreference.allCases.map(\.rawValue) == ["system", "celsius", "fahrenheit"])
    }

    // MARK: - Existing inline API

    @Test("L10n translates strings, room names, and device subtitles in English mode")
    func englishFormatting() {
        L10n.$overrideLanguage.withValue(.en) {
            #expect(L10n.tr("书房", "Study") == "Study")
            #expect(L10n.displayRoomName("书房") == "Study")
            #expect(L10n.displayRoomName("客厅") == "Living Room")
            #expect(L10n.displayRoomName("主卧") == "Master Bedroom")
            #expect(L10n.displayRoomName("CustomRoom") == "CustomRoom")

            let light = SmartDevice(
                id: "dev_light",
                name: "Study Ceiling Light",
                roomId: "study",
                roomName: "书房",
                model: "yeelink.light.ceiling20",
                isOnline: true,
                kind: .light(LightSpec(
                    entityId: "light.study",
                    isOn: true,
                    brightnessPercent: 75,
                    colorTempKelvin: 4000,
                    currentEffect: "Night",
                    availableEffects: ["Day", "Night"]
                ))
            )
            #expect(light.statusSubtitle.contains("Moonlight"))
            #expect(light.statusSubtitle.contains("75%"))

            let ac = SmartDevice(
                id: "dev_ac",
                name: "Living Room AC",
                roomId: "living",
                roomName: "客厅",
                model: "xiaomi.aircondition.mt0",
                isOnline: true,
                kind: .climate(ClimateSpec(
                    entityId: "climate.ac",
                    isOn: true,
                    hvacMode: "cool",
                    availableModes: ["off", "cool", "heat"],
                    targetTemperature: 24.0,
                    currentTemperature: 26.0
                ))
            )
            #expect(ac.statusSubtitle.contains("Cool"))
        }
    }

    @Test("Device subtitles follow the display unit while the model stays Celsius")
    func subtitleUsesDisplayUnit() {
        let ac = SmartDevice(
            id: "dev_ac", name: "AC", roomId: "living", roomName: "客厅",
            model: "xiaomi.aircondition.mt0", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.ac", isOn: true, hvacMode: "cool",
                availableModes: ["cool"], targetTemperature: 25.0, currentTemperature: 22.0
            ))
        )
        let sensor = SmartDevice(
            id: "dev_sensor", name: "Sensor", roomId: "living", roomName: "客厅",
            model: "miaomiaoce.sensor_ht.t2", isOnline: true,
            kind: .sensor(SensorSpec(temperature: 22.0, humidity: 48))
        )
        L10n.$overrideLanguage.withValue(.zhHans) {
            L10n.$overrideTemperatureUnit.withValue(.celsius) {
                #expect(ac.statusSubtitle.contains("25°C"))
                #expect(ac.statusSubtitle.contains("22°C"))
                #expect(sensor.statusSubtitle == "22.0°C · 48%")
            }
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
                #expect(ac.statusSubtitle.contains("77°F"))
                #expect(ac.statusSubtitle.contains("72°F"))
                #expect(sensor.statusSubtitle == "71.6°F · 48%")
                // The underlying spec is untouched.
                guard case .climate(let spec) = ac.kind else { return }
                #expect(spec.targetTemperature == 25.0)
            }
        }
    }

    @Test("LocalIntentParser parses English smart home commands and replies in English")
    func englishLocalIntentParsing() throws {
        try L10n.$overrideLanguage.withValue(.en) {
            let onPlan = try #require(AssistantTests.parse("turn on study light"))
            #expect(onPlan.source == .local)
            #expect(onPlan.intents == [
                DeviceIntent(targetId: "dev_study_ceiling", operation: .power(true)),
                DeviceIntent(targetId: "dev_study_desk", operation: .power(true))
            ])
            #expect(onPlan.reply == "Turned on 书房吸顶灯, 书房台灯")

            let moonPlan = try #require(AssistantTests.parse("study light moonlight mode"))
            #expect(moonPlan.intents == [
                DeviceIntent(targetId: "dev_study_ceiling", operation: .lightEffect("Night"))
            ])
            #expect(moonPlan.reply == "Switched 书房吸顶灯 to Moonlight mode")

            let tempPlan = try #require(L10n.$overrideTemperatureUnit.withValue(.celsius) {
                AssistantTests.parse("set living room ac to 24 degrees")
            })
            #expect(tempPlan.intents == [
                DeviceIntent(targetId: "dev_living_ac", operation: .targetTemperature(24))
            ])
            #expect(tempPlan.reply == "Set 客厅空调 to 24°C")
            let fahrenheitPlan = try #require(L10n.$overrideTemperatureUnit.withValue(.fahrenheit) {
                AssistantTests.parse("set living room ac to 24 degrees")
            })
            #expect(fahrenheitPlan.intents == tempPlan.intents)
            #expect(fahrenheitPlan.reply == "Set 客厅空调 to 75.2°F")

            let coolPlan = try #require(AssistantTests.parse("living room ac cool mode"))
            #expect(coolPlan.intents == [
                DeviceIntent(targetId: "dev_living_ac", operation: .hvacMode("cool"))
            ])
            #expect(coolPlan.reply == "Switched 客厅空调 to Cool")

            let dimPlan = try #require(AssistantTests.parse("dimmer"))
            #expect(dimPlan.intents == [
                DeviceIntent(targetId: "dev_bedside", operation: .brightness(60))
            ])
        }
    }

    @Test("DelayPhrase and UndoPhrase support English spoken timers and undo commands")
    func englishDelayAndUndoPhrases() throws {
        try L10n.$overrideLanguage.withValue(.en) {
            let match = try #require(DelayPhrase.extract("in 10 minutes turn off study light"))
            #expect(match.delay == 600)
            #expect(match.remainder == "turn off study light")
            #expect(DelayPhrase.describe(match.delay) == "In 10m: ")

            let secMatch = try #require(DelayPhrase.extract("after 30 seconds turn on bedside lamp"))
            #expect(secMatch.delay == 30)
            #expect(secMatch.remainder == "turn on bedside lamp")

            #expect(DelayPhrase.isCancel("cancel timer"))
            #expect(DelayPhrase.isCancel("clear all timers"))
            #expect(UndoPhrase.isUndo("undo"))
            #expect(UndoPhrase.isUndo("undo that"))
            #expect(UndoPhrase.isUndo("revert"))
        }
    }

    // MARK: - Persistence

    @Test("HomeStore persists appLanguagePreference and miCloudRegion")
    @MainActor
    func homeStoreLanguageAndRegionPersistence() throws {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suiteName)
        #expect(store.appLanguagePreference == .system)
        #expect(store.miCloudRegion == .cn)

        store.appLanguagePreference = .en
        store.miCloudRegion = .sg
        #expect(store.effectiveLanguage == .en)
        #expect(store.homeName == "My Home")
        #expect(defaults.string(forKey: "app_language") == "en")
        #expect(defaults.string(forKey: "mi_cloud_region") == "sg")

        store.appLanguagePreference = .zhHans
        #expect(store.effectiveLanguage == .zhHans)
        #expect(store.homeName == "我的家")

        // Traditional Chinese is a first-class stored preference now (#52).
        store.appLanguagePreference = .zhHant
        #expect(store.effectiveLanguage == .zhHant)
        #expect(defaults.string(forKey: "app_language") == "zh-Hant")
        #expect(AppLanguagePreference(rawValue: defaults.string(forKey: "app_language") ?? "") == .zhHant)
    }
}
