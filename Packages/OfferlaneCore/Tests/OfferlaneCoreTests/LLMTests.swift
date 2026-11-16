import XCTest
@testable import OfferlaneCore

final class LLMTests: XCTestCase {
    struct OK: Decodable, Equatable { var ok: Bool }

    func testDecodeToleratesFencesAndProse() throws {
        XCTAssertEqual(try AI.decode("```json\n{\"ok\": true}\n```", as: OK.self), OK(ok: true))
        XCTAssertEqual(try AI.decode("Sure! Here it is: {\"ok\": false} Hope that helps.", as: OK.self), OK(ok: false))
        XCTAssertEqual(try AI.decode("Result: [{\"ok\": true}]", as: [OK].self), [OK(ok: true)])
        XCTAssertThrowsError(try AI.decode("nope", as: OK.self))
        XCTAssertEqual(try AI.decode("Thinking: weigh {skills} and {pay} first.\n{\"ok\": true}", as: OK.self), OK(ok: true), "braces in thinking text")
    }

    func testTruncatedJSONIsRepairedOrReportedPlainly() async throws {
        let fixed = AI(client: FakeLLM(rules: [{ r in r.prompt.hasPrefix(AI.repairPrompt) ? "{\"ok\": true}" : "{\"ok\": tr" }]), store: nil)
        let v: OK = try await fixed.json(LLMRequest(prompt: "x")); XCTAssertEqual(v, OK(ok: true))
        let cut = AI(client: FakeLLM(rules: [{ _ in "{\"ok\": tr" }]), store: nil)
        do { let _: OK = try await cut.json(LLMRequest(prompt: "x")); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("couldn't be read")); XCTAssertFalse(error.localizedDescription.contains("{"))
        }
    }

    func testOneRepairRetryThenFail() async throws {
        actor Count { var n = 0; func inc() -> Int { n += 1; return n } }
        let c = Count()
        let flaky = FakeLLM(rules: [{ _ in nil }])
        _ = flaky
        struct Flaky: LLMClient {
            let c: Count
            var displayName: String { "flaky" }; var billed: Bool { false }
            func complete(_ r: LLMRequest) async throws -> LLMResponse {
                let n = await c.inc()
                return LLMResponse(text: n == 1 ? "garbage" : "{\"ok\": true}")
            }
        }
        let store = try Store()
        let ai = AI(client: Flaky(c: c), store: store)
        let v: OK = try await ai.json(LLMRequest(prompt: "x"))
        XCTAssertEqual(v, OK(ok: true)); XCTAssertEqual(ai.callsThisRun, 2)
        XCTAssertEqual(try store.usage().first?.calls, 2, "every call is metered")

        let never = AI(client: FakeLLM(rules: [{ _ in "still not json" }]), store: nil)
        do { let _: OK = try await never.json(LLMRequest(prompt: "x")); XCTFail() } catch let e as LLMError {
            if case .badJSON = e {} else { XCTFail("\(e)") }
        }
    }

    func testClaudeCLIArgumentsAndParsing() throws {
        let c = ClaudeCLIClient(executable: URL(fileURLWithPath: "/bin/echo"))
        let args = c.arguments(model: "haiku", systemFile: URL(fileURLWithPath: "/tmp/s.txt"))
        for flag in ["-p", "--output-format", "--tools", "--strict-mcp-config", "--setting-sources", "--no-session-persistence", "--system-prompt-file"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        let ok = try ClaudeCLIClient.parse(stdout: "noise\n{\"type\":\"result\",\"is_error\":false,\"result\":\"{\\\"ok\\\":true}\",\"usage\":{\"input_tokens\":12,\"output_tokens\":5,\"cache_read_input_tokens\":100}}",
                                           stderr: "", model: "haiku")
        XCTAssertEqual(ok.text, "{\"ok\":true}"); XCTAssertEqual(ok.usage.cacheRead, 100); XCTAssertEqual(ok.usd, 0)
        XCTAssertThrowsError(try ClaudeCLIClient.parse(stdout: "{\"is_error\":true,\"result\":\"Claude AI usage limit reached|1793500000\"}", stderr: "", model: "haiku")) {
            guard case LLMError.usageLimit = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue($0.localizedDescription.contains("usage limit"))
        }
        XCTAssertThrowsError(try ClaudeCLIClient.parse(stdout: "{\"is_error\":true,\"result\":\"Invalid API key · Please run /login\"}", stderr: "", model: "haiku")) {
            guard case LLMError.notSignedIn = $0 else { return XCTFail("\($0)") }
        }
    }

    func testClaudeCLIRunsAProcessWithStdin() async throws {
        // /bin/cat echoes stdin; feed it a result line to exercise the real subprocess path.
        let out = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), [], stdin: "{\"result\":\"hi\"}", timeout: 10)
        XCTAssertEqual(out.status, 0); XCTAssertEqual(out.stdout, "{\"result\":\"hi\"}")
    }

    func testAnthropicRequestBodyAndCost() throws {
        let c = AnthropicClient(apiKey: "sk-test")
        let b = c.body(LLMRequest(prompt: "p", system: "s", cache: "BANK", smart: true, maxTokens: 3500))
        XCTAssertEqual(b["model"] as? String, "claude-sonnet-5-5")
        XCTAssertNil(b["temperature"], "sampling params are rejected on the current API version")
        let sys = try XCTUnwrap(b["system"] as? [[String: Any]])
        XCTAssertEqual(sys.count, 2); XCTAssertEqual((sys[1]["cache_control"] as? [String: String])?["type"], "ephemeral")
        XCTAssertEqual((c.body(LLMRequest(prompt: "p"))["model"] as? String), "claude-haiku-5-5")
        XCTAssertEqual((c.body(LLMRequest(prompt: "p"))["system"] as? [[String: Any]])?.count, 1, "no empty cache block")

        let resp = """
        {"model":"claude-sonnet-5-5","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\\"ok\\":true}"}],
         "usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":0}}
        """
        let r = try AnthropicClient.parse(Data(resp.utf8))
        XCTAssertEqual(r.text, "{\"ok\":true}")
        XCTAssertEqual(r.usd, 2.0 + 0.2 + 1.0, accuracy: 1e-9)
    }

    func testLogRedaction() {
        XCTAssertEqual(Log.redact("mail me@x.com or +44 7700 900000 key sk-ant-abc_123"), "mail <email> or <phone> key <key>")
    }

    func testOllamaRequestSetsContextAndThinkPerRequest() throws {
        XCTAssertEqual(OllamaClient.contextLength(ramBytes: 8 << 30), 8192)
        XCTAssertEqual(OllamaClient.contextLength(ramBytes: 16 << 30), 16384)
        let c = OllamaClient(baseURL: URL(string: "http://localhost:11434/v1")!, modelFast: "small", modelSmart: "big", contextLength: 8192)
        let req = try c.request(LLMRequest(prompt: "hi", smart: true, maxTokens: 300))
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:11434/api/chat")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "big")
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, false)
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 8192)
        XCTAssertEqual(options["num_predict"] as? Int, 300)
        let noThink = try JSONSerialization.jsonObject(with: XCTUnwrap(c.request(LLMRequest(prompt: "hi"), sendThink: false).httpBody)) as? [String: Any]
        XCTAssertNil(noThink?["think"])
    }

    func testOllamaReplyAndErrors() async throws {
        MockReleaseServer.reset(); defer { MockReleaseServer.reset() }
        let session = URLSession(configuration: MockReleaseServer.config())
        let reply = #"{"message":{"role":"assistant","content":"<think>x</think>{\"ok\": true}"},"prompt_eval_count":12,"eval_count":3}"#
        MockReleaseServer.route("http://a.test/api/chat", .file(Data(reply.utf8)))
        let r = try await OllamaClient(baseURL: URL(string: "http://a.test")!, modelFast: "m", modelSmart: "m", session: session).complete(LLMRequest(prompt: "hi"))
        XCTAssertEqual(r.text, #"{"ok": true}"#)
        XCTAssertEqual(r.usage, LLMUsage(input: 12, output: 3))
        MockReleaseServer.route("http://b.test/api/chat", .status(404))
        do { _ = try await OllamaClient(baseURL: URL(string: "http://b.test")!, modelFast: "m", modelSmart: "m", session: session).complete(LLMRequest(prompt: "hi")); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Download it in Settings")) }
    }
}
