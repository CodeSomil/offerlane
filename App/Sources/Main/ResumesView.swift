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
    /// "PASS" or "FAIL: <problems>" for the rendered preview (text, name and email extractable).
    @State private var ats: String?
    /// The rendered PDF of the selected version, kept so a role change re-checks without re-rendering.
    @State private var pdf: Data?
    @State private var health: ResumeHealth?
    @State private var role = ""
    @State private var roles: [String] = []
    @State private var optimizing = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Resumes", subtitle: app.versions.isEmpty ? "" : "\(app.versions.count) version\(app.versions.count == 1 ? "" : "s") · the starred one is used by default") {
                if let s = selected, app.versions.first(where: { $0.name == s })?.isDefault == false {
                    Button("Make Default") { try? app.store.setDefaultResume(s); app.refresh() }.buttonStyle(.dsSecondary)
                }
                if let s = selected, app.versions.contains(where: { $0.name == s }) {
                    Button("LinkedIn & Portfolio…") { optimizing = true }.buttonStyle(.dsSecondary).accessibilityIdentifier("resumes.profile")
                }
                Button { adding = true } label: { Label("Add or Replace Resumes", systemImage: "plus") }
                    .buttonStyle(.ds(.primary, .large)).keyboardShortcut("n", modifiers: .command)
            }
            split
        }
        .sheet(isPresented: $adding, onDismiss: { app.refresh() }) {
            DSSheet(title: "Add or replace resumes", showsCancel: false, onPrimary: { adding = false }) {
                ScrollView { ResumeStepView(model: app.onboarding).padding(DS.Space.xl) }
            }
            .frame(width: 760, height: 640)
        }
        .sheet(isPresented: $optimizing) {
            if let v = app.versions.first(where: { $0.name == selected }) { ProfileOptimizerView(resume: v.content, role: role) }
        }
        .onAppear {
            roles = SkillPlanner.roles((try? app.store.get(.skillPlan)) ?? SkillPlanState(), app.search)
            if role.isEmpty { role = roles.first ?? "" }
            if selected == nil { selected = app.versions.first(where: \.isDefault)?.name ?? app.versions.first?.name }
        }
        .task(id: selected) { await render() }
        .task(id: role) { await rescore() }
    }

    private var split: some View {
        HSplitView {
            List(app.versions, selection: $selected) { v in
                HStack {
                    Image(systemName: v.content.format == "tex" ? "function" : "doc.text").foregroundStyle(DS.Palette.textSecondary).frame(width: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.label).font(.headline)
                        Text("\(v.content.sections.count) sections · \(v.content.bulletCount) bullets · \(v.content.format == "tex" ? "your LaTeX design" : "standard template")")
                            .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer()
                    if v.isDefault { Image(systemName: "star.fill").foregroundStyle(DS.Palette.warning).accessibilityLabel("Default") }
                }
                .tag(v.name)
                .contextMenu { Button("Make Default") { try? app.store.setDefaultResume(v.name); app.refresh() } }
            }
            .frame(minWidth: 280, idealWidth: 340)
            .accessibilityLabel("Resume versions")
            .overlay {
                if app.versions.isEmpty {
                    EmptyState(title: "No resumes", symbol: "doc.text", message: "Add a PDF, Word, text or LaTeX resume.") {
                        Button("Add Resume") { adding = true }.buttonStyle(.dsPrimary)
                    }
                }
            }
            ZStack {
                PDFPreview(url: preview, version: previewVersion).accessibilityHidden(preview == nil)
                if rendering && preview == nil {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SkeletonBlock(width: 220, height: 18)
                        ForEach(0..<9, id: \.self) { i in SkeletonBlock(width: i % 3 == 2 ? 180 : 300, height: 10) }
                        Spacer()
                    }
                    .padding(DS.Space.xxl).accessibilityLabel("Preparing the preview")
                }
                if let error { StatusLine(kind: .error, text: error).padding() }
                if let ats {
                    Chip(text: ats == "PASS" ? "ATS check passed" : "ATS check failed", symbol: "text.viewfinder", tint: ats == "PASS" ? DS.Palette.offer : DS.Palette.danger)
                        .help(ats == "PASS" ? "Applicant tracking systems can read your name, email and text." : ats)
                        .accessibilityIdentifier("resumes.ats")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(DS.Space.m)
                }
            }
            .frame(minWidth: 320)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview")
            healthPanel.frame(minWidth: 280, idealWidth: 320)
        }
    }

    private var healthPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if !roles.isEmpty {
                    Picker("Role", selection: $role) {
                        Text("No role").tag("")
                        ForEach(roles, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("resumes.role")
                }
                if let h = health {
                    SectionCard(title: "Resume health", subtitle: h.role.map { "For \($0), from \(h.postings) posting\(h.postings == 1 ? "" : "s") you've collected" } ?? "Pick a role to check keywords.", symbol: "heart.text.square") {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("\(h.score)/100").font(.title2.bold()).monospacedDigit()
                                .accessibilityLabel("Health score \(h.score) out of 100").accessibilityIdentifier("resumes.score")
                            ForEach(h.checks) { c in checkRow(c) }
                        }
                    }
                    if !h.readable.isEmpty || !h.missing.isEmpty {
                        SectionCard(title: "Most-asked skills", subtitle: "Add a missing one only if you really have it.", symbol: "text.magnifyingglass") {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                ForEach(h.readable, id: \.self) { Label($0, systemImage: "checkmark.circle").foregroundStyle(DS.Palette.offer) }
                                ForEach(h.missing, id: \.self) { Label($0, systemImage: "circle.dashed").foregroundStyle(DS.Palette.textSecondary) }
                            }
                        }
                    }
                } else if rendering {
                    SkeletonBlock(width: 240, height: 120).accessibilityLabel("Checking the resume")
                }
            }
            .padding(DS.Space.m)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Resume health")
    }

    private func checkRow(_ c: ResumeHealth.Check) -> some View {
        let texts = Dictionary(uniqueKeysWithValues: (app.versions.first { $0.name == selected }?.content.sections.flatMap(\.bullets) ?? []).map { ($0.id, $0.text) })
        return VStack(alignment: .leading, spacing: 2) {
            Label(c.title, systemImage: c.pass ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(c.pass ? DS.Palette.offer : DS.Palette.warning).font(.headline)
            Text(c.detail).font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(c.bulletIds, id: \.self) { id in
                if let t = texts[id] { Text("• " + t).font(.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(2) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("resumes.check")
    }

    /// Structure always; keywords from stored postings for the chosen role (same scan as Skills, no AI call).
    private func rescore() async {
        guard let pdf, let s = selected, let v = app.versions.first(where: { $0.name == s }) else { health = nil; return }
        let store = app.store, want = role
        let h = await Task.detached {
            ResumeHealth.check(v.content, pdf: pdf, scan: want.isEmpty ? nil : MarketScan.scan((try? store.jobs()) ?? [], role: want))
        }.value
        if want == role && s == selected { health = h }   // drop a stale result after a quick switch
    }

    /// The version as it would be sent with no tailoring. Rendered once per version and content, then cached.
    private func render() async {
        guard let s = selected, let v = app.versions.first(where: { $0.name == s }) else { preview = nil; return }
        let key = PreviewCache.key(v)
        if let hit = PreviewCache.shared[key] {
            preview = hit.url; error = hit.note; previewVersion += 1
            pdf = try? Data(contentsOf: hit.url)
            ats = pdf.map { atsHealth($0, v) }; await rescore(); return
        }
        rendering = true; error = nil; preview = nil; ats = nil; health = nil; pdf = nil
        do {
            let store = app.store
            let paper = await Task.detached { (try? store.profile())?.prefs.paper ?? "A4" }.value
            let out = try await Builder.render(v.content, version: v, paper: paper.isEmpty ? "A4" : paper)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("offerlane-preview-\(key).pdf")
            let pdf = out.pdf
            try await Task.detached { try pdf.write(to: url) }.value
            PreviewCache.shared[key] = (url, out.note)
            preview = url; previewVersion += 1; ats = atsHealth(pdf, v)
            if let note = out.note { error = note }
            self.pdf = pdf; await rescore()
        } catch { self.error = "The preview couldn't be made: \(error.plainMessage)" }
        rendering = false
    }

    /// No job here, so no keywords: drop the "(0/0 JD keywords readable)" tail.
    private func atsHealth(_ pdf: Data, _ v: ResumeVersion) -> String {
        let r = Builder.atsCheck(pdf, keywords: [], name: v.content.name).0
        return r.components(separatedBy: " (").first ?? r
    }
}

/// Rendered resume previews, keyed by version name + content, so switching back is instant.
@MainActor
final class PreviewCache {
    static let shared = PreviewCache()
    private var items: [String: (url: URL, note: String?)] = [:]
    subscript(key: String) -> (url: URL, note: String?)? {
        get { items[key].flatMap { FileManager.default.fileExists(atPath: $0.url.path) ? $0 : nil } }
        set { items[key] = newValue }
    }
    static func key(_ v: ResumeVersion) -> String {
        let data = (try? JSONEncoder().encode(v.content)) ?? Data()
        var h: UInt64 = 0xcbf29ce484222325                       // FNV-1a over the content
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "\(v.name)-\(String(h, radix: 16))"
    }
}
