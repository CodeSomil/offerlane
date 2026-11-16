import SwiftUI
import OfferlaneCore

/// Everything Offerlane depends on, checked and fixed from one screen. Opened from the sidebar health dot,
/// Settings → AI, or the Offerlane menu.
struct SetupCenterView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DSSheet(title: "Setup Center", primary: "Done", showsCancel: false, onPrimary: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    overview
                    SectionCard(title: "Checks", symbol: "stethoscope") { checks }
                    AISections()
                    SectionCard(title: "Built in", symbol: "shippingbox") {
                        Text("The resume PDF maker, the browser that fills in applications, and the fonts all come inside Offerlane. There's nothing else to install.")
                            .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Space.xl)
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 600, idealHeight: 720)
        .task { await app.checkHealth() }
    }

    private var overview: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: icon(app.healthStatus)).font(.system(size: 30)).foregroundStyle(color(app.healthStatus))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.health.isEmpty ? "Checking…" : app.needsAttention.isEmpty ? "Everything is working" : app.healthSummary)
                    .font(DS.Font.title).accessibilityIdentifier("setup.summary")
                if let r = app.repairing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(r) }.font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                } else if let r = app.repairResult {
                    Text(r).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("setup.repairResult")
                } else {
                    Text("Offerlane checks these whenever it opens. Fix anything here with one click.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            Spacer()
            Button("Repair Everything") { Task { await app.repairEverything() } }
                .buttonStyle(.dsPrimary)
                .disabled(app.repairing != nil || app.healthChecking && app.health.isEmpty)
                .accessibilityIdentifier("setup.repairAll")
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(app.health.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider().padding(.vertical, DS.Space.s) }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                    Image(systemName: icon(item.status)).foregroundStyle(color(item.status)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(DS.Font.headline)
                        Text(item.message).font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let fix = item.fix, item.status >= .warning {
                        Button(fix.label) { Task { await app.perform(fix) } }
                            .buttonStyle(.dsSecondary).disabled(app.repairing != nil)
                            .accessibilityIdentifier("health.fix.\(item.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("health.\(item.id)")
            }
            if app.health.isEmpty { SkeletonList(rows: 4) }
        }
    }

    private func icon(_ s: Health.Status) -> String {
        switch s {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }
    private func color(_ s: Health.Status) -> Color {
        switch s {
        case .ok: DS.Palette.offer
        case .info: .secondary
        case .warning: DS.Palette.warning
        case .problem: DS.Palette.danger
        }
    }
}

/// Connected AIs + the engine chooser: shared by the Connect AI screen and the Setup Center.
struct AISections: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        SectionCard(title: "Connected AIs", subtitle: "Tried in this order. The first one does the work; the others step in when it can't.", symbol: "list.number") {
            ConnectionsView()
        }
        SectionCard(title: "AI engine", subtitle: "The AI Offerlane uses to read resumes, score jobs and tailor applications.", symbol: "sparkles") {
            AIEngineChooser(model: app.onboarding)
            useThisAI
        }
    }

    @ViewBuilder private var useThisAI: some View {
        let setup = app.onboarding!
        let inUse = app.settings.provider == setup.provider && app.aiConnected
        HStack {
            if inUse { StatusLine(kind: .ok, text: "Offerlane is using this AI.") }
            Spacer()
            if !inUse || setup.provider == .ollama && app.settings.modelSmart != setup.ollamaModel {
                if app.aiConnected && !inUse {
                    Button("Add as Backup") { setup.saveAI(asBackup: true) }
                        .buttonStyle(.dsSecondary).disabled(!setup.aiReady)
                        .accessibilityIdentifier("setup.addBackup")
                }
                Button("Use This AI") { setup.saveAI() }
                    .buttonStyle(.dsPrimary).disabled(!setup.aiReady)
                    .accessibilityIdentifier("setup.useAI")
            }
        }
    }
}
