import Foundation
import OfferlaneCore

// offerlane-mcp: Offerlane's local MCP server for the user's own Claude app (stdio only: no network, no listening port).
//   offerlane-mcp [--account <id>]
// stdout carries only MCP messages; anything else goes to stderr (Claude keeps it in its MCP log).

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data(("offerlane-mcp: " + s + "\n").utf8)); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
var account: String?
if let i = args.firstIndex(of: "--account") {
    guard i + 1 < args.count else { fail("--account needs an id") }
    account = args[i + 1]
}

let server: MCPServer
do { server = MCPServer(store: try MCPServer.open(account: account)) } catch { fail(error.plainMessage) }

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let reply = await server.handle(line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
}
