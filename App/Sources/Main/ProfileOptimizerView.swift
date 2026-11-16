import SwiftUI
import AppKit
import OfferlaneCore

/// LinkedIn and portfolio checks plus suggestions from one resume version. Nothing is fetched from LinkedIn or saved: the user copies.
struct ProfileOptimizerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let resume: ResumeContent
    let role: String
    @State private var pasted = ""
    @State private var links: [String: String] = [:]
    @State private var advice: ProfileAdvice?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LinkedIn and portfolio").font(.title2.bold())
            Text("Built only from this resume\(role.isEmpty ? "" : ", aimed at \(role)"). Add only what's true. Offerlane never opens or changes your LinkedIn.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste your LinkedIn headline and About (optional) to see what's missing").font(.headline)
                    TextEditor(text: $pasted).frame(minHeight: 70).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                        .accessibilityLabel("Your LinkedIn text").accessibilityIdentifier("profile.pasted")
                    let checks = ProfileOptimizer.checks(resume: resume, links: links, pasted: pasted)
                    Text("Checks").font(.headline)
                    if checks.isEmpty { Label("Your links look right.", systemImage: "checkmark.circle").foregroundStyle(DS.Palette.offer) }
                    ForEach(checks) { f in
                        Label(f.text, systemImage: "exclamationmark.circle").accessibilityIdentifier("profile.check")
                    }
                    Text("Suggestions").font(.headline)
                    if let ai = app.ai {
                        Text("Suggestions send your resume to \(ai.client.displayName), the AI you connected.")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                    if let a = advice {
                        if let note = a.note { Text(note).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                        if !a.warnings.isEmpty { Text(a.warnings.joined(separator: " · ")).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                        ForEach(a.suggestions) { s in row(s) }
                    } else {
                        SkeletonBlock(width: 240, height: 80).accessibilityLabel("Making suggestions")
                    }
                }
            }
            HStack {
                Text(copied.map { "Copied \($0). Paste it into LinkedIn yourself." } ?? "Copy a suggestion, then edit it in your own words.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 620, height: 660)
        .task {
            let p = (try? app.store.profile())?.personal
            links = resume.links.merging(["linkedin": p?.linkedin ?? "", "github": p?.github ?? "", "portfolio": p?.portfolio ?? ""].filter { !$0.value.isEmpty }) { $1 }
            advice = await ProfileOptimizer.suggest(resume: resume, role: role, ai: app.ai)
        }
    }

    private func row(_ s: ProfileSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.title).font(.subheadline.bold())
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.text, forType: .string); copied = s.title
                }
                .accessibilityLabel("Copy \(s.title)").accessibilityIdentifier("profile.copy")
            }
            Text(s.text).textSelection(.enabled).accessibilityIdentifier("profile.suggestion")
            Text("From your resume: " + s.cites.map { ProfileOptimizer.citeText($0, resume: resume) }.joined(separator: " · "))
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}
