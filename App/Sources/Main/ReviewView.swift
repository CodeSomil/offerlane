import SwiftUI
import PDFKit
import OfferlaneCore

/// Gate 2: review every change to the tailored resume before anything is sent.
@MainActor @Observable
final class ReviewModel {
    let jobID: String
    @ObservationIgnored weak var app: AppModel?
    var job: Job?
    var data: ReviewData?
    var saved: ReviewData?
    var changes: Tailor.Changes?
    var pdfURL: URL?
    var pdfVersion = 0
    var answers = ""
    var editing = false
    var busy = false
    var error: String?

    init(jobID: String, app: AppModel) { self.jobID = jobID; self.app = app; load() }

    var tailor: Tailor? { app.flatMap { a in a.ai.map { Tailor(store: a.store, ai: $0) } } }
    var dirty: Bool { data != saved }

    func load() {
        guard let app, let j = try? app.store.job(jobID), let t = tailor else { return }
        job = j
        data = try? t.review(j); saved = data
        changes = t.changes(j); pdfURL = t.pdfURL(j); pdfVersion += 1
        answers = (try? String(contentsOf: Tailor.dir(j).appendingPathComponent("answers.md"), encoding: .utf8)) ?? ""
    }

    func rebuild() {
        guard let t = tailor, let d = data else { return }
        busy = true; error = nil
        Task {
            do { _ = try await t.rebuild(jobID, edit: d); editing = false; load() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    func saveAnswers() {
        guard let j = job else { return }
        try? answers.write(to: Tailor.dir(j).appendingPathComponent("answers.md"), atomically: true, encoding: .utf8)
    }
    func approve() {
        guard let app else { return }
        saveAnswers()
        do {
            try app.store.transition(jobID, to: .ready, by: "you", detail: "approved resume")
            app.refresh(); app.reviewing = nil
            app.toast = Toast(message: "Resume approved. The Apply window will open it next.")
            app.apply.next()
        } catch { self.error = error.localizedDescription }
    }
    func redo(note: String?, quick: Bool) {
        guard let app, let t = tailor else { return }
        do { try t.requeue(jobID, note: note, quick: quick); app.refresh(); app.kickTailoring(); app.reviewing = nil
             app.toast = Toast(message: quick ? "Using your resume as-is. It'll be back for review in a moment." : "Re-tailoring with your note.") }
        catch { self.error = error.localizedDescription }
    }
    func decline() { app?.decline([jobID]); app?.reviewing = nil }

    // Edit helpers
    func move(_ g: String, from: IndexSet, to: Int) { if let i = data?.groups.firstIndex(where: { $0.g == g }) { data!.groups[i].bullets.move(fromOffsets: from, toOffset: to) } }
    func restore(_ g: String, _ id: String) {
        guard let i = data?.groups.firstIndex(where: { $0.g == g }), let k = data!.groups[i].bullets.firstIndex(where: { $0.id == id }) else { return }
        data!.groups[i].bullets[k].text = data!.groups[i].bullets[k].original
    }
    func remove(_ g: String, _ id: String) {
        guard let i = data?.groups.firstIndex(where: { $0.g == g }), let b = data!.groups[i].bullets.first(where: { $0.id == id }) else { return }
        data!.groups[i].bullets.removeAll { $0.id == id }
        data!.unused.append(.init(id: b.id, text: b.original, group: g))
    }
    func add(_ u: ReviewData.Unused) {
        guard let i = data?.groups.firstIndex(where: { $0.g == u.group }) else { return }
        data!.groups[i].bullets.append(.init(id: u.id, text: u.text, original: u.text)); data!.unused.removeAll { $0.id == u.id }
    }
}

struct ReviewView: View {
    @Environment(AppModel.self) private var app
    @State var model: ReviewModel
    @State private var redoNote = ""
    @State private var showRedo = false
    @State private var confirmDecline = false

    var body: some View {
        HSplitView {
            ScrollView { content.padding(20) }
                .frame(minWidth: 360, idealWidth: 520)
            PDFPreview(url: model.pdfURL, version: model.pdfVersion)
                .frame(minWidth: 260, idealWidth: 380)
                .accessibilityLabel("Tailored resume preview")
        }
        .navigationTitle(model.job.map { "Review · \($0.company)" } ?? "Review")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.editing {
                    Button("Cancel") { model.data = model.saved; model.editing = false }
                    Button("Rebuild PDF") { model.rebuild() }.buttonStyle(.borderedProminent).disabled(model.busy).keyboardShortcut("s")
                } else {
                    Button("Edit") { model.editing = true }.accessibilityIdentifier("review.edit")
                    Button("Redo with Note…") { showRedo = true }
                        .popover(isPresented: $showRedo) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("What should change?").font(.headline)
                                TextField("e.g. lead with forecasting, mention stakeholder work", text: $redoNote, axis: .vertical).lineLimit(2...4).frame(width: 320)
                                HStack { Spacer(); Button("Redo") { showRedo = false; model.redo(note: redoNote, quick: false) }.buttonStyle(.borderedProminent).disabled(redoNote.isEmpty) }
                            }.padding()
                        }
                    Menu("More") {
                        Button("Use My Resume As-Is") { model.redo(note: nil, quick: true) }
                        if let u = model.pdfURL { Button("Show PDF in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                        Divider()
                        Button("Decline This Role…", role: .destructive) { confirmDecline = true }
                    }
                    Button { model.approve() } label: { Label("Approve & Apply", systemImage: "checkmark.seal").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("review.approve")
                }
            }
        }
        .confirmationDialog("Decline this role?", isPresented: $confirmDecline) {
            Button("Decline", role: .destructive) { model.decline() }
        } message: { Text("It will be hidden and won't come back in later searches.") }
        .overlay { if model.busy { ProgressView("Rebuilding your PDF…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    @ViewBuilder private var content: some View {
        if let j = model.job, let d = model.data {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(j.title).font(.title2.bold())
                    Text("\(j.company) · \(j.location)").foregroundStyle(.secondary)
                    if !j.changesSummary.isEmpty { Text(j.changesSummary).font(.callout).padding(.top, 2) }
                }
                checks(d)
                if let e = model.error { StatusLine(kind: .error, text: e) }
                headlineSummary(d)
                ForEach(d.groups) { g in GroupDiff(model: model, group: g) }
                if !d.unused.isEmpty {
                    DisclosureGroup("Left out · \(d.unused.count) bullet\(d.unused.count == 1 ? "" : "s")") {
                        ForEach(d.unused) { u in
                            HStack(alignment: .top) {
                                Text(u.text).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                if model.editing { Button("Add") { model.add(u) }.controlSize(.small) }
                            }.padding(.vertical, 2)
                        }
                    }
                }
                GroupBox("Cover letter and answers") {
                    TextEditor(text: $model.answers).font(.callout).frame(minHeight: 180).scrollContentBackground(.hidden)
                        .onChange(of: model.answers) { model.saveAnswers() }
                        .accessibilityLabel("Cover letter and answers")
                }
            }
        } else {
            ContentUnavailableView("Nothing to review", systemImage: "doc.text", description: Text("This role hasn't been tailored yet."))
        }
    }

    private func checks(_ d: ReviewData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let c = model.changes {
                    Chip(text: "\(c.pages) page\(c.pages == 1 ? "" : "s")", symbol: "doc")
                    Chip(text: c.ats.hasPrefix("PASS") ? "ATS check passed" : "ATS check failed", symbol: "text.viewfinder", tint: c.ats.hasPrefix("PASS") ? .green : .red)
                        .help(c.ats)
                }
                let rejected = d.warnings.filter { $0.contains("REJECTED") }.count
                if rejected > 0 { Chip(text: "\(rejected) invented claim\(rejected == 1 ? "" : "s") blocked", symbol: "shield.lefthalf.filled", tint: .orange) }
            }
            if let note = model.changes?.note { StatusLine(kind: .info, text: note) }
            if let missing = model.changes?.missingKeywords, !missing.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Not in your resume (add only if true):").font(.callout).foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) { ForEach(missing, id: \.self) { Chip(text: $0) } }
                }
            }
            ForEach(d.warnings, id: \.self) { w in
                Label(w, systemImage: w.contains("REJECTED") ? "xmark.shield" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(w.contains("REJECTED") ? Color.orange : Color.secondary)
            }
        }
    }

    @ViewBuilder private func headlineSummary(_ d: ReviewData) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if model.editing {
                    TextField("Headline", text: Binding(get: { model.data?.headline ?? "" }, set: { model.data?.headline = $0 }), axis: .vertical)
                    TextField("Summary", text: Binding(get: { model.data?.summary ?? "" }, set: { model.data?.summary = $0 }), axis: .vertical).lineLimit(2...6)
                } else {
                    DiffText(original: d.headlineOriginal, text: d.headline).font(.headline)
                    if !d.summary.isEmpty || !d.summaryOriginal.isEmpty { DiffText(original: d.summaryOriginal, text: d.summary) }
                }
            }.textFieldStyle(.roundedBorder).padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Original struck through in red, new text in green; unchanged text plain.
struct DiffText: View {
    let original: String, text: String
    var body: some View {
        if original == text || original.isEmpty { Text(text) }
        else {
            VStack(alignment: .leading, spacing: 3) {
                Text(original).strikethrough().foregroundStyle(.red.opacity(0.85)).accessibilityLabel("Original: \(original)")
                Text(text).foregroundStyle(.green).accessibilityLabel("Tailored: \(text)")
            }
        }
    }
}

private struct GroupDiff: View {
    let model: ReviewModel
    let group: ReviewData.Group
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title).font(.headline)
            if model.editing {
                List {
                    ForEach(group.bullets) { b in
                        HStack(alignment: .top) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            TextField("Bullet", text: binding(b.id), axis: .vertical).textFieldStyle(.plain)
                            if b.text != b.original { Button { model.restore(group.g, b.id) } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).help("Restore original") }
                            Button { model.remove(group.g, b.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Leave out")
                        }
                    }
                    .onMove { model.move(group.g, from: $0, to: $1) }
                }
                .frame(minHeight: CGFloat(group.bullets.count) * 52)
                .scrollDisabled(true)
            } else {
                ForEach(group.bullets) { b in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        DiffText(original: b.original, text: b.text)
                        Spacer(minLength: 0)
                        if group.moved.contains(b.id) { Chip(text: "moved", symbol: "arrow.up.arrow.down") }
                    }
                }
            }
        }
    }
    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { model.data?.groups.first { $0.g == group.g }?.bullets.first { $0.id == id }?.text ?? "" },
                set: { v in
                    guard let i = model.data?.groups.firstIndex(where: { $0.g == group.g }), let k = model.data!.groups[i].bullets.firstIndex(where: { $0.id == id }) else { return }
                    model.data!.groups[i].bullets[k].text = v
                })
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL?
    let version: Int
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.backgroundColor = .windowBackgroundColor; return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if context.coordinator.version != version { context.coordinator.version = version; v.document = url.flatMap { PDFDocument(url: $0) } }
        // Re-fit whenever the split view resizes the preview.
        v.autoScales = false; v.autoScales = true
    }
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var version = -1 }
}
