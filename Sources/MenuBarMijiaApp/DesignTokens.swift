import SwiftUI

/// Shared macOS presentation values. Focus rings and data marks retain their own functional widths.
enum DesignTokens {
    enum TypeSize {
        static let title: CGFloat = 15
        static let body: CGFloat = 13
        static let caption: CGFloat = 12
        static let control: CGFloat = 11.5
        static let micro: CGFloat = 10
        static let reading: CGFloat = 24
    }

    /// Ink that stays dark on the bright "on" platter even in dark mode.
    enum Ink {
        static let onPlatter = Color(red: 0.11, green: 0.12, blue: 0.14)
    }

    /// Control Center-style semantic colours for device icon orbs (#FF9500 / #007AFF / #30D158…).
    enum Orb {
        static let light = Color(red: 1.00, green: 0.58, blue: 0.00)
        static let climate = Color(red: 0.00, green: 0.48, blue: 1.00)
        static let plug = Color(red: 0.19, green: 0.82, blue: 0.35)
        static let fan = Color(red: 0.00, green: 0.78, blue: 0.75)
        static let vacuum = Color(red: 0.35, green: 0.34, blue: 0.84)
        static let speaker = Color(red: 0.75, green: 0.35, blue: 0.95)
        static let tv = Color(red: 0.35, green: 0.34, blue: 0.84)
        static let fridge = Color(red: 0.20, green: 0.70, blue: 0.90)
        static let camera = Color(red: 0.00, green: 0.62, blue: 1.00)
        static let sensor = Color(red: 0.00, green: 0.48, blue: 1.00)
    }

    /// Air-quality verdict tints in the air-purifier drawer and the fan-speed slider track.
    enum Purifier {
        static let good = Color(red: 0.16, green: 0.72, blue: 0.38)
        static let moderate = Color.orange
        static let poor = Color.red
        static let speedTrackTop = Color(red: 0.16, green: 0.76, blue: 0.68)
        static let speedTrackBottom = Color(red: 0.08, green: 0.62, blue: 0.56)
    }

    /// The panel's own brand marks: the home orb and the All-Off pill.
    enum Brand {
        static let homeTop = Color(red: 1.00, green: 0.72, blue: 0.12)
        static let homeBottom = Color(red: 1.00, green: 0.55, blue: 0.00)
        static let allOff = Color(red: 0.90, green: 0.44, blue: 0.08)
    }
    enum Settings {
        static let navigationWidth: CGFloat = 640
        static let contentWidth: CGFloat = 720
        static let fieldWidth: CGFloat = 200
        static let rowHeight: CGFloat = 28
        static let rowSpacing: CGFloat = 6
        static let segmentHeight: CGFloat = 32
        static let railInset: CGFloat = 4
    }
    enum Radius {
        static let panel: CGFloat = 16
        static let card: CGFloat = 12
        static let inset: CGFloat = 8
        static let label: CGFloat = 4

        static func nested(outer: CGFloat, inset: CGFloat) -> CGFloat {
            max(0, outer - inset)
        }
    }
    static let hairline: CGFloat = 0.5
    static let active = Color(red: 0.93, green: 0.43, blue: 0.06)
    enum Spectrum {
        static let warm = Color(red: 0.98, green: 0.62, blue: 0.16)
        static let neutral = Color(red: 1.0, green: 0.90, blue: 0.74)
        static let cool = Color(red: 0.56, green: 0.82, blue: 1.0)
        static let capsuleBulb = Color(red: 1, green: 0.84, blue: 0.04)
        static let onCapsuleBulb = Color(red: 0.23, green: 0.18, blue: 0)
    }
    static let separator = Color(nsColor: .separatorColor)
}
