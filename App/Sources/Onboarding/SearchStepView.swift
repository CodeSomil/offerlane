import SwiftUI
import OfferlaneCore

struct SearchStepView: View {
    @Bindable var model: OnboardingModel
    @State private var companyInput = ""
    @State private var companyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "What to look for", subtitle: "The AI drafted a search from your resume. Edit anything: titles are matched against posting titles, and Offerlane checks each company's own career site.")
            if model.drafting {
                HStack { StatusLine(kind: .working, text: "Drafting titles and 40–60 companies from your resume…"); Spacer(); Button("Cancel") { model.cancelLongTask(); model.drafting = false } }
            } else if let e = model.draftError {
                HStack { StatusLine(kind: .error, text: e); Spacer(); Button("Try Again") { model.draftSearch() } }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    ChipsField(title: "Target titles", items: $model.search.targetTitles, prompt: "e.g. Senior Data Scientist")
                    ChipsField(title: "Locations", items: $model.search.locations, prompt: "e.g. London, Bengaluru")
                    Toggle("Include remote roles", isOn: $model.search.remoteOk)
                    ChipsField(title: "Title must include one of", items: $model.search.titleInclude, prompt: "phrase, or re:regex")
                    ChipsField(title: "Skip titles containing", items: $model.search.titleExclude, prompt: "e.g. intern")
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Companies").font(.subheadline.weight(.semibold))
                        Text("\(model.search.companies.count)").foregroundStyle(.secondary)
                        Spacer()
                        if !model.drafting { Button("Suggest Again") { model.draftSearch() }.controlSize(.small) }
                    }
                    HStack {
                        TextField("Add a company by name, or paste its careers page URL", text: $companyInput)
                            .textFieldStyle(.roundedBorder).onSubmit(addCompany)
                            .accessibilityLabel("Add company")
                        Button("Add", action: addCompany).disabled(companyInput.isEmpty)
                    }
                    if let companyError { Text(companyError).font(.caption).foregroundStyle(.red) }
                    FlowLayout(spacing: 6) {
                        ForEach(model.search.companies) { c in
                            HStack(spacing: 6) {
                                Text(c.name).lineLimit(1)
                                if let ats = c.workday != nil ? "Workday" : c.ats?.capitalized {
                                    Text(ats).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                }
                                Button { model.search.companies.removeAll { $0.name == c.name } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Remove \(c.name)")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                        }
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
                    Text("Weaker matches are still kept under “Show weaker matches”.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
        }
    }

    private func addCompany() {
        companyError = model.addCompany(companyInput)
        if companyError == nil { companyInput = "" }
    }
}
