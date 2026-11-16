import SwiftUI
import OfferlaneCore

/// A brief on the employer built only from the saved posting (one cached AI call, Guard-checked). Read-only.
struct CompanyBriefView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var brief: CompanyBrief?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(job.company) brief").font(.title2.bold())
            Text("From this posting only. Offerlane doesn't look anything up, and lines the posting doesn't support are removed.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            if let ai = app.ai, !job.description.isEmpty {
                Text("Building it sends this posting (not your resume) to \(ai.client.displayName), the AI you connected.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            if let b = brief {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(b.points, id: \.self) { Label($0, systemImage: "building.2").accessibilityIdentifier("brief.point") }
                        if !b.questions.isEmpty {
                            Text("Questions you could ask").font(.headline).padding(.top, 6)
                            ForEach(b.questions, id: \.self) { Label($0, systemImage: "questionmark.bubble").accessibilityIdentifier("brief.question") }
                        }
                        if let note = b.note { Text(note).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("brief.note") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressRing(value: nil, size: 18, lineWidth: 2)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520, height: 440)
        .task { brief = await CompanyBriefs.brief(job: job, ai: app.ai) }
    }
}
