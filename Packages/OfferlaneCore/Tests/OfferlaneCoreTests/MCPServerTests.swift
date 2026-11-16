import XCTest
import GRDB
@testable import OfferlaneCore

/// P1.3: the local MCP server. Read tools leak no secrets and change nothing; save_draft only reaches Review, and only via the Guard.
/// Shared temp home and seeded store for the MCP and Copy to Claude tests.
class MCPTestBase: XCTestCase {
    var home: URL!
    let plantedKey = "sk-or-v1-PLANTEDabcdefghijklmnop123456"
    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        setenv("OFFERLANE_HOME", home.path, 1)
    }
    override func tearDown() { Paths.account = nil; unsetenv("OFFERLANE_HOME"); try? FileManager.default.removeItem(at: home) }

    func makeStore(url: URL? = nil, key: Data? = nil) throws -> Store {
        let store = try Store(url: url, key: key)
        var r = ResumeContent(); r.name = "Alex Rivera"; r.email = "alex.rivera@example.com"; r.phone = "+44 7700 900123"; r.headline = "Data Scientist"
        r.topSkills = ["python", "sql"]
        r.experience = [.init(id: "e1", title: "Data Scientist", company: "Contoso", dates: "2019 - 2023",
                              bullets: [.init(id: "e1.1", text: "Built a forecasting model for 120 stores"), .init(id: "e1.2", text: "Led a team of 4 analysts")])]
        try store.saveResume(ResumeVersion(name: "main", label: "Main", content: r, sourceText: "", sourceFile: "cv.txt"))
        var p = Profile(); p.personal.email = "alex.rivera@example.com"; p.work.expectedSalary = "95000"; try store.set(.profile, p)
        var s = SearchConfig(); s.targetTitles = ["Data Scientist"]; try store.set(.search, s)
        var settings = AppSettings(); settings.notify.ntfyTopic = "secret-ntfy-topic-77"; try store.set(.settings, settings)
        for (i, st) in [JobStatus.found, .tailoring, .review, .ready, .applied].enumerated() {
            var j = Job(company: "Co\(i)", title: "Data Scientist", location: "London")
            j.description = "Python and SQL. Contact hr@co\(i).example or call +44 20 7946 0000. Token \(plantedKey)."
            j.status = st; j.llmScore = 80 - i; try store.save(j)
        }
        return store
    }

}

final class MCPServerTests: MCPTestBase {
    func rpc(_ s: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Int = 1) async throws -> [String: Any] {
        let line = MCPServer.json(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let reply = await s.handle(line)
        let out = try XCTUnwrap(reply)
        XCTAssertFalse(out.contains("\n"), "stdio messages are one line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }
    func call(_ s: MCPServer, _ tool: String, _ args: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
        let raw = try await rpc(s, "tools/call", ["name": tool, "arguments": args])
        let r = try XCTUnwrap(raw["result"] as? [String: Any])
        let text = ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, r["isError"] as? Bool ?? true)
    }

    func testLifecycleAndErrors() async throws {
        let s = MCPServer(store: try makeStore())
        let i0 = try await rpc(s, "initialize", ["protocolVersion": "2025-06-18"])
        let i = try XCTUnwrap(i0["result"] as? [String: Any])
        XCTAssertEqual(i["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((i["capabilities"] as? [String: Any])?["tools"])
        let o0 = try await rpc(s, "initialize", ["protocolVersion": "1999-01-01"])
        let other = try XCTUnwrap(o0["result"] as? [String: Any])
        XCTAssertEqual(other["protocolVersion"] as? String, "2025-06-18", "unsupported version: answer with one we support")
        let none = await s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(none)
        let bad = await s.handle("not json")
        XCTAssertTrue(bad?.contains("-32700") ?? false)
        let unknown = try await rpc(s, "resources/list"), apply = try await rpc(s, "tools/call", ["name": "apply_job"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((apply["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testOnlyTheseToolsExist() async throws {
        let s = MCPServer(store: try makeStore())
        let list = try await rpc(s, "tools/list")
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["profile_summary", "list_matches", "job_detail", "resume_bullets", "skill_gaps", "save_draft"])
        XCTAssertTrue(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
    }

    func testReadToolsLeakNothingAndChangeNothing() async throws {
        let store = try makeStore(), s = MCPServer(store: store)
        let before = try store.jobs().map { "\($0.id):\($0.status.rawValue)" }.sorted()
        let ids = try store.jobs().map(\.id)
        var outputs = [try await call(s, "profile_summary"), try await call(s, "list_matches"), try await call(s, "resume_bullets"),
                       try await call(s, "skill_gaps"), try await call(s, "list_matches", ["limit": 500])]
        for id in ids { outputs.append(try await call(s, "job_detail", ["job_id": id])) }
        for o in outputs {
            XCTAssertFalse(o.isError, o.text)
            for secret in [plantedKey, "PLANTED", "alex.rivera@example.com", "7700 900123", "secret-ntfy-topic-77", "95000", "hr@co"] {
                XCTAssertFalse(o.text.contains(secret), "\(secret) leaked: \(o.text.prefix(200))")
            }
        }
        XCTAssertTrue(outputs[1].text.contains("Co0"), "found roles are listed")
        XCTAssertFalse(outputs[1].text.contains("Co1"), "only roles waiting for a decision are matches")
        XCTAssertTrue(outputs[2].text.contains("e1.1: Built a forecasting model for 120 stores"), "bullets come through intact")
        XCTAssertTrue(outputs[2].text.contains("(2019 - 2023)"), "date ranges aren't mistaken for phone numbers")
        XCTAssertEqual(try store.jobs().map { "\($0.id):\($0.status.rawValue)" }.sorted(), before)
    }

    func testSaveDraftOnlyThroughGuardAndOnlyToReview() async throws {
        let store = try makeStore(), s = MCPServer(store: store)
        let jobs = try store.jobs()
        let byStatus = { (st: JobStatus) in jobs.first { $0.status == st }!.id }
        let good: [String: Any] = ["headline": "Data Scientist", "order": ["e1": ["e1.2", "e1.1"]],
                                   "rewrites": ["e1.1": "Built forecasting models for 120 stores"], "cover_letter": "I led a team of 4 analysts."]

        for st in [JobStatus.found, .ready, .applied] {
            var args = good; args["job_id"] = byStatus(st)
            let r = try await call(s, "save_draft", args)
            XCTAssertTrue(r.isError, "\(st) can't take a draft: that would approve or alter a sent application")
            XCTAssertEqual(try store.job(byStatus(st))?.status, st)
        }
        var invented = good; invented["job_id"] = byStatus(.tailoring); invented["rewrites"] = ["e1.1": "Built a model for 900 stores"]
        var r = try await call(s, "save_draft", invented)
        XCTAssertTrue(r.isError); XCTAssertTrue(r.text.contains("Nothing was saved"), r.text)
        var letter = good; letter["job_id"] = byStatus(.tailoring); letter["cover_letter"] = "I grew revenue 300%."
        r = try await call(s, "save_draft", letter)
        XCTAssertTrue(r.isError, "the cover letter is Guard-checked too")
        XCTAssertEqual(try store.job(byStatus(.tailoring))?.status, .tailoring)

        for st in [JobStatus.tailoring, .review] {
            var ok = good; ok["job_id"] = byStatus(st)
            r = try await call(s, "save_draft", ok)
            XCTAssertFalse(r.isError, r.text)
            let j = try XCTUnwrap(try store.job(byStatus(st)))
            XCTAssertEqual(j.status, .review, "a draft lands in Review, never further")
            XCTAssertTrue(j.changesSummary.hasPrefix("Drafted with Claude."))
        }
    }

    func testOpenStoreNeedsOptIn() throws {
        let root = home.appendingPathComponent("acct")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secrets = MemorySecrets()
        XCTAssertThrowsError(try MCPServer.openStore(root: root, secrets: secrets), "off by default")
        try Data().write(to: root.appendingPathComponent(MCPServer.markerName))
        XCTAssertThrowsError(try MCPServer.openStore(root: root, secrets: secrets), "no database: never created by the server")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("offerlane.sqlite").path))
        try Store(url: root.appendingPathComponent("offerlane.sqlite")).db.close()
        XCTAssertThrowsError(try MCPServer.openStore(root: root, secrets: secrets), "unencrypted: the app encrypts it first") {
            XCTAssertTrue($0.plainMessage.contains("Open Offerlane once"))
        }
        XCTAssertNil(secrets.get(account: Encryption.keyAccount), "the helper never makes a key")
        try Backup.openStore(root: root, secrets: secrets).db.close()   // the app opened it: now encrypted
        XCTAssertNoThrow(try MCPServer.openStore(root: root, secrets: secrets))
        XCTAssertThrowsError(try MCPServer.openStore(root: root, secrets: MemorySecrets()), "no key, no access") {
            XCTAssertTrue($0.plainMessage.contains("allow access"), "says the Keychain refused, not that data is lost")
        }
        try Data().write(to: root.appendingPathComponent(Backup.pendingName))
        XCTAssertThrowsError(try MCPServer.openStore(root: root, secrets: secrets), "a waiting restore is the app's job")
    }

    func testAccountDraftsLandInThatAccountsFolder() async throws {
        XCTAssertThrowsError(try MCPServer.open(account: "../x"))
        XCTAssertThrowsError(try MCPServer.open(account: "a/b"))
        let root = Paths.accountRoot("acct1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(MCPServer.markerName))
        let kc = Keychain(service: Paths.keychainService(for: "acct1")); defer { kc.deleteAll() }   // test-namespaced service
        let db = root.appendingPathComponent("offerlane.sqlite")
        let seeded = try makeStore(url: db, key: try Encryption.key(for: db, in: kc))
        let id = try XCTUnwrap(try seeded.jobs([.tailoring]).first?.id)
        let s = MCPServer(store: try MCPServer.open(account: "acct1"))
        let r = try await call(s, "save_draft", ["job_id": id, "headline": "Data Scientist"])
        XCTAssertFalse(r.isError, r.text)
        let folder = try XCTUnwrap(try seeded.job(id)?.folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Applications/\(folder)/plan.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Applications/\(folder)").path), "never the base folder")
    }

    func testHelperNeverMigrates() throws {
        let root = home.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(MCPServer.markerName))
        let db = root.appendingPathComponent("offerlane.sqlite")
        try DatabaseQueue(path: db.path).write { try $0.execute(sql: "CREATE TABLE t(x)") }   // a database the app never set up
        XCTAssertThrowsError(try MCPServer.openStore(root: root, secrets: MemorySecrets())) { XCTAssertTrue($0.plainMessage.contains("Open Offerlane once")) }
    }

    func testChangedRoleIsNeverOverwritten() async throws {
        let store = try makeStore()
        var j = try XCTUnwrap(try store.jobs([.tailoring]).first)
        let dir = Paths.applications.appendingPathComponent("kept", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "old".write(to: dir.appendingPathComponent("plan.json"), atomically: true, encoding: .utf8)
        try store.transition(j.id, to: .review, by: "tailor") { $0.folder = "kept"; $0.changesSummary = "the app's own draft" }
        j.folder = "kept"   // the caller still thinks the role is in tailoring
        let tailor = Tailor(store: store, ai: AI(client: FakeLLM(rules: []), store: nil))
        var plan = TailorPlan(); plan.headline = "Data Scientist"
        do { try await tailor.finish(j, plan: plan, version: try XCTUnwrap(try store.resume()), profile: Profile(), by: "claude"); XCTFail("overwrote a changed role") }
        catch { guard case StoreError.changed = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("plan.json"), encoding: .utf8), "old")
        XCTAssertEqual(try store.job(j.id)?.changesSummary, "the app's own draft")
        let left = try FileManager.default.contentsOfDirectory(atPath: Paths.applications.path).filter { $0.hasPrefix(".draft-") }
        XCTAssertEqual(left, [], "temp folders are cleaned up")
    }
}
