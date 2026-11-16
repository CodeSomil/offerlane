import SwiftUI
import AppKit
import OfferlaneCore

/// Settings → Use with Claude (Route A, D1). Off by default. Turning it on lets this profile's data be read by the
/// offerlane-mcp helper that the user's own Claude app starts. Steps checked 2026-11-11 against
/// modelcontextprotocol.io/docs/develop/connect-local-servers and code.claude.com/docs/en/mcp.
struct ClaudeSection: View {
    @State private var enabled = FileManager.default.fileExists(atPath: ClaudeSection.marker.path)
    @State private var copied: String?

    static var marker: URL { Paths.root.appendingPathComponent(MCPServer.markerName) }
    static var helper: String { Bundle.main.url(forAuxiliaryExecutable: "offerlane-mcp")?.path ?? "/Applications/Offerlane.app/Contents/MacOS/offerlane-mcp" }
    static var args: [String] { Paths.account.map { ["--account", $0] } ?? [] }

    static var desktopConfig: String {
        let obj: [String: Any] = ["mcpServers": ["offerlane": ["command": helper, "args": args]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
    static var codeCommand: String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return (["claude mcp add --transport stdio offerlane --", q(helper)] + args.map(q)).joined(separator: " ")
    }

    var body: some View {
        SectionCard(title: "Use with Claude", subtitle: "Your own Claude app reads your matches and drafts resumes for you to review.", symbol: "bubble.left.and.text.bubble.right") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Let my Claude app read my matches and save drafts", isOn: $enabled)
                    .onChange(of: enabled) { _, on in set(on) }
                    .accessibilityIdentifier("claude.enable")
                Text("Claude can read your matches, roles, resume bullets and skill gaps, and save a draft to Review. It can't approve, apply, send or delete anything, and drafts with numbers that aren't in your resume are refused. What Claude reads goes to Anthropic under your Claude plan's terms.")
                    .font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if enabled {
                    Text("Claude desktop app").font(DS.Font.headline)
                    Text("1. In the menu bar, choose Claude → Settings…, open Developer, then click Edit Config.\n2. Add the lines below to claude_desktop_config.json (merge them into “mcpServers” if it's already there).\n3. Quit Claude completely and open it again.")
                        .font(DS.Font.callout).fixedSize(horizontal: false, vertical: true)
                    snippet(Self.desktopConfig, id: "desktop")
                    Text("Claude Code").font(DS.Font.headline)
                    snippet(Self.codeCommand, id: "code")
                    Text("Then ask Claude, for example: “Show my best Offerlane matches and draft a resume for the top one.”")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
    }

    private func snippet(_ text: String, id: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(copied == id ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = id
            }.buttonStyle(.dsSecondary).accessibilityIdentifier("claude.copy.\(id)")
        }
        .padding(DS.Space.m).background(DS.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.m))
    }

    private func set(_ on: Bool) {
        if on { FileManager.default.createFile(atPath: Self.marker.path, contents: Data()) }
        else { try? FileManager.default.removeItem(at: Self.marker) }
    }
}
