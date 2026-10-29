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
    public var scaleAmount: CGFloat = 0.972

    public init(scaleAmount: CGFloat = 0.972) {
        self.scaleAmount = scaleAmount
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .brightness(configuration.isPressed ? -0.015 : 0)
            .animation(AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

// MARK: - Native Liquid Glass Pill Button Style

public struct PillActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appSkin) private var skin
    @Environment(\.skinPalette) private var palette
    public var isSelected: Bool = false
    public var tintColor: Color = .accentColor

    public init(isSelected: Bool = false, tintColor: Color = .accentColor) {
        self.isSelected = isSelected
        self.tintColor = tintColor
    }

    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        if skin.isClassic {
            classicBody(configuration)
        } else {
            skinnedBody(configuration)
        }
    }

    private func skinnedBody(_ configuration: Configuration) -> some View {
        let p = palette
        let capsule = Capsule(style: .continuous)
        return configuration.label
            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? p.onAccent : p.fg.opacity(0.88))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    capsule
                        .fill(p.accentGradient)
                        .shadowIf(p.neumorphic || p.glow, color: p.accent.opacity(0.32), radius: 4, x: 0, y: 1.5)
                }
            }
            .modifier(
                SkinChipSurface(
                    shape: capsule,
                    tint: nil,
                    interactive: false,
                    clear: false,
                    isHidden: isSelected
                )
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }

    @ViewBuilder
    private func classicBody(_ configuration: Configuration) -> some View {
        let capsule = Capsule(style: .continuous)
        configuration.label
            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.88))
            .padding(.horizontal, 10.5)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    capsule
                        .fill(
                            LinearGradient(
                                colors: [
                                    tintColor.opacity(0.95),
                                    tintColor.opacity(0.82)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .modifier(
                SkinChipSurface(
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
                        lineWidth: 0.75
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

// MARK: - Device Semantic Palette (Separating Icon Orb, Glass Tint, and High-Contrast Text)

public enum DevicePalette {
    /// Rich saturated color for active icon badges and slider fill bars
    public static func accentColor(for device: SmartDevice) -> Color {
        guard device.isOnline else { return .secondary }
        switch device.kind {
        case .light(let s):
            return s.isOn ? Color(red: 0.95, green: 0.58, blue: 0.06) : .secondary
        case .climate(let s):
            guard s.isOn && s.hvacMode != "off" else { return .secondary }
            if s.hvacMode == "heat" {
                return Color(red: 0.95, green: 0.42, blue: 0.18)
            }
            return Color(red: 0.12, green: 0.58, blue: 0.96)
        case .fan(let s):
            return s.isOn ? Color(red: 0.12, green: 0.68, blue: 0.60) : .secondary
        case .plug(let s):
            return s.isOn ? Color(red: 0.16, green: 0.72, blue: 0.38) : .secondary
        case .fridge:
            return Color(red: 0.20, green: 0.60, blue: 0.92)
        case .vacuum(let s):
            return s.isCleaning ? Color(red: 0.16, green: 0.72, blue: 0.38) : Color(red: 0.30, green: 0.54, blue: 0.88)
        case .speaker(let s):
            return s.state == "playing" ? Color(red: 0.56, green: 0.34, blue: 0.92) : Color(red: 0.44, green: 0.42, blue: 0.90)
        case .tv:
            return Color(red: 0.36, green: 0.48, blue: 0.92)
        case .sensor:
            return Color(red: 0.16, green: 0.68, blue: 0.60)
        }
    }

    /// High-contrast adaptive text color for active device subtitles — guarantees WCAG AA/AAA readability on both light and dark glass
    public static func statusTextColor(for device: SmartDevice, colorScheme: ColorScheme) -> Color {
        guard device.isOnline && device.isActiveOn else {
            return .secondary
        }
        if colorScheme == .light {
            switch device.kind {
            case .light:
                return Color(red: 0.50, green: 0.29, blue: 0.02)
            case .climate(let s):
                if s.hvacMode == "heat" {
                    return Color(red: 0.64, green: 0.22, blue: 0.05)
                }
                return Color(red: 0.04, green: 0.36, blue: 0.66)
            case .fan, .sensor:
                return Color(red: 0.04, green: 0.42, blue: 0.36)
            case .plug:
                return Color(red: 0.06, green: 0.44, blue: 0.20)
            case .fridge:
                return Color(red: 0.06, green: 0.36, blue: 0.62)
            case .vacuum(let s):
                return s.isCleaning ? Color(red: 0.06, green: 0.44, blue: 0.20) : Color(red: 0.14, green: 0.34, blue: 0.64)
            case .speaker, .tv:
                return Color(red: 0.30, green: 0.20, blue: 0.66)
            }
        } else {
            switch device.kind {
            case .light:
                return Color(red: 1.0, green: 0.84, blue: 0.40)
            case .climate(let s):
                if s.hvacMode == "heat" {
                    return Color(red: 1.0, green: 0.64, blue: 0.42)
                }
                return Color(red: 0.48, green: 0.84, blue: 1.0)
            case .fan, .sensor:
                return Color(red: 0.44, green: 0.92, blue: 0.84)
            case .plug:
                return Color(red: 0.46, green: 0.94, blue: 0.64)
            case .fridge:
                return Color(red: 0.52, green: 0.84, blue: 1.0)
            case .vacuum(let s):
                return s.isCleaning ? Color(red: 0.46, green: 0.94, blue: 0.64) : Color(red: 0.60, green: 0.78, blue: 1.0)
            case .speaker, .tv:
                return Color(red: 0.78, green: 0.70, blue: 1.0)
            }
        }
    }
}

// MARK: - Native macOS 26 Liquid Glass Surface Modifier

public struct GlassTileBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appSkin) private var skin
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    public var isActive: Bool
    public var accent: Color
    public var cornerRadius: CGFloat

    @ViewBuilder
    public func body(content: Content) -> some View {
        if skin.isClassic {
            classicBody(content)
        } else {
            content.modifier(SkinTileSurface(isActive: isActive, cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    private func classicBody(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    // #41: Reduce Transparency swaps the material for an opaque surface.
                    if reduceTransparency {
                        shape.fill(Color(nsColor: .controlBackgroundColor))
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                    if isActive {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(colorScheme == .dark ? 0.26 : 0.20),
                                    accent.opacity(colorScheme == .dark ? 0.14 : 0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    } else {
                        shape.fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.06)
                                : Color.white.opacity(0.48)
                        )
                    }
                }
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                isActive
                                    ? accent.opacity(colorScheme == .dark ? 0.52 : 0.42)
                                    : Color.white.opacity(colorScheme == .dark ? 0.22 : 0.65),
                                isActive
                                    ? accent.opacity(0.16)
                                    : Color.primary.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
            }
            .shadow(
                color: isActive
                    ? accent.opacity(colorScheme == .dark ? 0.16 : 0.10)
                    : Color.black.opacity(colorScheme == .dark ? 0.14 : 0.04),
                radius: isActive ? 7 : 3,
                x: 0,
                y: 2
            )
    }
}

/// The original adaptive glass behaviour, kept verbatim for the classic skin.
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
                .overlay { shape.stroke(.white.opacity(0.28), lineWidth: 0.8) }
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
                        lineWidth: 0.7
                    )
                }
        }
    }
}

extension View {
    public func glassTile(isActive: Bool, accent: Color, cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassTileBackground(isActive: isActive, accent: accent, cornerRadius: cornerRadius))
    }

    /// Glass on the classic skin; an opaque chip from the active skin's palette otherwise.
    public func adaptiveGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        modifier(SkinChipSurface(shape: shape, tint: tint, interactive: interactive, clear: clear))
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

    @Environment(\.appSkin) private var skin
    @Environment(\.skinPalette) private var palette

    @ViewBuilder
    public var body: some View {
        Group {
            if skin.isClassic {
                classicBody
            } else {
                skinnedBody
            }
        }
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

    /// Flat track with an accent fill and a small round knob that grows while dragging.
    private var skinnedBody: some View {
        let p = palette
        return HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(p.muted)
                .frame(width: 16)

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let knob: CGFloat = isDragging ? 18 : 14
                let x = knob / 2 + normalizedProgress * (width - knob)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(isSpectrumTrack ? AnyShapeStyle(trackFill) : AnyShapeStyle(p.chip))
                        .opacity(isSpectrumTrack ? 0.75 : 1)
                        .frame(height: 6)
                        .overlay(Capsule(style: .continuous).stroke(p.line, lineWidth: 0.6))
                    if !isSpectrumTrack {
                        Capsule(style: .continuous)
                            .fill(p.accentGradient)
                            .frame(width: max(x, 6), height: 6)
                            .shadowIf(p.glow, color: p.accent.opacity(0.55), radius: 4)
                    }
                    Circle()
                        .fill(p.fg)
                        .frame(width: knob, height: knob)
                        .overlay(Circle().stroke(isSpectrumTrack ? p.line : p.accent, lineWidth: 2))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .position(x: x, y: geo.size.height / 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard isEnabled else { return }
                            if !isDragging { withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isDragging = true } }
                            updateValue(at: drag.location.x, in: width, thumbWidth: knob)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isDragging = false }
                        }
                )
            }
            .frame(height: 22)

            Text(formattedValue)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(p.fg.opacity(0.85))
                .frame(width: 44, alignment: .trailing)
        }
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    private var classicBody: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 11.5, weight: .semibold))
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
                                    lineWidth: 0.8
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
                .font(.system(size: 11, weight: .semibold, design: .rounded))
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
