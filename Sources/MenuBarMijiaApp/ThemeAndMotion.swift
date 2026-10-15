import SwiftUI
import MijiaCore

// MARK: - Apple Design Motion Curves & Springs

public enum AppleMotion {
    /// Critically damped spring (damping ~ 0.94, response 0.26s) — smooth, interruptible, no distracting overshoot
    public static let snappySpring = Animation.spring(response: 0.26, dampingFraction: 0.94, blendDuration: 0.08)

    /// Fast ease-out for press feedback (120ms)
    public static let pressFeedback = Animation.easeOut(duration: 0.12)

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
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

public struct PillActionButtonStyle: ButtonStyle {
    public var isSelected: Bool = false
    public var tintColor: Color = .accentColor

    public init(isSelected: Bool = false, tintColor: Color = .accentColor) {
        self.isSelected = isSelected
        self.tintColor = tintColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? tintColor : Color.primary.opacity(0.07))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.white.opacity(0.24) : Color.primary.opacity(0.08),
                                lineWidth: 0.75
                            )
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(AppleMotion.pressFeedback, value: configuration.isPressed)
    }
}

// MARK: - Device Semantic Palette

public enum DevicePalette {
    public static func accentColor(for device: SmartDevice) -> Color {
        guard device.isOnline else { return .secondary }
        switch device.kind {
        case .light(let s):
            return s.isOn ? Color(red: 0.96, green: 0.68, blue: 0.14) : .secondary
        case .climate(let s):
            guard s.isOn && s.hvacMode != "off" else { return .secondary }
            if s.hvacMode == "heat" {
                return Color(red: 0.95, green: 0.45, blue: 0.22)
            }
            return Color(red: 0.18, green: 0.64, blue: 0.96)
        case .fan(let s):
            return s.isOn ? Color(red: 0.20, green: 0.75, blue: 0.65) : .secondary
        case .plug(let s):
            return s.isOn ? Color(red: 0.22, green: 0.76, blue: 0.44) : .secondary
        case .fridge:
            return Color(red: 0.28, green: 0.66, blue: 0.92)
        case .vacuum(let s):
            return s.isCleaning ? Color(red: 0.22, green: 0.76, blue: 0.44) : Color(red: 0.36, green: 0.58, blue: 0.88)
        case .speaker(let s):
            return s.state == "playing" ? Color.purple : Color(red: 0.48, green: 0.46, blue: 0.92)
        case .tv:
            return Color(red: 0.42, green: 0.54, blue: 0.92)
        case .sensor:
            return Color(red: 0.24, green: 0.72, blue: 0.64)
        }
    }
}

// MARK: - Translucent Glass Surface Modifier

public struct GlassTileBackground: ViewModifier {
    public var isActive: Bool
    public var accent: Color
    public var cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isActive
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        accent.opacity(0.24),
                                        accent.opacity(0.13)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color.primary.opacity(0.055))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        isActive ? accent.opacity(0.50) : Color.white.opacity(0.16),
                                        isActive ? accent.opacity(0.20) : Color.primary.opacity(0.07)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                    }
                    .shadow(
                        color: isActive ? accent.opacity(0.14) : Color.black.opacity(0.04),
                        radius: isActive ? 8 : 3,
                        x: 0,
                        y: 2
                    )
            }
    }
}

extension View {
    public func glassTile(isActive: Bool, accent: Color, cornerRadius: CGFloat = 13) -> some View {
        modifier(GlassTileBackground(isActive: isActive, accent: accent, cornerRadius: cornerRadius))
    }
}
