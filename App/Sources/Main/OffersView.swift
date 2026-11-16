import SwiftUI
import AppKit
import OfferlaneCore

/// Pipeline → Offers: pay ranges your saved postings state, offers you enter side by side, and a negotiation script you copy.
struct OffersView: View {
    @Environment(AppModel.self) private var app
    @State private var offers: [Offer] = []
    @State private var role = ""
    @State private var editing: Offer?
    @State private var scripting: OfferRow?

    var body: some View {
        let rows = Offers.compare(offers, jobs: app.jobs, visa: Visa(profile: (try? app.store.profile()) ?? Profile()))
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SectionCard(title: "Posted pay", subtitle: "Ranges stated in your saved postings for this role. A small sample, not a market survey.", symbol: "dollarsign.circle") {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        TextField("Role", text: $role).textFieldStyle(.roundedBorder).frame(maxWidth: 320).accessibilityIdentifier("offers.role")
                        let bands = Offers.bands(jobs: app.jobs, role: role)
                        if bands.isEmpty {
                            Text("None of your saved postings for this role state a pay range.").foregroundStyle(DS.Palette.textSecondary)
                        }
                        ForEach(bands) { b in
                            Text("\(b.label) · median \(Offers.money(b.median, b.currency)) · from \(b.jobIds.count) posting\(b.jobIds.count == 1 ? "" : "s")")
                                .accessibilityIdentifier("offers.band")
                        }
                    }
                }
                SectionCard(title: "Your offers", subtitle: "Figures you enter, stored only on this Mac. Equity is your own yearly estimate.", symbol: "scalemass") {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        ForEach(Offers.drafts(jobs: app.jobs, existing: offers)) { d in
                            Button { editing = d } label: { Label("\(d.company): \(d.title) is at Offer. Add its numbers", systemImage: "plus.circle") }
                                .buttonStyle(.link)
                        }
                        if rows.isEmpty { Text("No offers yet. Add one to compare totals and draft a negotiation reply.").foregroundStyle(DS.Palette.textSecondary) }
                        ForEach(rows) { row($0) }
                        Button { editing = Offer() } label: { Label("Add offer", systemImage: "plus") }
                            .buttonStyle(.ds(.secondary, .regular)).accessibilityIdentifier("offers.add")
                    }
                }
            }
            .padding(DS.Space.xl)
        }
        .task {
            offers = (try? app.store.get(.offers)) ?? []
            if role.isEmpty { role = SkillPlanner.roles((try? app.store.get(.skillPlan)) ?? SkillPlanState(), app.search).first ?? "" }
        }
        .sheet(item: $editing) { OfferEditor(offer: $0) { save($0) } }
        .sheet(item: $scripting) { NegotiationView(row: $0) }
    }

    private func row(_ r: OfferRow) -> some View {
        let o = r.offer
        return HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(o.company) · \(o.title)").font(DS.Font.headline)
                Text([o.location, Visa.label(r.visa), r.position.map { "base \($0) the posted range" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("First year \(Offers.money(o.firstYear, o.currency))").monospacedDigit().accessibilityIdentifier("offers.firstYear")
                Text("Then \(Offers.money(o.yearly, o.currency)) a year").font(DS.Font.caption).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
            }
            Button("Edit") { editing = o }
            Button("Negotiate…") { scripting = r }.accessibilityIdentifier("offers.negotiate")
            Button("Remove", role: .destructive) { offers.removeAll { $0.id == o.id }; persist() }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("offers.row")
    }

    private func save(_ o: Offer) {
        if let i = offers.firstIndex(where: { $0.id == o.id }) { offers[i] = o } else { offers.append(o) }
        persist()
    }
    private func persist() {
        do { try app.store.set(.offers, offers) } catch {
            app.toast = .error("Couldn't save your offers: \(error.plainMessage). Free some disk space, then try again.", "Try Again") { persist() }
        }
    }
}

private struct OfferEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var offer: Offer
    let onSave: (Offer) -> Void

    var body: some View {
        Form {
            TextField("Company", text: $offer.company).accessibilityIdentifier("offer.company")
            TextField("Role", text: $offer.title).accessibilityIdentifier("offer.title")
            TextField("Location", text: $offer.location)
            Picker("Currency", selection: $offer.currency) { ForEach(["$", "£", "€"], id: \.self) { Text($0) } }
            amount("Base salary a year", $offer.base, id: "offer.base")
            amount("Bonus a year", $offer.bonus, id: "offer.bonus")
            amount("Equity a year (your estimate)", $offer.equityPerYear, id: "offer.equity")
            amount("Sign-on bonus", $offer.signOn, id: "offer.signOn")
            TextField("Notes", text: $offer.notes)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(offer); dismiss() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                    .disabled(offer.company.isEmpty || offer.title.isEmpty).accessibilityIdentifier("offer.save")
            }
        }
        .padding(20).frame(width: 460)
    }

    private func amount(_ label: String, _ v: Binding<Double>, id: String) -> some View {
        TextField(label, value: v, format: .number).accessibilityIdentifier(id)
    }
}

private struct NegotiationView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let row: OfferRow
    @State private var script: NegotiationScript?
    @State private var bodyText = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Negotiate \(row.offer.title) at \(row.offer.company)").font(.title2.bold())
            if let ai = app.ai {
                Text("Drafting sends this offer's figures and the posted range to \(ai.client.displayName), the AI you connected. Your resume isn't sent.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            if let note = script?.note { Text(note).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            if let w = script?.warnings, !w.isEmpty { Text(w.joined(separator: " · ")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            TextEditor(text: $bodyText).frame(minHeight: 220).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("negotiation.body").disabled(script == nil)
            HStack {
                Text(copied ? "Copied. Paste it into your reply." : "Only ask for what you'd accept. Offerlane never sends it.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bodyText, forType: .string); copied = true }
                    .disabled(bodyText.isEmpty).accessibilityIdentifier("negotiation.copy")
                Button("Done") { dismiss() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 580, height: 480)
        .task {
            let store = app.store
            let (expected, name) = await Task.detached { () -> (String, String) in
                let p = (try? store.profile()) ?? Profile()
                let n = (try? store.resume())?.content.name ?? ""
                return (p.work.expectedSalary, n.isEmpty ? "\(p.personal.firstName) \(p.personal.lastName)".trimmingCharacters(in: .whitespaces) : n)
            }.value
            let s = await Offers.script(row, expected: expected, name: name, ai: app.ai)
            script = s; bodyText = s.body
        }
    }
}
