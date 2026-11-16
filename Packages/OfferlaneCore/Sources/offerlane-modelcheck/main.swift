import Foundation
import OfferlaneCore

// offerlane-modelcheck: runs the five-check qualification suite (ModelCheck) and writes models.json.
//   swift run offerlane-modelcheck --offline [--out models.json]
//   OFFERLANE_LIVE=1 OPENROUTER_API_KEY=… swift run offerlane-modelcheck [--models a/x,b/y] [--out models.json]
// Live mode costs money on the caller's OpenRouter credit. The key is read from the environment only, never stored or printed.

let args = CommandLine.arguments.dropFirst()
func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.index(after: $0) < args.endIndex ? args[args.index(after: $0)] : nil } }
let env = ProcessInfo.processInfo.environment
let out = URL(fileURLWithPath: value("--out") ?? "models.json")
let fixturesDir = URL(fileURLWithPath: value("--fixtures")
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Tests/OfferlaneCoreTests/Fixtures").standardized.path)

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }

let fixtures: ModelCheck.Fixtures
do { fixtures = try ModelCheck.fixtures(dir: fixturesDir) } catch { fail("Can't read fixtures at \(fixturesDir.path): \(error)") }

var reports: [ModelCheck.Report] = []
let mode: String
if args.contains("--offline") {
    mode = "offline"
    reports.append(await ModelCheck.run(ModelCheck.offlineModel, model: "offline-fake", fixtures: fixtures))
} else {
    guard env["OFFERLANE_LIVE"] == "1" else { fail("Live mode needs OFFERLANE_LIVE=1 (it spends OpenRouter credit). Use --offline otherwise.") }
    guard let key = env["OPENROUTER_API_KEY"], !key.isEmpty else { fail("Set OPENROUTER_API_KEY in the environment for live mode.") }
    mode = "live"
    let base = URL(string: "https://openrouter.ai/api/v1")!
    let picks = ((try? ProviderRegistry.load(refreshed: nil)) ?? []).first { $0.id == "openrouter" }?.picks ?? []
    var ids: [String] = []
    for id in value("--models")?.split(separator: ",").map(String.init) ?? picks.flatMap({ [$0.id] + ($0.fast.map { [$0] } ?? []) }) where !ids.contains(id) { ids.append(id) }
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("offerlane-modelcheck-prices.json")
    let prices = await OpenRouterCatalog.models(baseURL: base, cache: cache)
    for id in ids {
        // Every request carries the D6 provider block (OpenAICompatibleClient adds it for openrouter.ai).
        let client = OpenAICompatibleClient(baseURL: base, modelFast: id, modelSmart: id, apiKey: key, name: "OpenRouter")
        var r = await ModelCheck.run(client, model: id, fixtures: fixtures)
        if let p = prices.first(where: { $0.id == id }), let i = p.inPerM, let o = p.outPerM {
            r.usd = (Double(r.tokensIn) * i + Double(r.tokensOut) * o) / 1_000_000
        }
        reports.append(r)
    }
}

struct Output: Encodable { var generatedAt: Date; var mode: String; var models: [ModelCheck.Report] }
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
do { try enc.encode(Output(generatedAt: Date(), mode: mode, models: reports)).write(to: out, options: .atomic) } catch { fail("Can't write \(out.path): \(error)") }
for r in reports {
    print("\(r.pass ? "PASS" : "FAIL") \(r.model)" + (r.usd.map { String(format: " $%.4f", $0) } ?? ""))
    for c in r.checks { print("  \(c.pass ? "ok  " : "FAIL") \(c.name): \(c.detail)") }
}
exit(reports.allSatisfy(\.pass) ? 0 : 1)
