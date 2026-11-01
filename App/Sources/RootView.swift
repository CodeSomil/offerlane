import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content.onAppear {
            model.apply.openWindow = { [openWindow] in openWindow(id: "apply") }
            AppDelegate.onAction = { [openWindow] category in
                if category == "OPEN_FORM" { openWindow(id: "apply") } else { model.reviewing = nil; model.selection = .todo }
                NSApp.activate(ignoringOtherApps: true)
            }
            // UI tests pin the appearance so light and dark screenshots are both captured.
            switch ProcessInfo.processInfo.environment["OFFERLANE_APPEARANCE"] {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let err = model.fatalError {
            ContentUnavailableView("Can't open your data", systemImage: "exclamationmark.triangle", description: Text(err))
        } else if !model.settings.onboarded {
            OnboardingView()
        } else {
            main
        }
    }

    private var main: some View {
        @Bindable var model = model
        return NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(item == .todo ? model.todoCount : item == .matches ? model.strongMatches.count : 0)
                    .tag(item)
                    .accessibilityIdentifier("sidebar.\(item.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            if let id = model.reviewing {
                ReviewView(model: ReviewModel(jobID: id, app: model)).id(id)
                    .toolbar { ToolbarItem(placement: .navigation) { Button { model.reviewing = nil } label: { Label("Back", systemImage: "chevron.left") } } }
            } else {
                detail(for: model.selection ?? .todo)
            }
        }
        .onChange(of: model.selection) { model.reviewing = nil }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search roles")
        .navigationSubtitle(model.findProgress?.message ?? model.tailoringMessage ?? "")
        .overlay(alignment: .bottom) { ToastView() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.reviewing != nil {
                    EmptyView()
                } else if model.isFinding {
                    HStack(spacing: 8) {
                        ProgressView(value: model.findProgress?.fraction ?? 0).progressViewStyle(.circular).controlSize(.small)
                        Button("Stop") { model.cancelFind() }.accessibilityIdentifier("toolbar.stop")
                    }
                    .help(model.findProgress?.message ?? "")
                } else {
                    Button { model.findJobs() } label: {
                        Label("Find Jobs", systemImage: "sparkle.magnifyingglass").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.aiConnected)
                    .help("Check every career site and score new roles (⌘F)")
                    .accessibilityIdentifier("toolbar.findJobs")
                }
            }
            ToolbarItem(placement: .status) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(model.aiConnected ? .green : .secondary)
                    .padding(.horizontal, 4)
                    .help(model.aiConnected ? "AI connected" : "AI not connected — set it up in Settings")
                    .accessibilityLabel(model.aiConnected ? "AI connected" : "AI not connected")
            }
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .settings: SettingsView()
        case .todo: TodoView()
        case .matches: MatchesView()
        case .activity: ActivityView()
        case .applications: ApplicationsView()
        case .resumes: ResumesView()
        default:
            ContentUnavailableView {
                Label(item.title, systemImage: item.symbol)
            } description: {
                Text(emptyText(item))
            } actions: {
                if item == .todo || item == .matches {
                    Button("Find Jobs") { model.findJobs() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func emptyText(_ item: SidebarItem) -> String {
        switch item {
        case .todo: "Nothing needs you right now. Click Find Jobs to look for new roles."
        case .matches: "No matches yet. Find Jobs checks your companies' career sites and scores each role."
        case .resumes: "Add a resume (PDF, Word, text or LaTeX) to get started."
        case .applications: "Applications you submit will be tracked here."
        case .activity: "Runs and changes will appear here."
        case .settings: ""
        }
    }
}

/// Bottom toast with an optional Undo; disappears after a few seconds.
struct ToastView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let t = app.toast {
            HStack(spacing: 12) {
                Text(t.message).lineLimit(2)
                if let label = t.undoLabel, let undo = t.undo { Button(label) { undo() }.buttonStyle(.borderless).fontWeight(.semibold) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("toast")
            .task(id: t.id) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if app.toast?.id == t.id { withAnimation { app.toast = nil } }
            }
        }
    }
}
