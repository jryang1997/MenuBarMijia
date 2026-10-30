import SwiftUI
import MijiaCore

/// Temperature / humidity sensor card: large temperature, humidity ring, comfort hint, battery,
/// plus an expandable time-series trend chart drawer (`24h` hourly / `7d` daily).
/// Compact (half row) stacks temperature over a humidity bar; full row lays them out side by side.
struct SensorCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEditingLayout) private var isEditingLayout
    /// Observed so a temperature-unit change in Settings re-renders open cards (#52).
    @AppStorage(TemperatureUnitPreference.storageKey) private var temperatureUnitRaw = TemperatureUnitPreference.system.rawValue

    let device: SmartDevice
    let spec: SensorSpec
    var store: HomeStore? = nil
    let isCompact: Bool
    let showRoomBadge: Bool
    var forceExpanded: Bool = false

    @State private var selectedWindow: SensorHistoryWindow = .last24Hours
    @State private var selectedMetric: SensorMetricKind = .temperature
    @State private var hoveredSlotIndex: Int? = nil

    private var isExpanded: Bool {
        if forceExpanded { return true }
        return store?.expandedDeviceId == device.id
    }

    private var fg: Color { .primary }
    private var muted: Color { .secondary }
    private var track: Color { Color.primary.opacity(0.08) }

    var body: some View {
        Group {
            if isExpanded {
                expandedContainer
            } else if isCompact {
                compact
            } else {
                wide
            }
        }
        .frame(minHeight: (isCompact && !isExpanded) ? 50 : nil, maxHeight: isExpanded ? nil : .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditingLayout, let store else { return }
            withAnimation(AppleMotion.snappySpring) {
                store.toggleExpanded(device.id)
            }
        }
        .glassTile(isActive: false, cornerRadius: DesignTokens.Radius.card)
        .opacity(device.isOnline ? 1 : 0.58)
        // Display-only card when collapsed: VoiceOver reads one sentence instead of five loose labels (#41).
        .accessibilityElement(children: isExpanded ? .contain : .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityAddTraits(.isButton)
        .panelHelp(isExpanded
            ? L10n.tr("点击卡片顶部收起折线图", "Click header to collapse chart")
            : L10n.tr("点击展开温湿度分时段折线", "Click to expand temperature & humidity chart"))
    }

    private var accessibilitySummary: String {
        guard device.isOnline else {
            return L10n.tr("\(device.name)，离线", "\(device.name), offline")
        }
        var parts: [String] = [device.name]
        if let t = spec.temperature {
            parts.append(L10n.format("温度 %@", "temperature %@", L10n.temperature(t, fractionDigits: 1)))
        }
        if let h = spec.humidity {
            parts.append(String(format: L10n.tr("湿度 %.0f%%", "humidity %.0f%%"), h))
        }
        if let b = spec.battery {
            parts.append(L10n.tr("电量 \(b)%", "battery \(b)%"))
        }
        return parts.joined(separator: "，")
    }

    // MARK: Layouts

    private var compact: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(tempColor)
                Text(displayName)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                Spacer(minLength: 2)
                comfortChip
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                temperatureText(size: DesignTokens.TypeSize.reading)
                if let h = spec.humidity {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                        Text(String(format: "%.0f%%", h))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(humidityColor)
                }
            }
            humidityBar
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private var wide: some View {
        wideContent(showCollapseChevron: false)
    }

    private func wideContent(showCollapseChevron: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(displayName)
                        .font(.system(size: DesignTokens.TypeSize.body, weight: .semibold))
                        .foregroundStyle(fg)
                        .lineLimit(1)
                    if showRoomBadge {
                        Text(L10n.displayRoomName(device.roomName))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                            .foregroundStyle(muted)
                    }
                    if showCollapseChevron {
                        Image(systemName: "chevron.up")
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .bold))
                            .foregroundStyle(muted)
                            .padding(.leading, 1)
                    }
                }
                temperatureText(size: DesignTokens.TypeSize.reading)
                HStack(spacing: 6) {
                    comfortChip
                    if let b = spec.battery {
                        Label("\(b)%", systemImage: batterySymbol(b))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(b <= 20 ? Color.red : muted)
                    }
                }
            }
            Spacer(minLength: 0)
            if let h = spec.humidity { humidityRing(h) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Expanded Chart Container

    private var expandedContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            wideContent(showCollapseChevron: !forceExpanded)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isEditingLayout, !forceExpanded, let store else { return }
                    withAnimation(AppleMotion.snappySpring) {
                        store.toggleExpanded(device.id)
                    }
                }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 14)

            historyDrawer
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .transition(AppleMotion.drawerTransition)
                // Absorb taps inside the chart controls so switching 24h/7d or metric never collapses the card.
                .onTapGesture {}
        }
        .onAppear {
            if spec.temperature == nil && spec.humidity != nil {
                selectedMetric = .humidity
            }
            store?.requestSensorHistory(for: device.id, window: selectedWindow)
        }
        .onChange(of: selectedWindow) { _, newWindow in
            hoveredSlotIndex = nil
            store?.requestSensorHistory(for: device.id, window: newWindow)
        }
    }

    private var historyPoints: [SensorHistoryPoint] {
        guard let store else { return [] }
        return store.sensorHistory.points(forDevice: device.id, window: selectedWindow)
    }

    private var historySummary: SensorMetricSummary? {
        guard let store else { return nil }
        return store.sensorHistory.summary(forDevice: device.id, window: selectedWindow, metric: selectedMetric)
    }

    private var isSyncingCloud: Bool {
        store?.sensorHistory.isLoading(deviceId: device.id, window: selectedWindow) ?? false
    }

    private var activeMetricColor: Color {
        selectedMetric == .temperature ? tempColor : humidityColor
    }

    private var historyDrawer: some View {
        let points = historyPoints
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                metricPicker
                Spacer(minLength: 4)
                windowPicker
            }

            readoutBar(points: points)

            chartPlot(points: points)
                .frame(height: 96)

            axisFooter(points: points)
        }
    }

    private var metricPicker: some View {
        HStack(spacing: 3) {
            metricTab(.temperature, title: L10n.tr("温度", "Temp"), symbol: "thermometer.medium", tint: tempColor)
            metricTab(.humidity, title: L10n.tr("湿度", "Humidity"), symbol: "drop.fill", tint: humidityColor)
        }
        .padding(2.5)
        .background(Capsule(style: .continuous).fill(track))
    }

    private func metricTab(_ kind: SensorMetricKind, title: String, symbol: String, tint: Color) -> some View {
        let isSelected = selectedMetric == kind
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedMetric = kind
            }
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: symbol)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : muted)
                Text(title)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? fg : muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var windowPicker: some View {
        HStack(spacing: 3) {
            windowTab(.last24Hours, title: L10n.tr("24小时", "24h"))
            windowTab(.last7Days, title: L10n.tr("7天", "7d"))
        }
        .padding(2.5)
        .background(Capsule(style: .continuous).fill(track))
    }

    private func windowTab(_ window: SensorHistoryWindow, title: String) -> some View {
        let isSelected = selectedWindow == window
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedWindow = window
            }
        } label: {
            Text(title)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? fg : muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func readoutBar(points: [SensorHistoryPoint]) -> some View {
        HStack(spacing: 6) {
            if let idx = hoveredSlotIndex, points.indices.contains(idx) {
                let pt = points[idx]
                Text(slotDetailLabel(pt.bucketStart))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fg)

                if pt.isObserved {
                    HStack(spacing: 6) {
                        if let t = pt.temperature {
                            Text(formattedTemperaturePoint(pt, fallback: t))
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(tempColor)
                        }
                        if let h = pt.humidity {
                            Text(formattedHumidityPoint(pt, fallback: h))
                                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(humidityColor)
                        }
                    }
                } else {
                    Text(L10n.tr("该时段无记录", "No reading"))
                        .font(.system(size: DesignTokens.TypeSize.caption))
                        .foregroundStyle(muted)
                }
            } else if let summary = historySummary {
                HStack(spacing: 8) {
                    statBadge(label: L10n.tr("最新", "Latest"), value: formatMetric(summary.latest, kind: selectedMetric))
                    statBadge(label: L10n.tr("最高", "High"), value: formatMetric(summary.max, kind: selectedMetric))
                    statBadge(label: L10n.tr("最低", "Low"), value: formatMetric(summary.min, kind: selectedMetric))
                    statBadge(label: L10n.tr("均值", "Avg"), value: formatMetric(summary.average, kind: selectedMetric))
                }
            } else {
                Text(L10n.tr("正在收集分时段温湿度样本…", "Collecting time-series readings…"))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(muted)
            }

            Spacer(minLength: 4)

            if isSyncingCloud {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                    Text(L10n.tr("同步中", "Syncing"))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                        .foregroundStyle(muted)
                }
            } else if let store {
                let hasCloud = store.sensorHistory.hasCloudHistory(forDevice: device.id)
                Text(hasCloud
                    ? (store.homeBackend == .demo ? L10n.tr("演示曲线", "Demo") : L10n.tr("云端+本机", "Cloud + Local"))
                    : L10n.tr("本机记录", "Local"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(muted.opacity(0.85))
            }
        }
        .frame(minHeight: 16)
    }

    private func statBadge(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: DesignTokens.TypeSize.caption))
                .foregroundStyle(muted)
            Text(value)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(fg)
        }
    }

    // MARK: - Chart Plot

    private func chartPlot(points: [SensorHistoryPoint]) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let observed: [(index: Int, value: Double, lo: Double, hi: Double)] = points.enumerated().compactMap { idx, pt in
                guard let v = pt.value(for: selectedMetric) else { return nil }
                let r = pt.range(for: selectedMetric) ?? (v, v)
                return (idx, v, r.min, r.max)
            }
            let bounds = yBounds(for: observed, metric: selectedMetric)
            let span = max(bounds.max - bounds.min, 0.1)
            let topPad: CGFloat = 8
            let bottomPad: CGFloat = 8
            let plotHeight = max(size.height - topPad - bottomPad, 1)
            let count = max(points.count, 2)

            let xForIndex = { (idx: Int) -> CGFloat in
                guard count > 1 else { return size.width / 2 }
                return CGFloat(idx) / CGFloat(count - 1) * size.width
            }
            let yForValue = { (val: Double) -> CGFloat in
                let normalized = min(max((val - bounds.min) / span, 0), 1)
                return topPad + plotHeight * CGFloat(1 - normalized)
            }

            ZStack(alignment: .topLeading) {
                // Horizontal reference grid lines (top, mid, bottom)
                ForEach([0.0, 0.5, 1.0], id: \.self) { frac in
                    let y = topPad + plotHeight * CGFloat(frac)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(
                        Color.primary.opacity(0.06),
                        style: StrokeStyle(lineWidth: DesignTokens.hairline, dash: frac == 0.5 ? [3, 3] : [])
                    )
                }

                if observed.count >= 2 {
                    let coords = observed.map { CGPoint(x: xForIndex($0.index), y: yForValue($0.value)) }

                    // Min-max band when buckets carry a range (e.g. 7-day high/low)
                    if observed.contains(where: { ($0.hi - $0.lo) >= 0.2 }) {
                        Path { p in
                            for (i, item) in observed.enumerated() {
                                let pt = CGPoint(x: xForIndex(item.index), y: yForValue(item.hi))
                                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                            }
                            for item in observed.reversed() {
                                p.addLine(to: CGPoint(x: xForIndex(item.index), y: yForValue(item.lo)))
                            }
                            p.closeSubpath()
                        }
                        .fill(activeMetricColor.opacity(0.10))
                    }

                    // Smooth area fill under the line
                    smoothAreaPath(coords: coords, baselineY: topPad + plotHeight)
                        .fill(
                            LinearGradient(
                                colors: [activeMetricColor.opacity(0.28), activeMetricColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Smooth trend line
                    smoothLinePath(coords: coords)
                        .stroke(
                            activeMetricColor,
                            style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                        )
                } else if let single = observed.first {
                    let pt = CGPoint(x: xForIndex(single.index), y: yForValue(single.value))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: pt.y))
                        p.addLine(to: CGPoint(x: size.width, y: pt.y))
                    }
                    .stroke(activeMetricColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                }

                // Data nodes
                ForEach(observed, id: \.index) { item in
                    let pt = CGPoint(x: xForIndex(item.index), y: yForValue(item.value))
                    let isHovered = hoveredSlotIndex == item.index
                    let isLatest = item.index == observed.last?.index
                    if isHovered || isLatest || selectedWindow == .last7Days || observed.count <= 8 {
                        Circle()
                            .fill(activeMetricColor)
                            .frame(width: isHovered ? 7 : 4.5, height: isHovered ? 7 : 4.5)
                            .overlay(
                                Circle().stroke(Color.white.opacity(0.9), lineWidth: isHovered ? 1.5 : 0.8)
                            )
                            .position(pt)
                    }
                }

                // Hover vertical scrubber line
                if let hovered = hoveredSlotIndex, points.indices.contains(hovered) {
                    let x = xForIndex(hovered)
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 2))
                        p.addLine(to: CGPoint(x: x, y: size.height - 2))
                    }
                    .stroke(
                        Color.primary.opacity(0.24),
                        style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5])
                    )
                }

                // Y-axis top & bottom scale labels
                VStack(alignment: .trailing) {
                    Text(formatMetric(bounds.max, kind: selectedMetric))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(muted.opacity(0.75))
                    Spacer()
                    Text(formatMetric(bounds.min, kind: selectedMetric))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(muted.opacity(0.75))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.vertical, 1)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    guard points.count > 1, size.width > 1 else {
                        hoveredSlotIndex = points.indices.first
                        return
                    }
                    let ratio = min(max(loc.x / size.width, 0), 1)
                    let idx = Int((ratio * CGFloat(points.count - 1)).rounded())
                    if hoveredSlotIndex != idx {
                        hoveredSlotIndex = idx
                    }
                case .ended:
                    hoveredSlotIndex = nil
                }
            }
        }
    }

    private func axisFooter(points: [SensorHistoryPoint]) -> some View {
        let ticks = axisTickIndices(count: points.count, window: selectedWindow)
        return HStack(spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { pos, idx in
                if pos > 0 { Spacer(minLength: 2) }
                if points.indices.contains(idx) {
                    Text(axisLabel(for: points[idx].bucketStart, isLast: idx == points.count - 1))
                        .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(hoveredSlotIndex == idx ? fg : muted)
                }
            }
        }
    }

    // MARK: - Path & Formatting Helpers

    private func smoothLinePath(coords: [CGPoint]) -> Path {
        Path { path in
            guard let first = coords.first else { return }
            path.move(to: first)
            guard coords.count > 1 else { return }
            for i in 1..<coords.count {
                let prev = coords[i - 1]
                let cur = coords[i]
                // Connect across large missing-bucket gaps with a straight segment; smooth adjacent points.
                let midX = (prev.x + cur.x) / 2
                path.addCurve(
                    to: cur,
                    control1: CGPoint(x: midX, y: prev.y),
                    control2: CGPoint(x: midX, y: cur.y)
                )
            }
        }
    }

    private func smoothAreaPath(coords: [CGPoint], baselineY: CGFloat) -> Path {
        var path = smoothLinePath(coords: coords)
        if let last = coords.last, let first = coords.first {
            path.addLine(to: CGPoint(x: last.x, y: baselineY))
            path.addLine(to: CGPoint(x: first.x, y: baselineY))
            path.closeSubpath()
        }
        return path
    }

    private func yBounds(
        for observed: [(index: Int, value: Double, lo: Double, hi: Double)],
        metric: SensorMetricKind
    ) -> (min: Double, max: Double) {
        guard !observed.isEmpty else {
            return metric == .temperature ? (18, 30) : (30, 80)
        }
        let rawMin = observed.map(\.lo).min() ?? 0
        let rawMax = observed.map(\.hi).max() ?? 100
        let minSpan = metric == .temperature ? 2.0 : 8.0
        let pad = max((rawMax - rawMin) * 0.18, minSpan / 2)
        let lo = (rawMin - pad).rounded(.down)
        let hi = (rawMax + pad).rounded(.up)
        if hi - lo < minSpan {
            let mid = (rawMin + rawMax) / 2
            return (mid - minSpan / 2, mid + minSpan / 2)
        }
        if metric == .humidity {
            return (max(0, lo), min(100, hi))
        }
        return (lo, hi)
    }

    private func axisTickIndices(count: Int, window: SensorHistoryWindow) -> [Int] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        switch window {
        case .last24Hours:
            // Show 5 evenly spaced hourly ticks ending at the current hour: -23h, -18h, -12h, -6h, now
            let candidates = [0, 5, 11, 17, count - 1]
            return candidates.filter { $0 >= 0 && $0 < count }
        case .last7Days:
            return Array(0..<count)
        }
    }

    private func axisLabel(for date: Date, isLast: Bool) -> String {
        switch selectedWindow {
        case .last24Hours:
            if isLast { return L10n.tr("现在", "Now") }
            let hour = Calendar.current.component(.hour, from: date)
            return String(format: "%02d:00", hour)
        case .last7Days:
            if isLast { return L10n.tr("今天", "Today") }
            return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
        }
    }

    private func slotDetailLabel(_ date: Date) -> String {
        let cal = Calendar.current
        switch selectedWindow {
        case .last24Hours:
            let hour = cal.component(.hour, from: date)
            let prefix = cal.isDateInToday(date)
                ? L10n.tr("今天", "Today")
                : L10n.tr("昨天", "Yesterday")
            return String(format: "%@ %02d:00", prefix, hour)
        case .last7Days:
            if cal.isDateInToday(date) { return L10n.tr("今天", "Today") }
            if cal.isDateInYesterday(date) { return L10n.tr("昨天", "Yesterday") }
            return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
    }

    private func formatMetric(_ value: Double, kind: SensorMetricKind) -> String {
        switch kind {
        case .temperature:
            return L10n.temperatureValue(value, fractionDigits: 1) + "°"
        case .humidity:
            return String(format: "%.0f%%", value)
        }
    }

    private func formattedTemperaturePoint(_ pt: SensorHistoryPoint, fallback: Double) -> String {
        if let r = pt.range(for: .temperature), abs(r.max - r.min) >= 0.3 {
            let lo = L10n.temperatureValue(r.min, fractionDigits: 1)
            let hi = L10n.temperatureValue(r.max, fractionDigits: 1)
            return "\(lo)~" + hi + L10n.temperatureSymbol
        }
        return L10n.temperature(fallback, fractionDigits: 1)
    }

    private func formattedHumidityPoint(_ pt: SensorHistoryPoint, fallback: Double) -> String {
        if let r = pt.range(for: .humidity), abs(r.max - r.min) >= 1.5 {
            return String(format: "%.0f~%.0f%%", r.min, r.max)
        }
        return String(format: "%.0f%%", fallback)
    }

    // MARK: Pieces

    private func temperatureText(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(spec.temperature.map { L10n.temperatureValue($0, fractionDigits: 1) } ?? "--")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: spec.temperature ?? 0))
                .foregroundStyle(fg)
            Text(L10n.temperatureSymbol)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                .foregroundStyle(muted)
        }
    }

    private var humidityBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(track)
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [humidityColor.opacity(0.6), humidityColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(max((spec.humidity ?? 0) / 100, 0), 1)))
            }
        }
        .frame(height: isCompact ? 3 : 4)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: spec.humidity)
    }

    private func humidityRing(_ h: Double) -> some View {
        ZStack {
            Circle().stroke(track, lineWidth: 6)
            // Comfortable band 40–60% drawn faintly behind the value arc.
            Circle()
                .trim(from: 0.4, to: 0.6)
                .stroke(humidityColor.opacity(0.15), style: StrokeStyle(lineWidth: 6, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: CGFloat(min(max(h / 100, 0), 1)))
                .stroke(
                    AngularGradient(colors: [humidityColor.opacity(0.55), humidityColor], center: .center),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Image(systemName: "drop.fill")
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                    .foregroundStyle(humidityColor)
                Text(String(format: "%.0f%%", h))
                    .font(.system(size: DesignTokens.TypeSize.title, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fg)
            }
        }
        .frame(width: 62, height: 62)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: h)
    }

    private var comfortChip: some View {
        let label = comfortLabel
        return Text(label)
            .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
            .foregroundStyle(muted)
            .padding(.horizontal, isCompact ? 5.5 : 6)
            .padding(.vertical, isCompact ? 1.5 : 2)
            .background(Capsule(style: .continuous).fill(track))
    }

    // MARK: Semantics

    private var displayName: String {
        let n = device.name.replacingOccurrences(of: "米家智能温湿度计", with: "温湿度计")
        return n.isEmpty ? device.name : n
    }

    private var comfortLabel: String {
        let t = spec.temperature ?? 24, h = spec.humidity ?? 50
        if t >= 28 { return L10n.tr("偏热", "Warm") }
        if t <= 16 { return L10n.tr("偏冷", "Cool") }
        if h < 35 { return L10n.tr("偏干", "Dry") }
        if h > 70 { return L10n.tr("偏湿", "Humid") }
        return L10n.tr("舒适", "Comfy")
    }

    private var tempColor: Color { muted }

    private var humidityColor: Color { .secondary }

    private func batterySymbol(_ b: Int) -> String {
        switch b {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
