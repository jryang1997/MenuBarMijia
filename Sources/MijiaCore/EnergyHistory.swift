import Foundation
import Observation

/// One local day of totals for #62; `isObserved` is `false` when no plug counter was read that day,
/// so the UI can show “—” instead of claiming zero consumption. `kwh == 0` with `isObserved == true`
/// means a reading arrived and the counter did not grow.
public struct EnergyDayTotal: Equatable, Sendable, Identifiable {
    public let day: Date
    public let kwh: Double
    public let isObserved: Bool

    public var id: Date { day }

    public init(day: Date, kwh: Double, isObserved: Bool) {
        self.day = day
        self.kwh = kwh
        self.isObserved = isObserved
    }
}

/// One device's measured total over a window, ranked by consumption.
public struct EnergyDeviceTotal: Equatable, Sendable, Identifiable {
    public let deviceId: String
    /// Last name seen for the device; callers may prefer the live name from `HomeStore.devices`.
    public let name: String
    public let kwh: Double

    public var id: String { deviceId }

    public init(deviceId: String, name: String, kwh: Double) {
        self.deviceId = deviceId
        self.name = name
        self.kwh = kwh
    }
}

/// One persisted day of measured electricity: per-device deltas plus the fact that at least one
/// counter was read that day. File-scoped (not nested in `EnergyHistory`) so its `Codable`
/// witnesses stay nonisolated.
private struct EnergyHistoryBucket: Codable, Equatable, Sendable {
    var day: Date
    var perDevice: [String: Double]
}

/// The single persisted payload: measured day buckets, which days were actually read, the last
/// counter value seen per device (the baseline), each device's last sample time, and remembered names.
private struct EnergyHistoryStored: Codable, Equatable, Sendable {
    var buckets: [EnergyHistoryBucket] = []
    var observedDays: [Date] = []
    var baselines: [String: Double] = [:]
    var lastSampleAt: [String: Date] = [:]
    var names: [String: String] = [:]
    var recordingStartedAt: Date?
}

/// Local, on-device energy history for plugs (#62).
///
/// The only input is each plug's own cumulative lifetime counter (`PlugSpec.energyKwh`), so every
/// number here is a measured difference between two observations of that counter. Wattage is
/// deliberately not used: multiplying `powerWatts` by elapsed time (or anything else) would invent
/// consumption the meter never reported, and a plug without a counter contributes nothing.
///
/// Rules that keep the numbers honest:
/// - The first observation of a counter only records a baseline. Nothing before the app started
///   watching is backfilled, so "today" never claims energy that was consumed before recording began.
/// - A reading must be finite and non-negative; `nil`, NaN, `.infinity` and negatives are ignored.
/// - A delta is credited to the **earlier** of the two observation days. When a sample spans
///   midnight (the Mac was asleep, or the plug was offline) the whole delta lands on the earlier
///   day instead of being split or extrapolated, so today's figure never overstates what the counter
///   proved was consumed while the app was watching today. A gap longer than the retention window
///   is dropped rather than guessed.
/// - A lower reading means the counter was reset or rolled back: the baseline is rebased and no
///   negative consumption is recorded. Repeats and out-of-order samples (a timestamp not newer than
///   the previous sample for that device) add nothing, so a duplicated snapshot cannot double count.
///
/// Everything lives in one `UserDefaults` payload, `clear()` removes all recorded samples *and* the
/// baselines (so the next reading starts over instead of producing a jump), and the cleared state is
/// persisted immediately, so relaunching cannot resurrect old data.
@Observable
@MainActor
public final class EnergyHistory {
    /// Daily buckets kept on disk. Seven are displayed; a month is retained so ranking has context
    /// and the payload stays small (one `Double` per device per day).
    public static let retentionDays = 31
    public static let storageKey = "plug_energy_history_v1"

    private let defaults: UserDefaults
    private let calendar: Calendar

    private var stored: EnergyHistoryStored

    /// Price per kWh entered by the user; `nil` means “not set”, which hides every cost figure.
    public private(set) var pricePerKwh: Double?

    public init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        let loaded = Self.decode(from: defaults)
        self.stored = Self.sanitized(loaded, calendar: calendar)
        let storedPrice: Double? = defaults.object(forKey: Self.priceKey) != nil
            ? defaults.double(forKey: Self.priceKey)
            : nil
        self.pricePerKwh = Self.sanitizedPrice(storedPrice)
    }

    /// The day the first baseline was recorded. `nil` until a plug with a counter is observed.
    public var recordingStartedAt: Date? { stored.recordingStartedAt }

    /// Whether any measured consumption exists yet (a baseline alone is not consumption).
    public var hasMeasuredConsumption: Bool { !stored.buckets.isEmpty }

    // MARK: Recording

    /// Feeds the current device list into the history. `now` is the observation time.
    ///
    /// Called once per provider snapshot; nothing is derived from the device list order.
    public func record(devices: [SmartDevice], now: Date) {
        // `lastSampleAt` alone is not worth a write: losing it across a crash only means one
        // already-seen snapshot may be accepted again, and the baseline still prevents double count.
        var shouldPersist = false
        var observedCounter = false

        for device in devices {
            guard device.isOnline,
                  case .plug(let spec) = device.kind,
                  let reading = spec.energyKwh,
                  reading.isFinite,
                  reading >= 0 else {
                continue
            }
            observedCounter = true

            let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, stored.names[device.id] != name {
                stored.names[device.id] = name
                shouldPersist = true
            }

            // Repeats and out-of-order samples: a timestamp that is not newer than the last sample
            // for this device cannot add new consumption and must not move the baseline backwards.
            let lastSeen = stored.lastSampleAt[device.id]
            if let lastSeen, now <= lastSeen {
                continue
            }
            stored.lastSampleAt[device.id] = now

            guard let baseline = stored.baselines[device.id] else {
                // First observation: this is the baseline only. No consumption is inferred.
                stored.baselines[device.id] = reading
                if stored.recordingStartedAt == nil {
                    stored.recordingStartedAt = now
                }
                shouldPersist = true
                continue
            }

            if baseline != reading {
                stored.baselines[device.id] = reading
                shouldPersist = true
            }

            // Counter reset or rollback: rebase and record nothing, never a negative delta.
            guard reading >= baseline else { continue }

            let delta = reading - baseline
            guard delta > 0 else { continue }

            // Attribute the delta to the earlier observation day. A missing previous timestamp (only
            // possible from a partial persisted payload) or a gap longer than the retention window
            // means the increase cannot be pinned to a day the history still keeps, so it is dropped
            // instead of being charged to one day.
            guard let previousSampleAt = lastSeen, isInsideRetentionWindow(previousSampleAt, now: now) else {
                continue
            }
            // The delta happened somewhere between the two samples; crediting the earlier day keeps
            // “today” from claiming energy that may have been used yesterday.
            add(delta, deviceId: device.id, at: previousSampleAt)
            shouldPersist = true
        }

        if observedCounter {
            let observationDay = calendar.startOfDay(for: now)
            if !stored.observedDays.contains(where: { calendar.isDate($0, inSameDayAs: observationDay) }) {
                stored.observedDays.append(observationDay)
                shouldPersist = true
            }
        }

        guard shouldPersist else { return }
        prune(now: now)
        persist()
    }

    private func add(_ delta: Double, deviceId: String, at date: Date) {
        let day = calendar.startOfDay(for: date)
        if let index = stored.buckets.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            stored.buckets[index].perDevice[deviceId, default: 0] += delta
        } else {
            stored.buckets.append(EnergyHistoryBucket(day: day, perDevice: [deviceId: delta]))
        }
    }

    // MARK: Reading

    /// Daily totals for the window ending today (inclusive), oldest day first. Days without a
    /// recorded reading are present with `kwh == 0` and `isObserved == false`.
    public func dailyTotals(dayCount: Int = 7, now: Date = Date()) -> [EnergyDayTotal] {
        let count = min(max(dayCount, 1), Self.retentionDays)
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(count - 1), to: today) else { return [] }

        var totals: [EnergyDayTotal] = []
        totals.reserveCapacity(count)
        for offset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { continue }
            let bucket = stored.buckets.first { calendar.isDate($0.day, inSameDayAs: day) }
            let kwh = bucket.map { sum($0.perDevice.values) } ?? 0
            // A bucket only ever exists because a counter was read, so it implies observation even
            // if the recorded day list was trimmed.
            let isObserved = bucket != nil
                || stored.observedDays.contains { calendar.isDate($0, inSameDayAs: day) }
            totals.append(EnergyDayTotal(day: day, kwh: kwh, isObserved: isObserved))
        }
        return totals
    }

    /// Consumption per device for the window ending today, highest first. Only devices with a
    /// positive total appear, so an idle plug never claims a rank from invented data.
    public func deviceTotals(dayCount: Int = 7, now: Date = Date()) -> [EnergyDeviceTotal] {
        let count = min(max(dayCount, 1), Self.retentionDays)
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(count - 1), to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        var perDevice: [String: Double] = [:]
        for bucket in stored.buckets {
            let day = calendar.startOfDay(for: bucket.day)
            guard day >= first, day < tomorrow else { continue }
            for (deviceId, kwh) in bucket.perDevice {
                perDevice[deviceId, default: 0] += kwh
            }
        }

        return perDevice
            .filter { $0.value > 0 && $0.value.isFinite }
            .map { EnergyDeviceTotal(deviceId: $0.key, name: stored.names[$0.key] ?? $0.key, kwh: $0.value) }
            .sorted { lhs, rhs in
                if lhs.kwh != rhs.kwh { return lhs.kwh > rhs.kwh }
                return lhs.name < rhs.name
            }
    }

    /// Total consumption for the window ending today.
    public func totalKwh(dayCount: Int = 7, now: Date = Date()) -> Double {
        sum(dailyTotals(dayCount: dayCount, now: now).map(\.kwh))
    }

    /// Today's measured consumption for a single plug, or `nil` when no counter reading has been
    /// observed for this device today. Returns `0` once the plug has been observed today and its
    /// counter has not increased yet.
    public func todayKwh(forDevice deviceId: String, now: Date = Date()) -> Double? {
        let today = calendar.startOfDay(for: now)
        if let bucket = stored.buckets.first(where: { calendar.isDate($0.day, inSameDayAs: today) }),
           let kwh = bucket.perDevice[deviceId], kwh.isFinite, kwh >= 0 {
            return kwh
        }
        guard stored.baselines[deviceId] != nil,
              let lastSeen = stored.lastSampleAt[deviceId],
              calendar.isDate(lastSeen, inSameDayAs: today) else {
            return nil
        }
        return 0
    }

    // MARK: Price and cost

    /// Stores the price per kWh. A non-finite or non-positive value clears it (cost stays hidden).
    public func setPricePerKwh(_ value: Double?) {
        let sanitized = Self.sanitizedPrice(value)
        guard sanitized != pricePerKwh else { return }
        pricePerKwh = sanitized
        if let sanitized {
            defaults.set(sanitized, forKey: Self.priceKey)
        } else {
            defaults.removeObject(forKey: Self.priceKey)
        }
    }

    /// Cost of a measured amount, or `nil` when no price is configured.
    public func cost(forKwh kwh: Double) -> Double? {
        guard let price = pricePerKwh, kwh.isFinite, kwh >= 0 else { return nil }
        let cost = kwh * price
        return cost.isFinite ? cost : nil
    }

    /// Cost of a window's total, or `nil` when no price is configured.
    public func totalCost(dayCount: Int = 7, now: Date = Date()) -> Double? {
        cost(forKwh: totalKwh(dayCount: dayCount, now: now))
    }

    // MARK: Clearing

    /// Deletes every recorded sample, baseline and remembered name. The next observation of each
    /// counter becomes a new baseline, so clearing cannot manufacture a jump from the old reading.
    /// The price is a preference, not recorded consumption, so it survives.
    public func clear() {
        stored = EnergyHistoryStored()
        persist()
    }

    // MARK: Persistence

    private static let priceKey = "plug_energy_price_v1"

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func decode(from defaults: UserDefaults) -> EnergyHistoryStored {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(EnergyHistoryStored.self, from: data) else {
            return EnergyHistoryStored()
        }
        return decoded
    }

    private static func sanitized(_ stored: EnergyHistoryStored, calendar: Calendar) -> EnergyHistoryStored {
        var result = stored

        result.buckets = result.buckets.compactMap { bucket in
            let day = calendar.startOfDay(for: bucket.day)
            let perDevice = bucket.perDevice.filter { $0.value.isFinite && $0.value > 0 }
            guard !perDevice.isEmpty else { return nil }
            return EnergyHistoryBucket(day: day, perDevice: perDevice)
        }

        // Merge duplicate day buckets (defensive against a corrupted or hand-edited payload).
        var merged: [EnergyHistoryBucket] = []
        for bucket in result.buckets {
            if let index = merged.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: bucket.day) }) {
                for (deviceId, kwh) in bucket.perDevice {
                    merged[index].perDevice[deviceId, default: 0] += kwh
                }
            } else {
                merged.append(bucket)
            }
        }
        merged.sort { $0.day < $1.day }
        if merged.count > retentionDays {
            merged.removeFirst(merged.count - retentionDays)
        }
        result.buckets = merged

        var observed: [Date] = []
        for day in result.observedDays {
            let normalized = calendar.startOfDay(for: day)
            if !observed.contains(where: { calendar.isDate($0, inSameDayAs: normalized) }) {
                observed.append(normalized)
            }
        }
        observed.sort()
        if observed.count > retentionDays {
            observed.removeFirst(observed.count - retentionDays)
        }
        result.observedDays = observed

        result.baselines = result.baselines.filter { $0.value.isFinite && $0.value >= 0 }
        result.names = result.names.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return result
    }

    private static func sanitizedPrice(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Drops buckets and per-device tracking state older than the retention window so the payload
    /// cannot grow without bound.
    private func prune(now: Date) {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: today) else {
            return
        }

        stored.buckets.removeAll { calendar.startOfDay(for: $0.day) < cutoff }
        stored.buckets.sort { $0.day < $1.day }
        if stored.buckets.count > Self.retentionDays {
            stored.buckets.removeFirst(stored.buckets.count - Self.retentionDays)
        }

        stored.observedDays.removeAll { calendar.startOfDay(for: $0) < cutoff }
        stored.observedDays.sort()
        if stored.observedDays.count > Self.retentionDays {
            stored.observedDays.removeFirst(stored.observedDays.count - Self.retentionDays)
        }

        let recentDevices = Set(stored.buckets.flatMap { $0.perDevice.keys })
        let lastSampleAt = stored.lastSampleAt
        func isTracked(_ deviceId: String) -> Bool {
            recentDevices.contains(deviceId) || (lastSampleAt[deviceId] ?? .distantPast) >= cutoff
        }
        stored.baselines = stored.baselines.filter { isTracked($0.key) }
        stored.names = stored.names.filter { isTracked($0.key) }
        stored.lastSampleAt = lastSampleAt.filter { isTracked($0.key) }
    }

    private func sum<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        values.reduce(0, +)
    }

    /// Whether `earlier` still falls inside the retained day window ending at `now` — i.e. a delta
    /// measured from it can be attributed to a day the history still keeps.
    private func isInsideRetentionWindow(_ earlier: Date, now: Date) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: today) else {
            return false
        }
        return earlier >= cutoff
    }
}
