import SwiftUI
import OfferlaneCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    private let env = TestHooks.env

    var body: some View {
        content
            .tint(DS.Palette.accent)
            .overlay { if showsSplash { SplashView() } }
            .onAppear {
                model.openApplyWindow = { [openWindow] in openWindow(id: "apply") }
                AppDelegate.onAction = { [openWindow] category in
                    if category == "OPEN_FORM" { openWindow(id: "apply") } else { model.navigate(to: .review) }
                    NSApp.activate(ignoringOtherApps: true)
                }
                // UI tests pin the appearance so light and dark screenshots are both captured.
                switch env["OFFERLANE_APPEARANCE"] {
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                default: break
                }
            }
    }

    /// The branded splash plays on a normal launch; UI tests opt in with OFFERLANE_SPLASH=1.
    private var showsSplash: Bool { !AppModel.isUITest || env["OFFERLANE_SPLASH"] == "1" }

    @ViewBuilder private var content: some View {
        if let err = model.fatalError {
            EmptyState(title: "Offerlane can't open your data", symbol: "exclamationmark.triangle", message: err) {
                Button("Try Again") {
                    let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                }.buttonStyle(.dsPrimary)
            }
        } else {
            switch model.auth {
            case .signedOut: WelcomeView().transition(.opacity)
            case .locked(let a): LockView(account: a)
            case .claiming(let a): ClaimDataView(account: a)
            case .signedIn:
                if !model.settings.onboarded { OnboardingView() } else { main }
            }
        }
    }

    private var main: some View {
        @Bindable var model = model
        let selection = Binding<SidebarItem?>(get: { model.selection }, set: { if let s = $0 { model.navigate(to: s) } })
        return NavigationSplitView {
            VStack(spacing: 0) {
                Wordmark(size: 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.xs).padding(.bottom, DS.Space.m)
                List(selection: selection) {
                    ForEach(SidebarItem.Group.allCases, id: \.self) { group in
                        let items = SidebarItem.allCases.filter { $0.group == group }
                        // A one-item group needs no header: "Today" over "Today" is noise.
                        Section {
                            ForEach(items) { item in
                                Label(item.title, systemImage: item.symbol)
                                    .badge(badge(item))
                                    .tag(item)
                                    .accessibilityIdentifier("sidebar.\(item.rawValue)")
                            }
                        } header: {
                            if items.count > 1 {
                                // Distinct label: the "Pipeline" header must not read (or query) as the "Pipeline" screen.
                                Text(group.rawValue).accessibilityLabel("\(group.rawValue) group").accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                SidebarStatus()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            ZStack {
                if let id = model.reviewing {
                    ReviewView(model: ReviewModel(jobID: id, app: model)).id(id)
                        .toolbar { ToolbarItem(placement: .navigation) { Button { model.closeReview() } label: { Label("Back", systemImage: "chevron.left") }
                            .keyboardShortcut("[", modifiers: .command).help("Back (⌘[)") } }
                        .transition(.opacity)
                } else {
                    detail(for: model.selection ?? .find)
                        .id(model.selection)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { GlassBackdrop() }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search roles")
        .overlay(alignment: .bottom) { ToastView() }
        .overlay(alignment: .topLeading) { perfProbe }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NotificationsButton() }
            if model.isFinding && model.selection != .find {
                ToolbarItem(placement: .status) {
                    Button { model.navigate(to: .find) } label: {
                        HStack(spacing: 6) { ProgressRing(value: model.findProgress?.fraction, size: 14, lineWidth: 2); Text("Finding jobs…") }
                    }
                    .buttonStyle(.plain).help(model.findProgress?.message ?? "")
                }
            }
        }
        .alert("You have unsaved changes", isPresented: Binding(get: { model.pendingNavigation != nil }, set: { if !$0 { model.pendingNavigation = nil } })) {
            if model.unsaved?.save != nil { Button("Save") { model.resolvePendingNavigation(save: true) } }
            Button("Discard Changes", role: .destructive) { model.resolvePendingNavigation(save: false) }
            Button("Keep Editing", role: .cancel) { model.pendingNavigation = nil }
        } message: { Text(model.unsaved?.message ?? "") }
        .sheet(isPresented: $model.showSetupCenter) { SetupCenterView().environment(model) }
        .sheet(isPresented: $model.showDiagnostics) { DiagnosticsView().environment(model) }
        .sheet(isPresented: $model.showPalette) { CommandPalette().environment(model) }
        .overlay(alignment: .bottomTrailing) { TourOverlay().dsAnimation(value: model.tourStep) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshHealth() }
    }

    private func badge(_ item: SidebarItem) -> Int {
        switch item {
        case .find: model.strongMatches.count
        case .review: model.reviewCount
        default: 0
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        if !model.loaded {
            SkeletonList(label: "Loading your roles")
        } else {
            switch item {
            case .find: FindView()
            case .review: ReviewQueueView()
            case .applications: ApplicationsView()
            case .resumes: ResumesView()
            case .settings: SettingsView()
            case .home: HomeView()
            case .goals: GoalsView()
            case .skills: SkillsView()
            case .interview: InterviewView()
            case .connectAI: ConnectAIView()
            }
        }
    }

    /// Launch-time readout for the performance UI test (OFFERLANE_PERF=1 only).
    @ViewBuilder private var perfProbe: some View {
        if env["OFFERLANE_PERF"] == "1", let ms = model.launchMillis {
            Text("\(ms)").font(.caption2).opacity(0.01).accessibilityIdentifier("perf.launchMillis")
        }
    }
}

/// Sidebar footer: is the AI ready? One click to fix it if not.
private struct SidebarStatus: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let ok = app.needsAttention.isEmpty
        let text = !app.aiConnected ? "AI not connected — Fix it" : ok ? (app.ai?.client.displayName ?? "All set") : app.healthSummary
        Button { app.showSetupCenter = true } label: {
            // A quiet status chip (v4): only a coloured dot speaks up when something needs attention.
            HStack(spacing: DS.Space.xs) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(text).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
            .background(Capsule().fill(DS.Palette.surfaceSunken))
            .contentShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m)
        }
        .buttonStyle(.plain)
        .help(ok && app.aiConnected ? "Everything is working. Click to open the Setup Center." : "Click to see what needs attention and fix it.")
        .accessibilityLabel(ok && app.aiConnected ? "Health: all set. Open Setup Center." : "Health: \(text). Open Setup Center to fix it.")
        .accessibilityIdentifier("sidebar.health")
    }

    private var dot: Color {
        if !app.aiConnected { return DS.Palette.warning }
        switch app.healthStatus {
        case .ok, .info: return DS.Palette.offer
        case .warning: return DS.Palette.warning
        case .problem: return DS.Palette.danger
        }
    }
}
