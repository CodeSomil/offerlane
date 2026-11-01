import SwiftUI
import OfferlaneCore

struct MatchesView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<String>()
    @State private var showWeaker = false

    var body: some View {
        let strong = filter(app.strongMatches), weaker = filter(app.weakerMatches)
        Group {
            if app.matches.isEmpty {
                if app.isFinding { SkeletonList() } else {
                    ContentUnavailableView {
                        Label("No matches yet", systemImage: "sparkle.magnifyingglass")
                    } description: {
                        Text("Find Jobs checks your companies' career sites and scores each role. Nothing is tailored or applied until you approve it.")
                    } actions: {
                        Button("Find Jobs") { app.findJobs() }.buttonStyle(.borderedProminent).disabled(!app.aiConnected)
                    }
                }
            } else {
                List(selection: $selection) {
                    Section {
                        ForEach(strong) { MatchRow(job: $0) }
                    } header: {
                        Text("Strong matches · score \(app.search.minScore)+ · \(strong.count)")
                    }
                    if !weaker.isEmpty {
                        Section {
                            if showWeaker { ForEach(weaker) { MatchRow(job: $0) } }
                        } header: {
                            Button { withAnimation(.snappy) { showWeaker.toggle() } } label: {
                                Label(showWeaker ? "Hide weaker matches · \(weaker.count)" : "Show weaker matches · \(weaker.count)",
                                      systemImage: showWeaker ? "chevron.down" : "chevron.right")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("matches.toggleWeaker")
                        }
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("matches.list")
            }
        }
        .navigationTitle("Matches")
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                if !selection.isEmpty {
                    Button("Approve \(selection.count)") { app.approve(selection); selection = [] }
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Decline \(selection.count)", role: .destructive) { app.decline(selection); selection = [] }
                        .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
    }

    private func filter(_ js: [Job]) -> [Job] {
        let q = app.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return js }
        return js.filter { "\($0.title) \($0.company) \($0.location)".lowercased().contains(q) }
    }
}

struct MatchRow: View {
    @Environment(AppModel.self) private var app
    let job: Job
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScoreBadge(score: job.llmScore, local: job.localScore, threshold: app.search.minScore)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(.headline).lineLimit(2)
                Text([job.company, job.location].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
                if !job.llmReason.isEmpty { Text(job.llmReason).font(.callout).lineLimit(2) }
                HStack(spacing: 6) {
                    if let p = job.posted, let d = Dates.day(p) { Chip(text: "Posted " + d.formatted(.relative(presentation: .named)), symbol: "calendar") }
                    if let y = job.minYears { Chip(text: "\(y)+ yrs asked", symbol: "clock") }
                    if !job.visa.isEmpty { Chip(text: Visa.label(job.visa), symbol: "airplane", tint: visaTint) }
                    if app.versions.count > 1 {
                        Menu {
                            ForEach(app.versions) { v in Button(v.label) { app.setVariant(job.id, v.name) } }
                        } label: { Chip(text: "Resume: " + (app.versions.first { $0.name == job.variant }?.label ?? "default"), symbol: "doc.text") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                if expanded {
                    Text(job.description.isEmpty ? "No description available." : job.description)
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 4)
                    if let u = URL(string: job.url), !job.url.isEmpty { Link("Open posting", destination: u).font(.callout) }
                }
                Button(expanded ? "Hide description" : "Show description") { withAnimation(.snappy) { expanded.toggle() } }
                    .buttonStyle(.link).font(.callout)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button { app.approve([job.id]) } label: { Label("Approve", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).help("Tailor a resume and apply (you'll review first)")
                    .accessibilityIdentifier("approve.\(job.id)")
                Button { app.decline([job.id]) } label: { Label("Decline", systemImage: "xmark") }
                    .help("Hide this role; it won't come back")
                    .accessibilityIdentifier("decline.\(job.id)")
            }
            .controlSize(.small).labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 6)
        .tag(job.id)
        .accessibilityElement(children: .contain)
    }

    private var visaTint: Color {
        switch job.visa { case "ok", "sponsors", "sponsor-register", "remote": .green; case "no-sponsorship": .red; case "h1b-lottery", "unknown": .orange; default: .secondary }
    }
}

struct ScoreBadge: View {
    let score: Int?, local: Double?, threshold: Int
    var body: some View {
        let value = score ?? Int(local ?? 0)
        VStack(spacing: 1) {
            Text("\(value)").font(.title3.weight(.bold)).monospacedDigit()
            Text(score == nil ? "local" : "score").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 50, height: 46)
        .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.15)))
        .foregroundStyle(color)
        .accessibilityLabel(score == nil ? "Not scored by AI, local score \(value)" : "Score \(value) of 100")
    }
    private var color: Color {
        guard let score else { return .secondary }
        return score >= max(threshold, 80) ? .green : score >= threshold ? .blue : .orange
    }
}

struct Chip: View {
    let text: String; var symbol: String? = nil; var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Placeholder rows while the first search runs.
struct SkeletonList: View {
    var body: some View {
        List(0..<6, id: \.self) { _ in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9).frame(width: 50, height: 46)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).frame(width: 260, height: 14)
                    RoundedRectangle(cornerRadius: 4).frame(width: 180, height: 11)
                }
            }
            .foregroundStyle(.quaternary).padding(.vertical, 6)
        }
        .listStyle(.inset)
        .accessibilityLabel("Searching career sites")
    }
}
