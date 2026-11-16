import SwiftUI
import AppKit

/// Offerlane design tokens. Colours come from `Branding/offerlane-icon.svg`
/// (blue #1D4ED8 → indigo #3730A3 → night #1E1B4B, lane dashes #4F46E5, the offer #34D399).
enum DS {
    // MARK: colour
    enum Palette {
        // Liquid glass: backdrop* sits behind every glass surface; glassTint is laid under content so text keeps AA
        // contrast whatever the blur shows (checked by scripts/check_contrast.py on these generated values).
        // BEGIN GENERATED palette (scripts/gen_tokens.py from Packages/design-tokens/tokens.json; do not edit)
        /// lane indigo
        static let accent = dynamic(light: 0x4338CA, dark: 0xA5B4FC)
        /// Fill behind white text (primary buttons, selection): ≥ 4.5:1 against white in both appearances.
        static let accentFill = dynamic(light: 0x4F46E5, dark: 0x5145CD)
        static let accentStrong = dynamic(light: 0x3730A3, dark: 0xC7D2FE)
        static let accentSoft = dynamic(light: 0x4F46E5, dark: 0x818CF8, alpha: 0.12)
        static let brandBlue = Color(hex: 0x1D4ED8)
        static let brandNight = Color(hex: 0x1E1B4B)
        /// success / "the offer"
        static let offer = dynamic(light: 0x065F46, dark: 0x34D399)
        static let warning = dynamic(light: 0x92400E, dark: 0xFBBF24)
        static let danger = dynamic(light: 0x991B1B, dark: 0xFCA5A5)
        static let info = dynamic(light: 0x1D4ED8, dark: 0x93C5FD)
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1C22)
        static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x24242C)
        static let surfaceSunken = dynamic(light: 0x0F172A, dark: 0xFFFFFF, alpha: 0.04)
        static let hairline = dynamic(light: 0x0F172A, dark: 0xFFFFFF, alpha: 0.1)
        /// Supporting text. The system secondary colour is about 4:1 on white; this keeps 4.5:1 on every surface.
        static let textSecondary = dynamic(light: 0x55555F, dark: 0xA8A8B3)
        static let backdropBase = dynamic(light: 0xF3F4FA, dark: 0x0E0D1A)
        /// indigo glow
        static let backdropA = dynamic(light: 0xDCE2FF, dark: 0x23206B)
        /// offer-green glow
        static let backdropB = dynamic(light: 0xD5F3E8, dark: 0x0B2A2A)
        static let glassTint = dynamic(light: 0xFFFFFF, dark: 0x1C1C22, alpha: 0.55)
        /// Soft specular edge on glass (top-left highlight).
        static let glassEdge = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, alpha: 0.55)
        // END GENERATED palette
        static let canvas = Color(nsColor: .windowBackgroundColor)
        static let textPrimary = Color.primary
    }

    // MARK: layout
    // BEGIN GENERATED layout (scripts/gen_tokens.py from Packages/design-tokens/tokens.json; do not edit)
    enum Space {
        static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }
    enum Radius {
        static let s: CGFloat = 6, m: CGFloat = 10, l: CGFloat = 14, xl: CGFloat = 20, pill: CGFloat = 999
    }
    // END GENERATED layout

    // MARK: type (SF Pro, Dynamic-Type relative)
    enum Font {
        static let display = SwiftUI.Font.system(.largeTitle, design: .default).weight(.bold)
        static let title = SwiftUI.Font.system(.title2).weight(.semibold)
        static let headline = SwiftUI.Font.system(.headline)
        static let body = SwiftUI.Font.system(.body)
        static let callout = SwiftUI.Font.system(.callout)
        static let caption = SwiftUI.Font.system(.caption)
        static let metric = SwiftUI.Font.system(.title2, design: .rounded).weight(.bold).monospacedDigit()
    }

    // MARK: elevation
    struct Shadow { let color: Color; let radius: CGFloat; let y: CGFloat }
    enum Elevation {
        static let card = Shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        static let raised = Shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        static let overlay = Shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        static let glass = Shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }

    // MARK: motion (0.15–0.25 s springs; Reduce Motion falls back to a short fade)
    enum Motion {
        static let quick = Animation.spring(response: 0.15, dampingFraction: 0.9)
        static let standard = Animation.spring(response: 0.22, dampingFraction: 0.86)
        static let gentle = Animation.spring(response: 0.25, dampingFraction: 0.8)
        /// Backdrop drift period (seconds); frozen under Reduce Motion.
        static let drift: Double = 40
        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        /// The animation to use, honouring Reduce Motion.
        static func pick(_ a: Animation) -> Animation { reduced ? .easeInOut(duration: 0.12) : a }
    }

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    func dsShadow(_ s: DS.Shadow) -> some View { shadow(color: s.color, radius: s.radius, y: s.y) }
    /// Animate a state change with a design-system curve, honouring Reduce Motion.
    func dsAnimation<V: Equatable>(_ a: Animation = DS.Motion.standard, value: V) -> some View { animation(DS.Motion.pick(a), value: value) }
}

func withDSAnimation<R>(_ a: Animation = DS.Motion.standard, _ body: () throws -> R) rethrows -> R {
    try withAnimation(DS.Motion.pick(a), body)
}
