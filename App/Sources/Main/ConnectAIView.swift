import SwiftUI
import OfferlaneCore

/// Connect AI: choose, connect and order the AIs Offerlane uses, on its own screen.
struct ConnectAIView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: SidebarItem.connectAI.title, subtitle: app.aiConnected ? "Connected · resume text goes only to the AI you connect here" : "Not connected yet") {
                Button { app.showSetupCenter = true } label: { Label("Setup Center", systemImage: "stethoscope") }.buttonStyle(.dsSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) { AISections() }.padding(DS.Space.xl)
            }
        }
    }
}
