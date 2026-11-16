import SwiftUI
import OfferlaneCore

/// Help → Offerlane Help (⌘?): searchable answers grouped by topic.
struct HelpView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selection: HelpTopic.ID? = HelpContent.topics.first?.id
    @FocusState private var searchFocused: Bool

    private var results: [HelpTopic] { query.isEmpty ? HelpContent.topics : HelpContent.topics.filter { $0.matches(query) } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(HelpContent.sections, id: \.self) { section in
                    let items = results.filter { $0.section == section }
                    if !items.isEmpty {
                        Section(section) {
                            ForEach(items) { t in Text(t.question).tag(t.id).accessibilityIdentifier("help.topic.\(t.id)") }
                        }
                    }
                }
            }
            .overlay { if results.isEmpty { EmptyState(title: "No answers found", symbol: "magnifyingglass", message: "Try a different word, such as “resume”, “email” or “Ollama”.") } }
            .searchable(text: $query, placement: .sidebar, prompt: "Search help")
            .onChange(of: query) { if let first = results.first, !results.contains(where: { $0.id == selection }) { selection = first.id } }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            if let t = HelpContent.topics.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        Text(t.section.uppercased()).font(DS.Font.caption.weight(.semibold)).foregroundStyle(DS.Palette.textSecondary)
                        Text(t.question).font(DS.Font.title).accessibilityAddTraits(.isHeader)
                        Text(LocalizedStringKey(t.answer)).font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).accessibilityIdentifier("help.answer")
                        if let action = t.action {
                            Button(label(action)) { run(action) }.buttonStyle(.dsPrimary).padding(.top, DS.Space.s)
                                .accessibilityIdentifier("help.action")
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(DS.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyState(title: "Choose a question", symbol: "questionmark.circle", message: "Pick a question on the left, or search.")
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private func label(_ a: HelpTopic.Action) -> String {
        switch a {
        case .setupCenter: "Open Setup Center"
        case .tour: "Take the Tour"
        case .diagnostics: "Create Diagnostics Report…"
        case .settings: "Open Settings"
        }
    }

    private func run(_ a: HelpTopic.Action) {
        switch a {
        case .settings: openSettings(); return
        case .setupCenter: app.showSetupCenter = true
        case .tour: app.startTour()
        case .diagnostics: app.showDiagnostics = true
        }
        showMainWindow(openWindow)
    }
}
