import SwiftUI
import OfferlaneCore

/// Find: run a search and decide on new roles (gate 1). Primary action: Find Jobs.
struct FindView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<String>()
    @State private var showWeaker = false
    @State private var tab = "fit"
    @State private var remoteOnly = false

    var body: some View {
        let strong = filter(app.strongMatches), weaker = filter(app.weakerMatches)
        VStack(spacing: 0) {
            // The empty state carries the Find Jobs button itself: one primary action per screen.
            ScreenHeader(title: SidebarItem.find.title, subtitle: subtitle) { if !app.matches.isEmpty || app.isFinding { primary } }
            if app.isFinding {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ProgressStream(lines: app.findLog)
                    if let p = app.findProgress, p.tokens > 0 || p.tokenLimit != nil { UsageMeter(tokens: p.tokens, limit: p.tokenLimit) }
                }
                .padding(DS.Space.m).glassSurface(radius: DS.Radius.l)
                .padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.s)
            }
            if !app.matches.isEmpty { tabBar(strong) }
            if !selection.isEmpty { bulkBar }
            Group {
                if app.matches.isEmpty {
                    if app.isFinding { SkeletonList(label: "Searching career sites") } else {
                        EmptyState(title: "No matches yet", symbol: "sparkle.magnifyingglass",
                                   message: "Find Jobs searches free job sites and company career sites, then scores each role. Nothing is tailored or applied until you approve it.") {
                            Button { app.findJobs() } label: { Label("Find Jobs", systemImage: "sparkle.magnifyingglass") }
                                .buttonStyle(.ds(.primary, .large)).disabled(!app.aiConnected)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                    List(selection: $selection) {
                        if tab == "stretch" {
                            Section {
                                ForEach(strong.filter { $0.tier == "stretch" }) { MatchRow(job: $0) }
                            } header: {
                                Text("A step up or aside from your experience so far")
                            }
                        } else {
                            Section {
                                ForEach(strong.filter { $0.tier != "stretch" }) { MatchRow(job: $0) }
                            } header: {
                                Text("Score \(app.search.minScore)+")
                            }
                        }
                        if tab == "fit", !weaker.isEmpty {
                            Section {
                                if showWeaker { ForEach(weaker) { MatchRow(job: $0) } }
                            } header: {
                                Button { withDSAnimation { showWeaker.toggle() } } label: {
                                    Label(showWeaker ? "Hide weaker matches · \(weaker.count)" : "Show weaker matches · \(weaker.count)",
                                          systemImage: showWeaker ? "chevron.down" : "chevron.right")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("matches.toggleWeaker")
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("matches.list")
                    .onKeyPress(characters: CharacterSet(charactersIn: "jkadJKAD")) { k in
                        // Plain keys only: ⌘D or ⌥A must never decline or approve by accident.
                        guard k.modifiers.subtracting(.shift).isEmpty else { return .ignored }
                        return triage(k.characters.lowercased(), visible(strong, weaker))
                    }
                    .onKeyPress(.return) { triage("\r", visible(strong, weaker)) }
                    keyHints
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var subtitle: String {
        if app.isFinding { return app.findProgress?.message ?? "Searching…" }
        if let s = app.lastSummary {
            let ai = s.tokens > 0 ? " · AI used \(UsageMeter.short(s.tokens))\(s.tokenLimit.map { " of \(UsageMeter.short($0))" } ?? "") tokens" : ""
            return "Last search: \(s.discovery.checked + s.discovery.sourcesChecked.count) sites checked, \(s.discovery.new) new roles" + ai
        }
        return app.matches.isEmpty ? "" : "\(app.strongMatches.count) strong · \(app.weakerMatches.count) weaker"
    }

    @ViewBuilder private var primary: some View {
        if app.isFinding {
            HStack(spacing: DS.Space.s) {
                ProgressRing(value: app.findProgress?.fraction)
                Button("Stop") { app.cancelFind() }.buttonStyle(.dsSecondary).accessibilityIdentifier("toolbar.stop")
            }
        } else {
            Button { app.findJobs() } label: { Label("Find Jobs", systemImage: "sparkle.magnifyingglass") }
                .buttonStyle(.ds(.primary, .large))
                .disabled(!app.aiConnected)
                .help("Search job sites and career sites, then score new roles (⌘F)")
                .accessibilityIdentifier("toolbar.findJobs")
        }
    }

    private var bulkBar: some View {
        HStack(spacing: DS.Space.s) {
            Text("\(selection.count) selected").font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            Button("Clear") { selection = [] }.buttonStyle(.ds(.ghost, .small))
            Button("Decline \(selection.count)") { app.decline(selection); selection = [] }
                .buttonStyle(.ds(.secondary, .small)).keyboardShortcut(.delete, modifiers: .command)
            Button("Approve \(selection.count)") { app.approve(selection); selection = [] }
                .buttonStyle(.ds(.primary, .small)).keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.s)
        .background(DS.Palette.accentSoft)
        .transition(DS.Motion.reduced ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    // MARK: keyboard triage (J/K move, A approve, D decline, Return opens the posting)

    /// Rows in on-screen order, so J/K walk what the user sees.
    private func visible(_ strong: [Job], _ weaker: [Job]) -> [Job] {
        tab == "stretch" ? strong.filter { $0.tier == "stretch" }
            : strong.filter { $0.tier != "stretch" } + (showWeaker ? weaker : [])
    }

    private func triage(_ key: String, _ rows: [Job]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let i = selection.compactMap { id in rows.firstIndex { $0.id == id } }.min()
        func select(_ n: Int) { selection = [rows[max(0, min(rows.count - 1, n))].id] }
        switch key {
        case "j": select(i.map { $0 + 1 } ?? 0)
        case "k": select(i.map { $0 - 1 } ?? 0)
        case "a", "d":
            // Only rows on screen: the search filter may hide part of the selection.
            let ids = Set(rows.map(\.id)).intersection(selection)
            guard let i, !ids.isEmpty else { return .ignored }
            // Same calls as the row buttons: approving only queues tailoring; nothing is sent without Review.
            if key == "a" { app.approve(ids) } else { app.decline(ids) }
            let rest = rows.filter { !ids.contains($0.id) }
            selection = rest.isEmpty ? [] : [rest[min(i, rest.count - 1)].id]
        case "\r":
            guard selection.count == 1, let i, let u = URL.web(rows[i].url) else { return .ignored }
            NSWorkspace.shared.open(u)
        default: return .ignored
        }
        return .handled
    }

    private var keyHints: some View {
        HStack(spacing: DS.Space.l) {
            ForEach([("J K", "next / previous"), ("A", "approve"), ("D", "decline"), ("↩", "open posting")], id: \.0) { k in
                HStack(spacing: 4) {
                    Text(k.0).font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(DS.Palette.hairline))
                    Text(k.1).font(DS.Font.caption)
                }
            }
        }
        .foregroundStyle(DS.Palette.textSecondary)
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(DS.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.xl).padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keyboard: J and K move, A approves, D declines, Return opens the posting")
        .accessibilityIdentifier("matches.keys")
    }

    private func filter(_ js: [Job]) -> [Job] {
        let q = app.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return js.filter {
            (q.isEmpty || "\($0.title) \($0.company) \($0.location)".lowercased().contains(q))
                && (!remoteOnly || $0.location.localizedCaseInsensitiveContains("remote"))
        }
    }

    /// Best fit / Stretch tabs plus the Remote filter; search text comes from the toolbar field.
    private func tabBar(_ strong: [Job]) -> some View {
        let stretch = strong.filter { $0.tier == "stretch" }.count
        return HStack(spacing: DS.Space.m) {
            Picker("Matches", selection: $tab) {
                Text("Best fit · \(strong.count - stretch)").tag("fit")
                Text("Stretch · \(stretch)").tag("stretch")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            .accessibilityIdentifier("matches.tab")
            Toggle("Remote only", isOn: $remoteOnly).toggleStyle(.checkbox).accessibilityIdentifier("matches.remoteOnly")
            Spacer()
        }
        .padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.s)
    }
}

struct MatchRow: View {
    @Environment(AppModel.self) private var app
    let job: Job
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Monogram(name: job.company, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(DS.Font.headline).lineLimit(2)
                Text([job.company, job.location].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                if !job.llmReason.isEmpty {
                    (Text("Why it fits: ").fontWeight(.semibold) + Text(job.llmReason)).font(DS.Font.callout).lineLimit(expanded ? nil : 1)
                        .help(job.llmReason)
                }
                HStack(spacing: 6) {
                    if let pay = PayRange.parse(job.description).first { Pill(text: Self.pay(pay), symbol: "banknote") }
                    if !job.visa.isEmpty { Pill(text: Visa.label(job.visa), symbol: "airplane", tint: visaTint) }
                    if let p = job.posted, let d = Dates.day(p) { Pill(text: "Posted " + d.formatted(.relative(presentation: .named)), symbol: "calendar") }
                    if let y = job.minYears { Pill(text: "\(y)+ yrs asked", symbol: "clock") }
                    // Source terms (e.g. Remotive) require naming the source and linking back to it.
                    if let src = JobSources.all.first(where: { "api:" + $0.id == job.source }), let u = URL.web(job.url) {
                        Link(destination: u) { Pill(text: "via " + src.name, symbol: "link") }.help("Open this posting on \(src.name)")
                    }
                    // Adzuna's terms: an "Adzuna" label at least 116×23 on each advert, linking to Adzuna (the advert's country site).
                    if job.source == "api:adzuna" {
                        Link(destination: Adzuna.attribution(for: job.url)) {
                            Text("Jobs by Adzuna").font(DS.Font.caption.weight(.semibold)).frame(minWidth: 116, minHeight: 23)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.Palette.textSecondary.opacity(0.5)))
                        }
                        .help("Adzuna, where this job was found").accessibilityIdentifier("adzuna.attribution")
                        .accessibilityValue(Adzuna.attribution(for: job.url).host ?? "")  // VoiceOver (and tests) hear which site it opens
                    }
                    if app.versions.count > 1 {
                        Menu {
                            ForEach(app.versions) { v in Button(v.label) { app.setVariant(job.id, v.name) } }
                        } label: { Pill(text: "Resume: " + (app.versions.first { $0.name == job.variant }?.label ?? "default"), symbol: "doc.text") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                if expanded {
                    Text(job.description.isEmpty ? "No description available." : job.description)
                        .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled).padding(.top, 4)
                    if let u = URL.web(job.url) { Link("Open posting", destination: u).font(DS.Font.callout) }
                }
                Button(expanded ? "Hide description" : "Show description") { withDSAnimation { expanded.toggle() } }
                    .buttonStyle(.link).font(DS.Font.caption)
            }
            Spacer(minLength: DS.Space.s)
            ScoreBadge(score: job.llmScore, local: job.localScore, threshold: app.search.minScore)
            VStack(spacing: 6) {
                Button { app.approve([job.id]) } label: { Label("Approve", systemImage: "checkmark").frame(minWidth: 78) }
                    .buttonStyle(.ds(.primary, .small)).help("Tailor a resume and apply (you'll review first) · A")
                    .accessibilityIdentifier("approve.\(job.id)")
                Button { app.decline([job.id]) } label: { Label("Decline", systemImage: "xmark").frame(minWidth: 78) }
                    .buttonStyle(.ds(.secondary, .small))
                    .help("Hide this role; it won't come back · D")
                    .accessibilityIdentifier("decline.\(job.id)")
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Palette.hairline))
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
        .tag(job.id)
        .accessibilityElement(children: .contain)
    }

    /// "$120–150k a year", "€45–60 an hour": compact, as the mockup chips.
    static func pay(_ p: PayRange) -> String {
        func n(_ v: Double) -> String { v >= 1000 ? (v / 1000).formatted(.number.precision(.fractionLength(0...1))) : v.formatted(.number.precision(.fractionLength(0))) }
        // One "k" only when both ends are thousands; a mixed range spells out each end.
        let both = p.low >= 1000 && p.high >= 1000
        let lo = both ? n(p.low) : p.low.formatted(.number.precision(.fractionLength(0)))
        let hi = both ? n(p.high) + "k" : p.high.formatted(.number.precision(.fractionLength(0)))
        return "\(p.currency)\(lo)–\(hi)" + (p.period == .year ? "" : p.period.per)
    }

    private var visaTint: Color {
        switch job.visa {
        case "ok", "sponsors", "sponsor-register", "remote": DS.Palette.offer
        case "no-sponsorship": DS.Palette.danger
        case "h1b-lottery", "unknown": DS.Palette.warning
        default: .secondary
        }
    }
}

/// Match ring (v4): the score as a ring filled to its value, coloured by how it compares with the threshold.
struct ScoreBadge: View {
    let score: Int?, local: Double?, threshold: Int
    var body: some View {
        let value = score ?? Int(local ?? 0)
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(max(0, min(100, value))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(value)").font(.system(.callout, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(DS.Palette.textPrimary)
        }
        .frame(width: 44, height: 44)
        .opacity(score == nil ? 0.7 : 1)
        .help(score == nil ? "Local score; not scored by AI yet" : "Match score \(value) of 100")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score == nil ? "Not scored by AI, local score \(value)" : "Score \(value) of 100")
    }
    private var color: Color {
        guard let score else { return .secondary }
        return score >= max(threshold, 80) ? DS.Palette.offer : score >= threshold ? DS.Palette.accent : DS.Palette.warning
    }
}
