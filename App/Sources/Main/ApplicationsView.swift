import SwiftUI
import UniformTypeIdentifiers
import OfferlaneCore

/// Submitted applications: a Kanban board (drag to change status), a table and the activity log, with notes and a timeline.
struct ApplicationsView: View {
    @Environment(AppModel.self) private var app
    @State private var mode = 0
    @State private var showRemoved = false
    @State private var selected: String?

    var body: some View {
        let tracked = filter(app.allTracked), removed = app.removed
        VStack(spacing: 0) {
            let quiet = tracked.filter { PipelineHints.isStale($0) }.count
            ScreenHeader(title: SidebarItem.applications.title,
                         subtitle: "\(tracked.count) application\(tracked.count == 1 ? "" : "s")" + (quiet > 0 ? " · \(quiet) need\(quiet == 1 ? "s" : "") a follow-up" : "")) {
                Button { app.checkInbox() } label: {
                    HStack(spacing: 6) {
                        if app.checkingInbox { ProgressRing(value: nil, size: 13, lineWidth: 2) } else { Image(systemName: "envelope.badge") }
                        Text(app.checkingInbox ? "Checking…" : "Check Inbox")
                    }
                }
                .buttonStyle(.ds(.primary, .large)).disabled(app.checkingInbox)
                .help("Read new replies from employers and update each application (⌘⇧I)")
            }
            HStack(spacing: DS.Space.s) {
                stat("Applied", tracked.count)
                stat("Interviewing", tracked.filter { [.screen, .assessment, .interview].contains($0.status) }.count)
                stat("Offers", tracked.filter { $0.status == .offer }.count)
                stat("Removed", removed.count)
                Spacer()
                if mode < 2 { Toggle("Show removed", isOn: $showRemoved).toggleStyle(.checkbox).accessibilityIdentifier("applications.showRemoved") }
                Picker("View", selection: $mode) { Text("Board").tag(0); Text("Table").tag(1); Text("Activity").tag(2); Text("Insights").tag(3); Text("Offers").tag(4); Text("People").tag(5) }
                    .pickerStyle(.segmented).frame(width: 470).labelsHidden().accessibilityIdentifier("applications.mode")
            }
            .padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.m)
            Divider()
            if mode == 2 {
                ActivityView()
            } else if mode == 3 {
                InsightsView()
            } else if mode == 4 {
                OffersView()
            } else if mode == 5 {
                ContactsView()
            } else if tracked.isEmpty && !(showRemoved && !removed.isEmpty) {
                EmptyState(title: "No applications yet", symbol: "rectangle.split.3x1",
                           message: "Roles you submit appear here. Replies from employers update them automatically when email tracking is on.") {
                    Button { app.navigate(to: .review) } label: { Label("Go to Review", systemImage: "checklist") }.buttonStyle(.ds(.secondary, .large))
                }
            } else if mode == 0 {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: DS.Space.m) {
                        ForEach(JobStatus.tracked, id: \.self) { s in column(s, tracked.filter { $0.status == s }) }
                        if showRemoved { column(.rejected, removed) }
                    }
                    .padding(16)
                }
            } else {
                Table(showRemoved ? tracked + removed : tracked, selection: $selected) {
                    TableColumn("Company", value: \.company).width(min: 100, ideal: 150)
                    TableColumn("Role", value: \.title).width(min: 160, ideal: 280)
                    TableColumn("Status") { Text($0.status.title) }.width(min: 90, ideal: 110)
                    TableColumn("Updated") { j in Text(Dates.day(j.updated).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "") }.width(min: 90, ideal: 110)
                    TableColumn("Notes") { Text($0.notes).lineLimit(1).foregroundStyle(DS.Palette.textSecondary) }
                }
            }
        }
        .sheet(item: Binding(get: { selected.map(IDBox.init) }, set: { selected = $0?.id })) { box in ApplicationDetail(jobID: box.id) }
    }

    private func filter(_ js: [Job]) -> [Job] {
        let q = app.searchText.lowercased()
        return q.isEmpty ? js : js.filter { "\($0.company) \($0.title)".lowercased().contains(q) }
    }
    private func stat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) { Text("\(n)").font(DS.Font.metric); Text(label).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            .frame(minWidth: 84, alignment: .leading)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
            // Solid, not glass: the audit's contrast sampling fails small metric text on translucent material.
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.hairline))
            .accessibilityElement(children: .combine)
    }

    private func column(_ s: JobStatus, _ jobs: [Job]) -> some View {
        BoardColumn(status: s, jobs: jobs, selected: $selected)
    }
}

/// One stage on the board (v4 mockup). Empty stages fold to a thin strip that still takes drops.
private struct BoardColumn: View {
    @Environment(AppModel.self) private var app
    let status: JobStatus
    let jobs: [Job]
    @Binding var selected: String?
    @State private var targeted = false

    private var title: String { status == .rejected ? "Removed" : status.title }

    var body: some View {
        Group {
            if jobs.isEmpty {
                VStack(spacing: DS.Space.s) {
                    Text("0").font(DS.Font.caption.weight(.bold)).monospacedDigit()
                    Text(title).font(DS.Font.caption.weight(.semibold)).fixedSize().rotationEffect(.degrees(90)).frame(width: 16, height: 120)
                    Spacer()
                }
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.vertical, DS.Space.m)
                .frame(width: 36)
                .frame(minHeight: 300, alignment: .top)
                .accessibilityElement(children: .combine)  // .combine keeps a text role; .ignore left it role-less
                .accessibilityLabel("\(title), empty")
                .accessibilityIdentifier("board.folded.\(status.rawValue)")
            } else {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack {
                        Text(title).font(DS.Font.caption.weight(.bold)).foregroundStyle(DS.Palette.textSecondary)
                        Spacer()
                        Text("\(jobs.count)").font(DS.Font.caption.weight(.bold)).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                            .accessibilityLabel("\(jobs.count) applications")
                    }
                    .padding(.horizontal, 4)
                    ForEach(jobs) { j in card(j) }
                    Spacer(minLength: 40)
                }
                .padding(DS.Space.s)
                .frame(width: 210)
                .frame(minHeight: 300, alignment: .top)
            }
        }
        .background(DS.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            .strokeBorder(targeted ? DS.Palette.accent : .clear, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { app.move(id, to: status) }  // illegal moves are refused by the state machine with a message
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
        .dsAnimation(DS.Motion.quick, value: targeted)
    }

    private func card(_ j: Job) -> some View {
        let days = PipelineHints.age(j), stale = PipelineHints.isStale(j), offer = j.status == .offer
        return Button { selected = j.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                if offer {
                    Label("Offer received", systemImage: "checkmark.seal.fill").font(DS.Font.caption.weight(.bold)).foregroundStyle(DS.Palette.offer)
                }
                Text(j.title).font(DS.Font.callout.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Monogram(name: j.company, size: 18)
                    Text("\(j.company) · \(days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s")")").lineLimit(1)
                }
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                if stale { Pill(text: "No reply in \(days) days", symbol: "clock.badge.exclamationmark", tint: DS.Palette.warning) }
                Divider()
                (Text("Next: ").fontWeight(.bold).foregroundColor(DS.Palette.accent) + Text(PipelineHints.nextStep(j))).font(DS.Font.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background {
                // The offer moment: the lane ends in offer green, nothing louder than that.
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(DS.Palette.surface)
                if offer {
                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                        .fill(LinearGradient(colors: [DS.Palette.offer.opacity(0.14), .clear], startPoint: .top, endPoint: .center))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .strokeBorder(offer ? DS.Palette.offer.opacity(0.55) : stale ? DS.Palette.warning.opacity(0.5) : DS.Palette.hairline))
            .dsShadow(DS.Elevation.card)
        }
        .buttonStyle(.plain)
        .draggable(j.id)
        .contextMenu {
            Menu("Move to") {
                ForEach(JobStatus.tracked + [.rejected, .withdrawn], id: \.self) { t in
                    if t != j.status { Button(t.title) { app.move(j.id, to: t) } }
                }
            }
        }
        // Company first: VoiceOver users scan the board by employer.
        .accessibilityLabel("\(j.company), \(j.title), \(status.title), \(days) days" + (stale ? ", no reply, follow up" : ""))
        .accessibilityHint("Open it, or drag it to another column, to change its status")
    }
}

private struct IDBox: Identifiable { let id: String }

/// Notes and the full timeline for one application.
private struct ApplicationDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    @State private var notes = ""
    @State private var j: Job?
    @State private var events: [JobEvent] = []
    @State private var networking = false
    @State private var briefing = false
    @State private var scheduled = false
    @State private var when = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let j {
                Text(j.title).font(.title2.bold())
                HStack {
                    Text("\(j.company) · \(j.location)").foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                    // Keyboard and VoiceOver users change status here (the board itself uses drag-and-drop).
                    Menu("Status: \(j.status.title)") {
                        ForEach(JobStatus.tracked + [.rejected, .withdrawn], id: \.self) { t in
                            if t != j.status { Button(t.title) { app.move(j.id, to: t); Task { await load() } } }
                        }
                    }
                    .fixedSize().accessibilityIdentifier("application.status")
                }
                HStack {
                    if let u = URL.web(j.url) { Link("Open posting", destination: u) }
                    Spacer()
                    Button("Company brief…") { briefing = true }.accessibilityIdentifier("application.brief")
                    Button("Draft outreach…") { networking = true }.accessibilityIdentifier("application.outreach")
                }
                if [.screen, .assessment, .interview].contains(j.status) || scheduled {
                    HStack {
                        Toggle("Interview scheduled", isOn: $scheduled).toggleStyle(.checkbox).accessibilityIdentifier("application.scheduled")
                        if scheduled { DatePicker("When", selection: $when).labelsHidden().accessibilityIdentifier("application.interviewAt") }
                    }
                    .onChange(of: scheduled) { app.saveInterviewAt(jobID, scheduled ? when : nil) }
                    .onChange(of: when) { if scheduled { app.saveInterviewAt(jobID, when) } }
                }
                Text("Notes").font(.headline)
                TextEditor(text: $notes).frame(minHeight: 90).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                Text("Timeline").font(.headline)
                List(events) { e in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Dates.isoSeconds.date(from: e.ts).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? e.ts).font(.caption).foregroundStyle(DS.Palette.textSecondary).frame(width: 130, alignment: .leading)
                        Text(JobStatus(rawValue: e.status)?.title ?? e.status).fontWeight(.medium)
                        Text(e.detail).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                    }
                }
                .frame(minHeight: 160)
            }
            HStack {
                Text("Notes save automatically.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560, height: 560)
        .task { await load() }
        .sheet(isPresented: $networking) { if let j { NetworkingView(job: j) } }
        .sheet(isPresented: $briefing) { if let j { CompanyBriefView(job: j) } }
        // Closing with Esc or Done never loses notes.
        .onDisappear { if j != nil && notes != (j?.notes ?? "") { app.saveNotes(jobID, notes); app.refresh() } }
    }

    private func load() async {
        let store = app.store, id = jobID, firstLoad = j == nil
        let loaded = await Task.detached { (try? store.job(id), (try? store.events(for: id)) ?? []) }.value
        j = loaded.0; events = loaded.1
        if firstLoad {
            notes = j?.notes ?? ""
            if let j, let d = InterviewCalendar.date(j) { when = d; scheduled = true }
        }
    }
}

/// Every search, approval and status change, newest first.
struct ActivityView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let events = app.data.events
        let titles = Dictionary((app.jobs + app.removed).map { ($0.id, "\($0.company) — \($0.title)") }, uniquingKeysWith: { a, _ in a })
        Group {
            if events.isEmpty {
                EmptyState(title: "No activity yet", symbol: "clock.arrow.circlepath", message: "Searches, approvals and status changes will appear here.")
            } else {
                Table(events) {
                    TableColumn("When") { e in Text(Dates.isoSeconds.date(from: e.ts).map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? e.ts) }
                        .width(min: 110, ideal: 130, max: 160)
                    TableColumn("Role") { e in Text(e.jobId == "run" ? "Find Jobs" : titles[e.jobId] ?? e.jobId).lineLimit(1).help(titles[e.jobId] ?? "") }
                        .width(min: 180, ideal: 320)
                    TableColumn("Change") { e in Text(JobStatus(rawValue: e.status)?.title ?? e.status.capitalized) }.width(min: 80, ideal: 110, max: 150)
                    TableColumn("By") { e in Text(e.source) }.width(min: 40, ideal: 55, max: 80)
                    TableColumn("Details") { e in Text(e.detail).lineLimit(2).foregroundStyle(DS.Palette.textSecondary) }.width(min: 120, ideal: 220)
                }
            }
        }
    }
}

/// Reply and interview rates by resume version, source and role type, plus weekly insights. Computed locally, no AI.
struct InsightsView: View {
    @Environment(AppModel.self) private var app
    @State private var report: AnalyticsReport?

    var body: some View {
        Group {
            if let r = report, r.total.sent > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SectionCard(title: "This week", subtitle: "Counted from your applications on this Mac. A reply is any employer response except an automatic receipt.", symbol: "lightbulb") {
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                ForEach(r.insights, id: \.self) { Text($0).accessibilityIdentifier("insights.line") }
                            }
                        }
                        breakdown("By resume version", r.byVersion, symbol: "doc.text")
                        breakdown("By source", r.bySource, symbol: "globe")
                        breakdown("By role type", r.byRole, symbol: "briefcase")
                    }
                    .padding(DS.Space.xl)
                }
            } else {
                EmptyState(title: "No insights yet", symbol: "chart.bar",
                           message: "Reply rates by resume version, source and role type appear after you submit applications.")
            }
        }
        .task(id: app.data.events.first?.id) { report = try? Analytics.report(store: app.store) }
    }

    private func breakdown(_ title: String, _ groups: [AnalyticsGroup], symbol: String) -> some View {
        SectionCard(title: title, subtitle: "Compared only with at least \(Analytics.minSample) applications.", symbol: symbol) {
            Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
                GridRow {
                    ForEach(["Name", "Sent", "Replies", "Reply rate", "Interview rate"], id: \.self) {
                        Text($0).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                ForEach(groups) { g in
                    GridRow {
                        Text(g.name)
                        Text("\(g.sent)").monospacedDigit()
                        Text("\(g.responses)").monospacedDigit()
                        Text("\(g.responseRate)%").monospacedDigit()
                        Text("\(g.interviewRate)%").monospacedDigit()
                    }
                    .foregroundStyle(g.sent < Analytics.minSample ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("insights.row")
                }
            }
        }
    }
}

extension JobEvent: @retroactive Identifiable {}
