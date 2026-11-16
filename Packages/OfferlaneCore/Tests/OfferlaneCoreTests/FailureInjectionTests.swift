import GRDB
import XCTest
@testable import OfferlaneCore

/// One place that injects each failure the app must survive and checks the user gets a cause plus a next step.
final class FailureInjectionTests: XCTestCase {
    func testDiskFullKeepsSavedDataAndSaysHowToFix() throws {
        let s = try Store()
        var p = Profile(); p.personal.fullName = "Ada"
        try s.set(.profile, p)
        let pages = try s.db.read { try Int.fetchOne($0, sql: "PRAGMA page_count") ?? 0 }
        try s.db.writeWithoutTransaction { try $0.execute(sql: "PRAGMA max_page_count = \(pages)") }  // the "disk" is now full
        var big = p; big.personal.fullName = String(repeating: "x", count: 200_000)
        XCTAssertThrowsError(try s.set(.profile, big)) { error in
            XCTAssertTrue(error.isDiskFull)
            XCTAssertTrue(error.plainMessage.contains("disk is full") && error.plainMessage.contains("Free some space"))
        }
        XCTAssertEqual(try s.profile().personal.fullName, "Ada", "the failed write didn't damage what was saved")
    }

    func testDiskFullFromFileWritesIsRecognised() {
        XCTAssertTrue(CocoaError(.fileWriteOutOfSpace).isDiskFull)
        XCTAssertTrue(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)).isDiskFull)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(wrapped.isDiskFull)
        XCTAssertFalse(CocoaError(.fileNoSuchFile).isDiskFull)
        XCTAssertEqual(StoreError.missingJob("x").plainMessage, StoreError.missingJob("x").localizedDescription)
    }

    // MARK: AI provider failures, injected at the network layer of a real key client

    private func client(_ mode: FailingURL.Mode) -> OpenAICompatibleClient {
        FailingURL.mode = mode
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [FailingURL.self]
        return OpenAICompatibleClient(baseURL: URL(string: "https://api.example.test/v1")!, modelFast: "m", modelSmart: "m",
                            apiKey: "sk-test", name: "Example AI", session: URLSession(configuration: c))
    }
    private func failure(_ mode: FailingURL.Mode) async -> String {
        do { _ = try await client(mode).complete(LLMRequest(prompt: "p")); XCTFail("expected a failure"); return "" }
        catch { return error.plainMessage }
    }

    func testEachProviderFailureSaysCauseAndNextStep() async {
        let cases: [(FailingURL.Mode, cause: String, fix: String)] = [
            (.offline, "Can't reach Example AI", "internet connection"),
            (.status(401), "refused the API key", "paste it again"),
            (.status(429), "rate limit", "Settings → AI"),
            (.status(503), "having problems", "Try again in a few minutes"),
            (.status(400), "refused the request", "Settings → AI"),
            (.body("<html>oops"), "couldn't read", "Try again"),
        ]
        for (mode, cause, fix) in cases {
            let text = await failure(mode)
            XCTAssertTrue(text.contains(cause) && text.contains(fix), "\(mode): \(text)")
            XCTAssertFalse(text.contains("sk-test"), "never shows the key")
        }
    }

    func testProviderDownEverywhereEndsWithAClearMessage() async {
        let a = ScriptedClient("A", errors: Array(repeating: .http(503, "down"), count: 3))
        let b = ScriptedClient("B", errors: Array(repeating: .unreachable("Can't reach B. Check your internet connection."), count: 3))
        do { _ = try await ResilientClient(chain: [a, b], sleep: { _ in }).complete(LLMRequest(prompt: "p")); XCTFail() }
        catch { XCTAssertFalse(error.plainMessage.isEmpty); XCTAssertTrue(error.plainMessage.contains("Check") || error.plainMessage.contains("Try again"), error.plainMessage) }
    }
    // Malformed AI output (prose, fences, truncation): LLMTests.testDecodeTolerates… and testTruncatedJSON….
}

/// Fails every request the way the chosen mode says.
final class FailingURL: URLProtocol, @unchecked Sendable {
    enum Mode { case offline, status(Int), body(String) }
    nonisolated(unsafe) static var mode = Mode.offline
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (code, body): (Int, String)
        switch Self.mode {
        case .offline: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        case .status(let c): (code, body) = (c, "{\"error\":\"x\"}")
        case .body(let b): (code, body) = (200, b)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
