import Foundation
import Testing
@testable import MijiaCore

private let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .current
    return calendar
}()

/// 2026-01-01 00:00 plus `dayOffset` days, at `hour`:`minute` local time.
private func testDate(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    let base = testCalendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour, minute: minute))
        ?? Date(timeIntervalSince1970: 0)
    return testCalendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
}

/// A plug whose only fields that matter to #62 are the cumulative counter and the live wattage.
private func testPlug(_ id: String, _ name: String, kwh: Double?, watts: Double? = nil) -> SmartDevice {
    SmartDevice(
        id: id,
        name: name,
        roomId: "study",
        roomName: "书房",
        model: "cuco.plug.v3",
        isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.\(id)", isOn: true, powerWatts: watts, energyKwh: kwh))
    )
}

/// #62: local plug energy history. Every number must come from deltas of a plug's own cumulative
/// counter — no wattage integration, no backfill, no negatives after a counter reset, no duplicates
/// from repeated or out-of-order snapshots.
struct EnergyHistoryTests {
    /// A throwaway `UserDefaults` suite plus its name, so each test owns its own persistence.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "test.energy.history.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func expectClose(_ value: Double, _ expected: Double) {
        #expect(abs(value - expected) < 1e-9, "expected \(expected), got \(value)")
    }

    @Test("Offline cached counters do not create a baseline or observed day")
    @MainActor
    func offlineCounterIsNotAnObservation() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)
        var offline = testPlug("plug_tv", "电视插座", kwh: 10)
        offline.isOnline = false

        history.record(devices: [offline], now: testDate(0, 9))
        #expect(history.recordingStartedAt == nil)
        #expect(history.dailyTotals(dayCount: 1, now: testDate(0, 9)).first?.isObserved == false)

        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 11)], now: testDate(1, 9))
        #expect(history.recordingStartedAt == testDate(1, 9))
        #expect(history.totalKwh(dayCount: 7, now: testDate(1, 9)) == 0)
    }

    @Test("Offline snapshots preserve the last valid counter and observation time")
    @MainActor
    func offlineDayDoesNotMoveTheBaseline() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 10)], now: testDate(0, 9))
        var offline = testPlug("plug_tv", "电视插座", kwh: 10.5)
        offline.isOnline = false
        history.record(devices: [offline], now: testDate(1, 9))

        let restored = EnergyHistory(defaults: defaults, calendar: testCalendar)
        #expect(restored.dailyTotals(dayCount: 1, now: testDate(1, 9)).first?.isObserved == false)
        restored.record(devices: [testPlug("plug_tv", "电视插座", kwh: 11)], now: testDate(2, 9))
        let days = restored.dailyTotals(dayCount: 3, now: testDate(2, 9))
        #expect(days.map(\.isObserved) == [true, false, true])
        expectClose(days[0].kwh, 1)
        expectClose(days[1].kwh, 0)
    }

    // MARK: Baselines

    @Test("The first reading only sets a baseline; nothing is invented")
    @MainActor
    func firstSampleIsBaselineOnly() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 10)], now: testDate(0, 9))

        #expect(history.hasMeasuredConsumption == false)
        #expect(history.recordingStartedAt == testDate(0, 9))
        #expect(history.totalKwh(dayCount: 7, now: testDate(0, 12)) == 0)
        #expect(history.deviceTotals(dayCount: 7, now: testDate(0, 12)).isEmpty)
        let today = try #require(history.dailyTotals(dayCount: 1, now: testDate(0, 12)).first)
        #expect(today.kwh == 0)
        // A counter was read that day, so the day is observed — with zero measured consumption.
        #expect(today.isObserved)
    }

    @Test("A counter increase is recorded once; repeats at the same or later time add nothing")
    @MainActor
    func deltaRecordedOnce() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 10)], now: testDate(0, 9))
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 10.5)], now: testDate(0, 10))
        // Exact duplicate snapshot (same timestamp, same reading).
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 10.5)], now: testDate(0, 10))
        // Later snapshot with an unchanged reading: zero delta, no bucket growth.
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 10.5)], now: testDate(0, 11))

        let today = try #require(history.dailyTotals(dayCount: 1, now: testDate(0, 12)).first)
        #expect(today.isObserved)
        expectClose(today.kwh, 0.5)

        let ranking = history.deviceTotals(dayCount: 7, now: testDate(0, 12))
        #expect(ranking.count == 1)
        #expect(ranking.first?.deviceId == "plug_tv")
        #expect(ranking.first?.name == "电视插座")
        expectClose(ranking.first?.kwh ?? 0, 0.5)
    }

    @Test("A lower reading rebases the counter and never records negative consumption")
    @MainActor
    func counterResetNeverGoesNegative() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 10)], now: testDate(0, 9))
        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 10.5)], now: testDate(0, 10))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 10)), 0.5)

        // Device rebooted: the lifetime counter dropped. Rebase, record nothing.
        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 10.2)], now: testDate(0, 11))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 11)), 0.5)

        // Consumption after the reset is measured from the rebound baseline.
        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 10.6)], now: testDate(0, 12))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 12)), 0.9)
    }

    @Test("Non-finite, negative and missing readings are ignored")
    @MainActor
    func invalidReadingsIgnored() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_a", "无效读数", kwh: nil)], now: testDate(0, 8))
        history.record(devices: [testPlug("plug_a", "无效读数", kwh: Double.nan)], now: testDate(0, 9))
        history.record(devices: [testPlug("plug_a", "无效读数", kwh: Double.infinity)], now: testDate(0, 10))
        history.record(devices: [testPlug("plug_a", "无效读数", kwh: -1)], now: testDate(0, 11))
        #expect(history.recordingStartedAt == nil)
        #expect(history.hasMeasuredConsumption == false)

        history.record(devices: [testPlug("plug_a", "有效读数", kwh: 10)], now: testDate(0, 12))
        // A bogus reading must not move the baseline or the last-sample time.
        history.record(devices: [testPlug("plug_a", "有效读数", kwh: Double.nan)], now: testDate(0, 13))
        history.record(devices: [testPlug("plug_a", "有效读数", kwh: 10.4)], now: testDate(0, 14))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 14)), 0.4)
    }

    @Test("Out-of-order snapshots add nothing and cannot rewind the baseline")
    @MainActor
    func outOfOrderSamplesIgnored() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_fridge", "冰箱插座", kwh: 10)], now: testDate(0, 9))
        history.record(devices: [testPlug("plug_fridge", "冰箱插座", kwh: 11)], now: testDate(0, 11))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 11)), 1.0)

        // Stale snapshot delivered late: older timestamp, higher reading.
        history.record(devices: [testPlug("plug_fridge", "冰箱插座", kwh: 12)], now: testDate(0, 10))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 11)), 1.0)

        // The next fresh sample is measured from the last accepted baseline (11), not the stale one.
        history.record(devices: [testPlug("plug_fridge", "冰箱插座", kwh: 11.5)], now: testDate(0, 12))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 12)), 1.5)
    }

    @Test("A delta spanning midnight is credited to the earlier sample day, never split")
    @MainActor
    func crossMidnightDeltaUsesEarlierDay() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 5)], now: testDate(0, 22))
        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 6)], now: testDate(1, 8))

        let totals = history.dailyTotals(dayCount: 2, now: testDate(1, 12))
        #expect(totals.count == 2)
        let yesterday = try #require(totals.first)
        let today = try #require(totals.last)
        expectClose(yesterday.kwh, 1.0)
        #expect(yesterday.isObserved)
        expectClose(today.kwh, 0)
        // The counter was read that morning, so the day counts as observed even though the delta
        // was credited to the earlier day.
        #expect(today.isObserved)
        expectClose(history.totalKwh(dayCount: 2, now: testDate(1, 12)), 1.0)
    }

    // MARK: Daily totals and ranking

    @Test("Days with no reading are marked unobserved instead of claiming zero usage")
    @MainActor
    func unreadDaysAreUnobserved() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 1)], now: testDate(0, 9))
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 2)], now: testDate(0, 18))
        // Day 1 sends nothing at all (app closed); day 2 resumes.
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 2)], now: testDate(2, 9))
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 3)], now: testDate(2, 18))

        let totals = history.dailyTotals(dayCount: 3, now: testDate(2, 20))
        #expect(totals.count == 3)
        #expect(totals.map(\.isObserved) == [true, false, true])
        #expect(totals[0].kwh == 1)
        #expect(totals[1].kwh == 0)
        #expect(totals[2].kwh == 1)
    }

    @Test("A gap longer than the retention window is dropped instead of being guessed")
    @MainActor
    func longGapIsDropped() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 0)], now: testDate(0, 9))

        // 45 days later: the counter rose by 90 kWh, but nobody was watching in between, so the
        // amount cannot be attributed to any day and must not inflate today.
        let resumeDay = EnergyHistory.retentionDays + 14
        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 90)], now: testDate(resumeDay, 9))

        #expect(history.hasMeasuredConsumption == false)
        #expect(history.totalKwh(dayCount: 7, now: testDate(resumeDay, 12)) == 0)
        let today = try #require(history.dailyTotals(dayCount: 1, now: testDate(resumeDay, 12)).first)
        #expect(today.kwh == 0)
        #expect(today.isObserved)

        // Recording continues from the resumed baseline.
        history.record(devices: [testPlug("plug_heater", "取暖器", kwh: 90.5)], now: testDate(resumeDay, 12))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(resumeDay, 12)), 0.5)
    }

    @Test("The last-seven-day window is ascending, zero-filled and window-bounded")
    @MainActor
    func sevenDayWindow() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        // Ten days, one kWh per day measured twice a day so each delta lands on its own day.
        for day in 0..<10 {
            history.record(devices: [testPlug("plug_tv", "电视插座", kwh: Double(day))], now: testDate(day, 9))
            history.record(devices: [testPlug("plug_tv", "电视插座", kwh: Double(day) + 1)], now: testDate(day, 18))
        }

        let totals = history.dailyTotals(dayCount: 7, now: testDate(9, 20))
        #expect(totals.count == 7)
        #expect(totals.map(\.day) == totals.map(\.day).sorted())
        for total in totals {
            #expect(total.isObserved)
            expectClose(total.kwh, 1.0)
        }
        expectClose(history.totalKwh(dayCount: 7, now: testDate(9, 20)), 7.0)
        // Day 0 is outside the seven-day window.
        expectClose(history.totalKwh(dayCount: 10, now: testDate(9, 20)), 10.0)
        #expect(history.dailyTotals(dayCount: 1, now: testDate(9, 20)).first?.day == testCalendar.startOfDay(for: testDate(9, 20)))
    }

    @Test("Devices are ranked by measured consumption inside the window only")
    @MainActor
    func deviceRanking() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        func snapshot(tv: Double, heater: Double, lamp: Double, at when: Date) {
            history.record(
                devices: [
                    testPlug("plug_tv", "电视插座", kwh: tv),
                    testPlug("plug_heater", "取暖器", kwh: heater),
                    testPlug("plug_lamp", "台灯插座", kwh: lamp)
                ],
                now: when
            )
        }

        // Day 0: baseline, then the first measured increase.
        snapshot(tv: 0, heater: 0, lamp: 0, at: testDate(0, 9))
        snapshot(tv: 0.5, heater: 2, lamp: 0, at: testDate(0, 18))
        // Day 1: heater keeps climbing; tv and lamp idle.
        snapshot(tv: 0.5, heater: 2, lamp: 0, at: testDate(1, 9))
        snapshot(tv: 0.5, heater: 2.5, lamp: 0, at: testDate(1, 18))
        // Day 2: nothing changes.
        snapshot(tv: 0.5, heater: 2.5, lamp: 0, at: testDate(2, 9))
        snapshot(tv: 0.5, heater: 2.5, lamp: 0, at: testDate(2, 18))
        // Day 9: tv grows well outside a three-day window.
        snapshot(tv: 0.5, heater: 2.5, lamp: 0, at: testDate(9, 9))
        snapshot(tv: 1.5, heater: 2.5, lamp: 0, at: testDate(9, 18))

        let ranking = history.deviceTotals(dayCount: 3, now: testDate(2, 18))
        #expect(ranking.map(\.deviceId) == ["plug_heater", "plug_tv"])
        expectClose(ranking[0].kwh, 2.5)
        expectClose(ranking[1].kwh, 0.5)
        #expect(ranking[0].name == "取暖器")

        let wide = history.deviceTotals(dayCount: 10, now: testDate(9, 18))
        expectClose(wide.first(where: { $0.deviceId == "plug_tv" })?.kwh ?? 0, 1.5)
    }

    // MARK: Price and cost

    @Test("Cost stays hidden until a valid price is entered")
    @MainActor
    func priceAndCost() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        #expect(history.pricePerKwh == nil)
        #expect(history.cost(forKwh: 2) == nil)

        history.setPricePerKwh(0.6)
        expectClose(try #require(history.cost(forKwh: 0.5)), 0.3)

        // Invalid prices clear the setting instead of becoming a hidden zero.
        history.setPricePerKwh(-1)
        #expect(history.pricePerKwh == nil)
        history.setPricePerKwh(Double.nan)
        #expect(history.pricePerKwh == nil)
        history.setPricePerKwh(nil)
        #expect(history.pricePerKwh == nil)
    }

    @Test("Total cost follows measured energy and the configured price")
    @MainActor
    func totalCost() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 1)], now: testDate(0, 9))
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 1.5)], now: testDate(0, 18))
        #expect(history.totalCost(dayCount: 7, now: testDate(0, 19)) == nil)

        history.setPricePerKwh(1.2)
        expectClose(try #require(history.totalCost(dayCount: 7, now: testDate(0, 19))), 0.6)
    }

    // MARK: Clearing

    @Test("Clearing removes samples and baselines, so the next reading starts over")
    @MainActor
    func clearRemovesBaselines() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)
        history.setPricePerKwh(0.5)

        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 10)], now: testDate(0, 9))
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 10.5)], now: testDate(0, 10))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 10)), 0.5)

        history.clear()

        #expect(history.hasMeasuredConsumption == false)
        #expect(history.recordingStartedAt == nil)
        #expect(history.totalKwh(dayCount: 7, now: testDate(0, 11)) == 0)
        #expect(history.deviceTotals(dayCount: 7, now: testDate(0, 11)).isEmpty)
        // The price is a preference, not recorded consumption.
        #expect(history.pricePerKwh == 0.5)

        // Without the old baseline, a much higher reading cannot produce a jump.
        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 100)], now: testDate(0, 12))
        #expect(history.recordingStartedAt == testDate(0, 12))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 12)), 0)

        history.record(devices: [testPlug("plug_tv", "电视插座", kwh: 100.25)], now: testDate(0, 13))
        expectClose(history.totalKwh(dayCount: 7, now: testDate(0, 13)), 0.25)
    }

    @Test("A cleared history stays cleared across a relaunch")
    @MainActor
    func clearSurvivesRestart() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = EnergyHistory(defaults: defaults, calendar: testCalendar)
        first.record(devices: [testPlug("plug_tv", "电视插座", kwh: 1)], now: testDate(0, 9))
        first.record(devices: [testPlug("plug_tv", "电视插座", kwh: 3)], now: testDate(0, 10))
        expectClose(first.totalKwh(dayCount: 7, now: testDate(0, 10)), 2.0)

        first.clear()

        let relaunched = EnergyHistory(defaults: defaults, calendar: testCalendar)
        #expect(relaunched.hasMeasuredConsumption == false)
        #expect(relaunched.recordingStartedAt == nil)
        #expect(relaunched.totalKwh(dayCount: 7, now: testDate(0, 11)) == 0)
    }

    // MARK: Persistence and bounds

    @Test("History and baselines survive a relaunch without duplicating the delta")
    @MainActor
    func restartKeepsHistoryAndBaseline() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = EnergyHistory(defaults: defaults, calendar: testCalendar)
        first.record(devices: [testPlug("plug_tv", "电视插座", kwh: 1)], now: testDate(0, 9))
        first.record(devices: [testPlug("plug_tv", "电视插座", kwh: 1.5)], now: testDate(0, 10))

        let relaunched = EnergyHistory(defaults: defaults, calendar: testCalendar)
        expectClose(relaunched.totalKwh(dayCount: 7, now: testDate(0, 11)), 0.5)

        relaunched.record(devices: [testPlug("plug_tv", "电视插座", kwh: 2)], now: testDate(0, 12))
        expectClose(relaunched.totalKwh(dayCount: 7, now: testDate(0, 12)), 1.0)
    }

    @Test("History is bounded; older days are pruned instead of accumulating forever")
    @MainActor
    func historyIsBounded() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        let days = EnergyHistory.retentionDays + 9
        for day in 0..<days {
            history.record(devices: [testPlug("plug_tv", "电视插座", kwh: Double(day))], now: testDate(day, 9))
            history.record(devices: [testPlug("plug_tv", "电视插座", kwh: Double(day) + 1)], now: testDate(day, 18))
        }

        let lastDay = days - 1
        let totals = history.dailyTotals(dayCount: EnergyHistory.retentionDays + 5, now: testDate(lastDay, 20))
        #expect(totals.count == EnergyHistory.retentionDays)
        expectClose(history.totalKwh(dayCount: EnergyHistory.retentionDays, now: testDate(lastDay, 20)), Double(EnergyHistory.retentionDays))
        // The oldest retained day is exactly the retention cut-off.
        #expect(totals.first?.day == testCalendar.startOfDay(for: testDate(lastDay - (EnergyHistory.retentionDays - 1), 0)))
    }

    @Test("Two stores in different defaults suites stay isolated")
    @MainActor
    func suitesAreIsolated() throws {
        let (firstDefaults, firstSuite) = try makeDefaults()
        let (secondDefaults, secondSuite) = try makeDefaults()
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }

        let first = EnergyHistory(defaults: firstDefaults, calendar: testCalendar)
        let second = EnergyHistory(defaults: secondDefaults, calendar: testCalendar)

        first.record(devices: [testPlug("plug_tv", "电视插座", kwh: 1)], now: testDate(0, 9))
        first.record(devices: [testPlug("plug_tv", "电视插座", kwh: 2)], now: testDate(0, 10))
        first.setPricePerKwh(0.5)

        #expect(second.hasMeasuredConsumption == false)
        #expect(second.recordingStartedAt == nil)
        #expect(second.pricePerKwh == nil)
        #expect(second.totalKwh(dayCount: 7, now: testDate(0, 11)) == 0)
    }

    @Test("Corrupt persisted data is ignored instead of crashing")
    @MainActor
    func corruptPayloadIgnored() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: EnergyHistory.storageKey)

        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)
        #expect(history.recordingStartedAt == nil)
        #expect(history.hasMeasuredConsumption == false)
    }

    // MARK: Store wiring

    @Test("A provider snapshot feeds the store's history once, and the recording is not a rollback")
    @MainActor
    func storeSnapshotFeedsHistory() async throws {
        let suite = "test.energy.history.store.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let plug = testPlug("plug_tv", "电视插座", kwh: 4)
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [plug], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        // First snapshot only sets a baseline: subscribing alone must never invent consumption.
        #expect(store.energyHistory.recordingStartedAt != nil)
        #expect(store.energyHistory.hasMeasuredConsumption == false)
        #expect(store.energyHistory.totalKwh(dayCount: 7) == 0)

        await mock.updateSnapshot(SynthesizedHome(devices: [testPlug("plug_tv", "电视插座", kwh: 4.75)], scenes: []))
        for _ in 0..<50 where !store.energyHistory.hasMeasuredConsumption {
            try await Task.sleep(for: .milliseconds(10))
        }

        // The history saw the fresh reading through the same store instance.
        #expect(store.energyHistory.hasMeasuredConsumption)
        #expect(store.energyHistory.totalKwh(dayCount: 7) > 0)
    }

    // MARK: Non-counter devices

    @Test("Devices without a counter contribute nothing — wattage is never converted into energy")
    @MainActor
    func noCounterMeansNoConsumption() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = EnergyHistory(defaults: defaults, calendar: testCalendar)

        let light = SmartDevice(
            id: "light_study", name: "书房台灯", roomId: "study", roomName: "书房",
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.study", isOn: true))
        )
        let powerOnly = testPlug("plug_heater", "取暖器", kwh: nil, watts: 2_000)

        for hour in 0..<8 {
            history.record(devices: [light, powerOnly], now: testDate(0, hour))
        }

        #expect(history.recordingStartedAt == nil)
        #expect(history.hasMeasuredConsumption == false)
        #expect(history.totalKwh(dayCount: 7, now: testDate(0, 9)) == 0)
    }
}
