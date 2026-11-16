import SwiftUI
import AppKit
import OfferlaneCore

/// Copy to Claude (Route B, D1): copy the tailoring request, paste Claude's reply back. The reply goes through the Guard
/// and lands in Review like any tailoring; plain text only, nothing is sent anywhere by Offerlane.
struct ClaudeHandoffSheet: View {
    let app: AppModel
    let job: Job
    @Environment(\.dismiss) private var dismiss
    @State private var reply = ""
    @State private var copied = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Tailor with Claude").font(DS.Font.title)
            Text("\(job.title) · \(job.company)").foregroundStyle(DS.Palette.textSecondary)
            Text("1. Copy the request. It holds your resume bullets, search goals and this role. Contact details and pay are left out.")
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy Request for Claude") { copy() }.buttonStyle(.dsPrimary).accessibilityIdentifier("handoff.copy")
            Text("2. Paste it into a new chat in your Claude app, then paste Claude's whole reply here.").fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $reply).font(.system(.callout, design: .monospaced)).frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(DS.Palette.hairline))
                .accessibilityLabel("Claude's reply").accessibilityIdentifier("handoff.reply")
            if let error { StatusLine(kind: .error, text: error).accessibilityIdentifier("handoff.error") }
            HStack {
                Text("Numbers that aren't in your resume are refused. You still review the result.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.dsSecondary).keyboardShortcut(.cancelAction)
                Button("Send to Review") { send() }.buttonStyle(.dsPrimary).disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    .accessibilityIdentifier("handoff.send")
            }
        }
        .padding(DS.Space.xl).frame(width: 560)
    }

    private func copy() {
        do {
            let text = try ClaudeHandoff.prompt(for: job, store: app.store)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true; error = nil
        } catch { self.error = error.plainMessage }
    }

    private func send() {
        saving = true; error = nil
        let store = app.store, id = job.id, text = reply
        Task {
            defer { saving = false }
            do {
                try await ClaudeHandoff.save(try ClaudeHandoff.parse(text), job: id, store: store, by: "claude-paste")
                app.refresh(); dismiss()
            } catch { self.error = error.plainMessage }
        }
    }
}
