import SwiftUI

// MARK: Button

/// Offerlane buttons: one `.primary` per screen; `.secondary`, `.ghost` and `.destructive` for the rest.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    enum Size { case small, regular, large }
    var kind: Kind = .secondary
    var size: Size = .regular
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .padding(.horizontal, hPad).padding(.vertical, vPad)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous)
                    .strokeBorder(kind == .secondary ? DS.Palette.hairline : .clear)
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: DS.Radius.s + 3, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2.5).padding(-3)
                }
            }
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.Motion.pick(DS.Motion.quick), value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }

    private var font: Font {
        switch size { case .small: .callout.weight(.medium); case .regular: .body.weight(.medium); case .large: .body.weight(.semibold) }
    }
    private var hPad: CGFloat { switch size { case .small: 9; case .regular: 12; case .large: 18 } }
    private var vPad: CGFloat { switch size { case .small: 3; case .regular: 5; case .large: 9 } }
    private var foreground: Color {
        switch kind { case .primary: .white; case .secondary: .primary; case .ghost: DS.Palette.accent; case .destructive: .white }
    }
    private func background(pressed: Bool) -> Color {
        let lift = (hovering && enabled ? 0.08 : 0) + (pressed ? 0.08 : 0)
        switch kind {
        case .primary: return DS.Palette.accentFill.opacity(1 - lift)
        case .destructive: return DS.Palette.danger.opacity(1 - lift)
        case .secondary: return lift == 0 ? DS.Palette.surfaceRaised : Color.primary.opacity(0.04 + lift * 0.6)
        case .ghost: return DS.Palette.accent.opacity(hovering || pressed ? 0.10 + lift : 0)
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsDestructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
    static func ds(_ kind: DSButtonStyle.Kind, _ size: DSButtonStyle.Size = .regular) -> DSButtonStyle { DSButtonStyle(kind: kind, size: size) }
}

// MARK: Card

/// A calm raised surface for grouped content.
struct Card<Content: View>: View {
    var padding: CGFloat = DS.Space.l
    var hoverable = false
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(radius: DS.Radius.l)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(hovering ? DS.Palette.accent.opacity(0.45) : .clear))
            .onHover { if hoverable { hovering = $0 } }
            .dsAnimation(DS.Motion.quick, value: hovering)
    }
}

/// Titled card used for settings-style sections.
struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(DS.Palette.accent).frame(width: 18).accessibilityHidden(true) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(DS.Font.headline)
                        if let subtitle { Text(subtitle).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                content
            }
        }
    }
}

// MARK: Pill

/// Small status chip.
struct Pill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.weight(.semibold)) }
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .background((tint == .secondary ? Color.secondary : tint).opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Kept for existing call sites.
typealias Chip = Pill

// MARK: EmptyState

/// One message, one clear action.
struct EmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    let message: String
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: DS.Space.m) {
            // A small static illustration (v4): a lane ring, the symbol, two accent dots. No motion, so nothing to reduce.
            ZStack {
                Circle().strokeBorder(DS.Palette.accent.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [4, 5])).frame(width: 104, height: 104)
                Circle().fill(DS.Palette.accentSoft).frame(width: 68, height: 68)
                Image(systemName: symbol).font(.system(size: 28, weight: .medium)).foregroundStyle(DS.Palette.accent)
                Circle().fill(DS.Palette.offer).frame(width: 9, height: 9).offset(x: 40, y: -30)
                Circle().fill(DS.Palette.accent.opacity(0.5)).frame(width: 6, height: 6).offset(x: -44, y: 22)
            }
            .frame(width: 112, height: 112)
            .accessibilityHidden(true)
            Text(title).font(DS.Font.title)
            // No fixedSize here: the window's minimum-size pass proposes zero width, and a fixed
            // vertical size would then demand a one-letter-per-line height and overflow the window.
            Text(message).font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            actions.padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(title: String, symbol: String, message: String) { self.init(title: title, symbol: symbol, message: message) { EmptyView() } }
}

// MARK: ProgressRing

/// Determinate (or indeterminate when `value` is nil) circular progress.
struct ProgressRing: View {
    var value: Double?
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().stroke(DS.Palette.accent.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: value.map { max(0.04, min(1, $0)) } ?? 0.28)
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90 + (value == nil && spin ? 360 : 0)))
                .animation(value == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : DS.Motion.standard, value: value == nil ? AnyHashable(spin) : AnyHashable(value))
        }
        .frame(width: size, height: size)
        .onAppear { if value == nil && !DS.Motion.reduced { spin = true } }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

// MARK: Skeleton

/// Placeholder block with a soft shimmer (static under Reduce Motion).
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 4
    @State private var phase: CGFloat = -1
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.4)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .frame(width: width, height: height)
            .onAppear {
                guard !DS.Motion.reduced else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Rows of skeleton placeholders shaped like job rows.
struct SkeletonList: View {
    var rows = 6
    var label = "Loading"
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: DS.Space.m) {
                    SkeletonBlock(width: 50, height: 46, radius: DS.Radius.m)
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        SkeletonBlock(width: 260 - CGFloat(i % 3) * 30, height: 14)
                        SkeletonBlock(width: 180, height: 11)
                    }
                    Spacer()
                }
            }
            Spacer()
        }
        .padding(DS.Space.xl)
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

// MARK: Sheet

/// Standard sheet chrome: title, scrollable content, Cancel + primary action at the bottom.
struct DSSheet<Content: View>: View {
    let title: String
    var primary: String = "Done"
    var primaryDisabled = false
    var showsCancel = true
    var onCancel: () -> Void = {}
    var onPrimary: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(DS.Font.title); Spacer() }
                .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.l).padding(.bottom, DS.Space.m)
            Divider()
            content
            Divider()
            HStack(spacing: DS.Space.s) {
                Spacer()
                if showsCancel { Button("Cancel", action: onCancel).buttonStyle(.dsSecondary).keyboardShortcut(.cancelAction) }
                Button(primary, action: onPrimary).buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction).disabled(primaryDisabled)
            }
            .padding(DS.Space.m)
        }
    }
}

// MARK: Toast

/// Bottom toast with an optional Undo; disappears after a few seconds.
struct ToastView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ZStack {
            if let t = app.toast {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(t.isError ? DS.Palette.warning : DS.Palette.offer)
                        .accessibilityHidden(true)
                    Text(t.message).lineLimit(3)
                    if let label = t.actionLabel, let action = t.action {
                        Button(label) { action() }.buttonStyle(.ds(.ghost, .small))
                    }
                    Button { withDSAnimation { app.toast = nil } } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                        .buttonStyle(.plain).foregroundStyle(DS.Palette.textSecondary).accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s + 2)
                .frame(maxWidth: 560)
                .glassSurface(radius: DS.Radius.l, chrome: true)
                .dsShadow(DS.Elevation.overlay)
                .padding(.bottom, 18)
                .transition(DS.Motion.reduced ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toast")
                .task(id: t.id) {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if app.toast?.id == t.id { withDSAnimation { app.toast = nil } }
                }
            }
        }
        .dsAnimation(value: app.toast?.id)
    }
}

// MARK: Stepper

/// Numbered steps joined by connectors: done steps show a tick, the current one is filled.
/// Steps after the current one (and `locked` ones) can't be clicked.
struct DSStepper: View {
    struct Step: Identifiable { let id: String; let title: String; var locked = false }
    let steps: [Step]
    let current: Int
    var onSelect: (Int) -> Void = { _ in }
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                let done = i < current, now = i == current
                Button { onSelect(i) } label: { bubble(i + 1, s.title, done: done, current: now) }
                    .buttonStyle(.plain)
                    .disabled(i > current || s.locked)
                    .accessibilityLabel("Step \(i + 1) of \(steps.count), \(s.title)\(now ? ", current" : done ? ", done" : "")")
                    .accessibilityIdentifier(s.id)
                if i < steps.count - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).frame(minWidth: 8, maxWidth: 40).accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func bubble(_ number: Int, _ title: String, done: Bool, current: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(current ? DS.Palette.accentFill : done ? DS.Palette.accentSoft : Color.secondary.opacity(0.15))
                if done { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(DS.Palette.accent) }
                else { Text("\(number)").font(.caption.bold()).foregroundStyle(current ? .white : .secondary) }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            Text(title).font(.callout.weight(current ? .semibold : .regular)).foregroundStyle(current ? .primary : .secondary)
                .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Progress stream

/// Live log of a long run's steps, newest last; earlier lines fade back.
struct ProgressStream: View {
    let lines: [String]
    var visible = 4
    var body: some View {
        let shown = Array(lines.suffix(visible))
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, line in
                let last = i == shown.count - 1
                HStack(spacing: DS.Space.s) {
                    Image(systemName: last ? "circle.dotted" : "checkmark").font(.caption2.weight(.semibold))
                        .foregroundStyle(last ? DS.Palette.accent : DS.Palette.offer).frame(width: 12).accessibilityHidden(true)
                    Text(line).font(DS.Font.caption).foregroundStyle(last ? DS.Palette.textPrimary : DS.Palette.textSecondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.last ?? "")
        .accessibilityIdentifier("progressStream")
    }
}

// MARK: Screen header

/// Title row at the top of each main screen with its single primary action on the right.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.display).accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).lineLimit(1) }
            }
            Spacer(minLength: DS.Space.l)
            trailing
        }
        .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.l).padding(.bottom, DS.Space.m)
    }
}


// MARK: UsageMeter

/// AI tokens used this run against its limit: a thin bar that turns amber near the limit.
struct UsageMeter: View {
    let tokens: Int
    let limit: Int?
    var body: some View {
        let f = limit.map { Double(tokens) / Double(max(1, $0)) } ?? 0
        HStack(spacing: DS.Space.s) {
            Text("AI use this run").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            if limit != nil {
                ProgressView(value: min(f, 1)).tint(f > 0.85 ? DS.Palette.warning : DS.Palette.accent).frame(maxWidth: 160)
            }
            Text("\(Self.short(tokens))\(limit.map { " of \(Self.short($0))" } ?? "") tokens").font(DS.Font.caption).monospacedDigit()
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI use this run: \(tokens.formatted()) tokens\(limit.map { " of \($0.formatted())" } ?? "")")
        .accessibilityIdentifier("find.usageMeter")
    }
    static func short(_ n: Int) -> String { n >= 1000 ? String(format: n >= 10_000 ? "%.0fk" : "%.1fk", Double(n) / 1000) : "\(n)" }
}

// MARK: Monogram

/// Company initials on a soft accent tile (v4 cards). No logo fetching: that would leak which companies you look at.
struct Monogram: View {
    let name: String
    var size: CGFloat = 36
    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(DS.Palette.accent)
            .frame(width: size, height: size)
            .background(DS.Palette.accentSoft, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        let s = words.count > 1 ? words.compactMap(\.first).map(String.init).joined() : String(words.first?.prefix(2) ?? "?")
        return s.uppercased()
    }
}
