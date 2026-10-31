import Foundation

// Menu-bar metrics and the derived device lists the panel renders (#48).
extension HomeStore {
    // MARK: - Computed Views of State

    public var activeDeviceCount: Int {
        devices.filter(\.isActiveOn).count
    }

    public var onlineDeviceCount: Int {
        devices.filter(\.isOnline).count
    }

    public var totalPowerWatts: Double {
        devices.reduce(0.0) { acc, dev in
            guard dev.isOnline, case .plug(let s) = dev.kind, s.isOn else { return acc }
            return acc + (s.powerWatts ?? 0)
        }
    }

    public var availableMenuBarOptions: [MenuBarMetricOption] {
        let _ = effectiveLanguage
        var opts: [MenuBarMetricOption] = [
            MenuBarMetricOption(id: "auto:primary", title: L10n.tr("自动（第一个温度传感器）", "Auto (First Temp Sensor)"))
        ]
        for env in environmentReadings where env.temperature != nil {
            opts.append(MenuBarMetricOption(id: "temp:\(env.id)", title: L10n.tr("\(env.label) · 温度", "\(env.label) · Temp")))
            if env.humidity != nil {
                opts.append(MenuBarMetricOption(id: "temp_hum:\(env.id)", title: L10n.tr("\(env.label) · 温湿度", "\(env.label) · Temp & Humidity")))
            }
        }
        opts.append(MenuBarMetricOption(id: "power:total", title: L10n.tr("全屋实时总功率 (W)", "Total Home Power (W)")))
        opts.append(MenuBarMetricOption(id: "active:count", title: L10n.tr("开启设备数量", "Active Device Count")))
        opts.append(MenuBarMetricOption(id: "icon:only", title: L10n.tr("仅显示图标", "Icon Only")))
        return opts
    }

    /// The environment reading selected for `menuBarTargetId` (`temp:<id>` / `temp_hum:<id>`),
    /// falling back to the first reading with a temperature, or the first reading overall (#103).
    public var preferredEnvironmentReading: EnvironmentReading? {
        for prefix in ["temp:", "temp_hum:"] where menuBarTargetId.hasPrefix(prefix) {
            let targetId = String(menuBarTargetId.dropFirst(prefix.count))
            if let match = environmentReadings.first(where: { $0.id == targetId && $0.temperature != nil }) {
                return match
            }
        }
        return environmentReadings.first(where: { $0.temperature != nil }) ?? environmentReadings.first
    }

    public var hiddenDevices: [SmartDevice] {
        devices.filter { hiddenDeviceIds.contains($0.id) }
    }

    public var filteredDevices: [SmartDevice] {
        devices.filter { dev in
            if hiddenDeviceIds.contains(dev.id) { return false }
            if hideOfflineDevices && !dev.isOnline { return false }
            if let roomId = selectedRoomId {
                return dev.roomId == roomId
            }
            return true
        }
    }

    public var favoriteDevices: [SmartDevice] {
        let favs = filteredDevices.filter { favoriteDeviceIds.contains($0.id) }
        guard !favoriteOrder.isEmpty else { return favs }
        let orderIndex = Dictionary(uniqueKeysWithValues: favoriteOrder.enumerated().map { ($1, $0) })
        return favs.sorted { a, b in
            let ia = orderIndex[a.id] ?? Int.max
            let ib = orderIndex[b.id] ?? Int.max
            if ia != ib { return ia < ib }
            return false
        }
    }

    public var nonFavoriteDevices: [SmartDevice] {
        filteredDevices.filter { !favoriteDeviceIds.contains($0.id) }
    }

    public var orderedVisibleDevices: [SmartDevice] {
        if selectedRoomId == nil {
            return favoriteDevices + nonFavoriteDevices
        }
        return filteredDevices
    }

    public var menuBarSymbolName: String {
        activeDeviceCount > 0 ? "house.fill" : "house"
    }

    public var menuBarText: String? {
        let sensorReading = { (prefix: String) -> EnvironmentReading? in
            guard self.menuBarTargetId.hasPrefix(prefix) else { return nil }
            let sensorId = String(self.menuBarTargetId.dropFirst(prefix.count))
            return self.environmentReadings.first(where: { $0.id == sensorId && $0.temperature != nil })
                ?? self.environmentReadings.first(where: { $0.temperature != nil })
                ?? self.environmentReadings.first
        }

        if let env = sensorReading("temp:"), let t = env.temperature {
            return L10n.temperature(t, fractionDigits: 1)
        }
        if let env = sensorReading("temp_hum:"), let t = env.temperature {
            if let h = env.humidity {
                return "\(L10n.temperature(t, fractionDigits: 1)) \(String(format: "%.0f%%", h))"
            }
            return L10n.temperature(t, fractionDigits: 1)
        }
        if menuBarTargetId == "power:total" {
            return String(format: "%.0fW", totalPowerWatts)
        }
        if menuBarTargetId == "active:count" {
            let _ = effectiveLanguage
            return activeDeviceCount > 0 ? L10n.tr("\(activeDeviceCount)开", "\(activeDeviceCount) On") : nil
        }
        if menuBarTargetId == "icon:only" {
            return nil
        }

        switch menuBarDisplayMode {
        case .iconOnly:
            return nil
        case .sensorTemperature:
            // No room names: the first reading that actually reports a temperature (#36).
            if let sensor = environmentReadings.first(where: { $0.temperature != nil }),
               let t = sensor.temperature {
                return L10n.temperature(t, fractionDigits: 1)
            }
            return nil
        case .activeCount:
            let _ = effectiveLanguage
            return activeDeviceCount > 0 ? L10n.tr("\(activeDeviceCount)开", "\(activeDeviceCount) On") : nil
        }
    }
}
