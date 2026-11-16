import SwiftUI
import OfferlaneCore

struct AIStepView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Choose your AI", subtitle: "Offerlane uses an AI to read your resume, score roles and tailor applications. You can change this later in Settings.")
            MacNotices()
            AIEngineChooser(model: model)
        }
    }
}

/// Offline, low disk or Rosetta, shown above the AI choice so problems surface before an install starts.
struct MacNotices: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let notes = app.health.filter { $0.id != "ai" && $0.status >= .warning }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(notes) { item in
                    HStack(alignment: .firstTextBaseline) {
                        StatusLine(kind: item.status == .problem ? .error : .info, text: item.message)
                        Spacer()
                        if let fix = item.fix { Button(fix.label) { Task { await app.perform(fix) } } }
                    }
                }
            }
            .padding(12)
            .background(DS.Palette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("setup.notices")
        }
    }
}

/// Every verified AI as a card, the best one for this Mac first, the rest under "More options", then the panel for the chosen one.
/// Used by onboarding and the Setup Center.
struct AIEngineChooser: View {
    @Bindable var model: OnboardingModel
    private let options = FirstRun.options(SystemCheck.hardware, specs: (try? ProviderRegistry.visible()) ?? [])
    private let specs = (try? ProviderRegistry.load()) ?? []
    private let columns = [GridItem(.adaptive(minimum: 210), spacing: DS.Space.m, alignment: .top)]
    @State private var showMore: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                // P1.6: one recommended button keeps first run short; every other option is one click away under More.
                ForEach(Array(options.prefix(1).enumerated()), id: \.offset) { i, o in
                    card(o, badge: "Recommended").accessibilityIdentifier("provider.recommended.\(i)")
                }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Recommended AI option")
            let rest = Array(options.dropFirst(1))
            let expanded = showMore ?? (rest.contains(where: isSelected) || model.provider == .claudeCLI)
            Button { showMore = !expanded } label: {
                Label(expanded ? "Fewer options" : "More options", systemImage: expanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("provider.more")
            if expanded {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.m) {
                    // Claude account stays only for people already using it (deferred in P2.5, not offered to new users).
                    if model.provider == .claudeCLI {
                        ProviderCard(selected: true, logo: nil, symbol: "person.crop.circle.badge.checkmark", title: "Claude account",
                                     detail: "Your Claude Pro or Max plan, set up earlier.", badge: nil, cost: nil) {}
                            .accessibilityIdentifier("provider.claude")
                    }
                    ForEach(rest, id: \.providerID) { o in card(o, badge: nil).accessibilityIdentifier("provider.\(o.providerID)") }
                }
                .accessibilityElement(children: .contain).accessibilityLabel("More AI options")
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.provider {
                    case .claudeCLI: ClaudePanel(model: model)
                    case .anthropic: APIKeyPanel(model: model)
                    case .ollama: OllamaPanel(model: model)
                    case .apiKey: KeyProviderPanel(model: model)
                    case .none: EmptyView()
                    }
                    // The key panel shows its own provider's note.
                    if let note = privacyNote {
                        StatusLine(kind: .info, text: "Privacy: \(note)").accessibilityIdentifier("ai.privacy")
                    }
                    Divider()
                    connectionStatus
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { model.providerChanged() }
    }

    private func card(_ o: FirstRun.Option, badge: String?) -> some View {
        let spec = specs.first { $0.id == o.providerID }
        return ProviderCard(selected: isSelected(o), logo: spec?.logo, symbol: ProviderLogo.symbol(o.providerID), title: o.name,
                            detail: o.reason, badge: badge, cost: spec.flatMap(Self.cost)) { choose(o) }
    }

    private static func cost(_ s: ProviderSpec) -> (String, Color)? {
        if s.id == "custom" { return nil }
        if s.pkceSignIn != nil { return ("Free or paid", DS.Palette.offer) }
        return s.kind == .local ? ("On this Mac", DS.Palette.offer) : s.free ? ("Free", DS.Palette.offer) : ("Paid", .secondary)
    }

    private func select(_ p: AppSettings.Provider) {
        guard model.provider != p else { return }
        model.provider = p; model.providerChanged()
    }

    private var privacyNote: String? {
        let id = model.provider == .ollama ? "ollama" : model.provider == .anthropic ? "anthropic" : nil
        return specs.first { $0.id == id }.map(\.privacyNote).flatMap { $0.isEmpty ? nil : $0 }
    }
    private func isSelected(_ o: FirstRun.Option) -> Bool {
        model.provider == o.provider && (o.provider != .apiKey || model.keySpecID == o.providerID)
    }
    private func choose(_ o: FirstRun.Option) {
        if o.provider == .apiKey, model.keySpecID != o.providerID { model.keySpecID = o.providerID; model.keyProviderChanged() }
        select(o.provider)
    }

    @ViewBuilder private var connectionStatus: some View {
        if AppModel.isUITest { StatusLine(kind: .ok, text: "Connected (test AI)") }
        else if model.connectionTesting { StatusLine(kind: .working, text: "Testing the connection…") }
        else if model.aiReady { StatusLine(kind: .ok, text: "Connected" + (model.connectedSeconds.map { String(format: " · answered in %.1f s", $0) } ?? "")) }
        else if let e = model.connectionError {
            ErrorRow(text: e, action: "Try Again") { Task { await model.testConnection() } }
        } else { StatusLine(kind: .info, text: "Not connected yet.") }
    }
}

/// An error with its way out next to it.
struct ErrorRow: View {
    let text: String, action: String, perform: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            StatusLine(kind: .error, text: text)
            Spacer()
            Button(action, action: perform)
        }
    }
}

/// A labelled progress bar with Cancel.
struct ProgressRow: View {
    let status: String
    let fraction: Double?
    let label: String
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status).font(.callout)
                Spacer()
                if let fraction, fraction > 0 { Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(DS.Palette.textSecondary) }
                Button("Cancel", action: cancel)
            }
            if let fraction, fraction > 0 { ProgressView(value: min(fraction, 1)).accessibilityLabel(label) }
            else { ProgressView().progressViewStyle(.linear).accessibilityLabel(label) }
        }
    }
}

private struct ProviderCard: View {
    let selected: Bool, logo: String?, symbol: String, title: String, detail: String, badge: String?, cost: (String, Color)?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .top) {
                    ProviderLogo(asset: logo, symbol: symbol)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? DS.Palette.accent : Color.secondary.opacity(0.5)).accessibilityHidden(true)
                }
                Text(title).font(DS.Font.headline).fixedSize(horizontal: false, vertical: true)
                if badge != nil || cost != nil {
                    HStack(spacing: DS.Space.xs) {
                        if let badge { Pill(text: badge, symbol: "star.fill", tint: DS.Palette.accent) }
                        if let cost { Pill(text: cost.0, tint: cost.1) }
                    }
                }
                Text(detail).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l).fill(selected ? DS.Palette.accentSoft : DS.Palette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l).strokeBorder(selected ? DS.Palette.accent : DS.Palette.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.l))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The provider's own logo where its brand rules allow (registry `logo`), otherwise a neutral symbol.
struct ProviderLogo: View {
    let asset: String?, symbol: String
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let asset { Image(asset).resizable().scaledToFit().padding(size * 0.2) }
            else { Image(systemName: symbol).font(.system(size: size * 0.45)).foregroundStyle(DS.Palette.accent) }
        }
        .frame(width: size, height: size)
        .background(DS.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.m))
        .accessibilityHidden(true)
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "ollama": "desktopcomputer"
        case "anthropic": "key"
        case "cloudflare": "cloud"
        case "groq": "bolt"
        case "gemini": "sparkles"
        case "custom": "server.rack"
        default: "key.horizontal"
        }
    }
}

private struct ClaudePanel: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude subscriptions work only through Claude's own apps, so Offerlane uses the official Claude Code tool as a bridge. Calls count toward your plan's usage limits.")
                .font(.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            if model.claudeChecking && model.claudeExe == nil && !model.claudeInstalling {
                StatusLine(kind: .working, text: "Looking for Claude Code…")
            } else if let exe = model.claudeExe {
                StatusLine(kind: .ok, text: "Claude Code is installed\(model.claudeVersion.map { " (\($0))" } ?? "").")
                    .help(exe.path)
                if let auth = model.claudeAuth, auth.loggedIn {
                    StatusLine(kind: .ok, text: "Signed in with \(auth.planName).")
                } else {
                    HStack {
                        StatusLine(kind: .info, text: "Sign in once with your Claude account.")
                        Spacer()
                        Button("Sign In…") { model.showClaudeSignIn = true }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("claude.signIn")
                    }
                }
            } else if model.claudeInstalling {
                ProgressRow(status: model.claudeInstallStatus.isEmpty ? "Installing Claude Code…" : model.claudeInstallStatus,
                            fraction: model.claudeInstallProgress, label: "Claude Code download progress") { model.cancelLongTask() }
                if !model.claudeInstallLog.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView { Text(model.claudeInstallLog).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(maxHeight: 120)
                    }
                }
            } else {
                HStack {
                    StatusLine(kind: .info, text: "Claude Code isn't installed on this Mac yet. It's about 300 MB, downloaded from Anthropic and checked before it's installed.")
                    Spacer()
                    Button("Install") { model.installClaude() }.buttonStyle(.borderedProminent).accessibilityIdentifier("claude.install")
                }
                if let e = model.claudeError { ErrorRow(text: e, action: "Try Again") { model.installClaude() } }
            }
        }
        .sheet(isPresented: $model.showClaudeSignIn) {
            if let exe = model.claudeExe {
                ClaudeSignInSheet(executable: exe) { status in
                    model.showClaudeSignIn = false
                    if let status { model.claudeAuth = status; Task { await model.testConnection() } }
                }
            }
        }
    }
}

private struct APIKeyPanel: View {
    @Bindable var model: OnboardingModel
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Create a key in the Claude Console, then paste it here. It's stored in your Mac's Keychain.")
                    .font(.callout).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Button("Get a Key") { openURL(URL(string: "https://console.anthropic.com/settings/keys")!) }
            }
            HStack {
                SecureField("sk-ant-…", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.testConnection() } }
                    .onChange(of: model.apiKey) { if model.connectedProvider == .anthropic { model.connectedProvider = nil } }
                    .accessibilityLabel("API key")
                Button("Test Key") { Task { await model.testConnection() } }.disabled(model.apiKey.count < 20 || model.connectionTesting)
            }
            if !model.apiKey.isEmpty && !model.apiKey.hasPrefix("sk-ant-") {
                StatusLine(kind: .info, text: "Claude API keys usually start with “sk-ant-”.")
            }
            Text("Typical cost: a few cents per Find Jobs run and about a cent per tailored resume. Spend is shown in Settings → Usage.")
                .font(.caption).foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

/// Get a key → paste it → connect, for the key provider picked on its card. Steps and links come from the registry.
private struct KeyProviderPanel: View {
    @Bindable var model: OnboardingModel
    @Environment(\.openURL) private var openURL
    @FocusState private var keyFocused: Bool
    @State private var openedPage = false
    @State private var manualKey = false
    @AppStorage("developer.showAllModels") private var showAllModels = false

    /// Unqualified picks never carry the word "Recommended" (P1 gate 2).
    static func title(_ p: ProviderSpec.Pick) -> String {
        let name = switch p.tier { case .recommended: p.qualified ? "Recommended" : "Balanced"; case .cheaper: "Cheaper"; case .advanced: "Advanced" }
        return p.qualified ? name : "\(name) · not yet tested"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let spec = model.keySpec, let adapter = model.keyAdapter { fields(spec, adapter) }
        }
        .task(id: model.keySpecID) { openedPage = false; manualKey = false; await model.loadModels() }
        // Back from the browser with the key copied: the key box is ready for ⌘V. Never reads the clipboard itself.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if openedPage && model.keyValue.isEmpty { keyFocused = true }
        }
    }

    private func step(_ spec: ProviderSpec) -> Int {
        if model.aiReady && model.connectedProvider == .apiKey { return 3 }
        if spec.keyLooksValid(model.keyValue) { return 2 }
        return openedPage || !model.keyValue.isEmpty || spec.keyPageURL == nil ? 1 : 0
    }

    private func openPage(_ url: URL) { openedPage = true; openURL(url) }

    @ViewBuilder private func fields(_ spec: ProviderSpec, _ adapter: KeyProviderAdapter) -> some View {
        HStack(spacing: DS.Space.m) {
            ProviderLogo(asset: spec.logo, symbol: ProviderLogo.symbol(spec.id), size: 32)
            Text(spec.name).font(DS.Font.headline)
        }
        if adapter.needsAccountID {
            TextField("Account ID", text: $model.keyAccountID, prompt: Text("Shown in the dashboard sidebar"))
                .textFieldStyle(.roundedBorder).onChange(of: model.keyAccountID) { model.keyFieldsChanged() }
        }
        if spec.baseURL == nil {
            TextField("Endpoint", text: $model.keyBaseURL, prompt: Text("https://example.com/v1"))
                .textFieldStyle(.roundedBorder).onChange(of: model.keyBaseURL) { model.keyFieldsChanged() }
        }
        if let picks = spec.picks, !picks.isEmpty {
            HStack(alignment: .top, spacing: DS.Space.m) {
                ForEach(picks) { p in
                    let price = model.keyModels.first { $0.id == p.id }?.priceText ?? "price unavailable"
                    ProviderCard(selected: model.keyModel == p.id, logo: spec.logo, symbol: ProviderLogo.symbol(spec.id), title: Self.title(p),
                                 detail: "\(p.use)\n\(p.privacy)", badge: p.qualified && p.tier == .recommended ? "Recommended" : nil,
                                 cost: (price, DS.Palette.textSecondary)) { model.keyModel = p.id; model.keyFieldsChanged() }
                        .accessibilityIdentifier("key.pick.\(p.tier.rawValue)")
                }
            }
            Toggle("Show all models (developer)", isOn: $showAllModels).toggleStyle(.checkbox).accessibilityIdentifier("key.showAll")
            if showAllModels {
                StatusLine(kind: .error, text: "Warning: models outside these three haven't been checked by Offerlane. Some may invent facts in your resume or ignore the privacy rules.")
                if model.keyModels.isEmpty {
                    TextField("Model", text: $model.keyModel, prompt: Text("Model id")).textFieldStyle(.roundedBorder)
                        .onChange(of: model.keyModel) { model.keyFieldsChanged() }
                } else {
                    Picker("Model", selection: $model.keyModel) {
                        ForEach(model.keyModels) { Text("\($0.id) · \($0.priceText)").tag($0.id) }
                        if !model.keyModels.contains(where: { $0.id == model.keyModel }) { Text(model.keyModel).tag(model.keyModel) }
                    }
                    .onChange(of: model.keyModel) { model.keyFieldsChanged() }
                    .accessibilityIdentifier("key.model")
                }
            }
        } else {
            TextField("Model", text: $model.keyModel, prompt: Text(spec.models.first ?? "Model name"))
                .textFieldStyle(.roundedBorder).onChange(of: model.keyModel) { model.keyFieldsChanged() }
        }
        Text(spec.limits).font(.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        // Shown before Connect: this is when resume text could start leaving the Mac.
        StatusLine(kind: .info, text: "Privacy: \(spec.privacyNote) Resume text and job posts go to \(spec.name) only after you connect.")
            .accessibilityIdentifier("key.privacy")
        if spec.pkceSignIn != nil {
            let brand = spec.name.components(separatedBy: " (")[0]
            if model.keySigningIn {
                ProgressRow(status: "Approve Offerlane in your browser. The key comes back here by itself.", fraction: nil,
                            label: "\(brand) sign-in") { model.cancelLongTask() }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Button("Sign In with \(brand)") { model.signInForKey() }.buttonStyle(.dsPrimary).accessibilityIdentifier("key.signIn")
                    Text("No copying: \(brand) sends Offerlane a key after you approve.")
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // The manual route stays one click away, so the sign-in button is the only thing to read first.
            if !showManual(spec) {
                Button("Get a key yourself instead") { manualKey = true }.buttonStyle(.link).accessibilityIdentifier("key.manual")
            } else { Divider() }
        }
        if showManual(spec) {
            DSStepper(steps: [.init(id: "key.step.get", title: "Get a key"), .init(id: "key.step.paste", title: "Paste it"),
                              .init(id: "key.step.connect", title: "Connect")],
                      current: step(spec)) { i in
                if i == 0, let url = spec.keyPageURL { openPage(url) } else if i == 1 { keyFocused = true } else if i == 2 { connect() }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(spec.steps.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1). \(step)").font(.callout)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("key.steps")
            if let url = spec.keyPageURL {
                HStack(alignment: .firstTextBaseline) {
                    Button("Open the \(spec.name) Key Page") { openPage(url) }.buttonStyle(.ds(.secondary)).accessibilityIdentifier("key.page")
                    Text("Opens in your browser. Copy the key, come back, and press ⌘V.").font(.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            SecureField("API key", text: $model.keyValue, prompt: Text("Paste the key"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.keyValue) { model.keyFieldsChanged() }
                .onSubmit { connect() }
                .focused($keyFocused)
                .accessibilityIdentifier("key.value")
            keyFormatLine(spec)
            HStack {
                Button("Connect") { connect() }
                    .buttonStyle(.dsPrimary)
                    .disabled(!spec.keyLooksValid(model.keyValue) || adapter.baseURL == nil || model.connectionTesting)
                    .accessibilityIdentifier("key.connect")
                if let step = model.keyStep { Text("Step: \(step.rawValue)…").font(.caption).foregroundStyle(DS.Palette.textSecondary) }
            }
        }
    }

    /// Sign-in providers hide the paste-a-key steps until asked (or a key is already there).
    private func showManual(_ spec: ProviderSpec) -> Bool { spec.pkceSignIn == nil || manualKey || !model.keyValue.isEmpty }

    @ViewBuilder private func keyFormatLine(_ spec: ProviderSpec) -> some View {
        if model.keyValue.isEmpty { EmptyView() }
        else if let owner = model.keyBelongsElsewhere {
            HStack {
                StatusLine(kind: .info, text: "This looks like a \(owner.name) key, not a \(spec.name) one.")
                Button("Use \(owner.name)") { model.moveKey(to: owner) }.accessibilityIdentifier("key.switch")
            }
        }
        else if spec.keyLooksValid(model.keyValue) {
            StatusLine(kind: .ok, text: "The key's format looks right. Connect to test it.").accessibilityIdentifier("key.format")
        } else {
            StatusLine(kind: .error, text: "That doesn't look like a \(spec.name) key. Copy the whole key again.").accessibilityIdentifier("key.format")
        }
    }

    private func connect() { Task { await model.testConnection() } }
}

private struct OllamaPanel: View {
    @Bindable var model: OnboardingModel
    @State private var removeModels = false
    @State private var modelToRemove: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = model.ollamaInstallProgress {
                ProgressRow(status: model.ollamaInstallStatus, fraction: p, label: "Ollama download progress") { model.cancelLongTask() }
            } else if let working = model.ollamaWorking {
                StatusLine(kind: .working, text: working)
            } else if !model.ollamaInstalled {
                HStack {
                    StatusLine(kind: .info, text: model.ollamaInstallPaused ? "The Ollama download was paused." : "Ollama isn't installed on this Mac.")
                    Spacer()
                    Button(model.ollamaInstallPaused ? "Resume Download" : "Install Ollama…") {
                        if model.ollamaInstallPaused { model.installOllama() } else { model.askOllamaInstall = true }
                    }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("ollama.install")
                }
            } else if !model.ollamaRunning {
                HStack {
                    StatusLine(kind: .info, text: "Ollama is installed but not running.")
                    Spacer()
                    Button("Start Ollama") { model.startOllama() }.buttonStyle(.borderedProminent)
                }
            } else {
                StatusLine(kind: .ok, text: "Ollama is running.")
                modelPicker
                if let p = model.ollamaPullProgress {
                    ProgressRow(status: model.ollamaPullStatus, fraction: p, label: "Model download progress") { model.cancelLongTask() }
                } else if model.ollamaHasModel {
                    HStack {
                        StatusLine(kind: .ok, text: "\(model.ollamaModel) is downloaded.")
                        Spacer()
                        if !model.aiReady { Button("Test") { Task { await model.testConnection() } } }
                    }
                } else {
                    HStack {
                        let choice = OllamaSetup.choices.first { $0.name == model.ollamaModel }
                        let fits = choice.map { OllamaSetup.fits($0, freeDisk: model.freeDisk) } ?? true
                        Text(downloadNote(choice, fits: fits)).font(.callout).foregroundStyle(fits ? Color.secondary : DS.Palette.warning)
                        Spacer()
                        Button(model.ollamaPausedModel == model.ollamaModel ? "Resume Download" : "Download Model") { model.pullOllamaModel() }
                            .buttonStyle(.borderedProminent).disabled(!fits).accessibilityIdentifier("ollama.pull")
                    }
                }
            }
            if let e = model.ollamaError { ErrorRow(text: e, action: "Try Again") { retry() } }
            Text("Your Mac has \(SystemCheck.ramBytes / 1_073_741_824) GB of memory and \(SystemCheck.gb(model.freeDisk)) free. Local models are slower than Claude, and tailoring quality is lower.")
                .font(.caption).foregroundStyle(DS.Palette.textSecondary)
            if model.ollamaInstalled && model.ollamaInstallProgress == nil && model.ollamaWorking == nil { manage }
        }
        .confirmationDialog("Install Ollama?", isPresented: $model.askOllamaInstall) {
            Button("Download and Install") { model.installOllama() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Offerlane will download Ollama (about 230 MB) from its official release, check it's genuine, put it in your Applications folder and start it.")
        }
        .confirmationDialog("Remove \(modelToRemove ?? "this model")?", isPresented: Binding(get: { modelToRemove != nil }, set: { if !$0 { modelToRemove = nil } })) {
            Button("Remove Model", role: .destructive) { if let m = modelToRemove { model.removeModel(m) }; modelToRemove = nil }
            Button("Cancel", role: .cancel) { modelToRemove = nil }
        } message: {
            Text("This frees its disk space. Using it again means downloading it again.")
        }
        .confirmationDialog("Remove Ollama?", isPresented: $model.askOllamaUninstall) {
            Button(removeModels ? "Remove Ollama and Models" : "Remove Ollama", role: .destructive) { model.uninstallOllama(removeModels: removeModels) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeModels ? "Ollama and its downloaded models go to the Trash." : "Ollama goes to the Trash. Downloaded models stay, in case you reinstall.")
        }
    }

    private var modelPicker: some View {
        Picker("Model", selection: $model.ollamaModel) {
            let rec = OllamaSetup.recommended(freeDisk: model.freeDisk)
            ForEach(OllamaSetup.choices) { c in
                Text("\(c.name) · \(c.note) · \(String(format: "%.1f", c.sizeGB)) GB\(c == rec ? " (recommended)" : "")").tag(c.name)
            }
            let extra = model.ollamaModels.filter { m in !OllamaSetup.choices.contains { $0.name == m || $0.name + ":latest" == m } }
            if !extra.isEmpty {
                Divider()
                ForEach(extra, id: \.self) { Text("\($0) (already downloaded)").tag($0) }
            }
        }
        .onChange(of: model.ollamaModel) { model.connectedProvider = nil }
    }

    private func downloadNote(_ c: OllamaSetup.ModelChoice?, fits: Bool) -> String {
        guard let c else { return "Downloads the model once." }
        if !fits { return "Needs \(SystemCheck.gb(c.sizeBytes + OllamaSetup.diskMargin)) free. Pick a smaller model or free some space." }
        return model.ollamaPausedModel == c.name ? "Paused. It continues where it stopped." : "Downloads \(String(format: "%.1f", c.sizeGB)) GB once."
    }

    private func retry() {
        if !model.ollamaInstalled { model.installOllama() }
        else if !model.ollamaRunning { model.startOllama() }
        else if !model.ollamaHasModel { model.pullOllamaModel() }
        else { Task { await model.testConnection() } }
    }

    private var manage: some View {
        DisclosureGroup("Manage Ollama") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.ollamaModels, id: \.self) { m in
                    HStack {
                        Text(m).font(.callout)
                        Spacer()
                        Button("Remove") { modelToRemove = m }.accessibilityIdentifier("ollama.remove.\(m)")
                    }
                }
                if model.ollamaModels.isEmpty && model.ollamaRunning { Text("No models downloaded.").font(.callout).foregroundStyle(DS.Palette.textSecondary) }
                Divider()
                HStack {
                    Toggle("Also remove downloaded models", isOn: $removeModels).toggleStyle(.checkbox)
                    Spacer()
                    Button("Uninstall Ollama…", role: .destructive) { model.askOllamaUninstall = true }.accessibilityIdentifier("ollama.uninstall")
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }
}
