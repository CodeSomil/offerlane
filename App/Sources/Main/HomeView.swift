import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OfferlaneCore

/// Today (v4 mockup): one next action, setup readiness, this week's funnel, upcoming interviews.
/// Reads stored data only; no AI call.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var report: AnalyticsReport?
    @State private var skipped = 0
    @State private var stories = 0

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: SidebarItem.home.title, subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide))) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    hero
                    HStack(alignment: .top, spacing: DS.Space.l) {
                        readinessCard.frame(maxWidth: 340)
                        weekCard
                    }
                    interviewsCard
                    coachingCard
                }
                .padding(DS.Space.xl)
            }
        }
        .task(id: app.data.events.first?.id) {
            report = try? Analytics.report(store: app.store)
            stories = (try? app.store.get(.interviewPrep, as: InterviewPrepState.self))??.stories.count ?? 0
        }
    }

    // MARK: hero: the single next action

    private struct Action: Identifiable { let id: String; let title: String; let detail: String; let button: String; let go: SidebarItem }

    private var actions: [Action] {
        var a: [Action] = []
        if !app.aiConnected { a.append(Action(id: "ai", title: "Connect an AI", detail: "Offerlane needs one to score roles and tailor your résumé.", button: "Connect", go: .connectAI)) }
        let r = app.reviewCount
        if r > 0 { a.append(Action(id: "review", title: "Review \(r) tailored résumé\(r == 1 ? "" : "s")", detail: "Approve them and Offerlane fills in each form. You click Submit yourself.", button: "Review now", go: .review)) }
        let due = Contacts.due(app.data.contacts)
        if !due.isEmpty { a.append(Action(id: "followUp", title: "Follow up with \(due.count == 1 ? due[0].name : "\(due.count) people")", detail: "Pipeline → People has who and why. You send the message yourself.", button: "Open Pipeline", go: .applications)) }
        let n = app.strongMatches.count
        if n > 0 { a.append(Action(id: "approve", title: "Decide on \(n) new match\(n == 1 ? "" : "es")", detail: "Approve the roles worth tailoring for. Nothing is sent until you say so.", button: "Open Discover", go: .find)) }
        if a.isEmpty { a.append(Action(id: "find", title: "Find new roles", detail: "Search your target companies and boards for fresh matches.", button: "Find roles", go: .find)) }
        return a
    }

    private var hero: some View {
        let all = actions, a = all[skipped % all.count]
        return HStack(alignment: .center, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT STEP").font(.caption.weight(.bold)).tracking(0.6).foregroundStyle(DS.Palette.accent)
                Text(a.title).font(.system(.title2).weight(.semibold))
                Text(a.detail).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DS.Space.m)
            if all.count > 1 {
                Button("Later") { skipped += 1 }.buttonStyle(.dsSecondary).accessibilityIdentifier("home.later")
            }
            Button(a.button) { app.navigate(to: a.go) }.buttonStyle(.dsPrimary).accessibilityIdentifier("home.action.\(a.id)")
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: DS.Radius.l)
        .background(LinearGradient(colors: [DS.Palette.accentSoft, .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)))
        .dsAnimation(DS.Motion.standard, value: skipped)
    }

    // MARK: readiness: is setup complete?

    private var checklist: [(id: String, text: String, done: Bool, fix: SidebarItem)] {
        [("resume", "Résumé added", !app.versions.isEmpty, .resumes),
         ("ai", "AI connected", app.aiConnected, .connectAI),
         ("search", "Search set up", !app.search.targetTitles.isEmpty, .find),
         ("email", "Email tracking", app.settings.email.enabled, .settings)]
    }

    private var readinessCard: some View {
        let items = checklist, pct = Double(items.filter(\.done).count) / Double(items.count)
        return SectionCard(title: "Readiness", symbol: "gauge.with.dots.needle.67percent") {
            HStack(spacing: DS.Space.l) {
                ZStack {
                    ProgressRing(value: pct, size: 76, lineWidth: 8)
                    Text("\(Int(pct * 100))%").font(DS.Font.headline).monospacedDigit().accessibilityHidden(true)
                }
                .accessibilityRepresentation { ProgressView("Setup readiness", value: pct) }  // a real progress role for VoiceOver
                .accessibilityIdentifier("home.readiness")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.id) { i in
                        HStack(spacing: 6) {
                            Image(systemName: i.done ? "checkmark" : "circle").font(.caption.weight(.bold))
                                .foregroundStyle(i.done ? DS.Palette.offer : DS.Palette.warning).accessibilityHidden(true)
                            Text(i.text).font(DS.Font.callout)
                            if !i.done {
                                Button("Turn on") { app.navigate(to: i.fix) }.buttonStyle(.link).font(DS.Font.caption)
                                    .accessibilityLabel("Set up \(i.text)")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(i.done ? "Done" : "Not done")
                    }
                }
            }
        }
    }

    // MARK: this week's funnel

    private var funnel: [(String, Int)] {
        // shortcut: Matches/Approved count from the newest 400 events DataSnapshot loads; fine unless someone logs 400+ moves in 7 days.
        let since = Dates.now(Date().addingTimeInterval(-7 * 86_400))
        let approved = Set(app.data.events.filter { $0.ts >= since && $0.status == JobStatus.tailoring.rawValue }.map(\.jobId)).count
        return [("Matches", app.jobs.filter { $0.firstSeen >= since }.count),
                ("Approved", approved),
                ("Applied", report?.thisWeek.sent ?? 0),
                ("Replies", report?.thisWeek.responses ?? 0)]
    }

    private var weekCard: some View {
        let rows = funnel
        return SectionCard(title: "This week", subtitle: "Last 7 days", symbol: "calendar") {
            // Plain bars, not Swift Charts: macOS Charts exposes bars with no accessibility role and labels with no
            // real frame, which fails the audit. Four bars need no chart engine.
            let top = max(1, rows.map(\.1).max() ?? 0)
            Grid(alignment: .leading, horizontalSpacing: DS.Space.s, verticalSpacing: DS.Space.s) {
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(r.0 == "Replies" ? DS.Palette.offer : DS.Palette.accentFill)
                                .frame(width: max(4, g.size.width * CGFloat(r.1) / CGFloat(top)))
                        }
                        .frame(height: 18)
                        .accessibilityHidden(true)
                        Text("\(r.1)").font(DS.Font.caption.weight(.semibold)).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home.week.\(r.0.lowercased())")
                }
            }
            if let w = report {
                Text(answered(w.thisWeek) + " Last week: \(w.lastWeek.responses) of \(w.lastWeek.sent).")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityIdentifier("home.week.rate")
            }
        }
    }

    private func answered(_ g: AnalyticsGroup) -> String {
        g.sent == 0 ? "No applications sent this week." : "\(g.responses) of \(g.sent) applications answered (\(g.responseRate)%)."
    }

    // MARK: weekly coaching review (template sentences, no AI)

    private var coachingCard: some View {
        let c = Coaching.weekly(report: report ?? AnalyticsReport(), tracked: app.allTracked, contactsDue: Contacts.due(app.data.contacts).count)
        return SectionCard(title: "Weekly review", subtitle: "From your own counts. No AI.", symbol: "text.badge.checkmark") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(c.headline).font(DS.Font.body.weight(.semibold)).accessibilityIdentifier("home.coaching.headline")
                ForEach(c.points, id: \.self) { Label($0, systemImage: "arrow.right.circle").font(DS.Font.callout).accessibilityIdentifier("home.coaching.point") }
            }
        }
    }

    // MARK: upcoming interviews

    private var interviewsCard: some View {
        // Dated interviews first, soonest first; past dates drop off. Undated roles at Screen/Interview follow, newest change first.
        let today = Calendar.current.startOfDay(for: Date())
        let roles = app.allTracked.filter { [.screen, .interview].contains($0.status) }
        let dated = roles.compactMap { j in InterviewCalendar.date(j).map { (j, $0) } }.filter { $0.1 >= today }.sorted { $0.1 < $1.1 }
        let upcoming = (dated.map(\.0) + roles.filter { InterviewCalendar.date($0) == nil }).prefix(4)
        return SectionCard(title: "Upcoming interviews", symbol: "person.wave.2") {
            if upcoming.isEmpty {
                Text("No interviews yet. When a role reaches Screen or Interview, it shows here with its prep.")
                    .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary)
            }
            ForEach(Array(upcoming)) { j in
                HStack(spacing: DS.Space.m) {
                    Monogram(name: j.company)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(j.title) · \(j.company)").font(DS.Font.body.weight(.semibold)).lineLimit(1)
                        Text((j.status == .screen ? "Screening call" : "Interview") + (InterviewCalendar.date(j).map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? " · add the date in Pipeline"))
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Pill(text: stories > 0 ? "\(stories) STAR stor\(stories == 1 ? "y" : "ies") ready" : "Prep not started",
                         tint: stories > 0 ? DS.Palette.offer : DS.Palette.warning)
                    Button("Prepare") { app.navigate(to: .interview) }.buttonStyle(.dsSecondary)
                }
                .accessibilityIdentifier("home.interview.\(j.id)")
            }
            if !dated.isEmpty {
                Button { exportCalendar(dated.map(\.0)) } label: { Label("Export to Calendar…", systemImage: "calendar.badge.plus") }
                    .buttonStyle(.dsSecondary).accessibilityIdentifier("home.exportCalendar")
                    .help("Saves an .ics file. Open it to add these interviews to your calendar app.")
            }
        }
    }

    private func exportCalendar(_ jobs: [Job]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Offerlane interviews.ics"; panel.allowedContentTypes = [.calendarEvent]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(InterviewCalendar.ics(jobs).utf8).write(to: url, options: .atomic)
            app.toast = Toast(message: "Saved \(jobs.count) interview\(jobs.count == 1 ? "" : "s"). Open the file to add them to your calendar.")
        } catch {
            app.toast = .error("Couldn't save the calendar file: \(error.plainMessage).", "Try Again") { exportCalendar(jobs) }
        }
    }
}
