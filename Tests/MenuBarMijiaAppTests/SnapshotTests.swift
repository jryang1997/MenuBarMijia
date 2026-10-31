import Testing
import Foundation
import SwiftUI
import AppKit
import SnapshotTesting
import MijiaCore
@testable import MenuBarMijiaApp

/// UI snapshots for the menu-bar panel and the five device-card families (#46).
///
/// Two-phase baseline: CI first runs `SNAPSHOT_RECORD=1 swift test --filter SnapshotTests`, which
/// writes PNGs into `Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests/`; those files are then
/// committed. SnapshotTesting also reports "Record mode is on" as a failure for that run, so the
/// record job is expected to exit non-zero while still producing every baseline. Later runs compare
/// against them; on a mismatch the new bitmap is written under `$SNAPSHOT_ARTIFACTS`/SnapshotTests
/// (or `$TMPDIR/SnapshotTests`) and the diff command is printed in the failure message.
///
/// The renderer is fed fixed demo data and the accessibility "reduce motion" / "reduce transparency"
/// switches, so animations and materials cannot make two runs differ. The suite is serialized
/// because it changes `UserDefaults.standard` (the panel reads skin/appearance through
/// `@AppStorage`) and `L10n.currentLanguage`.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    private var recordMode: SnapshotTestingConfiguration.Record {
        ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1" ? .all : .missing
    }

    // MARK: - Panel: one system look (Chinese, light, single column)

    @Test("Panel renders in the system look")
    func panelSnapshot() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }

        UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)

        assertRendered(
            snapshotReady(ControlCenterPanel(store: fixture.store)),
            size: CGSize(width: 376, height: 560),
            named: "panel-zh-light"
        )
    }

    // MARK: - Device cards: light / climate / plug / sensor / TV

    @Test("Five device card families render")
    func deviceCardSnapshots() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        let light = try #require(fixture.store.devices.first { device in
            if case .light = device.kind { return true } else { return false }
        })
        let climate = try #require(fixture.store.devices.first { device in
            if case .climate = device.kind { return true } else { return false }
        })
        let plug = try #require(fixture.store.devices.first { device in
            if case .plug = device.kind { return true } else { return false }
        })
        let sensor = try #require(fixture.store.devices.first { device in
            if case .sensor = device.kind { return true } else { return false }
        })
        let tv = try #require(fixture.store.devices.first { device in
            if case .tv = device.kind { return true } else { return false }
        })

        let cards: [(String, SmartDevice)] = [
            ("light", light),
            ("climate", climate),
            ("plug", plug),
            ("sensor", sensor),
            ("tv", tv)
        ]

        for (name, device) in cards {
            let view = snapshotReady(
                DeviceCardView(device: device, store: fixture.store, showRoomBadge: true)
                    .padding(8)
                    .frame(width: 360)
            )
            assertRendered(
                view,
                size: CGSize(width: 376, height: 140),
                named: "card-\(name)-zh-light"
            )
        }
    }

    @Test("Climate card wears its tinted platter when on")
    func climateOnCardSnapshot() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        var climate = try #require(fixture.store.devices.first { device in
            if case .climate = device.kind { return true } else { return false }
        })
        await fixture.store.togglePrimary(climate)?.value
        climate = try #require(fixture.store.devices.first { $0.id == climate.id })
        #expect(climate.isActiveOn, "MockHomeProvider should apply the power toggle")

        assertRendered(
            snapshotReady(
                DeviceCardView(device: climate, store: fixture.store, showRoomBadge: true)
                    .padding(8)
                    .frame(width: 360)
            ),
            size: CGSize(width: 376, height: 140),
            named: "card-climate-on-zh-light"
        )
        assertRendered(
            snapshotReady(
                DeviceCardView(device: climate, store: fixture.store, showRoomBadge: true)
                    .padding(8)
                    .frame(width: 360),
                scheme: .dark
            ),
            size: CGSize(width: 376, height: 140),
            named: "card-climate-on-zh-dark",
            scheme: .dark
        )
    }

    @Test("Settings remain readable in light and dark appearances")
    func settingsSnapshots() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        for tab in [SettingsTab.general, .connection, .assistant, .appearance, .privacy, .about] {
            for scheme in [ColorScheme.light, .dark] {
                assertRendered(
                    SettingsWindowView(store: fixture.store, selectedTab: tab)
                        .environment(\.colorScheme, scheme)
                        .environment(\.reduceMotionOverride, true)
                        .environment(\.reduceTransparencyOverride, true),
                    size: CGSize(width: 780, height: 680),
                    named: "settings-\(tab.rawValue)-\(scheme == .dark ? "dark" : "light")",
                    scheme: scheme
                )
            }
        }
    }

    @Test("Settings capsule fits English at minimum window size with glass enabled")
    func settingsCapsuleVariants() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        for language in [AppLanguage.zhHans, .en] {
            L10n.currentLanguage = language
            fixture.store.appLanguagePreference = AppLanguagePreference(language)
            for scheme in [ColorScheme.light, .dark] {
                assertRendered(
                    SettingsWindowView(store: fixture.store, selectedTab: .privacy)
                        .environment(\.colorScheme, scheme)
                        .environment(\.reduceMotionOverride, true)
                        .environment(\.reduceTransparencyOverride, false),
                    size: CGSize(width: 740, height: 600),
                    named: "settings-capsule-\(language == .en ? "en" : "zh")-\(scheme == .dark ? "dark" : "light")",
                    scheme: scheme
                )
            }
        }
    }

    @Test("Settings stay proportional in wide windows and with motion enabled")
    func settingsWideWindows() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        for width: CGFloat in [900, 1200] {
            for scheme in [ColorScheme.light, .dark] {
                assertRendered(
                    SettingsWindowView(store: fixture.store)
                        .environment(\.colorScheme, scheme)
                        .environment(\.reduceMotionOverride, false)
                        .environment(\.reduceTransparencyOverride, false),
                    size: CGSize(width: width, height: 680),
                    named: "settings-wide-\(Int(width))-\(scheme == .dark ? "dark" : "light")",
                    scheme: scheme
                )
            }
        }
    }

    @Test("Panel supports dark, compact and expanded controls")
    func panelInteractionStates() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }
        for compact in [false, true] {
            fixture.store.isCompactGridMode = compact
            assertRendered(
                snapshotReady(ControlCenterPanel(store: fixture.store), scheme: .dark),
                size: CGSize(width: 376, height: 560),
                named: compact ? "panel-compact-dark" : "panel-dark",
                scheme: .dark
            )
        }
        let light = try #require(fixture.store.devices.first { if case .light = $0.kind { true } else { false } })
        fixture.store.expandedDeviceId = light.id
        for scheme in [ColorScheme.light, .dark] {
            assertRendered(
                snapshotReady(DeviceCardView(device: light, store: fixture.store, showRoomBadge: true).padding(8), scheme: scheme),
                size: CGSize(width: 376, height: 260),
                named: "expanded-light-\(scheme == .dark ? "dark" : "light")",
                scheme: scheme
            )
        }
    }

    // MARK: - Non-visual guards for the appearance work (#51) and tooltip (#54)

    @Test("On and off tiles never share the same ink or fill")
    func platterContrastHoldsInBothSchemes() {
        let lit = TileSurface(isActive: true, scheme: .light)
        let quiet = TileSurface(isActive: false, scheme: .light)
        #expect(lit.ink == PanelLook.platterInk)
        #expect(quiet.ink == .primary)
        #expect(lit.secondaryInk == PanelLook.platterInk.opacity(0.55))
        #expect(quiet.secondaryInk == .secondary)
        // The platter keeps a defined hairline in light mode; wells get the quieter one.
        #expect(lit.hairline != quiet.hairline)

        // A tinted lit surface is dark blue glass in dark mode, so it takes white ink and the
        // family hairline instead of the platter rules.
        let darkTinted = TileSurface(isActive: true, tint: DesignTokens.Orb.climate, scheme: .dark)
        #expect(darkTinted.ink == .white)
        #expect(darkTinted.ink != lit.ink)
        #expect(darkTinted.secondaryInk == .white.opacity(0.62))
        #expect(darkTinted.hairline != lit.hairline)
    }

    @Test("Scene icons map to one visual category per family")
    func sceneVisualCategoriesMapFromSymbols() {
        // Quick actions own their category outright; no symbol parsing involved.
        #expect(QuickAction.lightsOff.visualCategory == .light)
        #expect(QuickAction.softNightLight.visualCategory == .night)
        #expect(QuickAction.climateSleepOff.visualCategory == .climate)
        // Externally supplied scene icons resolve through the centralised keyword map.
        #expect(SceneVisualCategory(iconSymbol: "moon.stars.fill") == .night)
        #expect(SceneVisualCategory(iconSymbol: "wind.snow") == .climate)
        #expect(SceneVisualCategory(iconSymbol: "drop.fill") == .water)
        #expect(SceneVisualCategory(iconSymbol: "flame.fill") == .heat)
        #expect(SceneVisualCategory(iconSymbol: "tv.fill") == .media)
        // Unknown symbols land on the warm default instead of vanishing.
        #expect(SceneVisualCategory(iconSymbol: "sparkles") == .light)
    }

    @Test("Menu-bar tooltip summarises devices, temperature and backend")
    func menuBarSummaryDescribesCurrentState() async throws {
        let fixture = try await SnapshotFixture()
        defer { fixture.restore() }

        let text = MenuBarStatusSummary.text(for: fixture.store)
        #expect(text.hasPrefix("MenuBarMijia · "))
        #expect(text.contains("台开启"))
        #expect(text.contains("已连接 Home Assistant"))
    }

    // MARK: - Rendering switches

    private func snapshotReady<V: View>(_ view: V, scheme: ColorScheme = .light) -> some View {
        view
            .environment(\.colorScheme, scheme)
            .environment(\.reduceMotionOverride, true)
            .environment(\.reduceTransparencyOverride, true)
            .transaction { transaction in
                transaction.disablesAnimations = true
            }
    }

    /// SnapshotTesting only ships the SwiftUI `.image(layout:)` strategy for iOS/tvOS, so macOS
    /// renders through an `NSHostingView` inside a borderless window and snapshots the NSView.
    private func assertRendered<V: View>(
        _ view: V,
        size: CGSize,
        named name: String,
        scheme: ColorScheme = .light,
        file: StaticString = #filePath,
        testName: String = #function
    ) {
        // `swift test` does not launch an app; AppKit still needs its shared application object
        // before offscreen windows and hosting views can be created.
        _ = NSApplication.shared

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            Issue.record("Could not create a 1x snapshot bitmap")
            return
        }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        assertSnapshot(
            of: image,
            as: .image,
            named: name,
            record: recordMode,
            file: file,
            testName: testName
        )

        window.contentView = nil
        window.orderOut(nil)
    }
}

/// A loaded store over the built-in virtual home, with a fixed language and the standard-defaults
/// keys the panel reads through `@AppStorage`.
@MainActor
private struct SnapshotFixture {
    struct MissingDefaults: Error {}

    let store: HomeStore
    private let previousAppearance: String?
    private let previousTemperatureUnit: String?
    private let previousLanguage: AppLanguage

    init() async throws {
        previousLanguage = L10n.currentLanguage
        L10n.currentLanguage = .zhHans
        previousAppearance = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        previousTemperatureUnit = UserDefaults.standard.string(forKey: TemperatureUnitPreference.storageKey)
        UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)
        UserDefaults.standard.set(TemperatureUnitPreference.celsius.rawValue, forKey: TemperatureUnitPreference.storageKey)

        let suiteName = "MenuBarMijiaSnapshotTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw MissingDefaults()
        }
        defaults.set(true, forKey: "has_completed_onboarding")
        defaults.set(AppLanguagePreference.zhHans.rawValue, forKey: "app_language")
        defaults.set(TemperatureUnitPreference.celsius.rawValue, forKey: TemperatureUnitPreference.storageKey)
        defaults.set(false, forKey: "show_quick_actions_bar")
        // The panel's `.task` checks for updates; keep the snapshot offline and deterministic.
        defaults.set(false, forKey: "automatically_checks_for_updates")

        store = HomeStore(
            provider: MockHomeProvider(snapshot: DemoHomeProvider.defaultHome()),
            defaultsSuiteName: suiteName
        )

        var attempts = 0
        while store.devices.isEmpty && attempts < 200 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }
        #expect(!store.devices.isEmpty, "MockHomeProvider should deliver a snapshot right away")
    }

    func restore() {
        if let previousAppearance {
            UserDefaults.standard.set(previousAppearance, forKey: AppAppearance.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppAppearance.storageKey)
        }
        L10n.currentLanguage = previousLanguage
        if let previousTemperatureUnit {
            UserDefaults.standard.set(previousTemperatureUnit, forKey: TemperatureUnitPreference.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TemperatureUnitPreference.storageKey)
        }
    }
}
