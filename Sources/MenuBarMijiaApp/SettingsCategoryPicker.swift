import SwiftUI
import AppKit
import MijiaCore

struct SettingsCategoryGeometry {
    let width: CGFloat
    let count: Int
    private let inset = DesignTokens.Settings.railInset

    var segmentWidth: CGFloat { max(1, (width - inset * 2) / CGFloat(max(count, 1))) }

    func center(of index: Int) -> CGFloat {
        inset + segmentWidth * (CGFloat(index) + 0.5)
    }

    func clampedCenter(_ position: CGFloat) -> CGFloat {
        min(max(position, center(of: 0)), center(of: max(count - 1, 0)))
    }

    func index(at position: CGFloat) -> Int {
        min(max(Int(((position - inset) / segmentWidth).rounded(.down)), 0), max(count - 1, 0))
    }
    func destination(from index: Int, translation: CGFloat, predictedTranslation: CGFloat) -> Int {
        // A quick release can cross a nearby midpoint, but must not skip several categories.
        let momentum = min(max(predictedTranslation - translation, -segmentWidth * 0.35), segmentWidth * 0.35)
        return self.index(at: clampedCenter(center(of: index) + translation + momentum))
    }

}

/// A single glass lens follows the pointer; the page changes only when the drag commits.
struct SettingsCategoryPicker: View {
    @Binding var selection: SettingsTab
    var hasUpdateBadge: Bool = false
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @GestureState private var dragCenter: CGFloat?
    @State private var cancelledDrag = false
    /// Only keyboard navigation draws the accent ring; a window that merely regains focus must not.
    @State private var keyboardSelection = false
    @FocusState private var navigationFocused: Bool

    private let items = SettingsTab.allCases
    private var selectedIndex: Int { items.firstIndex(of: selection) ?? 0 }

    var body: some View {
        GeometryReader { proxy in
            let geometry = SettingsCategoryGeometry(width: proxy.size.width, count: items.count)
            let center = cancelledDrag ? geometry.center(of: selectedIndex) : (dragCenter ?? geometry.center(of: selectedIndex))
            let previewIndex = geometry.index(at: center)
            let dragging = dragCenter != nil && !cancelledDrag

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        Button {
                            keyboardSelection = NSApp.currentEvent?.type == .keyDown
                            navigationFocused = true
                            selection = item
                        } label: {
                            categoryLabel(item, emphasized: previewIndex == index)
                                .frame(maxWidth: .infinity)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(selection == item ? [.isSelected] : [])
                        .help(item.title)
                    }
                }
                .padding(.horizontal, DesignTokens.Settings.railInset)
                .compositingGroup()
                .zIndex(0)

                // Keep the lens foreground in its glass surface. Sibling text can be
                // occluded by the system glass compositor, regardless of ZStack order.
                let lensOrigin = center - geometry.segmentWidth / 2
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        categoryLabel(item, emphasized: true)
                            .frame(width: geometry.segmentWidth)
                    }
                }
                .frame(width: geometry.segmentWidth * CGFloat(items.count), alignment: .leading)
                .offset(x: DesignTokens.Settings.railInset - lensOrigin)
                .frame(width: geometry.segmentWidth, height: DesignTokens.Settings.segmentHeight, alignment: .leading)
                .clipShape(Capsule())
                .settingsSelectionGlass()
                .scaleEffect(dragging && !reduceMotion ? 1.025 : 1)
                .offset(x: lensOrigin)
                .animation(reduceMotion || keyboardSelection || dragging ? nil : .spring(response: 0.26, dampingFraction: 0.95), value: center)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .zIndex(1)
            }
            .frame(height: DesignTokens.Settings.segmentHeight)
            .padding(.vertical, DesignTokens.Settings.railInset)
            .background(Color.primary.opacity(0.045), in: Capsule())
            .contentShape(Capsule())
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local)
                    .updating($dragCenter) { value, state, transaction in
                        let origin = geometry.center(of: selectedIndex)
                        guard abs(value.startLocation.x - origin) <= geometry.segmentWidth / 2 else { return }
                        transaction.animation = nil
                        state = geometry.clampedCenter(origin + value.translation.width)
                    }
                    .onChanged { _ in
                        if dragCenter != nil {
                            keyboardSelection = false
                            navigationFocused = true
                        }
                    }
                    .onEnded { value in
                        let origin = geometry.center(of: selectedIndex)
                        guard !cancelledDrag, abs(value.startLocation.x - origin) <= geometry.segmentWidth / 2 else { return }
                        keyboardSelection = false
                        selection = items[geometry.destination(from: selectedIndex, translation: value.translation.width, predictedTranslation: value.predictedEndTranslation.width)]
                    }
            )
        }
        .settingsGlassContainer()
        .frame(height: DesignTokens.Settings.segmentHeight + DesignTokens.Settings.railInset * 2)
        .focusable()
        .focused($navigationFocused)
        .focusEffectDisabled()
        .overlay {
            if navigationFocused && keyboardSelection {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("设置分类", "Settings categories"))
        .onKeyPress(.leftArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.escape) {
            guard dragCenter != nil else { return .ignored }
            cancelledDrag = true
            return .handled
        }
        .onChange(of: dragCenter == nil) { _, finished in
            if finished { cancelledDrag = false }
        }
    }

    private func categoryLabel(_ item: SettingsTab, emphasized: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.monochrome)
                .frame(width: 16, height: 16)
            Text(item.navigationTitle)
                .lineLimit(1)
            if item == .about && hasUpdateBadge {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        .font(.system(size: DesignTokens.TypeSize.body, weight: emphasized ? .semibold : .regular))
        .foregroundStyle(emphasized ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .frame(height: DesignTokens.Settings.segmentHeight)
    }

    private func moveSelection(by offset: Int) {
        keyboardSelection = true
        selection = items[min(max(selectedIndex + offset, 0), items.count - 1)]
    }
}
