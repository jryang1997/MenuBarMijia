import SwiftUI
import MijiaCore

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
    public var isSelected: Bool = false
    public var tintColor: Color = .accentColor

    public init(isSelected: Bool = false, tintColor: Color = .accentColor) {
        self.isSelected = isSelected
        self.tintColor = tintColor
    }

    public func makeBody(configuration: Configuration) -> some View {
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
                                    tintColor.opacity(0.92),
                                    tintColor.opacity(0.78)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .glassEffect(
                isSelected
                    ? .regular.tint(tintColor.opacity(0.50)).interactive()
                    : .regular.interactive(),
                in: capsule
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
    public var isActive: Bool
    public var accent: Color
    public var cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if isActive {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(colorScheme == .dark ? 0.22 : 0.15),
                                    accent.opacity(colorScheme == .dark ? 0.10 : 0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .glassEffect(
                isActive
                    ? .regular.tint(accent.opacity(colorScheme == .dark ? 0.24 : 0.14))
                    : .regular,
                in: shape
            )
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                isActive
                                    ? accent.opacity(colorScheme == .dark ? 0.52 : 0.42)
                                    : Color.white.opacity(colorScheme == .dark ? 0.22 : 0.55),
                                isActive
                                    ? accent.opacity(0.14)
                                    : Color.primary.opacity(0.06)
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

extension View {
    public func glassTile(isActive: Bool, accent: Color, cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassTileBackground(isActive: isActive, accent: accent, cornerRadius: cornerRadius))
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
                        .glassEffect(.regular, in: Capsule(style: .continuous))
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
                        .glassEffect(.clear.interactive(), in: Capsule(style: .continuous))
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
            value = finalValue
        }
    }
}
