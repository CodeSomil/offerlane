import SwiftUI
import OfferlaneCore

/// Resume versions: set the default, add more, preview what gets sent.
struct ResumesView: View {
    @Environment(AppModel.self) private var app
    @State private var selected: String?
    @State private var adding = false
    @State private var preview: URL?
    @State private var previewVersion = 0
    @State private var rendering = false
    @State private var error: String?

    var body: some View {
        HSplitView {
            List(app.versions, selection: $selected) { v in
                HStack {
                    Image(systemName: v.content.format == "tex" ? "function" : "doc.text").foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.label).font(.headline)
                        Text("\(v.content.sections.count) sections · \(v.content.bulletCount) bullets · \(v.content.format == "tex" ? "your LaTeX design" : "standard template")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if v.isDefault { Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("Default") }
                }
                .tag(v.name)
                .contextMenu { Button("Make Default") { try? app.store.setDefaultResume(v.name); app.refresh() } }
            }
            .frame(minWidth: 280, idealWidth: 340)
            .overlay { if app.versions.isEmpty { ContentUnavailableView("No resumes", systemImage: "doc.text", description: Text("Add a PDF, Word, text or LaTeX resume.")) } }
            ZStack {
                PDFPreview(url: preview, version: previewVersion)
                if rendering { ProgressView("Rendering…") }
                if let error { StatusLine(kind: .error, text: error).padding() }
            }
            .frame(minWidth: 320)
        }
        .navigationTitle("Resumes")
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                if let s = selected, app.versions.first(where: { $0.name == s })?.isDefault == false {
                    Button("Make Default") { try? app.store.setDefaultResume(s); app.refresh() }
                }
                Button { adding = true } label: { Label("Add or Replace Resumes", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding, onDismiss: { app.refresh() }) {
            VStack(spacing: 0) {
                ScrollView { ResumeStepView(model: app.onboarding).padding(24) }
                Divider()
                HStack { Spacer(); Button("Done") { adding = false }.keyboardShortcut(.defaultAction) }.padding(12)
            }
            .frame(width: 760, height: 640)
        }
        .onAppear { if selected == nil { selected = app.versions.first(where: \.isDefault)?.name ?? app.versions.first?.name } }
        .task(id: selected) { await render() }
    }

    /// The version as it would be sent with no tailoring.
    private func render() async {
        guard let s = selected, let v = app.versions.first(where: { $0.name == s }) else { preview = nil; return }
        rendering = true; error = nil
        do {
            let paper = (try? app.store.profile())?.prefs.paper ?? "A4"
            let out = try await Builder.render(v.content, version: v, paper: paper.isEmpty ? "A4" : paper)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("offerlane-preview-\(v.name).pdf")
            try out.pdf.write(to: url); preview = url; previewVersion += 1
            if let note = out.note { error = note }
        } catch { self.error = error.localizedDescription }
        rendering = false
    }
}
