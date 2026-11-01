import SwiftUI
import UniformTypeIdentifiers
import OfferlaneCore

/// Submitted applications: a Kanban board (drag to change status) and a table, with notes and a timeline.
struct ApplicationsView: View {
    @Environment(AppModel.self) private var app
    @State private var mode = 0
    @State private var showRemoved = false
    @State private var selected: String?

    var body: some View {
        let tracked = filter(app.allTracked), removed = app.removed
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                stat("Applied", tracked.count)
                stat("Interviewing", tracked.filter { [.screen, .assessment, .interview].contains($0.status) }.count)
                stat("Offers", tracked.filter { $0.status == .offer }.count)
                stat("Removed", removed.count)
                Spacer()
                Toggle("Show removed", isOn: $showRemoved).toggleStyle(.checkbox).accessibilityIdentifier("applications.showRemoved")
                Picker("View", selection: $mode) { Text("Board").tag(0); Text("Table").tag(1) }.pickerStyle(.segmented).frame(width: 160).labelsHidden()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if tracked.isEmpty && !(showRemoved && !removed.isEmpty) {
                ContentUnavailableView("No applications yet", systemImage: "rectangle.split.3x1",
                                       description: Text("Roles you submit appear here. Replies from employers update them automatically when email tracking is on."))
            } else if mode == 0 {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
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
                    TableColumn("Notes") { Text($0.notes).lineLimit(1).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Applications")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button { app.checkInbox() } label: { Label("Check Inbox", systemImage: "envelope.badge") }.disabled(app.checkingInbox)
            }
        }
        .sheet(item: Binding(get: { selected.map(IDBox.init) }, set: { selected = $0?.id })) { box in ApplicationDetail(jobID: box.id) }
    }

    private func filter(_ js: [Job]) -> [Job] {
        let q = app.searchText.lowercased()
        return q.isEmpty ? js : js.filter { "\($0.company) \($0.title)".lowercased().contains(q) }
    }
    private func stat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) { Text("\(n)").font(.title2.bold()).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) }
            .accessibilityElement(children: .combine)
    }

    private func column(_ s: JobStatus, _ jobs: [Job]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(s == .rejected ? "Removed" : s.title).font(.headline); Spacer(); Text("\(jobs.count)").foregroundStyle(.secondary) }
            ForEach(jobs) { j in
                Button { selected = j.id } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(j.company).font(.subheadline.weight(.semibold))
                        Text(j.title).font(.callout).lineLimit(2)
                        if let d = Dates.isoSeconds.date(from: j.updated) ?? Dates.day(j.updated) { Text(d, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
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
                .accessibilityHint("Drag to another column to change its status")
            }
            Spacer(minLength: 40)
        }
        .padding(10)
        .frame(width: 180)
        .frame(minHeight: 300, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { app.move(id, to: s) }
            return !ids.isEmpty
        }
    }
}

private struct IDBox: Identifiable { let id: String }

/// Notes and the full timeline for one application.
private struct ApplicationDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    @State private var notes = ""

    var body: some View {
        let j = try? app.store.job(jobID), events = (try? app.store.events(for: jobID)) ?? []
        VStack(alignment: .leading, spacing: 14) {
            if let j {
                Text(j.title).font(.title2.bold())
                Text("\(j.company) · \(j.location) · \(j.status.title)").foregroundStyle(.secondary)
                if let u = URL(string: j.url), !j.url.isEmpty { Link("Open posting", destination: u) }
                Text("Notes").font(.headline)
                TextEditor(text: $notes).frame(minHeight: 90).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                Text("Timeline").font(.headline)
                List(events) { e in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Dates.isoSeconds.date(from: e.ts).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? e.ts).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text(JobStatus(rawValue: e.status)?.title ?? e.status).fontWeight(.medium)
                        Text(e.detail).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(minHeight: 160)
            }
            HStack { Spacer(); Button("Done") { app.saveNotes(jobID, notes); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 560, height: 560)
        .onAppear { notes = j?.notes ?? "" }
    }
}
