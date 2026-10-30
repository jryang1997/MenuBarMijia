import SwiftUI
import AppKit
import MijiaCore

/// Per-device card size picked from the card's context menu.
public enum TileSize: String, CaseIterable, Identifiable, Sendable {
    case auto, half, full, panel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return L10n.tr("自动", "Auto")
        case .half: return L10n.tr("半行", "Half Row")
        case .full: return L10n.tr("整行", "Full Row")
        case .panel: return L10n.tr("展开面板", "Open Panel")
        }
    }

    public var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .half: return "rectangle.split.2x1"
        case .full: return "rectangle"
        case .panel: return "rectangle.expand.vertical"
        }
    }
}

/// Stores `[deviceId: TileSize]` as JSON under one defaults key so views can observe it with `@AppStorage`.
public enum DeviceLayoutPrefs {
    public static let storageKey = "device_tile_sizes"

    public static func decode(_ raw: String) -> [String: TileSize] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict.compactMapValues(TileSize.init(rawValue:))
    }

    public static func encode(_ sizes: [String: TileSize]) -> String {
        // A page-scoped "auto" is kept: it overrides a non-auto default set for every page.
        let dict = sizes.filter { $0.value != .auto || $0.key.contains("|") }.mapValues(\.rawValue)
        guard let data = try? JSONEncoder().encode(dict) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Memoised decode: cards read their size on every render, the JSON only changes on edits.
    @MainActor private static var cache: (raw: String, sizes: [String: TileSize]) = ("", [:])

    /// Size for a device on one page (`scope` = room id or "all"); falls back to the all-pages default.
    @MainActor
    public static func cachedSize(raw: String, id: String, scope: String) -> TileSize {
        if cache.raw != raw { cache = (raw, decode(raw)) }
        return lookup(cache.sizes, id: id, scope: scope)
    }

    public static func lookup(_ sizes: [String: TileSize], id: String, scope: String) -> TileSize {
        sizes[scopedKey(id: id, scope: scope)] ?? sizes[id] ?? .auto
    }

    public static func scopedKey(id: String, scope: String) -> String { "\(scope)|\(id)" }

    /// Resolves `.auto` into a concrete size for the current grid mode and climate setting.
    public static func resolved(_ size: TileSize, device: SmartDevice, compactGrid: Bool, climatePanel: Bool) -> TileSize {
        guard size == .auto else { return size }
        if case .climate = device.kind, climatePanel { return .full }
        return compactGrid ? .half : .full
    }
}

// MARK: - Custom Order

extension DeviceLayoutPrefs {
    public static let orderKey = "device_custom_order"

    public static func decodeOrder(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    public static func encodeOrder(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Sorts by the saved order; devices not in it keep their incoming order after the known ones.
    public static func apply(order: [String], to devices: [SmartDevice]) -> [SmartDevice] {
        guard !order.isEmpty else { return devices }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return devices.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? (order.count + a.offset)
            let rb = rank[b.element.id] ?? (order.count + b.offset)
            return ra < rb
        }.map(\.element)
    }
}

// MARK: - Edit Mode (long-press → jiggle, drag to reorder, tap badge to resize)

private struct LayoutEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var isEditingLayout: Bool {
        get { self[LayoutEditingKey.self] }
        set { self[LayoutEditingKey.self] = newValue }
    }
}

/// Wraps one device card. Long-press then keep dragging picks the card up straight away (no
/// second click); while editing a plain drag moves any card. The card follows the pointer via
/// `dragOffset`, jiggles, and shows a size badge that cycles half → full → panel.
struct LayoutEditable: ViewModifier {
    @Environment(\.isEditingLayout) private var editing
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let deviceId: String
    let size: TileSize
    let isDragging: Bool
    let dragOffset: CGSize
    let onCycleSize: () -> Void

    // Per-card phase so neighbouring cards do not swing in sync.
    private var phase: Double { Double(abs(deviceId.hashValue % 97)) / 97 * .pi * 2 }

    func body(content: Content) -> some View {
        jiggling(content.allowsHitTesting(!editing))
            .scaleEffect(isDragging ? 1.05 : 1)
            .shadowIf(isDragging, color: .black.opacity(0.3), radius: 12, y: 6)
            .offset(dragOffset)
            .zIndex(isDragging ? 10 : 0)
            .overlay(alignment: .topTrailing) {
                if editing && !isDragging {
                    Button(action: onCycleSize) {
                        Image(systemName: size.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor))
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                    .buttonStyle(PressableCardButtonStyle(scaleAmount: 0.85))
                    .accessibilityLabel(Text(L10n.tr("切换卡片大小，当前 \(size.title)", "Change card size, currently \(size.title)")))
                    .panelHelp(L10n.tr("切换卡片大小：\(size.title)", "Card size: \(size.title)"))
                    .offset(x: 5, y: -5)
                    .transition(.scale.combined(with: .opacity))
                }
            }
    }

    /// Angle is computed from the clock each frame, so a card rebuilt mid-edit keeps jiggling
    /// instead of freezing at the last animated angle.
    @ViewBuilder
    private func jiggling<V: View>(_ view: V) -> some View {
        if editing && !reduceMotion && !isDragging {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                view.rotationEffect(.degrees(sin(t * 2 * .pi * 3.6 + phase) * 1.1))
            }
        } else {
            view
        }
    }
}

enum TileSpace {
    static let name = "device_tiles"
}

/// Card frames in the tile coordinate space, used to find which card the pointer is over.
struct TileFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Flow Layout

struct TileSpanKey: LayoutValueKey {
    static let defaultValue = 6
}

/// Packs children left to right into rows of 6 columns using each child's `TileSpanKey`.
/// Cards in a row share the tallest card's height.
struct TileFlowLayout: Layout {
    var spacing: CGFloat = 7

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func width(for span: Int, total: CGFloat) -> CGFloat {
        let unit = (total - spacing * 5) / 6
        return unit * CGFloat(span) + spacing * CGFloat(span - 1)
    }

    private func rows(_ subviews: Subviews, total: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var used = 0
        for (i, sub) in subviews.enumerated() {
            let span = min(max(sub[TileSpanKey.self], 1), 6)
            if used + span > 6, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                used = 0
            }
            let h = sub.sizeThatFits(ProposedViewSize(width: width(for: span, total: total), height: nil)).height
            current.indices.append(i)
            current.height = max(current.height, h)
            used += span
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 330
        let rs = rows(subviews, total: total)
        let height = rs.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rs.count - 1, 0))
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, total: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let span = min(max(subviews[i][TileSpanKey.self], 1), 6)
                let w = width(for: span, total: bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: row.height))
                x += w + spacing
            }
            y += row.height + spacing
        }
    }
}


// MARK: - Custom Groups

/// A user-named section ("灯光", "电器") that cards can be filed under on every page.
public struct DeviceGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
}

public enum GroupPrefs {
    public static let groupsKey = "device_groups"
    public static let mapKey = "device_group_map"
    public static let collapsedKey = "device_groups_collapsed"
    /// `[deviceId: display name]`; local to this app, the Mi Home name is untouched.
    public static let aliasesKey = "device_aliases"

    public static func groups(_ raw: String) -> [DeviceGroup] {
        (try? JSONDecoder().decode([DeviceGroup].self, from: Data(raw.utf8))) ?? []
    }

    public static func encode(_ groups: [DeviceGroup]) -> String {
        (try? String(data: JSONEncoder().encode(groups), encoding: .utf8)) ?? "[]"
    }

    public static func map(_ raw: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }

    public static func encode(_ map: [String: String]) -> String {
        (try? String(data: JSONEncoder().encode(map), encoding: .utf8)) ?? "{}"
    }

    public static func set(_ raw: String) -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? [])
    }

    public static func encode(_ set: Set<String>) -> String {
        (try? String(data: JSONEncoder().encode(set.sorted()), encoding: .utf8)) ?? "[]"
    }
}

/// Panel-wide UI requests raised from deep inside cards (context menus cannot host text input).
@MainActor
@Observable
final class LayoutUIState {
    static let shared = LayoutUIState()
    /// Non-nil while the "new group" name prompt is open; holds the device to file into it.
    var newGroupForDevice: String?
    /// Non-nil while renaming that group.
    var renamingGroupId: String?
    /// Non-nil while renaming that device (local display name only).
    var renamingDeviceId: String?
    /// Raised from a card's context menu, so entering edit mode no longer requires the 0.6 s
    /// long-press the audit flagged as inaccessible (#41).
    var isEditingLayoutRequested = false
}

/// Inline name prompt shown over the panel for creating or renaming a group.
struct GroupNamePrompt: View {
    let title: String
    @State var name: String
    var placeholder: String = L10n.tr("例如：灯光、电器、环境", "e.g. Lights, Appliances")
    var onReset: (() -> Void)? = nil
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .adaptiveGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($focused)
                .onSubmit(save)
            HStack {
                if let onReset {
                    Button(L10n.tr("恢复原名", "Reset"), action: onReset)
                        .buttonStyle(PillActionButtonStyle())
                }
                Spacer()
                Button(L10n.tr("取消", "Cancel"), action: onCancel)
                    .buttonStyle(PillActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存", "Save"), action: save)
                    .buttonStyle(PillActionButtonStyle(isSelected: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
