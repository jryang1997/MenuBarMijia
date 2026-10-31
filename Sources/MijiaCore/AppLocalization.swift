import Foundation

// MARK: - Temperature Units

/// How temperatures are *displayed*. Every stored value, protocol payload and control step stays in
/// Celsius; `L10n` converts only at the presentation boundary (#52).
public enum TemperatureUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case celsius
    case fahrenheit

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    /// Regions where everyday temperatures are Fahrenheit. Everywhere else, and any identifier
    /// without a region subtag, is Celsius.
    public static let fahrenheitRegionCodes: Set<String> = [
        "US", "PR", "GU", "VI", "AS", "MP", "LR", "MM", "BS", "BZ", "KY", "PW", "FM", "MH"
    ]

    /// Resolves the display unit from a BCP-47 identifier such as `en-US`, `zh-Hans-CN` or `my_MM`.
    /// Parses the identifier instead of asking `Locale.measurementSystem` so macOS and Linux agree.
    public static func resolved(localeIdentifier: String = Locale.current.identifier) -> TemperatureUnit {
        let withoutKeywords = localeIdentifier
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? localeIdentifier
        let subtags = withoutKeywords.split(whereSeparator: { $0 == "-" || $0 == "_" }).dropFirst()
        for subtag in subtags {
            let code = subtag.uppercased()
            // Skip script (4 letters) and variant subtags; the first 2-letter subtag is the region.
            guard code.count == 2, code.allSatisfy({ $0.isLetter }) else { continue }
            return fahrenheitRegionCodes.contains(code) ? .fahrenheit : .celsius
        }
        return .celsius
    }
}

/// A user preference that may defer to the system region.
public enum TemperatureUnitPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case celsius
    case fahrenheit

    /// `UserDefaults` key shared with the settings UI (`@AppStorage`), so a change re-renders panels.
    public static let storageKey = "temperature_unit"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system:
            return L10n.tr("跟随系统", "System Default")
        case .celsius:
            return L10n.tr("摄氏度 (°C)", "Celsius (°C)")
        case .fahrenheit:
            return L10n.tr("华氏度 (°F)", "Fahrenheit (°F)")
        }
    }

    public var label: String { title }

    public func resolved(localeIdentifier: String = Locale.current.identifier) -> TemperatureUnit {
        switch self {
        case .system: return TemperatureUnit.resolved(localeIdentifier: localeIdentifier)
        case .celsius: return .celsius
        case .fahrenheit: return .fahrenheit
        }
    }

    public static func stored(in defaults: UserDefaults = .standard) -> TemperatureUnitPreference {
        defaults.string(forKey: storageKey).flatMap(TemperatureUnitPreference.init(rawValue:)) ?? .system
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

// MARK: - App Language

/// A UI language. Deliberately not an enum: the selectable language list comes from the resource
/// tables in `Resources/Localizations`, so shipping a new language is a resource file, not a Swift
/// change (#52).
public struct AppLanguage: RawRepresentable, Hashable, Identifiable, Codable, Sendable, CaseIterable {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        self.rawValue = trimmed.isEmpty ? "en" : Self.canonical(trimmed)
    }

    public static let zhHans = AppLanguage(rawValue: "zh-Hans")
    public static let zhHant = AppLanguage(rawValue: "zh-Hant")
    public static let en = AppLanguage(rawValue: "en")

    public var id: String { rawValue }

    public var isEnglish: Bool { self == .en }

    /// Chinese readers always get Chinese text, even when a Traditional string is missing.
    public var isChinese: Bool { rawValue.lowercased().hasPrefix("zh") }

    public var nativeName: String { L10n.nativeName(for: self) }

    public var speechLocaleIdentifier: String { L10n.speechLocaleIdentifier(for: self) }

    /// Every language the app can actually show: the two built-in ones plus every resource table.
    public static var allCases: [AppLanguage] { L10n.availableLanguages }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func detectSystemLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        let available = L10n.availableLanguages
        for preferred in preferredLanguages {
            if let match = match(preferred, in: available) { return match }
        }
        return .en
    }

    /// Maps a BCP-47 identifier onto a supported language, honouring the Hant/Hans script and the
    /// TW/HK/MO regions that imply Traditional Chinese.
    static func match(_ identifier: String, in available: [AppLanguage]) -> AppLanguage? {
        let lower = identifier.lowercased()
        guard let languageSubtag = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else {
            return nil
        }
        let code = String(languageSubtag)
        if code == "zh" {
            let traditionalMarkers = ["hant", "-tw", "_tw", "-hk", "_hk", "-mo", "_mo"]
            if traditionalMarkers.contains(where: { lower.contains($0) }),
               let traditional = available.first(where: { $0 == .zhHant }) {
                return traditional
            }
            return available.first(where: { $0 == .zhHans }) ?? available.first(where: { $0.isChinese })
        }
        return available.first { $0.rawValue.lowercased() == code }
            ?? available.first { $0.rawValue.lowercased().hasPrefix(code + "-") }
    }

    /// `zh_hant_tw` → `zh-Hant-TW`, `EN` → `en`.
    static func canonical(_ raw: String) -> String {
        let parts = raw.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = parts.first else { return "en" }
        var result = [String(first).lowercased()]
        for part in parts.dropFirst() {
            let text = String(part)
            if text.count == 4 {
                result.append(text.prefix(1).uppercased() + text.dropFirst().lowercased())
            } else if text.count == 2 {
                result.append(text.uppercased())
            } else {
                result.append(text)
            }
        }
        return result.joined(separator: "-")
    }
}

/// The language picker's value: follow the system, or pin one language by its identifier.
public struct AppLanguagePreference: RawRepresentable, Hashable, Identifiable, Codable, Sendable, CaseIterable {
    public let rawValue: String

    private init(pinned rawValue: String) {
        self.rawValue = rawValue
    }

    /// A saved choice is kept when it still looks like a language tag, even if that language's
    /// resource table is missing right now; anything else falls back to the system choice.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        if trimmed == "system" {
            self.init(pinned: "system")
            return
        }
        guard !trimmed.isEmpty else { return nil }
        if let language = AppLanguage.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            self.init(pinned: language.rawValue)
            return
        }
        let canonical = AppLanguage.canonical(trimmed)
        let primary = canonical.split(separator: "-").first.map(String.init) ?? ""
        guard (2...3).contains(primary.count), primary.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }
        self.init(pinned: canonical)
    }

    public init(_ language: AppLanguage) {
        self.init(pinned: language.rawValue)
    }

    public static let system = AppLanguagePreference(pinned: "system")
    public static let zhHans = AppLanguagePreference(.zhHans)
    public static let zhHant = AppLanguagePreference(.zhHant)
    public static let en = AppLanguagePreference(.en)

    /// System first, then the built-in languages, then any language a resource table adds.
    public static var allCases: [AppLanguagePreference] {
        [.system] + AppLanguage.allCases.map { AppLanguagePreference($0) }
    }

    public var id: String { rawValue }

    public var language: AppLanguage? {
        self == .system ? nil : AppLanguage(rawValue: rawValue)
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let language {
            let available = L10n.availableLanguages
            if available.contains(language) { return language }
            if let match = AppLanguage.match(language.rawValue, in: available) { return match }
        }
        return AppLanguage.detectSystemLanguage(preferredLanguages: preferredLanguages)
    }

    public var title: String {
        language?.nativeName ?? L10n.tr("跟随系统", "System Default")
    }

    public var label: String { title }

    public init(from decoder: any Decoder) throws {
        self.init(pinned: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum MiCloudRegion: String, CaseIterable, Identifiable, Codable, Sendable {
    case cn = "cn"
    case de = "de"
    case i2 = "i2"
    case ru = "ru"
    case sg = "sg"
    case us = "us"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cn: return L10n.tr("中国大陆 (cn)", "China Mainland (cn)")
        case .de: return L10n.tr("欧洲 (de)", "Europe (de)")
        case .i2: return L10n.tr("印度 (i2)", "India (i2)")
        case .ru: return L10n.tr("俄罗斯 (ru)", "Russia (ru)")
        case .sg: return L10n.tr("新加坡 / 国际 (sg)", "Singapore / Global (sg)")
        case .us: return L10n.tr("美区 (us)", "United States (us)")
        }
    }

    public var label: String { title }
}

// MARK: - Localization

/// Thread-safe, zero-dependency localization helper that builds cleanly on both macOS and Linux.
///
/// `L10n.tr("中文", "English")` stays the inline call-site API: Simplified Chinese and English come
/// straight from the two arguments, and every other language is served from
/// `Sources/MijiaCore/Resources/Localizations/<id>.json`, keyed by that Chinese text with `*`
/// standing for an interpolated part. A new language is therefore a dropped-in file: it shows up in
/// `availableLanguages` and the language picker without touching Swift.
public enum L10n {
    @TaskLocal public static var overrideLanguage: AppLanguage?

    /// Pins the display unit for a scope (tests, previews).
    @TaskLocal public static var overrideTemperatureUnit: TemperatureUnit?

    /// Pins the translation-table directory for a scope. Tests use it so parallel suites never
    /// fight over one global path; `setTranslationDirectory` remains for tools.
    @TaskLocal public static var overrideTranslationDirectory: URL?

    // MARK: Locked storage

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func get() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: Value) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }

    private struct TranslationTable: Sendable {
        struct Pattern: Sendable {
            let match: String
            let literalLength: Int
            let value: String
        }

        let language: AppLanguage
        let nativeName: String
        let speechLocale: String?
        let order: Int
        let strings: [String: String]
        let patterns: [Pattern]

        func lookup(_ text: String) -> String? {
            if let exact = strings[text] { return exact }
            let collapsed = L10n.normalizedNumbers(text)
            if collapsed != text, let hit = strings[collapsed] { return hit }
            for pattern in patterns {
                if let captures = L10n.captures(pattern: pattern.match, against: text) {
                    return L10n.fill(pattern.value, with: captures)
                }
            }
            return nil
        }
    }

    private struct TableFile: Decodable {
        let id: String
        let nativeName: String?
        let speechLocale: String?
        let order: Int?
        let strings: [String: String]?
    }

    /// Name of the SwiftPM resource bundle that carries the translation tables.
    public static let resourceBundleName = "MenuBarMijia_MijiaCore"

    private static let languageBox = LockedBox<AppLanguage>(.zhHans)
    private static let directoryBox = LockedBox<URL?>(nil)
    private static let tableBox = LockedBox<[AppLanguage: TranslationTable]?>(nil)

    // MARK: Language

    public static var currentLanguage: AppLanguage {
        get { overrideLanguage ?? languageBox.get() }
        set { languageBox.set(newValue) }
    }

    public static var isEnglish: Bool {
        currentLanguage == .en
    }

    /// Languages whose text is actually available, in picker order: Simplified Chinese, English, then
    /// every additional resource table ordered by its `order` field.
    public static var availableLanguages: [AppLanguage] {
        let tables = translationTables()
        var ordered: [(language: AppLanguage, order: Int)] = [(.zhHans, 0), (.en, 5)]
        for table in tables.values where table.language != .zhHans && table.language != .en {
            ordered.append((table.language, table.order))
        }
        return ordered
            .sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.language.rawValue < $1.language.rawValue
            }
            .map { $0.language }
    }

    public static func nativeName(for language: AppLanguage) -> String {
        if let named = translationTables()[language]?.nativeName, !named.isEmpty { return named }
        switch language {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        default: return language.rawValue
        }
    }

    public static func speechLocaleIdentifier(for language: AppLanguage) -> String {
        if let spoken = translationTables()[language]?.speechLocale, !spoken.isEmpty { return spoken }
        switch language {
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .en: return "en-US"
        default: return language.rawValue
        }
    }

    /// Points table loading at a directory of `<id>.json` files (tests, tools). `nil` restores the
    /// bundle search order used by the app.
    public static func setTranslationDirectory(_ url: URL?) {
        directoryBox.set(url)
        tableBox.set(nil)
    }

    /// Drops the cached tables so a newly installed language file is picked up without relaunching.
    public static func reloadTranslationTables() {
        tableBox.set(nil)
    }

    // MARK: Strings

    /// Inline two-language lookup. Simplified Chinese and English come from the arguments; any other
    /// language is answered from its table, falling back to Simplified Chinese (for `zh-*`) or English.
    public static func tr(_ zh: String, _ en: String) -> String {
        let language = currentLanguage
        if language == .zhHans { return zh }
        if language == .en { return en }
        return translated(zh, in: language) ?? (language.isChinese ? zh : en)
    }

    /// Parameterized lookup: `L10n.format("亮度 %@", "Brightness %@", "60")`.
    /// `%@` is filled positionally *without* `String(format:)`, so a table may reorder arguments and
    /// the result is identical on macOS and Linux.
    public static func format(_ zh: String, _ en: String, _ arguments: String...) -> String {
        fillPlaceholders(tr(zh, en), with: arguments)
    }

    /// Displays common room names in English when the UI is in English mode, preserving custom names.
    public static func displayRoomName(_ raw: String) -> String {
        guard currentLanguage == .en else { return raw }
        switch raw {
        case "全部": return "All"
        case "全屋": return "Whole Home"
        case "客厅": return "Living Room"
        case "主卧": return "Master Bedroom"
        case "卧室": return "Bedroom"
        case "次卧", "小卧室": return "Second Bedroom"
        case "书房": return "Study"
        case "厨房": return "Kitchen"
        case "阳台": return "Balcony"
        case "餐厅": return "Dining Room"
        case "卫生间", "浴室": return "Bathroom"
        case "玄关": return "Entryway"
        default: return raw
        }
    }

    // MARK: Temperature display

    /// The unit every temperature shown to the user is in. Read from the preference on each access so
    /// a settings change is reflected immediately, and stored values never change.
    public static var temperatureUnit: TemperatureUnit {
        if let override = overrideTemperatureUnit { return override }
        return TemperatureUnitPreference.stored().resolved(localeIdentifier: Locale.current.identifier)
    }

    /// The persisted preference: settings UI binds to this (or to `TemperatureUnitPreference.storageKey`).
    public static var temperatureUnitPreference: TemperatureUnitPreference {
        get { TemperatureUnitPreference.stored() }
        set { newValue.store() }
    }

    /// The number the user should see, in display units.
    public static func temperatureNumber(_ celsius: Double) -> Double {
        switch temperatureUnit {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9 / 5 + 32
        }
    }

    /// Digits only, for places that draw the degree mark separately.
    public static func temperatureValue(_ celsius: Double, fractionDigits: Int? = nil) -> String {
        let digits: Int
        if let fractionDigits {
            digits = max(0, fractionDigits)
        } else if temperatureUnit == .celsius && abs(celsius - celsius.rounded()) >= 0.05 {
            digits = 1
        } else {
            digits = 0
        }
        return String(format: "%.\(digits)f", temperatureNumber(celsius))
    }

    /// Digits plus unit symbol, e.g. `24°C`, `25.5°C`, or `75°F`.
    public static func temperature(_ celsius: Double, fractionDigits: Int? = nil) -> String {
        temperatureValue(celsius, fractionDigits: fractionDigits) + temperatureUnit.symbol
    }

    public static var temperatureSymbol: String { temperatureUnit.symbol }

    /// Converts a value typed or spoken in display units back to the Celsius core.
    public static func celsiusValue(displayValue: Double) -> Double {
        switch temperatureUnit {
        case .celsius: return displayValue
        case .fahrenheit: return (displayValue - 32) * 5 / 9
        }
    }

    /// Converts a step expressed in display units into the Celsius delta a control applies.
    public static func celsiusDelta(displayDelta: Double) -> Double {
        switch temperatureUnit {
        case .celsius: return displayDelta
        case .fahrenheit: return displayDelta * 5 / 9
        }
    }

    /// The Celsius delta for one ± tap: the provider's step in Celsius, or exactly one whole °F.
    public static func celsiusStep(_ providerStep: Double) -> Double {
        switch temperatureUnit {
        case .celsius: return providerStep
        case .fahrenheit: return 5.0 / 9.0
        }
    }

    // MARK: Table loading

    private static func translated(_ text: String, in language: AppLanguage) -> String? {
        let tables = translationTables()
        for candidate in [language, language.isChinese ? .zhHans : .en] {
            if let table = tables[candidate], let hit = table.lookup(text) { return hit }
        }
        return nil
    }

    private static func translationTables() -> [AppLanguage: TranslationTable] {
        // A scoped test directory must never see another scope's cached tables.
        if overrideTranslationDirectory != nil { return loadTranslationTables() }
        if let cached = tableBox.get() { return cached }
        let loaded = loadTranslationTables()
        tableBox.set(loaded)
        return loaded
    }

    private static func loadTranslationTables() -> [AppLanguage: TranslationTable] {
        guard let directory = translationDirectory() else { return [:] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var tables: [AppLanguage: TranslationTable] = [:]
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode(TableFile.self, from: data) else { continue }
            let language = AppLanguage(rawValue: decoded.id)
            guard language != .zhHans, language != .en else { continue }
            let strings = decoded.strings ?? [:]
            let patterns = strings
                .filter { $0.key.contains("*") }
                .map {
                    TranslationTable.Pattern(
                        match: $0.key,
                        literalLength: literalLength($0.key),
                        value: $0.value
                    )
                }
                .sorted { $0.literalLength > $1.literalLength }
            tables[language] = TranslationTable(
                language: language,
                nativeName: decoded.nativeName ?? language.rawValue,
                speechLocale: decoded.speechLocale,
                order: decoded.order ?? 100,
                strings: strings.filter { !$0.key.contains("*") },
                patterns: patterns
            )
        }
        return tables
    }

    private static func literalLength(_ pattern: String) -> Int {
        pattern.reduce(0) { $1 == "*" ? $0 : $0 + 1 }
    }

    /// First directory holding at least one table file. Works for `swift test`, `swift run`, the
    /// hand-assembled `.app` and the Linux check package, whose resource bundle is named after its
    /// own package (`LinuxCheck_MijiaCore.resources`).
    static func translationDirectory() -> URL? {
        if let override = overrideTranslationDirectory { return override }
        if let cached = directoryBox.get() { return cached }
        guard let found = firstTranslationDirectory(in: translationDirectoryCandidates) else { return nil }
        directoryBox.set(found)
        return found
    }

    private final class BundleToken {}

    /// Searches the loaded bundles, the app, and executable locations and their parents.
    static var translationSearchBases: [URL] {
        var bases: [URL] = []
        #if !os(macOS)
        if let resources = Bundle.module.resourceURL { bases.append(resources) }
        #endif
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            bases.append(URL(fileURLWithPath: override))
        }
        var bundles: [Bundle] = [Bundle(for: BundleToken.self), Bundle.main]
        for bundle in Bundle.allBundles where !bundles.contains(bundle) {
            bundles.append(bundle)
        }
        for bundle in bundles {
            if let resources = bundle.resourceURL { bases.append(resources) }
            let bundleURL = bundle.bundleURL
            bases.append(bundleURL)
            bases.append(bundleURL.appendingPathComponent("Contents/Resources"))
            bases.append(bundleURL.appendingPathComponent("Contents/MacOS"))
            if let executable = bundle.executableURL {
                bases.append(executable.deletingLastPathComponent())
            }
            var parent = bundleURL.deletingLastPathComponent()
            for _ in 0..<3 {
                bases.append(parent)
                parent = parent.deletingLastPathComponent()
            }
        }
        return bases
    }

    /// Every candidate directory, in the order `firstTranslationDirectory` tries them. Each base is
    /// probed for `<Package>_MijiaCore.bundle/Contents/Resources/Localizations`,
    /// `<Package>_MijiaCore.bundle/Localizations`, `<Package>_MijiaCore.resources/Localizations`,
    /// the same three without `Localizations`, and a bare `Localizations`.
    static var translationDirectoryCandidates: some Sequence<URL> {
        translationSearchBases.lazy.flatMap { base -> [URL] in
            var candidates = [base.appendingPathComponent("Localizations")]
            for name in resourceDirectoryNames(in: base) {
                let root = base.appendingPathComponent(name)
                candidates.append(root.appendingPathComponent("Contents/Resources/Localizations"))
                candidates.append(root.appendingPathComponent("Localizations"))
                candidates.append(root)
            }
            return candidates
        }
    }

    /// Resource bundle/directory names produced for the `MijiaCore` target by any package name.
    static func resourceDirectoryNames(in base: URL) -> [String] {
        var names: [String] = []
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            guard name.hasSuffix("_MijiaCore.bundle") || name.hasSuffix("_MijiaCore.resources") else { continue }
            names.append(name)
        }
        // Fall back to the expected names when the parent listing is unavailable (e.g. sandboxing).
        if names.isEmpty {
            names.append(resourceBundleName + ".bundle")
            names.append(resourceBundleName + ".resources")
        }
        return names
    }

    static func firstTranslationDirectory(in candidates: some Sequence<URL>) -> URL? {
        var isDirectory: ObjCBool = false
        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: candidate,
                includingPropertiesForKeys: nil
            )) ?? []
            if files.contains(where: { $0.pathExtension.lowercased() == "json" }) { return candidate }
        }
        return nil
    }

    // MARK: Matching helpers

    /// Collapses numeric runs (`60`, `26.5`, `1.0.6`) into `#` so one table entry serves every value.
    static func normalizedNumbers(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var insideNumber = false
        var previousWasDigit = false
        for character in text {
            if character.isASCII, character.isNumber {
                if !insideNumber {
                    result.append("#")
                    insideNumber = true
                }
                previousWasDigit = true
                continue
            }
            if insideNumber, character == "." || character == ",", previousWasDigit {
                previousWasDigit = false
                continue
            }
            insideNumber = false
            previousWasDigit = false
            result.append(character)
        }
        return result
    }

    /// Extracts the `*` wildcards of a table pattern from a rendered string.
    static func captures(pattern: String, against text: String) -> [String]? {
        let parts = pattern.components(separatedBy: "*")
        guard parts.count > 1, let first = parts.first else { return nil }
        guard text.hasPrefix(first) else { return nil }
        var captures: [String] = []
        var index = text.index(text.startIndex, offsetBy: first.count)
        for (offset, part) in parts.enumerated().dropFirst() {
            if offset == parts.count - 1 {
                guard text.hasSuffix(part) else { return nil }
                let end = text.index(text.endIndex, offsetBy: -part.count)
                guard end >= index else { return nil }
                captures.append(String(text[index..<end]))
            } else {
                guard let range = text.range(of: part, range: index..<text.endIndex) else { return nil }
                captures.append(String(text[index..<range.lowerBound]))
                index = range.upperBound
            }
        }
        return captures
    }

    /// Fills `*` placeholders in a table value with the captured text, in order.
    static func fill(_ template: String, with captures: [String]) -> String {
        guard template.contains("*") else { return template }
        var result = ""
        var remaining = Substring(template)
        var next = 0
        while let star = remaining.firstIndex(of: "*") {
            result += remaining[remaining.startIndex..<star]
            if next < captures.count {
                result += captures[next]
                next += 1
            }
            remaining = remaining[remaining.index(after: star)...]
        }
        result += remaining
        return result
    }

    private static func fillPlaceholders(_ template: String, with arguments: [String]) -> String {
        guard template.contains("%@") else { return template }
        var result = ""
        var remaining = Substring(template)
        var index = 0
        while let range = remaining.range(of: "%@") {
            result += remaining[remaining.startIndex..<range.lowerBound]
            if index < arguments.count {
                result += arguments[index]
                index += 1
            } else {
                result += "%@"
            }
            remaining = remaining[range.upperBound...]
        }
        result += remaining
        return result
    }
}
