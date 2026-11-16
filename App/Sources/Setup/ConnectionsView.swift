import SwiftUI
import OfferlaneCore

extension AppModel {
    /// Swaps the connection at `index` with its neighbour `by` places away (-1 up, +1 down); the first one is the primary.
    func moveConnection(_ index: Int, by offset: Int) {
        var list = settings.connections
        guard list.indices.contains(index), list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        settings.connections = list
        rebuildAI(); refreshHealth()
    }

    /// Removes a connection; its saved key is deleted too when nothing else uses it.
    func removeConnection(_ index: Int) {
        var s = settings
        if let account = s.removeConnection(at: index) { keychain.delete(account: account) }
        settings = s
        rebuildAI(); refreshHealth()
    }

    /// Runs the strict-JSON test against one saved connection. nil = passed.
    func retestConnection(_ c: AppSettings.Connection) async -> String? {
        var s = settings; s.connection = c; s.fallbacks = []
        guard let client = AIFactory.client(s, keychain: keychain) else { return "This AI isn't fully set up any more. Connect it again above." }
        return await ProviderSetup.retest(client)
    }
}

/// Connected AIs in the order Offerlane tries them: re-test, reorder, remove.
struct ConnectionsView: View {
    @Environment(AppModel.self) private var app
    @State private var results: [AppSettings.Connection: String] = [:]
    @State private var testing: AppSettings.Connection?
    @State private var removing: Int?

    var body: some View {
        let list = app.settings.connections
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if list.isEmpty {
                Text("No AI connected yet. Choose one below.").font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
            }
            ForEach(Array(list.enumerated()), id: \.element) { i, c in
                if i > 0 { Divider() }
                row(i, c, count: list.count)
            }
            if list.count > 1 {
                Text("If one is busy or down, Offerlane sends the same request to the next one. Each AI here can see your resume and the job postings.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Remove this AI?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let i = removing { app.removeConnection(i) }; removing = nil }
        } message: {
            Text("Offerlane stops using it and deletes its saved key. Nothing is uninstalled; to remove Ollama itself, use Manage Ollama.")
        }
    }

    private func row(_ i: Int, _ c: AppSettings.Connection, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label).font(DS.Font.headline)
                Text(i == 0 ? "Primary" : "Backup \(i)").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                if testing == c { StatusLine(kind: .working, text: "Testing…") }
                else if let r = results[c] { StatusLine(kind: r.isEmpty ? .ok : .error, text: r.isEmpty ? "Passed the strict JSON test." : r) }
            }
            Spacer()
            Button { app.moveConnection(i, by: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.dsGhost).disabled(i == 0).help("Move up").accessibilityLabel("Move \(c.label) up")
                .accessibilityIdentifier("connection.up.\(i)")
            Button { app.moveConnection(i, by: 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.dsGhost).disabled(i == count - 1).help("Move down").accessibilityLabel("Move \(c.label) down")
                .accessibilityIdentifier("connection.down.\(i)")
            Button("Test") {
                testing = c
                Task { results[c] = await app.retestConnection(c) ?? ""; testing = nil }
            }
            .buttonStyle(.dsSecondary).disabled(testing != nil).accessibilityIdentifier("connection.test.\(i)")
            Button("Remove…") { removing = i }.buttonStyle(.dsSecondary).accessibilityIdentifier("connection.remove.\(i)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection.\(i)")
    }
}
