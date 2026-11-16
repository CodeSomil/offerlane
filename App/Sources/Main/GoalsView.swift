import SwiftUI
import OfferlaneCore

/// Goals: typical 1/3/5-year steps from the current role, pivots to adjacent tracks, each scored against collected postings.
struct GoalsView: View {
    @Environment(AppModel.self) private var app
    @State private var current = ""
    @State private var trackId: String?
    @State private var map: CareerMap?
    @State private var goal: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Goals", subtitle: "Typical paths from where you are. Readiness comes from the postings you've collected.") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    currentCard
                    if let map, map.track != nil {
                        if map.steps.isEmpty { Text("You're at the top of this ladder. The pivots below are sideways moves.").font(DS.Font.callout) }
                        ForEach(map.steps) { stepCard($0) }
                        if !map.pivots.isEmpty {
                            Text("Pivot options").font(DS.Font.headline).padding(.top, DS.Space.s)
                            ForEach(map.pivots) { stepCard($0) }
                        }
                    }
                }
                .padding(DS.Space.xl)
            }
        }
        .onAppear(perform: load)
        .onChange(of: trackId) { explore() }
    }

    private var currentCard: some View {
        SectionCard(title: "Where you are now", subtitle: "From your resume's latest role. Titles vary by company; these ladders are typical, not guaranteed.", symbol: "figure.walk") {
            HStack {
                TextField("Your current title", text: $current).textFieldStyle(.roundedBorder)
                    .onSubmit { trackId = nil; explore() }.accessibilityLabel("Current title").accessibilityIdentifier("goals.current")
                Picker("Track", selection: $trackId) {
                    Text("Match my title").tag(String?.none)
                    ForEach(CareerPaths.bundled) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 260).accessibilityIdentifier("goals.track")
            }
            if let map {
                if let t = map.track {
                    Text(map.level.map { "Track: \(t.name) · rung \($0 + 1) of \(t.ladder.count)" } ?? "Track: \(t.name) · starting from its first rung")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                } else {
                    Label("No typical ladder matches “\(current)”. Pick the closest track above.", systemImage: "questionmark.circle").font(DS.Font.callout)
                        .accessibilityIdentifier("goals.nomatch")
                }
            }
        }
    }

    private func stepCard(_ s: CareerStep) -> some View {
        let r = s.report, isGoal = goal == s.role
        return SectionCard(title: s.years.map { "In about \($0) year\($0 == 1 ? "" : "s"): \(s.role)" } ?? "\(s.role) · \(s.track)", symbol: s.years == nil ? "arrow.triangle.branch" : "arrow.up.right") {
            HStack(spacing: DS.Space.s) {
                if r.postings > 0 {
                    Pill(text: "\(r.readiness)% ready", tint: DS.Palette.accent)
                    Text("from \(r.postings) posting\(r.postings == 1 ? "" : "s")").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                } else {
                    Text("No postings collected for this role yet, so readiness is unknown.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                if isGoal { Pill(text: "Your goal", symbol: "flag.fill", tint: DS.Palette.offer) }
                else { Button("Set as Goal") { setGoal(s) }.buttonStyle(.dsSecondary).accessibilityLabel("Set \(s.role) as goal") }
                Button("Plan Skills") { setGoal(s); app.navigate(to: .skills) }.buttonStyle(.dsSecondary).accessibilityLabel("Plan skills for \(s.role)")
            }
            if !s.topGaps.isEmpty {
                Text("Top gaps: " + s.topGaps.map { "\($0.demand.name) (\($0.demand.count) of \(r.postings))" }.joined(separator: " · "))
                    .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("goals.step.\(s.role)")
    }

    private func load() {
        let state: SkillPlanState? = try? app.store.get(.skillPlan)
        goal = state?.goal
        if current.isEmpty {
            current = [(try? app.store.resume())?.content.experience.first?.title, (try? app.store.profile())?.work.currentTitle]
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        }
        explore()
    }

    private func explore() {
        do { map = try CareerPaths.explore(current: current, trackId: trackId, store: app.store) }
        catch { app.toast = .error("Couldn't read your saved postings: \(error.plainMessage). Restart Offerlane, then try again.", "Try Again") { explore() } }
    }

    private func setGoal(_ s: CareerStep) {
        do { try CareerPaths.setGoal(s.role, years: s.years, search: app.search, store: app.store); goal = s.role }
        catch { app.toast = .error("Couldn't save your goal: \(error.plainMessage). Free some disk space, then try again.", "Try Again") { setGoal(s) } }
    }
}
