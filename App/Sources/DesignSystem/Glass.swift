import SwiftUI

extension DS {
    /// UI tests: XCUITest can't toggle the system Reduce Transparency setting, so `OFFERLANE_REDUCE_TRANSPARENCY=1` forces its fallback.
    static let forceSolid = ProcessInfo.processInfo.environment["OFFERLANE_REDUCE_TRANSPARENCY"] == "1"
}

// MARK: Glass surface

/// Translucent layered surface: a tint over the (already blurred) backdrop with a specular edge, and a solid
/// surface under Reduce Transparency or Increase Contrast. `chrome` surfaces (sidebar, palette, toast) use native
/// Liquid Glass on macOS 26+. Content never sits on a live material or native glass: both make text vibrant,
/// which fails AA (caught by the accessibility audit); the tint's contrast is checked by scripts/check_contrast.py.
struct GlassSurface: ViewModifier {
    var radius: CGFloat = DS.Radius.xl
    var chrome = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || DS.forceSolid || contrast == .increased {
            content
                .background(DS.Palette.surface, in: shape)
                .overlay(shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.55) : DS.Palette.hairline))
        } else if chrome, #available(macOS 26, *) {
            content
                .background(DS.Palette.glassTint, in: shape)
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(DS.Palette.glassTint, in: shape)
                .overlay(shape.strokeBorder(LinearGradient(colors: [DS.Palette.glassEdge, .clear, DS.Palette.hairline],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing)))
                .dsShadow(DS.Elevation.glass)
        }
    }
}

extension View {
    /// Wrap this view in an Offerlane glass surface.
    func glassSurface(radius: CGFloat = DS.Radius.xl, chrome: Bool = false) -> some View {
        modifier(GlassSurface(radius: radius, chrome: chrome))
    }
}

// MARK: Backdrop

/// Slow drifting colour field behind the glass. Plain window colour under Reduce Transparency,
/// still under Reduce Motion.
struct GlassBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        if reduceTransparency || DS.forceSolid {
            DS.Palette.canvas.ignoresSafeArea()
        } else {
            GeometryReader { g in
                let d = max(g.size.width, g.size.height)
                ZStack {
                    DS.Palette.backdropBase
                    Circle().fill(DS.Palette.backdropA).frame(width: d * 0.9).blur(radius: d * 0.14)
                        .offset(x: g.size.width * (drift ? -0.25 : -0.05), y: g.size.height * (drift ? -0.2 : -0.35))
                    Circle().fill(DS.Palette.backdropB).frame(width: d * 0.7).blur(radius: d * 0.14)
                        .offset(x: g.size.width * (drift ? 0.3 : 0.15), y: g.size.height * (drift ? 0.35 : 0.2))
                }
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
            }
            // Top only: extending under the floating sidebar would tint its text below AA.
            .ignoresSafeArea(edges: .top)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: DS.Motion.drift).repeatForever(autoreverses: true)) { drift = true }
            }
        }
    }
}
