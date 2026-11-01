import SwiftUI
import OfferlaneCore

struct AboutStepView: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        let e = model.profile.validationErrors
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "About you", subtitle: "Used to fill application forms. We filled in what we could from your resume — check it and add the rest.")
            GroupBox("Contact") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    FieldRow(label: "First name", text: $model.profile.personal.firstName, error: e["firstName"])
                    FieldRow(label: "Last name", text: $model.profile.personal.lastName, error: e["lastName"])
                    FieldRow(label: "Email", text: $model.profile.personal.email, prompt: "you@example.com", error: e["email"])
                    FieldRow(label: "Phone", text: $model.profile.personal.phone, prompt: "+44 7700 900000", error: e["phone"])
                    FieldRow(label: "Street address", text: $model.profile.personal.address)
                    FieldRow(label: "City", text: $model.profile.personal.city)
                    FieldRow(label: "State / region", text: $model.profile.personal.state)
                    FieldRow(label: "Postal code", text: $model.profile.personal.postalCode)
                    FieldRow(label: "Country", text: $model.profile.personal.country)
                    FieldRow(label: "LinkedIn", text: $model.profile.personal.linkedin, prompt: "https://linkedin.com/in/…")
                    FieldRow(label: "GitHub", text: $model.profile.personal.github)
                    FieldRow(label: "Portfolio", text: $model.profile.personal.portfolio)
                }.padding(8)
            }
            GroupBox("Work") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    FieldRow(label: "Current employer", text: $model.profile.work.currentCompany)
                    FieldRow(label: "Current title", text: $model.profile.work.currentTitle)
                    FieldRow(label: "Years of experience", text: $model.profile.work.yearsExperience, error: e["years"])
                    FieldRow(label: "Notice period", text: $model.profile.work.noticePeriod, prompt: "e.g. 2 months")
                    FieldRow(label: "Current pay", text: $model.profile.work.currentSalary, prompt: "Only used if a form asks")
                    FieldRow(label: "Expected pay", text: $model.profile.work.expectedSalary)
                    FieldRow(label: "Degree", text: $model.profile.education.degree)
                    FieldRow(label: "School", text: $model.profile.education.school)
                    FieldRow(label: "Graduation year", text: $model.profile.education.graduationYear)
                }.padding(8)
            }
            GroupBox("Work authorization") {
                VStack(alignment: .leading, spacing: 10) {
                    ChipsField(title: "Countries where you can work without sponsorship", items: $model.profile.authorization.authorizedCountries,
                               prompt: "e.g. India, UK") { raw in
                        let c = Visa.canon(raw); return c.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
                    }
                    if let err = e["countries"] { Text(err).font(.caption).foregroundStyle(.red) }
                    Toggle("I need visa sponsorship to work anywhere else", isOn: $model.profile.authorization.needsSponsorship)
                    Grid(alignment: .leading, horizontalSpacing: 12) { FieldRow(label: "Citizenship", text: $model.profile.authorization.citizenship) }
                }.padding(8)
            }
            GroupBox("Preferences") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Willing to relocate", isOn: $model.profile.work.willingToRelocate)
                    Toggle("Open to remote work", isOn: $model.profile.work.openToRemote)
                    Picker("Resume paper size", selection: $model.profile.prefs.paper) { Text("A4").tag("A4"); Text("US Letter").tag("Letter") }
                        .pickerStyle(.segmented).frame(maxWidth: 320)
                    Text("Deal-breakers").font(.subheadline.weight(.semibold))
                    TextField("e.g. no relocation to the US, minimum pay, no agencies", text: $model.profile.prefs.dealbreakers, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                }.padding(8)
            }
            GroupBox("Standard answers") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    FieldRow(label: "How did you hear about us?", text: $model.profile.misc.howHeard)
                    FieldRow(label: "Earliest start date", text: $model.profile.misc.startDate, prompt: "e.g. 2 months after an offer")
                    FieldRow(label: "Pronouns (optional)", text: $model.profile.misc.pronouns)
                }.padding(8)
            }
            DisclosureGroup("Equal-opportunity questions (optional)") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    FieldRow(label: "Gender", text: $model.profile.eeo.gender)
                    FieldRow(label: "Race / ethnicity", text: $model.profile.eeo.race)
                    FieldRow(label: "Veteran status", text: $model.profile.eeo.veteran)
                    FieldRow(label: "Disability", text: $model.profile.eeo.disability)
                    FieldRow(label: "Sexual orientation", text: $model.profile.eeo.sexualOrientation)
                }.padding(.top, 8)
                Text("Every answer defaults to “Decline to self-identify”.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
