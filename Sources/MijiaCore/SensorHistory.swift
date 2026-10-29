import Foundation
import Observation

/// Time window displayed by the expandable sensor trend chart.
public enum SensorHistoryWindow: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case last24Hours = "24h"
    case last7Days = "7d"

    public var id: String { rawValue }

    public var bucketCount: Int {
        switch self {
        case .last24Hours: return 24
        case .last7Days: return 7
        }
    }
}

/// Metric selectable in the sensor trend chart.
public enum SensorMetricKind: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case temperature = "temperature"
    case humidity = "humidity"

    public var id: String { rawValue }
}

/// One historical reading or pre-aggregated bucket returned by a backend provider (e.g. Xiaomi Cloud).
public struct SensorHistorySample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let temperature: Double?
    public let minTemperature: Double?
    public let maxTemperature: Double?
    public let humidity: Double?
    public let minHumidity: Double?
    public let maxHumidity: Double?

    public init(
        timestamp: Date,
        temperature: Double? = nil,
        minTemperature: Double? = nil,
        maxTemperature: Double? = nil,
        humidity: Double? = nil,
        minHumidity: Double? = nil,
        maxHumidity: Double? = nil
    ) {
        self.timestamp = timestamp
        self.temperature = temperature
        self.minTemperature = minTemperature ?? temperature
        self.maxTemperature = maxTemperature ?? temperature
        self.humidity = humidity
        self.minHumidity = minHumidity ?? humidity
        self.maxHumidity = maxHumidity ?? humidity
    }
}

/// One time-aligned slot in a sensor trend chart (`24h` hourly or `7d` daily).
public struct SensorHistoryPoint: Equatable, Sendable, Identifiable {
    public let bucketStart: Date
    public let temperature: Double?
    public let minTemperature: Double?
    public let maxTemperature: Double?
    public let humidity: Double?
    public let minHumidity: Double?
    public let maxHumidity: Double?

    public var id: Date { bucketStart }

    public var isObserved: Bool {
        temperature != nil || humidity != nil
    }

    public init(
        bucketStart: Date,
        temperature: Double? = nil,
        minTemperature: Double? = nil,
        maxTemperature: Double? = nil,
        humidity: Double? = nil,
        minHumidity: Double? = nil,
        maxHumidity: Double? = nil
    ) {
        self.bucketStart = bucketStart
        self.temperature = temperature
        self.minTemperature = minTemperature ?? temperature
        self.maxTemperature = maxTemperature ?? temperature
        self.humidity = humidity
        self.minHumidity = minHumidity ?? humidity
        self.maxHumidity = maxHumidity ?? humidity
    }

    public func value(for metric: SensorMetricKind) -> Double? {
        switch metric {
        case .temperature: return temperature
        case .humidity: return humidity
        }
    }

    public func range(for metric: SensorMetricKind) -> (min: Double, max: Double)? {
        switch metric {
        case .temperature:
            guard let lo = minTemperature ?? temperature, let hi = maxTemperature ?? temperature else { return nil }
            return (min(lo, hi), max(lo, hi))
        case .humidity:
            guard let lo = minHumidity ?? humidity, let hi = maxHumidity ?? humidity else { return nil }
            return (min(lo, hi), max(lo, hi))
        }
    }
}

/// Summary statistics across the observed points of a chart window.
public struct SensorMetricSummary: Equatable, Sendable {
    public let min: Double
    public let max: Double
    public let average: Double
    public let latest: Double
    public let observedCount: Int

    public init(min: Double, max: Double, average: Double, latest: Double, observedCount: Int) {
        self.min = min
        self.max = max
        self.average = average
        self.latest = latest
        self.observedCount = observedCount
    }
}

private struct SensorBucketRecord: Codable, Equatable, Sendable {
    var bucketStart: Date
    var temperatureSum: Double = 0
    var temperatureCount: Int = 0
    var minTemperature: Double?
    var maxTemperature: Double?
    var humiditySum: Double = 0
    var humidityCount: Int = 0
    var minHumidity: Double?
    var maxHumidity: Double?

    var temperature: Double? {
        guard temperatureCount > 0 else { return nil }
        return ((temperatureSum / Double(temperatureCount)) * 10).rounded() / 10
    }

    var humidity: Double? {
        guard humidityCount > 0 else { return nil }
        return ((humiditySum / Double(humidityCount)) * 10).rounded() / 10
    }

    mutating func addSample(
        temperature t: Double?,
        minTemp tLo: Double? = nil,
        maxTemp tHi: Double? = nil,
        humidity h: Double?,
        minHum hLo: Double? = nil,
        maxHum hHi: Double? = nil,
        replace: Bool = false
    ) -> Bool {
        var changed = false
        if let t = SensorHistory.sanitizeTemperature(t) {
            let prevAvg = temperature
            let prevMin = minTemperature
            let prevMax = maxTemperature
            let lo = SensorHistory.sanitizeTemperature(tLo) ?? t
            let hi = SensorHistory.sanitizeTemperature(tHi) ?? t
            if replace || temperatureCount == 0 {
                temperatureSum = t
                temperatureCount = 1
                minTemperature = min(lo, hi)
                maxTemperature = max(lo, hi)
            } else {
                temperatureSum += t
                temperatureCount += 1
                minTemperature = min(minTemperature ?? lo, min(lo, hi))
                maxTemperature = max(maxTemperature ?? hi, max(lo, hi))
            }
            if let cur = temperature, prevAvg == nil || abs(cur - (prevAvg ?? cur)) >= 0.05
                || prevMin != minTemperature || prevMax != maxTemperature {
                changed = true
            }
        }
        if let h = SensorHistory.sanitizeHumidity(h) {
            let prevAvg = humidity
            let prevMin = minHumidity
            let prevMax = maxHumidity
            let lo = SensorHistory.sanitizeHumidity(hLo) ?? h
            let hi = SensorHistory.sanitizeHumidity(hHi) ?? h
            if replace || humidityCount == 0 {
                humiditySum = h
                humidityCount = 1
                minHumidity = min(lo, hi)
                maxHumidity = max(lo, hi)
            } else {
                humiditySum += h
                humidityCount += 1
                minHumidity = min(minHumidity ?? lo, min(lo, hi))
                maxHumidity = max(maxHumidity ?? hi, max(lo, hi))
            }
            if let cur = humidity, prevAvg == nil || abs(cur - (prevAvg ?? cur)) >= 0.2
                || prevMin != minHumidity || prevMax != maxHumidity {
                changed = true
            }
        }
        return changed
    }

    func toPoint() -> SensorHistoryPoint {
        SensorHistoryPoint(
            bucketStart: bucketStart,
            temperature: temperature,
            minTemperature: minTemperature ?? temperature,
            maxTemperature: maxTemperature ?? temperature,
            humidity: humidity,
            minHumidity: minHumidity ?? humidity,
            maxHumidity: maxHumidity ?? humidity
        )
    }
}

private struct SensorHistoryStored: Codable, Equatable, Sendable {
    var hourlyByDevice: [String: [SensorBucketRecord]] = [:]
    var dailyByDevice: [String: [SensorBucketRecord]] = [:]
    var cloudSyncedDevices: Set<String> = []
}

/// Local + Cloud merged time-series store for temperature and humidity sensors.
///
/// Local snapshots feed `record(devices:now:)` continuously while the app runs; opening a sensor's
/// chart drawer also triggers an on-demand cloud history fetch (`mergeCloudSamples`), filling in
/// hours or days reported by the home's Bluetooth/Zigbee gateway while the Mac was asleep.
@Observable
@MainActor
public final class SensorHistory {
    public static let retentionHours = 48
    public static let retentionDays = 14
    public static let storageKey = "sensor_history_v1"
    public static let cloudFetchCooldown: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let calendar: Calendar
    private var stored: SensorHistoryStored
    private var lastCloudFetchAt: [String: Date] = [:]
    private var loadingKeys: Set<String> = []
    /// Revision counter bumped on every mutation so SwiftUI views observing `SensorHistory` re-render.
    public private(set) var revision: Int = 0

    public init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        let loaded = Self.decode(from: defaults)
        self.stored = Self.sanitized(loaded, calendar: calendar)
    }

    // MARK: - Local Snapshot Recording

    public func record(devices: [SmartDevice], now: Date = Date()) {
        let hourStart = startOfHour(for: now)
        let dayStart = calendar.startOfDay(for: now)
        var shouldPersist = false

        for device in devices {
            guard device.isOnline, case .sensor(let spec) = device.kind else { continue }
            let t = Self.sanitizeTemperature(spec.temperature)
            let h = Self.sanitizeHumidity(spec.humidity)
            guard t != nil || h != nil else { continue }

            var hourly = stored.hourlyByDevice[device.id] ?? []
            if let idx = hourly.firstIndex(where: { isSameHour($0.bucketStart, hourStart) }) {
                if hourly[idx].addSample(temperature: t, humidity: h) {
                    shouldPersist = true
                }
            } else {
                var bucket = SensorBucketRecord(bucketStart: hourStart)
                _ = bucket.addSample(temperature: t, humidity: h)
                hourly.append(bucket)
                shouldPersist = true
            }
            stored.hourlyByDevice[device.id] = hourly

            var daily = stored.dailyByDevice[device.id] ?? []
            if let idx = daily.firstIndex(where: { calendar.isDate($0.bucketStart, inSameDayAs: dayStart) }) {
                if daily[idx].addSample(temperature: t, humidity: h) {
                    shouldPersist = true
                }
            } else {
                var bucket = SensorBucketRecord(bucketStart: dayStart)
                _ = bucket.addSample(temperature: t, humidity: h)
                daily.append(bucket)
                shouldPersist = true
            }
            stored.dailyByDevice[device.id] = daily
        }

        guard shouldPersist else { return }
        prune(now: now)
        persist()
        revision &+= 1
    }

    // MARK: - Cloud History Merging

    public func mergeCloudSamples(
        deviceId: String,
        window: SensorHistoryWindow,
        samples: [SensorHistorySample],
        now: Date = Date()
    ) {
        lastCloudFetchAt[syncKey(deviceId: deviceId, window: window)] = now
        guard !samples.isEmpty else {
            revision &+= 1
            return
        }

        var didChange = false
        for sample in samples {
            let t = Self.sanitizeTemperature(sample.temperature)
            let h = Self.sanitizeHumidity(sample.humidity)
            guard t != nil || h != nil else { continue }

            switch window {
            case .last24Hours:
                let hourStart = startOfHour(for: sample.timestamp)
                var hourly = stored.hourlyByDevice[deviceId] ?? []
                if let idx = hourly.firstIndex(where: { isSameHour($0.bucketStart, hourStart) }) {
                    if hourly[idx].addSample(
                        temperature: t,
                        minTemp: sample.minTemperature,
                        maxTemp: sample.maxTemperature,
                        humidity: h,
                        minHum: sample.minHumidity,
                        maxHum: sample.maxHumidity,
                        replace: true
                    ) {
                        didChange = true
                    }
                } else {
                    var bucket = SensorBucketRecord(bucketStart: hourStart)
                    _ = bucket.addSample(
                        temperature: t,
                        minTemp: sample.minTemperature,
                        maxTemp: sample.maxTemperature,
                        humidity: h,
                        minHum: sample.minHumidity,
                        maxHum: sample.maxHumidity,
                        replace: true
                    )
                    hourly.append(bucket)
                    didChange = true
                }
                stored.hourlyByDevice[deviceId] = hourly

            case .last7Days:
                let dayStart = calendar.startOfDay(for: sample.timestamp)
                var daily = stored.dailyByDevice[deviceId] ?? []
                if let idx = daily.firstIndex(where: { calendar.isDate($0.bucketStart, inSameDayAs: dayStart) }) {
                    if daily[idx].addSample(
                        temperature: t,
                        minTemp: sample.minTemperature,
                        maxTemp: sample.maxTemperature,
                        humidity: h,
                        minHum: sample.minHumidity,
                        maxHum: sample.maxHumidity,
                        replace: true
                    ) {
                        didChange = true
                    }
                } else {
                    var bucket = SensorBucketRecord(bucketStart: dayStart)
                    _ = bucket.addSample(
                        temperature: t,
                        minTemp: sample.minTemperature,
                        maxTemp: sample.maxTemperature,
                        humidity: h,
                        minHum: sample.minHumidity,
                        maxHum: sample.maxHumidity,
                        replace: true
                    )
                    daily.append(bucket)
                    didChange = true
                }
                stored.dailyByDevice[deviceId] = daily
            }
        }

        if !stored.cloudSyncedDevices.contains(deviceId) {
            stored.cloudSyncedDevices.insert(deviceId)
            didChange = true
        }

        if didChange {
            prune(now: now)
            persist()
        }
        revision &+= 1
    }

    // MARK: - Reading

    public func points(
        forDevice deviceId: String,
        window: SensorHistoryWindow,
        now: Date = Date()
    ) -> [SensorHistoryPoint] {
        _ = revision
        switch window {
        case .last24Hours:
            let currentHour = startOfHour(for: now)
            let count = window.bucketCount
            guard let firstHour = calendar.date(byAdding: .hour, value: -(count - 1), to: currentHour) else {
                return []
            }
            let buckets = stored.hourlyByDevice[deviceId] ?? []
            var result: [SensorHistoryPoint] = []
            result.reserveCapacity(count)
            for offset in 0..<count {
                guard let slot = calendar.date(byAdding: .hour, value: offset, to: firstHour) else { continue }
                if let match = buckets.first(where: { isSameHour($0.bucketStart, slot) }) {
                    result.append(match.toPoint())
                } else {
                    result.append(SensorHistoryPoint(bucketStart: slot))
                }
            }
            return result

        case .last7Days:
            let today = calendar.startOfDay(for: now)
            let count = window.bucketCount
            guard let firstDay = calendar.date(byAdding: .day, value: -(count - 1), to: today) else {
                return []
            }
            let buckets = stored.dailyByDevice[deviceId] ?? []
            var result: [SensorHistoryPoint] = []
            result.reserveCapacity(count)
            for offset in 0..<count {
                guard let slot = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
                if let match = buckets.first(where: { calendar.isDate($0.bucketStart, inSameDayAs: slot) }) {
                    result.append(match.toPoint())
                } else {
                    result.append(SensorHistoryPoint(bucketStart: slot))
                }
            }
            return result
        }
    }

    public func summary(
        forDevice deviceId: String,
        window: SensorHistoryWindow,
        metric: SensorMetricKind,
        now: Date = Date()
    ) -> SensorMetricSummary? {
        let pts = points(forDevice: deviceId, window: window, now: now)
        var values: [Double] = []
        var lo = Double.infinity
        var hi = -Double.infinity
        var latest: Double?

        for pt in pts {
            guard let v = pt.value(for: metric) else { continue }
            values.append(v)
            latest = v
            if let r = pt.range(for: metric) {
                lo = min(lo, r.min)
                hi = max(hi, r.max)
            } else {
                lo = min(lo, v)
                hi = max(hi, v)
            }
        }
        guard !values.isEmpty, let latest, lo.isFinite, hi.isFinite else { return nil }
        let avg = ((values.reduce(0, +) / Double(values.count)) * 10).rounded() / 10
        return SensorMetricSummary(
            min: lo,
            max: hi,
            average: avg,
            latest: latest,
            observedCount: values.count
        )
    }

    public func hasCloudHistory(forDevice deviceId: String) -> Bool {
        _ = revision
        return stored.cloudSyncedDevices.contains(deviceId)
    }

    public func isLoading(deviceId: String, window: SensorHistoryWindow) -> Bool {
        _ = revision
        return loadingKeys.contains(syncKey(deviceId: deviceId, window: window))
    }

    public func setLoading(_ loading: Bool, deviceId: String, window: SensorHistoryWindow) {
        let key = syncKey(deviceId: deviceId, window: window)
        if loading {
            loadingKeys.insert(key)
        } else {
            loadingKeys.remove(key)
        }
        revision &+= 1
    }

    public func shouldFetchCloud(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date = Date(),
        cooldown: TimeInterval = SensorHistory.cloudFetchCooldown
    ) -> Bool {
        let key = syncKey(deviceId: deviceId, window: window)
        if loadingKeys.contains(key) { return false }
        if let last = lastCloudFetchAt[key], now.timeIntervalSince(last) < cooldown {
            return false
        }
        return true
    }

    public func clear() {
        stored = SensorHistoryStored()
        lastCloudFetchAt.removeAll()
        loadingKeys.removeAll()
        persist()
        revision &+= 1
    }

    // MARK: - Helpers & Persistence

    public nonisolated static func sanitizeTemperature(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= -50, value <= 100 else { return nil }
        return (value * 10).rounded() / 10
    }

    public nonisolated static func sanitizeHumidity(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 100 else { return nil }
        return (value * 10).rounded() / 10
    }

    private func syncKey(deviceId: String, window: SensorHistoryWindow) -> String {
        "\(deviceId)|\(window.rawValue)"
    }

    private func startOfHour(for date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: comps) ?? date
    }

    private func isSameHour(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(startOfHour(for: lhs).timeIntervalSince(startOfHour(for: rhs))) < 1
    }

    private func prune(now: Date) {
        let currentHour = startOfHour(for: now)
        let hourCutoff = calendar.date(byAdding: .hour, value: -(Self.retentionHours - 1), to: currentHour) ?? .distantPast
        for (deviceId, buckets) in stored.hourlyByDevice {
            var trimmed = buckets.filter { $0.bucketStart >= hourCutoff }
            trimmed.sort { $0.bucketStart < $1.bucketStart }
            if trimmed.count > Self.retentionHours {
                trimmed.removeFirst(trimmed.count - Self.retentionHours)
            }
            if trimmed.isEmpty {
                stored.hourlyByDevice.removeValue(forKey: deviceId)
            } else {
                stored.hourlyByDevice[deviceId] = trimmed
            }
        }

        let today = calendar.startOfDay(for: now)
        let dayCutoff = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: today) ?? .distantPast
        for (deviceId, buckets) in stored.dailyByDevice {
            var trimmed = buckets.filter { calendar.startOfDay(for: $0.bucketStart) >= dayCutoff }
            trimmed.sort { $0.bucketStart < $1.bucketStart }
            if trimmed.count > Self.retentionDays {
                trimmed.removeFirst(trimmed.count - Self.retentionDays)
            }
            if trimmed.isEmpty {
                stored.dailyByDevice.removeValue(forKey: deviceId)
            } else {
                stored.dailyByDevice[deviceId] = trimmed
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func decode(from defaults: UserDefaults) -> SensorHistoryStored {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SensorHistoryStored.self, from: data) else {
            return SensorHistoryStored()
        }
        return decoded
    }

    private static func sanitized(_ stored: SensorHistoryStored, calendar: Calendar) -> SensorHistoryStored {
        var result = stored
        for (deviceId, buckets) in result.hourlyByDevice {
            let valid = buckets.filter { $0.temperatureCount > 0 || $0.humidityCount > 0 }
                .sorted { $0.bucketStart < $1.bucketStart }
            if valid.isEmpty {
                result.hourlyByDevice.removeValue(forKey: deviceId)
            } else {
                result.hourlyByDevice[deviceId] = Array(valid.suffix(retentionHours))
            }
        }
        for (deviceId, buckets) in result.dailyByDevice {
            let valid = buckets.filter { $0.temperatureCount > 0 || $0.humidityCount > 0 }
                .sorted { $0.bucketStart < $1.bucketStart }
            if valid.isEmpty {
                result.dailyByDevice.removeValue(forKey: deviceId)
            } else {
                result.dailyByDevice[deviceId] = Array(valid.suffix(retentionDays))
            }
        }
        return result
    }
}
