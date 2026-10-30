import SwiftUI
import AppKit
import MijiaCore

// MARK: - Panel Height

/// User-chosen panel height; `.max` fills the screen below the menu bar.
public enum PanelHeight: String, CaseIterable, Identifiable, Sendable {
    case compact, standard, tall, max

    public static let storageKey = "panel_height"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: return L10n.tr("紧凑", "Compact")
        case .standard: return L10n.tr("标准", "Standard")
        case .tall: return L10n.tr("加高", "Tall")
        case .max: return L10n.tr("最大", "Max")
        }
    }

    @MainActor
    public var points: CGFloat {
        let screen = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        switch self {
        case .compact: return 460
        case .standard: return Swift.min(560, screen)
        case .tall: return Swift.min(680, screen)
        case .max: return Swift.max(460, screen)
        }
    }
}

// MARK: - Appearance

/// Panel appearance: follow the system, or force light/dark.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public static let storageKey = "app_appearance"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return L10n.tr("跟随系统", "Follow System")
        case .light: return L10n.tr("浅色", "Light")
        case .dark: return L10n.tr("深色", "Dark")
        }
    }

    /// `nil` means "use the system colour scheme".
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// `nil` inherits the system appearance on `NSWindow` / `NSView`.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - System Panel Look

/// One system design, no skins. Tiles mirror Control Center: an opaque bright "platter" for
/// anything that is on, and a quiet translucent well for anything that is off. Text and hairlines
/// come from the system's semantic colours, so light and dark need no separate palettes.
public enum PanelLook {
    public static let tileRadius: CGFloat = 14

    public static func tileFill(scheme: ColorScheme, isActive: Bool) -> AnyShapeStyle {
        if isActive {
            return AnyShapeStyle(scheme == .dark ? Color.white.opacity(0.94) : Color.white)
        }
        return AnyShapeStyle(scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
    }

    /// Ink for a bright platter. `Color.primary` turns white in dark mode, so the platter needs
    /// its own fixed dark ink to stay legible.
    public static let platterInk = DesignTokens.Ink.onPlatter

    public static func ink(isActive: Bool) -> Color {
        isActive ? platterInk : .primary
    }

    public static func secondaryInk(isActive: Bool) -> Color {
        isActive ? platterInk.opacity(0.55) : Color.secondary
    }

    public static func hairline(scheme: ColorScheme, isActive: Bool) -> Color {
        if isActive { return Color.black.opacity(0.07) }
        return scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.05)
    }

    /// Soft drop shadow that keeps the platter above the glass; wells stay flat.
    public static func platterShadow(isActive: Bool) -> Color {
        isActive ? Color.black.opacity(0.18) : .clear
    }
}

// MARK: - Motion Helpers

/// Repeating halo used for the microphone while listening.
struct ListeningPulse: ViewModifier {
    let active: Bool
    let color: Color
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .background {
                if active {
                    Capsule(style: .continuous)
                        .stroke(color.opacity(phase ? 0 : 0.7), lineWidth: 2)
                        .scaleEffect(phase ? 1.6 : 1)
                        .onAppear {
                            phase = false
                            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { phase = true }
                        }
                }
            }
    }
}

/// Status dot that breathes slowly while connected.
struct BreathingDot: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let color: Color
    let animate: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard animate, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

extension View {
    /// Adds a shadow only when `active`; a clear shadow still costs an offscreen pass per frame.
    @ViewBuilder
    func shadowIf(_ active: Bool, color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        if active { self.shadow(color: color, radius: radius, x: x, y: y) } else { self }
    }

    func listeningPulse(_ active: Bool, color: Color) -> some View { modifier(ListeningPulse(active: active, color: color)) }

    /// System tooltip. Kept as one wrapper so the panel can drop tooltips in one place.
    func panelHelp(_ text: String) -> some View { help(text) }
}

// MARK: - Hold-to-Confirm All Off

/// "All Off" control: press and hold 0.6s to fire, with a filling progress sweep.
struct HoldToConfirmButton: View {
    let title: String
    let count: Int
    let onConfirm: () -> Void
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var holding = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "power").font(.system(size: DesignTokens.TypeSize.micro, weight: .bold))
            Text(title).font(.system(size: DesignTokens.TypeSize.control, weight: .semibold))
            Text("(\(count))")
                .font(.system(size: DesignTokens.TypeSize.control, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background {
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(DesignTokens.Brand.allOff)
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.black.opacity(0.2))
                        .frame(width: holding ? geo.size.width : 0)
                }
                .clipShape(Capsule(style: .continuous))
            }
        }
        .scaleEffect(holding ? 0.95 : 1)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.6, maximumDistance: 20) {
            holding = false
            // #54: a confirm that turns off the whole room deserves a level-change tap.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onConfirm()
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: 0.6) : .easeOut(duration: 0.2)) { holding = pressing }
        }
        .panelHelp(L10n.tr("按住 0.6 秒关闭这 \(count) 台设备", "Hold 0.6s to turn off these \(count) devices"))
        // VoiceOver cannot long-press easily; give it an explicit, clearly named action instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title) (\(count))"))
        .accessibilityHint(Text(L10n.tr("按住 0.6 秒关闭", "Hold 0.6 seconds to turn off")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.tr("关闭这 \(count) 台设备", "Turn off these \(count) devices"))) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            onConfirm()
        }
        .opacity(colorScheme == .dark ? 1 : 0.98)
    }
}

// MARK: - Panel Root

/// Panel root: one system material behind every state, with the forced appearance and the
/// "Reduce transparency" fallback (#41).
public struct PanelRoot: ViewModifier {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.effectiveReduceTransparency) private var reduceTransparency
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue

    public func body(content: Content) -> some View {
        let scheme = (AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme ?? systemScheme
        content
            .background {
                if reduceTransparency {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    // A thin material alone picks up whatever is behind the window: over a bright
                    // wallpaper the dark scheme stays light and white text loses contrast. The scrim
                    // pins the surface to the chosen appearance without losing the glass.
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(scheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.32))
                }
            }
            .environment(\.colorScheme, scheme)
    }
}

extension View {
    public func panelRoot() -> some View { modifier(PanelRoot()) }
}

// MARK: - Panel Preferences

/// Storage keys that are not a user-visible choice but still persist between launches.
public enum PanelPrefs {
    public static let climatePanelKey = "climate_panel_module"
}
