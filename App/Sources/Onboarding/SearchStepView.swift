import SwiftUI
import OfferlaneCore

struct SearchStepView: View {
    @Bindable var model: OnboardingModel
    @State private var companyInput = ""
    @State private var companyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "What to look for", subtitle: "The AI drafted a search from your resume. Edit anything: titles are matched against posting titles. Offerlane searches free job sites and every company career site it has learned about; your watchlist ranks higher.")
            if model.drafting {
                HStack { StatusLine(kind: .working, text: "Drafting titles and a company watchlist from your resume…"); Spacer(); Button("Cancel") { model.cancelLongTask(); model.drafting = false } }
            } else if let e = model.draftError {
                HStack { StatusLine(kind: .error, text: e); Spacer(); Button("Try Again") { model.draftSearch() } }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    ChipsField(title: "Target titles", items: $model.search.targetTitles, prompt: "e.g. Senior Data Scientist")
                    ChipsField(title: "Reaching for (stretch roles)", items: $model.search.aspirations, prompt: "e.g. Head of AI")
                    ChipsField(title: "Locations", items: $model.search.locations, prompt: "e.g. London, Bengaluru")
                    Toggle("Include remote roles", isOn: $model.search.remoteOk)
                    ChipsField(title: "Title must include one of", items: $model.search.titleInclude, prompt: "phrase, or re:regex")
                    ChipsField(title: "Skip titles containing", items: $model.search.titleExclude, prompt: "e.g. intern")
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Watchlist").font(.subheadline.weight(.semibold))
                        Text("\(model.search.companies.count)").foregroundStyle(DS.Palette.textSecondary)
                        Spacer()
                        if !model.drafting { Button("Suggest Again") { model.draftSearch() }.controlSize(.small) }
                    }
                    HStack {
                        TextField("Add a company by name, or paste its careers page URL", text: $companyInput)
                            .textFieldStyle(.roundedBorder).onSubmit(addCompany)
                            .accessibilityLabel("Add company")
                        Button("Add", action: addCompany).disabled(companyInput.isEmpty)
                    }
                    Text("Companies you'd especially like to work for. Their roles rank higher; other companies still show up.")
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    if let companyError { Text(companyError).font(.caption).foregroundStyle(DS.Palette.danger) }
                    FlowLayout(spacing: 6) {
                        ForEach(model.search.companies) { c in
                            HStack(spacing: 6) {
                                Text(c.name).lineLimit(1)
                                if let ats = c.workday != nil ? "Workday" : c.ats?.capitalized {
                                    Text(ats).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                }
                                Button { model.search.companies.removeAll { $0.name == c.name } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(DS.Palette.textSecondary).accessibilityLabel("Remove \(c.name)")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Job sources").font(.subheadline.weight(.semibold))
                    Text("Company career sites (your watchlist and boards found along the way) are always checked.")
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    ForEach(JobSources.all, id: \.id) { src in
                        Toggle(isOn: Binding(get: { model.search.sources[src.id] ?? src.defaultOn }, set: { model.search.sources[src.id] = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(src.name)
                                Text(src.terms).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                            }
                        }
                        .accessibilityIdentifier("source.\(src.id)")
                        if src.id == "adzuna", model.search.sources["adzuna"] == true { adzunaSetup }
                    }
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Show roles scoring at least")
                        Slider(value: Binding(get: { Double(model.search.minScore) }, set: { model.search.minScore = Int($0) }), in: 40...90, step: 5)
                            .frame(maxWidth: 240).accessibilityLabel("Score threshold")
                        Text("\(model.search.minScore)").monospacedDigit().frame(width: 28)
                    }
                    Stepper("Ignore postings older than \(model.search.maxAgeDays) days", value: $model.search.maxAgeDays, in: 3...90, step: 1)
                    Text("Weaker matches are still kept under “Show weaker matches”.").font(.caption).foregroundStyle(DS.Palette.textSecondary)
                }.padding(8)
            }
        }
    }

    /// Adzuna needs the user's own free key; it's kept in the Keychain and sent only to Adzuna.
    private var adzunaSetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("App ID", text: $model.adzunaId).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                    .accessibilityIdentifier("adzuna.appId")
                SecureField("App key", text: $model.adzunaKey).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .accessibilityIdentifier("adzuna.appKey")
                Picker("Country", selection: Binding(get: { Adzuna.country(model.search.adzunaCountry) }, set: { model.search.adzunaCountry = $0 })) {
                    ForEach(Adzuna.countries, id: \.self) { c in Text(Locale.current.localizedString(forRegionCode: c) ?? c.uppercased()).tag(c) }
                }.frame(maxWidth: 200).accessibilityIdentifier("adzuna.country")
            }
            .onSubmit { model.saveAdzuna() }
            HStack(spacing: 4) {
                Text("Your key stays in this Mac's Keychain. Your search terms go to Adzuna.")
                Link("Get a free key", destination: Adzuna.signUp)
            }.font(.caption).foregroundStyle(DS.Palette.textSecondary)
            if let e = model.adzunaError { Text(e).font(.caption).foregroundStyle(DS.Palette.danger).accessibilityIdentifier("adzuna.error") }
            if model.adzunaId.isEmpty || model.adzunaKey.isEmpty {
                Text("Adzuna is skipped until both the app ID and key are filled in.").font(.caption).foregroundStyle(DS.Palette.warning)
                    .accessibilityIdentifier("adzuna.missing")
            }
        }
        .padding(.leading, 20)
    }

    private func addCompany() {
        companyError = model.addCompany(companyInput)
        if companyError == nil { companyInput = "" }
    }
}
