import Foundation
import SwiftUI
import MijiaCore

/// Settings → 通用 → 插座用电统计 (#62).
///
/// Reads the local `EnergyHistory` maintained by `HomeStore`: today / last-7-day totals, the
/// per-device ranking, a configurable price, and a one-click wipe. The copy deliberately states
/// that nothing is estimated from wattage and that recording starts with the first reading.
struct EnergySettingsSection: View {
    let store: HomeStore

    @State private var priceDraft = ""
    @State private var isConfirmingClear = false

    private var history: EnergyHistory { store.energyHistory }
    private var daily: [EnergyDayTotal] { history.dailyTotals(dayCount: 7) }
    private var ranking: [EnergyDeviceTotal] { history.deviceTotals(dayCount: 7) }

    var body: some View {
        let _ = store.effectiveLanguage
        SettingsSection(title: L10n.tr("插座用电统计", "Plug Energy")) {
            Text(L10n.tr(
                "只保存在这台 Mac 上，来源是每个插座自己的累计电量计数，不用功率估算用电。记录从第一次收到读数开始，之前的用电不会补算；第一次读数只作为基线。跨零点的增量记在前一个采样日，不拆分也不猜测，因此「今天」不会把昨天可能用掉的电算进来。记录保留 31 天，可随时清除。",
                "Stored on this Mac only. Every figure comes from each plug's own cumulative counter — usage is never estimated from wattage. Recording starts with the first reading; earlier usage is never backfilled, and the first reading only sets a baseline. A delta that spans midnight is credited to the earlier sample day instead of being split or guessed, so “today” cannot claim energy that may have been used yesterday. History keeps 31 days and can be cleared at any time."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let startedAt = history.recordingStartedAt {
                Text(L10n.tr(
                    "记录开始于 \(startedAt.formatted(date: .abbreviated, time: .shortened))",
                    "Recording since \(startedAt.formatted(date: .abbreviated, time: .shortened))"
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary.opacity(0.8))

                if !history.hasMeasuredConsumption {
                    Text(L10n.tr(
                        "已记下基线，还等第一次电量增长：只有插座计数真的涨了，才会产生用电数字。",
                        "The baseline is stored; the first measured increase is still pending. A figure appears only when a counter actually grows."
                    ))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L10n.tr(
                    "还没有收到插座的电量读数。接入带累计电量的插座后会自动开始记录。",
                    "No plug counter reading yet. Recording starts automatically once a plug that reports cumulative energy is connected."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.primary.opacity(0.06))

            summaryRow
            weekList
            rankingList

            Divider().overlay(Color.primary.opacity(0.06))

            priceRow
            clearRow
        }
        .onAppear { seedPriceDraft() }
        .confirmationDialog(
            L10n.tr("清除全部用电记录？", "Clear all energy history?"),
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("清除", "Clear"), role: .destructive) {
                history.clear()
                store.showToast(L10n.tr("已清除用电记录", "Energy history cleared"))
            }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr(
                "所有已记录的用电和基线都会被删除，之后从下一次读数重新开始。电价会保留。",
                "Every recorded sample and baseline is deleted; recording restarts from the next reading. The price is kept."
            ))
        }
    }

    // MARK: Today / last 7 days

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 16) {
            summaryColumn(
                title: L10n.tr("今天", "Today"),
                kwh: daily.last?.kwh ?? 0,
                isObserved: daily.last?.isObserved ?? false
            )
            summaryColumn(
                title: L10n.tr("最近 7 天", "Last 7 days"),
                kwh: history.totalKwh(dayCount: 7),
                isObserved: daily.contains { $0.isObserved }
            )
            Spacer(minLength: 0)
        }
    }

    private func summaryColumn(title: String, kwh: Double, isObserved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
            Text(isObserved ? Self.kwhText(kwh) : "—")
                .font(.system(size: DesignTokens.TypeSize.title, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if isObserved, let cost = costText(kwh) {
                Text(cost)
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    // MARK: Seven-day breakdown

    private var weekList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("最近 7 天每天用电", "Daily usage, last 7 days"))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(daily) { total in
                HStack(spacing: 8) {
                    Text(Self.dayLabel(total.day, isToday: total.id == daily.last?.id))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(.secondary)
                        .frame(width: 88, alignment: .leading)

                    bar(fraction: fraction(total.kwh, of: maxDayKwh), isActive: total.isObserved)

                    Text(total.isObserved ? Self.kwhText(total.kwh) : "—")
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .monospacedDigit()
                        .foregroundStyle(total.isObserved ? Color.primary : Color.secondary)
                        .frame(width: 66, alignment: .trailing)

                    Text(costLabel(for: total))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary.opacity(0.8))
                        .frame(width: 68, alignment: .trailing)
                }
            }

            Text(L10n.tr(
                "显示「—」表示当天没有记录（应用未运行或设备未上报），不代表没有用电。",
                "A “—” means nothing was recorded that day (the app was not running or the plug reported nothing) — it does not mean zero usage."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.secondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Device ranking

    private var rankingList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("设备排行（最近 7 天）", "By device (last 7 days)"))
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            if ranking.isEmpty {
                Text(L10n.tr(
                    "还没有可排行的用电增量。插座电量计数增长后会自动出现。",
                    "No measured increase yet. Devices appear once their counter grows."
                ))
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
            } else {
                ForEach(ranking.prefix(6)) { total in
                    HStack(spacing: 8) {
                        Image(systemName: "powerplug")
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(deviceName(for: total))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .lineLimit(1)
                            .frame(width: 104, alignment: .leading)

                        bar(fraction: fraction(total.kwh, of: maxRankingKwh), isActive: true)

                        Text(Self.kwhText(total.kwh))
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .monospacedDigit()
                            .frame(width: 66, alignment: .trailing)

                        Text(costText(total.kwh) ?? "")
                            .font(.system(size: DesignTokens.TypeSize.caption))
                            .monospacedDigit()
                            .foregroundStyle(.secondary.opacity(0.8))
                            .frame(width: 68, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Price

    private var priceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.tr("电价（每度）", "Price per kWh"))
                    .font(.system(size: DesignTokens.TypeSize.body))
                Spacer()
                TextField(L10n.tr("未设置", "Not set"), text: $priceDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .onSubmit { applyPrice() }
                Button(L10n.tr("保存", "Save")) { applyPrice() }
                    .buttonStyle(PillActionButtonStyle(isSelected: priceDraft != Self.priceDraftText(history.pricePerKwh)))
                    .disabled(priceDraft == Self.priceDraftText(history.pricePerKwh))
                if history.pricePerKwh != nil {
                    Button(L10n.tr("清除", "Clear")) {
                        history.setPricePerKwh(nil)
                        seedPriceDraft()
                    }
                    .buttonStyle(PillActionButtonStyle())
                }
            }
            Text(history.pricePerKwh == nil
                ? L10n.tr(
                    "金额默认隐藏。填入本地电价后，按实测电量换算费用，不用功率估算。",
                    "Cost is hidden until you enter your price. It is the measured energy times this price, never estimated from wattage."
                )
                : L10n.tr(
                    "金额 = 实测电量 × 电价，仅在本机计算。",
                    "Cost = measured energy × price, calculated on this Mac only."
                ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.secondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Clear

    private var clearRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(.secondary)
            Text(L10n.tr(
                "清除会删除全部用电记录与基线，下一次读数重新开始；电价保留。",
                "Clearing deletes every recorded sample and baseline so the next reading starts over; the price is kept."
            ))
            .font(.system(size: DesignTokens.TypeSize.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.tr("清除用电记录", "Clear energy history")) {
                isConfirmingClear = true
            }
            .buttonStyle(PillActionButtonStyle())
            .disabled(history.recordingStartedAt == nil)
        }
    }

    // MARK: Helpers

    private var maxDayKwh: Double {
        max(daily.map(\.kwh).max() ?? 0, 0.0001)
    }

    private var maxRankingKwh: Double {
        max(ranking.map(\.kwh).max() ?? 0, 0.0001)
    }

    private func fraction(_ value: Double, of maximum: Double) -> Double {
        guard maximum > 0, value.isFinite, value > 0 else { return 0 }
        return min(1, value / maximum)
    }

    private func bar(fraction: Double, isActive: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(isActive ? Color.accentColor.opacity(0.55) : Color.clear)
                    .frame(width: max(0, proxy.size.width * fraction))
            }
        }
        .frame(height: 7)
    }

    private func costLabel(for total: EnergyDayTotal) -> String {
        guard total.isObserved else { return "" }
        return costText(total.kwh) ?? ""
    }

    private func deviceName(for total: EnergyDeviceTotal) -> String {
        store.devices.first { $0.id == total.deviceId }?.name ?? total.name
    }

    private func seedPriceDraft() {
        priceDraft = Self.priceDraftText(history.pricePerKwh)
    }

    private func applyPrice() {
        let normalized = priceDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        history.setPricePerKwh(normalized.isEmpty ? nil : Double(normalized))
        seedPriceDraft()
    }

    /// The amount for a measured quantity, or `nil` while no price is configured. The currency
    /// symbol follows the system locale because the price itself is entered by hand.
    private func costText(_ kwh: Double) -> String? {
        guard let cost = history.cost(forKwh: kwh) else { return nil }
        return "≈ " + Self.currencySymbol + String(format: "%.2f", cost)
    }

    private static func priceDraftText(_ price: Double?) -> String {
        guard let price else { return "" }
        return String(format: "%.2f", price)
    }

    private static func dayLabel(_ day: Date, isToday: Bool) -> String {
        let text = day.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        return isToday ? "\(text) · \(L10n.tr("今天", "Today"))" : text
    }

    private static func kwhText(_ kwh: Double) -> String {
        if kwh > 0, kwh < 0.01 {
            return "<0.01 kWh"
        }
        return String(format: "%.2f kWh", kwh)
    }

    private static var currencySymbol: String {
        Locale.current.currencySymbol ?? "¥"
    }
}
