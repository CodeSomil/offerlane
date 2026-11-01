import SwiftUI
import UniformTypeIdentifiers
import OfferlaneCore

struct ResumeStepView: View {
    @Bindable var model: OnboardingModel
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(title: "Add your resumes",
                       subtitle: "Add one or more versions (for example “IC” and “Manager”). Offerlane picks the best one for each role and never invents anything that isn't in them.")
            if model.legacyFolderAvailable && (model.uploads.isEmpty || model.importReport != nil || model.importing) { importCard }
            dropZone
            ForEach(model.uploads) { u in UploadCard(model: model, upload: u) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: OnboardingModel.resumeTypes, allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.add(urls: urls) }
        }
    }

    private var importCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your data from the previous version was found").font(.headline)
                    Text("Import your resume versions, profile, companies and tracked roles from the previous version of the app.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.importing { StatusLine(kind: .working, text: "Importing…") }
                    if let r = model.importReport { StatusLine(kind: .ok, text: r) }
                    if let e = model.importError { StatusLine(kind: .error, text: e) }
                }
                Spacer()
                if model.importReport == nil { Button("Import") { model.importLegacy() }.buttonStyle(.borderedProminent).disabled(model.importing) }
            }.padding(6)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.plus").font(.system(size: 34)).foregroundStyle(Color.accentColor)
            Text("Drop resume files here").font(.headline)
            Text("PDF, Word (.docx), text or LaTeX (.tex) · up to 10 MB").font(.callout).foregroundStyle(.secondary)
            Button("Choose Files…") {
                if let files = model.testFiles { model.add(urls: files) } else { importing = true }
            }
            .accessibilityIdentifier("resumes.choose")
        }
        .frame(maxWidth: .infinity).padding(28)
        .background(RoundedRectangle(cornerRadius: 14).fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in model.add(urls: urls); return !urls.isEmpty } isTargeted: { dropTargeted = $0 }
    }
}

private struct UploadCard: View {
    let model: OnboardingModel
    @Bindable var upload: ResumeUpload
    @State private var expanded = false
    @State private var confirmRemove = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Version name", text: $upload.label)
                            .textFieldStyle(.plain).font(.headline)
                            .onSubmit { model.save(upload) }
                            .accessibilityLabel("Version name for \(upload.filename)")
                        Text(upload.filename).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if upload.version?.isDefault == true {
                        Label("Default", systemImage: "star.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    } else if upload.state == .done {
                        Button("Make Default") { model.makeDefault(upload) }.controlSize(.small)
                    }
                    Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove this resume")
                        .accessibilityLabel("Remove \(upload.label)")
                }
                switch upload.state {
                case .parsing:
                    StatusLine(kind: .working, text: "Reading your resume… this takes up to a minute.")
                        .accessibilityIdentifier("upload.parsing")
                case .failed(let msg):
                    HStack(alignment: .top) {
                        StatusLine(kind: .error, text: msg)
                        Spacer()
                        Button("Retry") { model.parse(upload) }.disabled(upload.data.isEmpty)
                    }
                    .accessibilityIdentifier("upload.error")
                case .done:
                    if let v = upload.version {
                        HStack {
                            StatusLine(kind: .ok, text: summary(v.content))
                                .accessibilityIdentifier("upload.success")
                            Spacer()
                            Button(expanded ? "Hide Details" : "Review Details") { withAnimation { expanded.toggle() } }.controlSize(.small)
                        }
                        if expanded { ParsedResumeEditor(model: model, upload: upload) }
                    }
                }
            }
            .padding(6)
        }
        .confirmationDialog("Remove “\(upload.label)”?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove(upload) }
        } message: { Text("You can add it again later.") }
    }

    private var icon: String {
        switch (upload.filename as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "tex": "function"
        default: "doc.text"
        }
    }
    private func summary(_ c: ResumeContent) -> String {
        let secs = c.sections.filter { !$0.bullets.isEmpty }.count
        return "\(secs) section\(secs == 1 ? "" : "s") · \(c.bulletCount) bullets" + (c.format == "tex" ? " · your LaTeX design is kept" : "")
            + (c.name.isEmpty ? "" : " · \(c.name)")
    }
}

/// Quick edits to the parsed structure: headline, summary, bullet text, removing a stray bullet.
private struct ParsedResumeEditor: View {
    let model: OnboardingModel
    @Bindable var upload: ResumeUpload

    var body: some View {
        if let binding = Binding($upload.version) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Headline") {
                    TextField("Headline", text: binding.content.headline, axis: .vertical).onSubmit { model.save(upload) }
                }
                LabeledContent("Summary") {
                    TextField("Summary", text: binding.content.summary, axis: .vertical).lineLimit(2...6)
                }
                ForEach(binding.content.experience) { $sec in SectionEditor(section: $sec) }
                ForEach(binding.content.projects) { $sec in SectionEditor(section: $sec) }
                HStack { Spacer(); Button("Save Changes") { model.save(upload) }.buttonStyle(.borderedProminent).controlSize(.small) }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 4)
        }
    }
}

private struct SectionEditor: View {
    @Binding var section: ResumeContent.Section
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.heading.isEmpty ? section.id : section.heading).font(.subheadline.weight(.semibold))
                + Text(section.dates.isEmpty ? "" : "  ·  \(section.dates)").font(.caption).foregroundColor(.secondary)
            ForEach($section.bullets) { $b in
                HStack(alignment: .top) {
                    Text("•").foregroundStyle(.secondary)
                    TextField("Bullet", text: $b.text, axis: .vertical)
                    Button { section.bullets.removeAll { $0.id == b.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this bullet")
                        .accessibilityLabel("Remove bullet")
                }
            }
        }
        .padding(.top, 6)
    }
}
