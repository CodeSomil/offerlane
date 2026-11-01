import SwiftUI
import SwiftTerm
import OfferlaneCore

/// Runs `claude auth login` in an embedded terminal so Claude's own browser sign-in completes,
/// and closes by itself as soon as `claude auth status` reports a signed-in account.
struct ClaudeSignInSheet: View {
    let executable: URL
    let onDone: (ClaudeSetup.AuthStatus?) -> Void
    @State private var waiting = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Claude").font(.title2.bold())
            Text("Follow the prompts below. Your browser opens so you can sign in with your Claude account; this window closes by itself when you're done.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TerminalHost(executable: executable, args: ["auth", "login"])
                .frame(minWidth: 640, minHeight: 340)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Claude sign-in terminal")
            HStack {
                if waiting { StatusLine(kind: .working, text: "Waiting for you to finish signing in…") }
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let s = await ClaudeSetup.authStatus(executable), s.loggedIn { waiting = false; onDone(s); return }
            }
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let executable: URL, args: [String]
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 340))
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env.append("PATH=\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        env.append("HOME=\(home)")
        v.startProcess(executable: executable.path, args: args, environment: env, currentDirectory: NSTemporaryDirectory())
        return v
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) { nsView.terminate() }
}
