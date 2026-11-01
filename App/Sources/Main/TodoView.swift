import SwiftUI
import OfferlaneCore

/// Everything waiting for the user, most urgent first.
struct TodoView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sections: [(String, String, [Job])] = [
            ("Ready to submit", "paperplane", app.jobs(.prefilled)),
            ("Needs you", "hand.raised", app.jobs(.needsYou)),
            ("Account approvals", "person.badge.key", app.jobs(.account)),
            ("Review resumes", "doc.text.magnifyingglass", app.jobs(.review)),
        ]
        let newMatches = app.strongMatches, inProgress = app.jobs(.tailoring, .ready, .applying)
        Group {
            if sections.allSatisfy({ $0.2.isEmpty }) && newMatches.isEmpty && inProgress.isEmpty {
                ContentUnavailableView {
                    Label("You're all caught up", systemImage: "checkmark.circle")
                } description: {
                    Text(app.lastSummary == nil ? "Click Find Jobs to look for new roles." : "Nothing needs you right now. Click Find Jobs to look again.")
                } actions: {
                    Button("Find Jobs") { app.findJobs() }.buttonStyle(.borderedProminent).disabled(app.isFinding || !app.aiConnected)
                }
            } else {
                List {
                    ForEach(sections, id: \.0) { title, symbol, jobs in
                        if !jobs.isEmpty {
                            Section { ForEach(jobs) { PipelineRow(job: $0) } } header: { Label("\(title) · \(jobs.count)", systemImage: symbol) }
                        }
                    }
                    if !newMatches.isEmpty {
                        Section {
                            ForEach(newMatches.prefix(5)) { MatchRow(job: $0) }
                            if newMatches.count > 5 { Button("See all \(newMatches.count) matches") { app.selection = .matches }.buttonStyle(.link) }
                        } header: { Label("New matches · \(newMatches.count)", systemImage: "sparkles") }
                    }
                    if !inProgress.isEmpty {
                        Section { ForEach(inProgress) { PipelineRow(job: $0) } } header: { Label("In progress · \(inProgress.count)", systemImage: "gearshape.2") }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("To Do")
    }
}

/// A role somewhere in the apply pipeline.
struct PipelineRow: View {
    @Environment(AppModel.self) private var app
    let job: Job
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.headline)
                Text("\(job.company) · \(job.status.title)").foregroundStyle(.secondary)
                if !job.error.isEmpty { Text("Tailoring failed: \(job.error)").font(.callout).foregroundStyle(.red) }
                else if job.status == .tailoring { Text(app.tailoringMessage?.contains(job.company) == true ? "Tailoring now…" : "Waiting to be tailored").font(.callout).foregroundStyle(.secondary) }
                else if !job.autofill.isEmpty { Text(job.autofill).font(.callout) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let d = Dates.isoSeconds.date(from: job.updated) ?? Dates.day(job.updated) { Text(d, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary) }
                if job.status == .review { Button("Review") { app.reviewing = job.id }.buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityIdentifier("review.open.\(job.id)") }
                if job.status == .tailoring && !job.error.isEmpty { Button("Retry") { app.retryTailoring(job.id) }.controlSize(.small) }
                if [.prefilled, .needsYou, .account, .applying].contains(job.status) {
                    Button(job.status == .prefilled ? "Open Form" : "Open") { app.apply.show(job.id) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                if job.status == .ready { Button("Start") { app.apply.start(job.id) }.controlSize(.small) }
            }
        }
        .padding(.vertical, 4)
    }
    private var icon: String {
        switch job.status {
        case .prefilled: "paperplane"; case .needsYou: "hand.raised"; case .account: "person.badge.key"; case .review: "doc.text.magnifyingglass"
        case .tailoring: "wand.and.stars"; case .ready, .applying: "safari"; default: "circle"
        }
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let events = (try? app.store.events(limit: 400)) ?? []
        let titles = Dictionary(app.jobs.map { ($0.id, "\($0.company) — \($0.title)") }, uniquingKeysWith: { a, _ in a })
        Group {
            if events.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath", description: Text("Searches, approvals and status changes will appear here."))
            } else {
                Table(events) {
                    TableColumn("When") { e in Text(Dates.isoSeconds.date(from: e.ts).map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? e.ts) }
                        .width(min: 110, ideal: 130, max: 160)
                    TableColumn("Role") { e in Text(e.jobId == "run" ? "Find Jobs" : titles[e.jobId] ?? e.jobId).lineLimit(1).help(titles[e.jobId] ?? "") }
                        .width(min: 180, ideal: 320)
                    TableColumn("Change") { e in Text(JobStatus(rawValue: e.status)?.title ?? e.status.capitalized) }.width(min: 80, ideal: 110, max: 150)
                    TableColumn("By") { e in Text(e.source) }.width(min: 40, ideal: 55, max: 80)
                    TableColumn("Details") { e in Text(e.detail).lineLimit(2).foregroundStyle(.secondary) }.width(min: 120, ideal: 220)
                }
            }
        }
        .navigationTitle("Activity")
    }
}

extension JobEvent: Identifiable {}
