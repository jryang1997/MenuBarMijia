import SwiftUI
import AppKit
import MijiaCore

// MARK: - Overridable Accessibility Environment

// macOS 26 SDK 把 accessibilityReduceMotion/Transparency 的环境键改成了只读，也没有等效修饰符；
// 快照测试需要在进程级系统设置之外强制它们的值，所以提供可写入的覆盖键：
// 默认 nil = 跟随系统，`effective*` 是所有视图统一的读取口。

private struct ReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct ReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

public extension EnvironmentValues {
    var reduceMotionOverride: Bool? {
        get { self[ReduceMotionOverrideKey.self] }
        set { self[ReduceMotionOverrideKey.self] = newValue }
    }

    var reduceTransparencyOverride: Bool? {
        get { self[ReduceTransparencyOverrideKey.self] }
        set { self[ReduceTransparencyOverrideKey.self] = newValue }
    }

    var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? accessibilityReduceMotion
    }

    var effectiveReduceTransparency: Bool {
        reduceTransparencyOverride ?? accessibilityReduceTransparency
    }
}

// MARK: - Apple Design Motion Curves & Springs

public enum AppleMotion {
    /// Critically damped spring (damping ~ 0.94, response 0.26s) — smooth, interruptible, no distracting overshoot
    public static let snappySpring = Animation.spring(response: 0.26, dampingFraction: 0.94, blendDuration: 0.08)

    /// Fast ease-out for press feedback (120ms)
    public static let pressFeedback = Animation.easeOut(duration: 0.12)

    /// Liquid glass thumb expansion spring (200ms response, critically damped)
    public static let glassLensSpring = Animation.spring(response: 0.20, dampingFraction: 0.88, blendDuration: 0.05)

    /// Origin-aware drawer reveal transition (never scales from 0)
    public static var drawerTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)
        )
    }
}

// MARK: - Pressable Button Styles (Scale 0.97 on active press)

public struct PressableCardButtonStyle: ButtonStyle {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    public var scaleAmount: CGFloat = 0.972

    public init(scaleAmount: CGFloat = 0.972) {
        self.scaleAmount = scaleAmount
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scaleAmount : 1.0)
            .brightness(configuration.isPressed ? -0.015 : 0)
            .animation(reduceMotion ? nil : AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

// MARK: - Native Liquid Glass Pill Button Style

public struct PillActionButtonStyle: ButtonStyle {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    public var isSelected: Bool = false
    public var tintColor: Color = .accentColor

    public init(isSelected: Bool = false, tintColor: Color = .accentColor) {
        self.isSelected = isSelected
        self.tintColor = tintColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        let capsule = Capsule(style: .continuous)
        return configuration.label
            .font(.system(size: DesignTokens.TypeSize.caption, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(Color.primary.opacity(0.88))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    capsule.fill(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.09))
                }
            }
            .modifier(
                ChipSurface(
                    shape: capsule,
                    tint: nil,
                    interactive: true,
                    clear: false,
                    isHidden: isSelected
                )
            )
            .overlay {
                capsule
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isSelected ? 0.52 : (colorScheme == .dark ? 0.24 : 0.58)),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: DesignTokens.hairline
                    )
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

// MARK: - Device Semantic Colours

public enum DevicePalette {
    /// Semantic orb colour per device family. The tile surface carries the on/off contrast, so the
    /// orb keeps its identity in both states instead of fading to grey when the device is off.
    public static func accentColor(for device: SmartDevice) -> Color {
        switch device.kind {
        case .light: return DesignTokens.Orb.light
        case .climate: return DesignTokens.Orb.climate
        case .plug: return DesignTokens.Orb.plug
        case .fan: return DesignTokens.Orb.fan
        case .vacuum: return DesignTokens.Orb.vacuum
        case .speaker: return DesignTokens.Orb.speaker
        case .tv: return DesignTokens.Orb.tv
        case .fridge: return DesignTokens.Orb.fridge
        case .camera: return DesignTokens.Orb.camera
        case .sensor: return DesignTokens.Orb.sensor
        }
    }
}

// MARK: - Scene Semantic Colours

public enum ScenePalette {
    /// Scene pill icon tint per visual family; the model owns the category, this owns the colour.
    /// Unrecognised scene icons fall into `.light` — scene strips read as "actions" first.
    public static func tint(for category: SceneVisualCategory) -> Color {
        switch category {
        case .night: return DesignTokens.Orb.vacuum
        case .climate: return DesignTokens.Orb.fan
        case .water: return DesignTokens.Orb.climate
        case .heat: return DesignTokens.Orb.light
        case .media: return DesignTokens.Orb.speaker
        case .light: return DesignTokens.Orb.light
        }
    }
}

// MARK: - Panel Tile Surface

/// Tile surface: a bright platter when the device is on, a quiet glass well when it is off.
public struct GlassTileBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public var isActive: Bool
    public var cornerRadius: CGFloat
    public var tint: Color?

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface = TileSurface(isActive: isActive, tint: tint, scheme: colorScheme)
        content
            .background {
                shape.fill(surface.fill)
            }
            .overlay {
                shape.strokeBorder(surface.hairline, lineWidth: DesignTokens.hairline)
            }
            // Glass catch-light along the top edge, strongest on a lit platter. The strip is drawn
            // inside a full-height frame before clipping so the rounded corners clip it too.
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.white.opacity(specularStrength), Color.white.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1.5)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipShape(shape)
            }
            .shadowIf(isActive, color: PanelLook.platterShadow(isActive: isActive), radius: 8, y: 2)
            .animation(.easeOut(duration: 0.18), value: isActive)
    }

    private var specularStrength: CGFloat {
        switch (colorScheme, isActive) {
        case (.dark, true): return 0.40
        case (.dark, false): return 0.14
        case (_, true): return 0.90
        case (_, false): return 0.55
        }
    }
}

/// The panel's one small glass chip: thin material plus a white specular rim.
struct ChipSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let clear: Bool
    var isHidden = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isHidden {
            content
        } else {
            content.modifier(ClassicGlass(shape: shape, tint: tint, interactive: interactive, clear: clear))
        }
    }
}
struct ClassicGlass<S: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let interactive: Bool
    let clear: Bool
    var translucentOnly = false

    func body(content: Content) -> some View {
        if translucentOnly {
            content
                .background { shape.fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : .white.opacity(0.14)); if let tint { shape.fill(tint) } }
                .overlay { shape.stroke(.white.opacity(0.28), lineWidth: DesignTokens.hairline) }
        } else {
            content
                .background {
                    if clear {
                        shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.thinMaterial))
                    } else {
                        ZStack {
                            shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
                            shape.fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06)
                                    : Color.white.opacity(0.45)
                            )
                            if let tint {
                                shape.fill(tint)
                            }
                        }
                    }
                }
                .overlay {
                    shape.stroke(
                        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.50),
                        lineWidth: DesignTokens.hairline
                    )
                }
        }
    }
}

extension View {
    public func glassTile(isActive: Bool, cornerRadius: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(GlassTileBackground(isActive: isActive, cornerRadius: cornerRadius, tint: tint))
    }

    /// The panel's one glass chip (thin material + specular rim).
    public func adaptiveGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        modifier(ChipSurface(shape: shape, tint: tint, interactive: interactive, clear: clear))
    }
}

public struct AdaptiveGlassContainer<Content: View>: View {
    public var spacing: CGFloat
    @ViewBuilder public var content: () -> Content

    public init(spacing: CGFloat = 6, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        content()
    }
}

// MARK: - Settings Category Selection

/// One raised selection lens, shared by the settings tab rail and any picked option so both read as
/// the same object. `tint` carries the option's own colour; `isOn == false` leaves the view flat.
private struct SettingsSelectionGlass<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let isOn: Bool

    private var selectionFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.95)
    }

    private var rimColor: Color { DesignTokens.separator.opacity(0.6) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if !isOn {
            content
        } else if reduceTransparency {
            content
                .background {
                    ZStack {
                        shape.fill(selectionFill)
                        if let tint { shape.fill(tint) }
                    }
                }
                .overlay { shape.strokeBorder(rimColor, lineWidth: DesignTokens.hairline) }
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive().tint(tint), in: shape)
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.regularMaterial)
                        if let tint { shape.fill(tint) }
                    }
                }
                .overlay { shape.strokeBorder(rimColor, lineWidth: DesignTokens.hairline) }
        }
    }
}

private struct SettingsGlassContainer: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

/// Full-surface Liquid Glass for the panel root (macOS 26+; no-op on earlier systems, where
/// `panelRoot` keeps its material+scrim stack). The glass is far more translucent than
/// ultraThinMaterial, so the caller still applies a lighter appearance-pinning scrim.
private struct PanelRootGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Rectangle())
        } else {
            content
        }
    }
}

extension View {
    func panelRootGlass() -> some View { modifier(PanelRootGlass()) }
}

extension View {
    func settingsGlassContainer() -> some View {
        modifier(SettingsGlassContainer())
    }

    /// The tab rail's moving lens: a plain glass capsule.
    func settingsSelectionGlass() -> some View {
        settingsSelectionGlass(in: Capsule())
    }

    /// A selection lens in any shape; pass `tint` to mark the option's own colour and
    /// `isOn: false` to leave an unselected option flat.
    func settingsSelectionGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        isOn: Bool = true
    ) -> some View {
        modifier(SettingsSelectionGlass(shape: shape, tint: tint, isOn: isOn))
    }
}

// MARK: - Apple Control Center Liquid Glass Slider

public struct LiquidGlassSlider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double?
    public let iconName: String
    public let iconColor: Color
    public let trackFill: AnyShapeStyle
    public let isSpectrumTrack: Bool
    public let formattedValue: String

    @State private var isDragging: Bool = false

    public init<S: ShapeStyle>(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        iconName: String,
        iconColor: Color = .secondary,
        trackFill: S,
        isSpectrumTrack: Bool = false,
        formattedValue: String
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.iconName = iconName
        self.iconColor = iconColor
        self.trackFill = AnyShapeStyle(trackFill)
        self.isSpectrumTrack = isSpectrumTrack
        self.formattedValue = formattedValue
    }

    private var normalizedProgress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span)
    }

    public var body: some View {
        bodyWithChrome
    }

    private var bodyWithChrome: some View {
        classicBody
        // #41: VoiceOver can read and adjust the custom drag slider; keyboard users can too.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.tr("调节滑块", "Adjustment slider")))
        .accessibilityValue(Text(formattedValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: unitStep)
            case .decrement: adjust(by: -unitStep)
            @unknown default: break
            }
        }
        .focusable()
        // .focusable() 是方向键调节的前提，但 macOS 默认会给它画系统蓝框；
        // 玻璃滑杆自带高光与旋钮反馈，蓝框与卡片风格冲突，故只关掉 focus ring。
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { adjust(by: unitStep); return .handled }
        .onKeyPress(.rightArrow) { adjust(by: unitStep); return .handled }
        .onKeyPress(.downArrow) { adjust(by: -unitStep); return .handled }
        .onKeyPress(.leftArrow) { adjust(by: -unitStep); return .handled }
    }

    /// Ten percent of the range, snapped to the declared step when there is one.
    private var unitStep: Double {
        if let step, step > 0 { return step }
        let span = range.upperBound - range.lowerBound
        return max(span * 0.1, 0.1)
    }

    private func adjust(by delta: Double) {
        guard isEnabled else { return }
        var next = value + delta
        if let step, step > 0 {
            next = (next / step).rounded() * step
        }
        let clamped = min(max(next, range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        value = clamped
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// One `.alignment` tick every 10 % of the track (0 %, 50 % and 100 % included), not per pixel.
    private func hapticTick(from old: Double, to new: Double) {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return }
        let oldBucket = Int((((old - range.lowerBound) / span) * 10).rounded(.down))
        let newBucket = Int((((new - range.lowerBound) / span) * 10).rounded(.down))
        guard oldBucket != newBucket else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private var classicBody: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 16, alignment: .center)

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let thumbWidth: CGFloat = isDragging ? 29 : 23
                let thumbHeight: CGFloat = isDragging ? 20 : 16
                let trackHeight: CGFloat = 22
                let usableTravel = max(width - thumbWidth - 4, 1)
                let thumbCenterX = 2 + thumbWidth / 2 + normalizedProgress * usableTravel
                let fillWidth = isSpectrumTrack ? width : max(thumbCenterX + thumbWidth / 2 - 1, trackHeight)

                ZStack(alignment: .leading) {
                    // 1. Recessed Liquid Glass Track Capsule
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                        .frame(height: trackHeight)
                        .overlay {
                            // Active progress fill bar or full Kelvin spectrum inside glass track
                            GeometryReader { trackGeo in
                                Capsule(style: .continuous)
                                    .fill(trackFill)
                                    .frame(
                                        width: isSpectrumTrack ? trackGeo.size.width : min(fillWidth, trackGeo.size.width),
                                        height: trackHeight
                                    )
                            }
                            .clipShape(Capsule(style: .continuous))
                        }
                        .adaptiveGlass(in: Capsule(style: .continuous))
                        .overlay {
                            // Top inner specular rim
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(colorScheme == .dark ? 0.28 : 0.62),
                                            Color.primary.opacity(0.10)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: DesignTokens.hairline
                                )
                        }

                    // 2. Refractive 3D Liquid Glass Meniscus Thumb Lens
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isDragging ? 0.30 : (colorScheme == .dark ? 0.78 : 0.84)),
                                    Color.white.opacity(isDragging ? 0.10 : (colorScheme == .dark ? 0.42 : 0.52))
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: thumbWidth, height: thumbHeight)
                        .adaptiveGlass(in: Capsule(style: .continuous), interactive: true, clear: true)
                        .overlay {
                            // Outer meniscus specular highlight
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.98),
                                            Color.white.opacity(0.32),
                                            Color.white.opacity(0.75)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: isDragging ? 1.25 : 0.95
                                )
                        }
                        .shadow(
                            color: Color.black.opacity(isDragging ? 0.26 : 0.18),
                            radius: isDragging ? 5 : 2.5,
                            x: 0,
                            y: isDragging ? 2 : 1
                        )
                        .position(x: thumbCenterX, y: geo.size.height / 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard isEnabled else { return }
                            if !isDragging {
                                withAnimation(AppleMotion.glassLensSpring) {
                                    isDragging = true
                                }
                            }
                            updateValue(at: drag.location.x, in: width, thumbWidth: thumbWidth)
                        }
                        .onEnded { _ in
                            withAnimation(AppleMotion.glassLensSpring) {
                                isDragging = false
                            }
                        }
                )
            }
            .frame(height: 24)

            Text(formattedValue)
                .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.80))
                .frame(width: 42, alignment: .trailing)
        }
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    private func updateValue(at x: CGFloat, in totalWidth: CGFloat, thumbWidth: CGFloat) {
        let minX = 2 + thumbWidth / 2
        let maxX = max(totalWidth - 2 - thumbWidth / 2, minX + 1)
        let clampedX = min(max(x, minX), maxX)
        let ratio = Double((clampedX - minX) / (maxX - minX))
        var raw = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            raw = (raw / step).rounded() * step
        }
        let finalValue = min(max(raw, range.lowerBound), range.upperBound)
        if finalValue != value {
            let previous = value
            value = finalValue
            hapticTick(from: previous, to: finalValue)
        }
    }
}

// MARK: - Horizontal Strip Wheel & Trackpad Scroll

/// Routes mouse scroll-wheel and trackpad scroll gestures over registered horizontal `ScrollView`s
/// into horizontal scrolling of their backing `NSScrollView`.
@MainActor
public final class HorizontalWheelScrollMonitor {
    public static let shared = HorizontalWheelScrollMonitor()

    private let scrollViews = NSHashTable<NSScrollView>.weakObjects()
    private var localMonitor: Any?
    private weak var activeGestureScrollView: NSScrollView?
    private var isTrackingGesture = false
    private var gesturePhaseEnded = false

    private init() {}

    public func register(_ scrollView: NSScrollView) {
        if !scrollViews.contains(scrollView) {
            scrollViews.add(scrollView)
        }
        installMonitorIfNeeded()
    }

    private func installMonitorIfNeeded() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollWheel(event)
        }
    }

    /// Picks the dominant scroll axis (`scrollingDeltaX` when horizontal magnitude is at least
    /// vertical magnitude, otherwise `scrollingDeltaY`).
    public static func dominantDelta(deltaX: CGFloat, deltaY: CGFloat) -> CGFloat {
        abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
    }

    /// Converts a raw `NSEvent` scrolling delta into a horizontal point step.
    /// Trackpads and Magic Mice report precise point deltas; notched mouse wheels report line deltas.
    public static func horizontalStep(delta: CGFloat, hasPreciseDeltas: Bool) -> CGFloat {
        guard abs(delta) > 0.001 else { return 0 }
        if hasPreciseDeltas {
            return delta
        }
        let scaled = delta * 16
        if abs(scaled) < 18 {
            return delta > 0 ? 18 : -18
        }
        return scaled
    }

    /// Clamps the next horizontal scroll offset into `0...maxOffsetX`.
    public static func clampedTargetOffset(currentX: CGFloat, step: CGFloat, maxOffsetX: CGFloat) -> CGFloat {
        guard maxOffsetX > 0 else { return 0 }
        return min(max(0, currentX - step), maxOffsetX)
    }

    @discardableResult
    public static func applyHorizontalScroll(
        to scrollView: NSScrollView,
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool
    ) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let clipView = scrollView.contentView
        let maxOffsetX = max(0, documentView.bounds.width - clipView.bounds.width)
        guard maxOffsetX > 0.5 else { return false }

        let dominant = dominantDelta(deltaX: deltaX, deltaY: deltaY)
        let step = horizontalStep(delta: dominant, hasPreciseDeltas: hasPreciseDeltas)
        guard abs(step) > 0.001 else { return false }

        let currentX = clipView.bounds.origin.x
        let targetX = clampedTargetOffset(currentX: currentX, step: step, maxOffsetX: maxOffsetX)
        guard abs(targetX - currentX) > 0.01 else { return false }

        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    private func hitScrollView(for event: NSEvent) -> NSScrollView? {
        guard let eventWindow = event.window else { return nil }
        let location = event.locationInWindow
        for scrollView in scrollViews.allObjects {
            guard scrollView.window === eventWindow,
                  !scrollView.isHiddenOrHasHiddenAncestor,
                  let documentView = scrollView.documentView
            else { continue }
            let maxOffsetX = documentView.bounds.width - scrollView.contentView.bounds.width
            guard maxOffsetX > 0.5 else { continue }
            let localPoint = scrollView.convert(location, from: nil)
            if scrollView.bounds.contains(localPoint) {
                return scrollView
            }
        }
        return nil
    }

    func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        let phase = event.phase
        let momentumPhase = event.momentumPhase

        let targetScrollView: NSScrollView?
        if phase.isEmpty && momentumPhase.isEmpty {
            activeGestureScrollView = nil
            isTrackingGesture = false
            gesturePhaseEnded = false
            targetScrollView = hitScrollView(for: event)
        } else {
            if phase.contains(.began) || phase.contains(.mayBegin) {
                activeGestureScrollView = hitScrollView(for: event)
                isTrackingGesture = true
                gesturePhaseEnded = false
            } else if phase.contains(.changed) {
                if !isTrackingGesture || gesturePhaseEnded {
                    activeGestureScrollView = hitScrollView(for: event)
                    isTrackingGesture = true
                    gesturePhaseEnded = false
                }
            }

            targetScrollView = activeGestureScrollView

            if phase.contains(.ended) {
                gesturePhaseEnded = true
            }
            if phase.contains(.cancelled) || momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
                activeGestureScrollView = nil
                isTrackingGesture = false
                gesturePhaseEnded = false
            }
        }

        guard let scrollView = targetScrollView else { return event }
        _ = Self.applyHorizontalScroll(
            to: scrollView,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        return nil
    }
}

private struct HorizontalWheelScrollAttachment: NSViewRepresentable {
    func makeNSView(context: Context) -> HorizontalWheelProbeView {
        HorizontalWheelProbeView()
    }

    func updateNSView(_ nsView: HorizontalWheelProbeView, context: Context) {
        nsView.registerEnclosingScrollView()
    }
}

final class HorizontalWheelProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerEnclosingScrollView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        registerEnclosingScrollView()
    }

    override func layout() {
        super.layout()
        registerEnclosingScrollView()
    }

    func registerEnclosingScrollView() {
        guard let scrollView = enclosingScrollView else { return }
        HorizontalWheelScrollMonitor.shared.register(scrollView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension View {
    /// Enables horizontal scrolling via vertical or horizontal mouse wheel / trackpad gestures
    /// when placed on the content inside a `ScrollView(.horizontal)`.
    public func horizontalWheelScroll() -> some View {
        background(HorizontalWheelScrollAttachment())
    }
}

// MARK: - Glass Controls (settings)

/// A glass switch: translucent track (tinted while on) with a white knob. Built on the system
/// `glassEffect` material so it matches Liquid Glass in both schemes and when Reduce Transparency
/// is on it falls back to a flat tinted capsule.
struct GlassSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private var trackFill: Color {
        isOn ? Color.accentColor.opacity(0.78)
             : Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.10)
    }

    var body: some View {
        let track = Capsule(style: .continuous)
            .fill(trackFill)
            .frame(width: 40, height: 23)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .padding(2.5)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            }

        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                track.glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            } else {
                track.overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: DesignTokens.hairline)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: isOn)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            guard isEnabled else { return }
            isOn.toggle()
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// `.toggleStyle(.glass)` — the switch above, with the Toggle's own label and VoiceOver intact.
struct GlassSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassSwitch(isOn: configuration.$isOn)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
    }
}

extension ToggleStyle where Self == GlassSwitchToggleStyle {
    static var glass: GlassSwitchToggleStyle { GlassSwitchToggleStyle() }
}

/// One glass capsule holding equal-width segments; the selected segment is a white lens.
/// Used for the settings' horizontal choices so they match the panel's room strip.
struct GlassSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

struct GlassSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [GlassSegment<Value>]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                row
                    .padding(3)
                    // Glass over a white card stays white; the tint under it keeps the track
                    // distinguishable from the selected lens in light mode.
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.065))
                    }
                    .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
            } else {
                row
                    .padding(3)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(DesignTokens.separator.opacity(0.5), lineWidth: DesignTokens.hairline)
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var row: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = selection == segment.value
                Button {
                    guard !isSelected else { return }
                    withAnimation(reduceMotion ? nil : AppleMotion.snappySpring) { selection = segment.value }
                } label: {
                    Text(segment.title)
                        .font(.system(
                            size: DesignTokens.TypeSize.caption,
                            weight: isSelected ? .semibold : .medium
                        ))
                        .foregroundStyle(isSelected ? PanelLook.platterInk : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
            }
        }
    }
}
