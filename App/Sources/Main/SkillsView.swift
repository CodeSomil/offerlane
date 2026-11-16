import SwiftUI
import OfferlaneCore

/// Skill gaps: what employers hiring for a role ask for, what the resume already shows, and a free-first plan to close the rest.
struct SkillsView: View {
    @Environment(AppModel.self) private var app
    @State private var state = SkillPlanState()
    @State private var role = ""
    @State private var newRole = ""
    @State private var report: GapReport?
    @State private var plan: LearningPlan?
    @State private var planning = false
    @State private var planGeneration = 0

    private var roles: [String] { SkillPlanner.roles(state, app.search) }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Skill gaps", subtitle: report.map { "From \($0.postings) posting\($0.postings == 1 ? "" : "s") you've collected for \($0.role)" }) {
                if roles.count > 1 {
                    Picker("Role", selection: $role) { ForEach(roles, id: \.self) { Text($0).tag($0) } }
                        .frame(maxWidth: 260).accessibilityIdentifier("skills.role")
                }
                Button { planGeneration += 1 } label: { Label("Refresh Plan", systemImage: "arrow.clockwise") }
                    .buttonStyle(.dsSecondary).disabled(planning || report?.postings ?? 0 == 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    rolesCard
                    if let report, report.postings > 0 {
                        readinessCard(report)
                        marketCard(report)
                        planCard(report)
                    } else { noPostings }
                }
                .padding(DS.Space.xl)
            }
        }
        .onAppear(perform: load)
        .onChange(of: role) { rescore(); planGeneration += 1 }
        .task(id: planGeneration) { await makePlan() }
    }

    // MARK: roles

    private var rolesCard: some View {
        SectionCard(title: "Roles you're aiming for", subtitle: state.roles.isEmpty ? "Using your search goals until you add one here." : nil, symbol: "scope") {
            HStack(spacing: DS.Space.s) {
                ForEach(roles, id: \.self) { r in
                    Pill(text: r, symbol: r == role ? "checkmark" : nil, tint: r == role ? DS.Palette.accent : .secondary)
                        .onTapGesture { role = r }
                        .accessibilityAddTraits(.isButton).accessibilityAction { role = r }
                    if state.roles.contains(r) {
                        Button { state.roles.removeAll { $0 == r }; save(); if role == r { role = roles.first ?? "" } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(DS.Palette.textSecondary).accessibilityLabel("Remove \(r)")
                    }
                }
            }
            HStack {
                TextField("Add a role, e.g. Head of AI Startups, EMEA", text: $newRole).textFieldStyle(.roundedBorder)
                    .onSubmit(addRole).accessibilityLabel("New role").accessibilityIdentifier("skills.role.new")
                Button("Add", action: addRole).buttonStyle(.dsSecondary).disabled(newRole.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var noPostings: some View {
        EmptyState(title: role.isEmpty ? "Pick a role" : "No postings for \(role) yet", symbol: "graduationcap",
                   message: role.isEmpty ? "Add the role you want above. Offerlane will read the postings you collect for it and show what employers ask for."
                                         : "Skill gaps come from real postings. Find jobs for this role first, then come back.") {
            Button { app.navigate(to: .find) } label: { Label("Go to Find Jobs", systemImage: SidebarItem.find.symbol) }.buttonStyle(.ds(.secondary, .large))
        }
    }

    // MARK: readiness

    private func readinessCard(_ r: GapReport) -> some View {
        SectionCard(title: "Readiness for \(r.role)", subtitle: "Each skill counts by how many postings ask for it × how central it is. Skills your resume shows, or that you marked, count as covered.", symbol: "gauge.with.dots.needle.67percent") {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text("\(r.readiness)%").font(DS.Font.metric).accessibilityIdentifier("skills.readiness")
                Text("ready · \(r.gaps.count) gap\(r.gaps.count == 1 ? "" : "s")").font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            let total = max(r.items.reduce(0) { $0 + $1.score }, 0.0001)
            ForEach(r.items.prefix(20)) { item in skillRow(item, r, total: total) }
            if r.items.count > 20 { Text("\(r.items.count - 20) less frequent skills not shown.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
        }
    }

    private func skillRow(_ item: GapItem, _ r: GapReport, total: Double) -> some View {
        let known = state.known.contains(item.id)
        return DisclosureGroup {
            ForEach(item.demand.jobIds, id: \.self) { id in
                if let j = app.jobs.first(where: { $0.id == id }) {
                    if let u = URL(string: j.url), !j.url.isEmpty { Link("\(j.title) · \(j.company)", destination: u).font(DS.Font.caption) }
                    else { Text("\(j.title) · \(j.company)").font(DS.Font.caption) }
                }
            }
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: item.have ? "checkmark.circle.fill" : "circle").foregroundStyle(item.have ? DS.Palette.offer : DS.Palette.textSecondary).accessibilityHidden(true)
                Text(item.demand.name).font(DS.Font.body)
                if item.demand.kind != "skill" { Pill(text: item.demand.kind == "cert" ? "Certification" : "Tool") }
                Spacer()
                Text("\(item.demand.count) of \(r.postings) postings · \(Int((item.score / total * 100).rounded()))% of score")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).monospacedDigit()
                if !item.have || known {
                    Button(known ? "Undo" : "I have this") { toggleKnown(item.id) }.buttonStyle(.dsSecondary).controlSize(.small)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(item.demand.name), \(item.have ? "covered" : "gap"), asked for in \(item.demand.count) of \(r.postings) postings")
        }
    }

    // MARK: market

    private func marketCard(_ r: GapReport) -> some View {
        let pool = MarketScan.relevant(app.jobs, role: r.role)
        let cities = MarketIntel.byCity(pool), trends = MarketIntel.trending(pool), byRole = MarketIntel.byRole(app.jobs, roles: roles)
        func skills(_ d: [SkillDemand]) -> String { d.map { "\($0.name) (\($0.count))" }.joined(separator: ", ") }
        return SectionCard(title: "Market for \(r.role)", subtitle: "From \(r.postings) posting\(r.postings == 1 ? "" : "s") you've collected, not a market survey. Counted on this Mac; nothing is sent.", symbol: "chart.bar.xaxis") {
            if byRole.count > 1 {
                Text("Demand by role").font(DS.Font.headline)
                ForEach(byRole) { s in marketRow(s.name, "\(s.postings) posting\(s.postings == 1 ? "" : "s")", skills(Array(s.top.prefix(3)))) }
            }
            Text("Demand by city").font(DS.Font.headline)
            ForEach(cities.prefix(8)) { s in
                marketRow(s.name, "\(s.postings) posting\(s.postings == 1 ? "" : "s")", skills(s.top)).accessibilityIdentifier("skills.market.city.\(s.name)")
            }
            if cities.count > 8 { Text("\(cities.count - 8) more cities not shown.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            Text("Trending skills").font(DS.Font.headline)
            if trends.enough {
                ForEach(trends.rising) { t in marketRow("↑ \(t.demand.name)", trendText(t, trends), "") }
                ForEach(trends.falling) { t in marketRow("↓ \(t.demand.name)", trendText(t, trends), "") }
                if trends.rising.isEmpty && trends.falling.isEmpty { Text("No change between the last two 30-day windows.").font(DS.Font.callout) }
            } else {
                Text("Not enough history yet: trends need \(MarketIntel.minPostings) postings in each of the last two 30-day windows (now \(trends.recentPostings) and \(trends.priorPostings)). Keep running Find Jobs.")
                    .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("skills.market.trend")
            }
        }
    }

    private func trendText(_ t: MarketIntel.Trend, _ all: MarketIntel.Trends) -> String {
        "\(t.recent) of \(all.recentPostings) postings in the last 30 days, \(t.prior) of \(all.priorPostings) in the 30 before"
    }

    private func marketRow(_ name: String, _ count: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(name).font(DS.Font.body)
            Spacer()
            Text(detail.isEmpty ? count : "\(count) · \(detail)").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: plan

    private func planCard(_ r: GapReport) -> some View {
        SectionCard(title: "Learning plan", subtitle: "Free first. Every link was checked just now and only curated resources are shown. Picks use \(app.ai?.client.displayName ?? "no AI (standard order)"): only skill names and course titles are sent, never your resume.", symbol: "list.bullet.rectangle") {
            Stepper("About \(state.hoursPerWeek) hours a week", value: $state.hoursPerWeek, in: 1...40) { _ in save(); planGeneration += 1 }
            if planning { SkeletonList(label: "Checking links and building your plan") }
            else if let plan {
                if plan.offline { Label("Couldn't reach any course site, so nothing is shown. Check your internet connection, then Refresh Plan.", systemImage: "wifi.exclamationmark").foregroundStyle(DS.Palette.warning) }
                else if plan.hidden > 0 { Text("\(plan.hidden) resource\(plan.hidden == 1 ? "" : "s") hidden because the link didn't open.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                if plan.steps.isEmpty && !plan.offline { Text("No catalog resource covers these gaps yet. Show them with a portfolio project instead.").font(DS.Font.callout) }
                ForEach(plan.steps) { step in stepRow(step, postings: r.postings) }
                if !plan.projects.isEmpty {
                    Text("Portfolio projects").font(DS.Font.headline).padding(.top, DS.Space.s)
                    ForEach(plan.projects, id: \.self) { Label($0, systemImage: "hammer").font(DS.Font.callout) }
                }
            }
        }
    }

    private func stepRow(_ s: LearningPlan.Step, postings: Int) -> some View {
        let done = state.done[s.id] != nil
        return HStack(alignment: .top, spacing: DS.Space.m) {
            Toggle(isOn: Binding(get: { done }, set: { markDone(s.item, $0) })) { EmptyView() }
                .toggleStyle(.checkbox).accessibilityLabel(done ? "Done: \(s.item.title)" : "Mark \(s.item.title) done")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DS.Space.s) {
                    Text("Week \(s.week)").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    if let u = URL(string: s.item.url) { Link(s.item.title, destination: u).font(DS.Font.headline) }
                    if done { Pill(text: "Done", symbol: "checkmark", tint: DS.Palette.offer) }
                }
                HStack(spacing: DS.Space.s) {
                    Text(s.item.provider).font(DS.Font.caption)
                    Pill(text: access(s.item), tint: s.item.access == "free" ? DS.Palette.offer : s.item.access == "audit" ? DS.Palette.info : DS.Palette.warning)
                    Text(s.item.hours.map { $0 < 1 ? "\(Int($0 * 60)) min" : "\(Int($0)) h" } ?? "Time not listed").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    if s.askedBy > 0 { Text("Skill asked for in \(s.askedBy) of \(postings) postings").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                }
                if !s.why.isEmpty { Text(s.why).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary) }
                if s.item.kind == "cert" && !done { Text("Added to your resume only after you mark it done.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func access(_ c: CatalogItem) -> String {
        switch c.access {
        case "free": "Free"
        case "audit": "Free to audit · certificate paid"
        default: c.cost.map { "Paid · \($0)" } ?? "Paid"
        }
    }

    // MARK: actions

    private func load() {
        state = (try? app.store.get(.skillPlan)) ?? SkillPlanState()
        if role.isEmpty || !roles.contains(role) { role = roles.first ?? "" }
        rescore()
    }

    private func rescore() {
        report = role.isEmpty ? nil : (try? SkillPlanner.report(store: app.store, role: role))
    }

    private func makePlan() async {
        guard let r = report, r.postings > 0 else { plan = nil; return }
        planning = true
        plan = await SkillPlanner.plan(r, state: state, ai: app.ai, checker: LinkChecker(), store: app.store)
        planning = false
    }

    private func save() {
        do { try app.store.set(.skillPlan, state) } catch { app.toast = .error("Couldn't save your skill plan: \(error.plainMessage). Free some disk space, then try again.", "Try Again") { save() } }
    }

    private func addRole() {
        let r = newRole.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        if !state.roles.contains(r) { state.roles.append(r); save() }
        newRole = ""; role = r
    }

    private func toggleKnown(_ id: String) {
        if state.known.contains(id) { state.known.removeAll { $0 == id } } else { state.known.append(id) }
        save(); rescore()
    }

    /// Re-scores without a new plan (no AI call); a finished certificate is written to the resume here and only here.
    private func markDone(_ item: CatalogItem, _ done: Bool) {
        do {
            try SkillPlanner.setDone(item, done, store: app.store)
            state = (try? app.store.get(.skillPlan)) ?? state
            rescore()
            if item.kind == "cert" { app.refresh(); app.toast = Toast(message: done ? "Added “\(item.title)” to your resume." : "Removed “\(item.title)” from your resume.") }
        } catch {
            app.toast = .error("Couldn't save that: \(error.plainMessage). Free some disk space, then try again.", "Try Again") { markDone(item, done) }
        }
    }
}
