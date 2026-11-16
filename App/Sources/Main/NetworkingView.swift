import SwiftUI
import AppKit
import OfferlaneCore

/// Referral ideas and an editable outreach draft for one role. Drafts only: the user copies and sends.
struct NetworkingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var resume: ResumeContent?
    @State private var kind: OutreachKind = .referral
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var draft: OutreachDraft?
    @State private var drafting = false
    @State private var copied = false
    @State private var adding: Contact?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reach out about \(job.title)").font(.title2.bold())
            Text("Who to ask (you look them up; Offerlane never searches for people)").font(.headline)
            ForEach(Networking.ideas(job: job, resume: resume)) { idea in
                Button { kind = idea.kind } label: { Label(idea.text, systemImage: "person.2") }
                    .buttonStyle(.link).accessibilityIdentifier("networking.idea")
            }
            Picker("Message", selection: $kind) { ForEach(OutreachKind.allCases) { Text($0.title).tag($0) } }
                .fixedSize().accessibilityIdentifier("networking.kind")
            if let ai = app.ai {
                Text("Drafting sends your resume highlights and this posting to \(ai.client.displayName), the AI you connected.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            if let note = draft?.note { Text(note).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            if let w = draft?.warnings, !w.isEmpty { Text(w.joined(separator: " · ")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            TextField("Subject", text: $subject).textFieldStyle(.roundedBorder).accessibilityIdentifier("networking.subject")
            TextEditor(text: $bodyText).frame(minHeight: 160).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("networking.body").disabled(drafting)
            HStack {
                Text(copied ? "Copied. Paste it into your email or message app." : "Edit it in your own words. Offerlane never sends it.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Add contact…") { var c = Contact(name: ""); c.company = job.company; c.jobId = job.id; adding = c }
                    .accessibilityIdentifier("networking.addContact")
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("Subject: \(subject)\n\n\(bodyText)", forType: .string); copied = true
                }
                .disabled(bodyText.isEmpty).accessibilityIdentifier("networking.copy")
                Button("Done") { dismiss() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 580, height: 600)
        .task(id: kind) { await load() }
        .sheet(item: $adding) { ContactEditor(contact: $0, jobs: app.allTracked) { c in
            do { try Contacts.upsert(c, in: app.store); app.refresh() } catch {
                app.toast = .error("Couldn't save the contact: \(error.plainMessage). Free some disk space, then try again.", "OK") {}
            }
        } }
    }

    private func load() async {
        drafting = true; copied = false
        defer { drafting = false }
        let store = app.store, variant = job.variant
        if resume == nil {
            resume = await Task.detached { ((try? store.resume(variant.isEmpty ? nil : variant)) ?? (try? store.resume()))?.content }.value
        }
        let d = await Networking.draft(kind, job: job, resume: resume, ai: app.ai)
        draft = d; subject = d.subject; bodyText = d.body
    }
}
