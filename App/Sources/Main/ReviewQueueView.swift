import SwiftUI
import OfferlaneCore

/// Review: everything waiting on the user, most urgent first, plus what's in progress.
struct ReviewQueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sections: [(String, String, [Job])] = [
            ("Ready to submit", "paperplane", app.jobs(.prefilled)),
            ("Needs you", "hand.raised", app.jobs(.needsYou)),
            ("Account approvals", "person.badge.key", app.jobs(.account)),
            ("Review resumes", "doc.text.magnifyingglass", app.jobs(.review)),
        ].map { ($0.0, $0.1, filter($0.2)) }
        let inProgress = filter(app.jobs(.tailoring, .ready, .applying))
        VStack(spacing: 0) {
            ScreenHeader(title: "Review", subtitle: app.reviewCount == 0 ? "" : "\(app.reviewCount) waiting for you") { EmptyView() }
            if sections.allSatisfy({ $0.2.isEmpty }) && inProgress.isEmpty {
                EmptyState(title: "You're all caught up", symbol: "checkmark.circle",
                           message: app.strongMatches.isEmpty ? "Nothing needs you right now. Approve roles on \(SidebarItem.find.title) and they'll come here for your review."
                                                              : "Nothing needs you right now. \(app.strongMatches.count) new match\(app.strongMatches.count == 1 ? " is" : "es are") waiting on Find.") {
                    Button { app.navigate(to: .find) } label: { Label("Go to \(SidebarItem.find.title)", systemImage: "sparkle.magnifyingglass") }
                        .buttonStyle(.ds(.primary, .large))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.l) {
                        ForEach(sections + [("In progress", "gearshape.2", inProgress)], id: \.0) { title, symbol, jobs in
                            if !jobs.isEmpty {
                                SectionCard(title: "\(title) · \(jobs.count)", symbol: symbol) {
                                    VStack(spacing: DS.Space.s) {
                                        ForEach(jobs) { job in
                                            if job.id != jobs.first?.id { Divider() }
                                            PipelineRow(job: job)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.l)
                }
            }
        }
    }

    private func filter(_ js: [Job]) -> [Job] {
        let q = app.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? js : js.filter { "\($0.title) \($0.company)".lowercased().contains(q) }
    }
}

/// A role somewhere in the apply pipeline.
struct PipelineRow: View {
    @Environment(AppModel.self) private var app
    let job: Job
    @State private var handoff = false
    var body: some View {
        row.sheet(isPresented: $handoff) { ClaudeHandoffSheet(app: app, job: job) }
    }
    private var row: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(tint.opacity(0.12))
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
            }
            .frame(width: 40, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(DS.Font.headline)
                Text("\(job.company) · \(job.status.title)").foregroundStyle(DS.Palette.textSecondary)
                if !job.error.isEmpty { Text("Tailoring didn't finish: \(job.error)").font(DS.Font.callout).foregroundStyle(DS.Palette.danger) }
                else if job.status == .tailoring { Text(app.tailoringMessage?.contains(job.company) == true ? "Tailoring now…" : "Waiting to be tailored").font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary) }
                else if !job.autofill.isEmpty { Text(job.autofill).font(DS.Font.callout) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let d = Dates.isoSeconds.date(from: job.updated) ?? Dates.day(job.updated) { Text(d, format: .relative(presentation: .named)).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                if job.status == .review {
                    Button("Review") { withDSAnimation { app.reviewing = job.id } }.buttonStyle(.ds(.primary, .small))
                        .accessibilityIdentifier("review.open.\(job.id)")
                }
                if job.status == .tailoring && !job.error.isEmpty { Button("Try Again") { app.retryTailoring(job.id) }.buttonStyle(.ds(.secondary, .small)) }
                if job.status == .tailoring {
                    Button("Use Claude…") { handoff = true }.buttonStyle(.ds(.secondary, .small)).accessibilityIdentifier("handoff.open.\(job.id)")
                }
                if [.prefilled, .needsYou, .account, .applying].contains(job.status) {
                    Button(job.status == .prefilled ? "Open Form" : "Open") { app.apply.show(job.id) }.buttonStyle(.ds(.primary, .small))
                }
                if job.status == .ready { Button("Start") { app.apply.start(job.id) }.buttonStyle(.ds(.secondary, .small)) }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
    private var icon: String {
        switch job.status {
        case .prefilled: "paperplane"; case .needsYou: "hand.raised"; case .account: "person.badge.key"; case .review: "doc.text.magnifyingglass"
        case .tailoring: "wand.and.stars"; case .ready, .applying: "safari"; default: "circle"
        }
    }
    private var tint: Color {
        switch job.status {
        case .prefilled: DS.Palette.offer; case .needsYou, .account: DS.Palette.warning; case .review: DS.Palette.accent
        default: .secondary
        }
    }
}
