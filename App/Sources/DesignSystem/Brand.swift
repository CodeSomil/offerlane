import SwiftUI

/// Brand copy. The only place the tagline and descriptions are written (scripts/check_brand.sh enforces it).
enum Brand {
    static let tagline = "Your lane to what's next."
    /// Store, website and social cards.
    static let shortDescription = "Offerlane is your private career companion. Find the right roles, close skill gaps, tailor your applications, prepare for interviews and negotiate offers. You stay in control, and nothing is sent without your approval."
    /// README and website top.
    static let longDescription = "Offerlane helps you grow your career, not just land the next job. It reads your résumé and goals, finds roles worth your time, shows which skills stand between you and the ones you want, and tailors each application without inventing anything. It prepares you for interviews, tracks every reply, and helps you compare and negotiate offers. Your data stays yours, and Offerlane never submits anything until you do."
}

/// The app icon as an image (from `Branding/offerlane-icon-512.png`).
struct LogoMark: View {
    var size: CGFloat = 28
    var body: some View {
        Image("Logo").resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Logo + "Offerlane" (+ optional tagline), matching `Branding/offerlane-wordmark-*.svg`.
struct Wordmark: View {
    var size: CGFloat = 28
    var tagline = false
    var body: some View {
        HStack(spacing: size * 0.32) {
            LogoMark(size: size * 1.15)
            VStack(alignment: .leading, spacing: 0) {
                Text("Offerlane").font(.system(size: size * 0.78, weight: .bold)).tracking(-size * 0.012)
                if tagline { Text(Brand.tagline).font(.callout.weight(.medium)).foregroundStyle(DS.Palette.textSecondary) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tagline ? "Offerlane. \(Brand.tagline)" : "Offerlane")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The lane motif: a road narrowing to the horizon with dashes flowing toward the offer.
/// Static when Reduce Motion is on.
struct LaneMotif: View {
    var animated = true
    var body: some View {
        if animated && !DS.Motion.reduced {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                lane(phase: ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6)
            }
        } else {
            lane(phase: 0)
        }
    }

    private func lane(phase: Double) -> some View {
        Canvas { g, size in
            let w = size.width, h = size.height, cx = w / 2
            // Road: wide at the bottom, narrow at the horizon (40 % from the top).
            let horizon = h * 0.18, bottomHalf = w * 0.34, topHalf = w * 0.02
            var road = Path()
            road.move(to: CGPoint(x: cx - bottomHalf, y: h))
            road.addLine(to: CGPoint(x: cx - topHalf, y: horizon))
            road.addLine(to: CGPoint(x: cx + topHalf, y: horizon))
            road.addLine(to: CGPoint(x: cx + bottomHalf, y: h))
            road.closeSubpath()
            g.fill(road, with: .linearGradient(Gradient(colors: [DS.Palette.accent.opacity(0.18), DS.Palette.accent.opacity(0.02)]),
                                                startPoint: CGPoint(x: cx, y: h), endPoint: CGPoint(x: cx, y: horizon)))
            // Dashes: perspective spacing, flowing up the lane.
            let n = 9
            for i in 0..<n {
                let t = (Double(i) + phase) / Double(n)          // 0 = near, 1 = horizon
                let p = pow(t, 1.8)
                let y = h - (h - horizon) * p
                let len = (1 - p) * h * 0.08 + 2
                let width = max(1.2, (1 - p) * 7)
                var dash = Path()
                dash.move(to: CGPoint(x: cx, y: y)); dash.addLine(to: CGPoint(x: cx, y: max(horizon, y - len)))
                g.stroke(dash, with: .color(DS.Palette.accent.opacity(0.25 + 0.6 * (1 - p))), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            // The offer at the end of the lane.
            let r = w * 0.035
            g.fill(Path(ellipseIn: CGRect(x: cx - r, y: horizon - r * 2.2, width: r * 2, height: r * 2)), with: .color(DS.Palette.offer))
        }
        .accessibilityHidden(true)
    }
}

/// Branded launch overlay: logo, wordmark and the lane motif; fades out on its own and never blocks input.
struct SplashView: View {
    @State private var shown = true
    @State private var appeared = false
    var body: some View {
        ZStack {
            if shown {
                ZStack {
                    DS.Palette.canvas
                    LaneMotif().frame(width: 360, height: 300).offset(y: 120).opacity(0.9)
                    VStack(spacing: DS.Space.l) {
                        LogoMark(size: 96)
                            .scaleEffect(appeared ? 1 : 0.92)
                        Wordmark(size: 30, tagline: true).opacity(appeared ? 1 : 0)
                    }
                    .offset(y: -40)
                }
                .transition(.opacity)
                .accessibilityIdentifier("splash")
            }
        }
        .allowsHitTesting(false)
        .task {
            withAnimation(DS.Motion.pick(DS.Motion.gentle)) { appeared = true }
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(DS.Motion.pick(.easeOut(duration: 0.25))) { shown = false }
        }
    }
}
