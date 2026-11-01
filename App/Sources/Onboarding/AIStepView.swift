import SwiftUI
import OfferlaneCore

struct AIStepView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Choose your AI", subtitle: "Offerlane uses an AI to read your resume, score roles and tailor applications. You can change this later in Settings.")
            HStack(alignment: .top, spacing: 14) {
                ProviderCard(selected: model.provider == .claudeCLI, symbol: "person.crop.circle.badge.checkmark", title: "Claude account",
                             detail: "Sign in with your Claude Pro or Max plan. No API key needed.", badge: "Recommended") { select(.claudeCLI) }
                    .accessibilityIdentifier("provider.claude")
                ProviderCard(selected: model.provider == .anthropic, symbol: "key", title: "Claude API key",
                             detail: "Pay per use with a key from the Claude Console.", badge: nil) { select(.anthropic) }
                    .accessibilityIdentifier("provider.api")
                ProviderCard(selected: model.provider == .ollama, symbol: "desktopcomputer", title: "Ollama",
                             detail: "Free and private: runs on this Mac. Slower, and needs a few GB of disk.", badge: "Free") { select(.ollama) }
                    .accessibilityIdentifier("provider.ollama")
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.provider {
                    case .claudeCLI: ClaudePanel(model: model)
                    case .anthropic: APIKeyPanel(model: model)
                    case .ollama: OllamaPanel(model: model)
                    case .none: EmptyView()
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

    private func select(_ p: AppSettings.Provider) {
        guard model.provider != p else { return }
        model.provider = p; model.providerChanged()
    }

    @ViewBuilder private var connectionStatus: some View {
        if AppModel.isUITest { StatusLine(kind: .ok, text: "Connected (test AI)") }
        else if model.connectionTesting { StatusLine(kind: .working, text: "Testing the connection…") }
        else if model.aiReady { StatusLine(kind: .ok, text: "Connected" + (model.connectedSeconds.map { String(format: " · answered in %.1f s", $0) } ?? "")) }
        else if let e = model.connectionError {
            HStack { StatusLine(kind: .error, text: e); Spacer(); Button("Try Again") { Task { await model.testConnection() } } }
        } else { StatusLine(kind: .info, text: "Not connected yet.") }
    }
}

private struct ProviderCard: View {
    let selected: Bool, symbol: String, title: String, detail: String, badge: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
                    Spacer()
                    if let badge { Text(badge).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor.opacity(0.15), in: Capsule()) }
                }
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ClaudePanel: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude subscriptions work only through Claude's own apps, so Offerlane uses the official Claude Code tool as a bridge. Calls count toward your plan's usage limits.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.claudeChecking && model.claudeExe == nil {
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
                HStack { StatusLine(kind: .working, text: "Installing Claude Code…"); Spacer(); Button("Cancel") { model.cancelLongTask() } }
                if !model.claudeInstallLog.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView { Text(model.claudeInstallLog).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(maxHeight: 120)
                    }
                }
            } else {
                HStack {
                    StatusLine(kind: .info, text: "Claude Code isn't installed on this Mac yet.")
                    Spacer()
                    Button("Install") { model.installClaude() }.buttonStyle(.borderedProminent).accessibilityIdentifier("claude.install")
                }
                if let e = model.claudeError { StatusLine(kind: .error, text: e) }
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
                    .font(.callout).foregroundStyle(.secondary)
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
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct OllamaPanel: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = model.ollamaInstallProgress {
                HStack { Text("Downloading Ollama…"); Spacer(); Button("Cancel") { model.cancelLongTask() } }
                ProgressView(value: p).accessibilityLabel("Ollama download progress")
            } else if !model.ollamaInstalled {
                HStack {
                    StatusLine(kind: .info, text: "Ollama isn't installed on this Mac.")
                    Spacer()
                    Button("Install Ollama…") { model.askOllamaInstall = true }.buttonStyle(.borderedProminent)
                }
            } else if !model.ollamaRunning {
                HStack {
                    StatusLine(kind: .info, text: "Ollama is installed but not running.")
                    Spacer()
                    Button("Start Ollama") { model.startOllama() }.buttonStyle(.borderedProminent)
                }
            } else {
                StatusLine(kind: .ok, text: "Ollama is running.")
                Picker("Model", selection: $model.ollamaModel) {
                    ForEach(OllamaSetup.choices) { c in
                        Text("\(c.name) · \(c.note) · \(String(format: "%.1f", c.sizeGB)) GB\(c == OllamaSetup.recommended() ? " (recommended)" : "")").tag(c.name)
                    }
                    let extra = model.ollamaModels.filter { m in !OllamaSetup.choices.contains { $0.name == m || $0.name + ":latest" == m } }
                    if !extra.isEmpty {
                        Divider()
                        ForEach(extra, id: \.self) { Text("\($0) (already downloaded)").tag($0) }
                    }
                }
                .onChange(of: model.ollamaModel) { model.connectedProvider = nil }
                if let p = model.ollamaPullProgress {
                    HStack { Text(model.ollamaPullStatus.capitalized).font(.callout); Spacer(); Text("\(Int(p * 100))%").monospacedDigit(); Button("Cancel") { model.cancelLongTask() } }
                    ProgressView(value: p).accessibilityLabel("Model download progress")
                } else if model.ollamaHasModel {
                    HStack {
                        StatusLine(kind: .ok, text: "\(model.ollamaModel) is downloaded.")
                        Spacer()
                        if !model.aiReady { Button("Test") { Task { await model.testConnection() } } }
                    }
                } else {
                    HStack {
                        let size = OllamaSetup.choices.first { $0.name == model.ollamaModel }?.sizeGB
                        Text(size.map { "Downloads \(String(format: "%.1f", $0)) GB once." } ?? "Downloads the model once.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Download Model") { model.pullOllamaModel() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            if let e = model.ollamaError { StatusLine(kind: .error, text: e) }
            Text("Your Mac has \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB of memory. Local models are slower than Claude, and tailoring quality is lower.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Install Ollama?", isPresented: $model.askOllamaInstall) {
            Button("Download and Install") { model.installOllama() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Offerlane will download Ollama (about 230 MB) from ollama.com, put it in your Applications folder and start it.")
        }
    }
}
