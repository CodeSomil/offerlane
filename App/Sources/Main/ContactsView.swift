import SwiftUI
import OfferlaneCore

/// Pipeline → People: contacts and referrals the user enters, with follow-up dates that remind once. Nothing is sent from here.
struct ContactsView: View {
    @Environment(AppModel.self) private var app
    @State private var contacts: [Contact] = []
    @State private var editing: Contact?
    @State private var removing: Contact?

    var body: some View {
        let due = Set(Contacts.due(contacts).map(\.id))
        ScrollView {
            SectionCard(title: "People", subtitle: "Recruiters, referrers and hiring managers you add. Stored only on this Mac; Offerlane never contacts them.", symbol: "person.2") {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    if contacts.isEmpty { Text("No contacts yet. Add someone you're talking to and when to follow up.").foregroundStyle(DS.Palette.textSecondary) }
                    ForEach(contacts.sorted { ($0.followUp ?? "9") < ($1.followUp ?? "9") }) { row($0, due: due.contains($0.id)) }
                    Button { editing = Contact(name: "") } label: { Label("Add contact", systemImage: "plus") }
                        .buttonStyle(.ds(.secondary, .regular)).accessibilityIdentifier("contacts.add")
                }
            }
            .padding(DS.Space.xl)
        }
        .task(id: app.data.contacts) { contacts = app.data.contacts }
        .sheet(item: $editing) { ContactEditor(contact: $0, jobs: app.allTracked) { c in write { try Contacts.upsert(c, in: app.store) } } }
        .confirmationDialog("Remove \(removing.map { $0.name.isEmpty ? "this contact" : $0.name } ?? "this contact")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = removing?.id { write { try Contacts.remove(id: id, in: app.store) } }
                removing = nil
            }.accessibilityIdentifier("contacts.remove.confirm")
        } message: {
            Text("Their notes and follow-up dates are deleted. This can't be undone.")
        }
    }

    private func row(_ c: Contact, due: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text([c.name, c.role].filter { !$0.isEmpty }.joined(separator: " · ")).font(DS.Font.headline)
                Text([c.company, c.channel, c.lastContacted.map { "last contacted \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            if let f = c.followUp {
                Text(due ? "Follow up now" : "Follow up \(f)").font(DS.Font.caption).monospacedDigit()
                    .foregroundStyle(due ? DS.Palette.textPrimary : DS.Palette.textSecondary).accessibilityIdentifier("contacts.followUp")
            }
            Button("Contacted today") { write { try Contacts.upsert(Contacts.markContacted(c), in: app.store) } }.accessibilityIdentifier("contacts.contacted")
                .help("Records today and sets the next follow-up \(Contacts.defaultFollowUpDays) days from now")
            Button("Edit") { editing = c }
            Button("Remove", role: .destructive) { removing = c }.accessibilityIdentifier("contacts.remove")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("contacts.row")
    }

    /// Every write goes through the store (read-modify-write by id), so this screen's copy never overwrites newer state.
    private func write(_ change: @escaping () throws -> Void) {
        do { try change(); app.refresh() } catch {
            app.toast = .error("Couldn't save your contacts: \(error.plainMessage). Free some disk space, then try again.", "Try Again") { write(change) }
        }
    }
}

/// Add or edit one contact. Also opened from a role's outreach sheet with the company and job filled in.
struct ContactEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var contact: Contact
    let jobs: [Job]
    let onSave: (Contact) -> Void
    @State private var remind = false
    @State private var date = Date()

    var body: some View {
        Form {
            TextField("Name", text: $contact.name).accessibilityIdentifier("contact.name")
            TextField("Their role", text: $contact.role)
            TextField("Company", text: $contact.company).accessibilityIdentifier("contact.company")
            Picker("For application", selection: $contact.jobId) {
                Text("None").tag("")
                ForEach(jobs) { Text("\($0.company): \($0.title)").tag($0.id) }
            }
            TextField("How to reach them", text: $contact.channel, prompt: Text("Email, LinkedIn, phone…"))
            TextField("Notes", text: $contact.notes, axis: .vertical).lineLimit(2...5)
            Toggle("Remind me to follow up", isOn: $remind).accessibilityIdentifier("contact.remind")
            if remind { DatePicker("Follow up on", selection: $date, displayedComponents: .date).accessibilityIdentifier("contact.date") }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let day = remind ? Dates.today(date) : nil
                    if day != contact.followUp { contact.followUp = day; contact.remindedFor = nil }
                    onSave(contact); dismiss()
                }
                .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                .disabled(contact.name.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("contact.save")
            }
        }
        .padding(20).frame(width: 460)
        .onAppear {
            if let d = Dates.day(contact.followUp) { remind = true; date = d }
            else { date = Contacts.followUpDate() }
        }
    }
}
