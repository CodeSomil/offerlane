import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import OfferlaneAPI

/// Canned server: answers by operation id and records what the client sent.
private final class Stub: ClientTransport, @unchecked Sendable {
    var sent: [HTTPRequest] = []
    let answers: [String: (HTTPResponse.Status, String, HTTPFields)]
    init(_ answers: [String: (HTTPResponse.Status, String, HTTPFields)]) { self.answers = answers }
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        sent.append(request)
        let (status, json, extra) = answers[operationID]!
        var fields = extra
        fields[.contentType] = "application/json"
        return (HTTPResponse(status: status, headerFields: fields), HTTPBody(json))
    }
}

final class ClientTests: XCTestCase {
    private func client(_ stub: Stub) -> Client {
        .offerlane(serverURL: URL(string: "https://api.test")!, transport: stub, token: { "tok" })
    }

    func testMeSendsTheBearerToken() async throws {
        let stub = Stub(["getMe": (.ok, #"{"id":"u1"}"#, [:])])
        let me = try await client(stub).getMe().ok.body.json
        XCTAssertEqual(me.id, "u1")
        XCTAssertEqual(stub.sent.first?.headerFields[.authorization], "Bearer tok")
        XCTAssertEqual(stub.sent.first?.path, "/v1/me")
    }

    func testNoTokenOnHealthOrOverCleartext() async throws {
        let stub = Stub(["health": (.ok, #"{"ok":true}"#, [:]), "ready": (.serviceUnavailable, #"{"error":"not_ready"}"#, [:]),
                         "getMe": (.ok, #"{"id":"u1"}"#, [:])])
        _ = try await client(stub).health().ok
        let notReady = try await client(stub).ready().serviceUnavailable.body.json.error
        XCTAssertEqual(notReady, .notReady)
        XCTAssertNil(stub.sent[0].headerFields[.authorization])
        XCTAssertNil(stub.sent[1].headerFields[.authorization])
        let plain = Client.offerlane(serverURL: URL(string: "http://api.test")!, transport: stub, token: { "tok" })
        do { _ = try await plain.getMe(); XCTFail("sent a token over http") } catch {}
        XCTAssertEqual(stub.sent.count, 2)
    }

    func testSyncBlobAndConflict() async throws {
        let stub = Stub([
            "getSync": (.ok, #"{"version":3,"keyId":"k1","ciphertext":"b3BhcXVl"}"#, [HTTPField.Name("etag")!: #""v3""#]),
            "putSync": (.conflict, #"{"error":"conflict","version":3}"#, [:]),
        ])
        let c = client(stub)
        let got = try await c.getSync(path: .init(kind: .profile)).ok
        XCTAssertEqual(got.headers.etag, #""v3""#)
        XCTAssertEqual(try got.body.json.version, 3)
        let put = try await c.putSync(path: .init(kind: .profile), headers: .init(ifMatch: #""v2""#), body: .json(.init(keyId: "k1", ciphertext: "b3BhcXVl")))
        XCTAssertEqual(try put.conflict.body.json.version, 3)
        XCTAssertEqual(stub.sent.last?.headerFields[HTTPField.Name("if-match")!], #""v2""#) // literal, not %22v2%22
        _ = try await c.putSync(path: .init(kind: .profile), headers: .init(ifNoneMatch: .init(rawValue: "*")!, idempotencyKey: #"a%b"c"#),
                                body: .json(.init(keyId: "k1", ciphertext: "b3BhcXVl")))
        XCTAssertEqual(stub.sent.last?.headerFields[HTTPField.Name("if-none-match")!], "*")
        XCTAssertEqual(stub.sent.last?.headerFields[HTTPField.Name("idempotency-key")!], #"a%b"c"#)
    }

    func testJobsPageWithNullDate() async throws {
        let job = #"{"id":"1","ats":"greenhouse","title":"Engineer","company":"Acme","location":"Remote","remote":true,"url":"https://x","applyUrl":"https://x","description":"d","postedAt":null}"#
        let stub = Stub(["listJobs": (.ok, #"{"items":[\#(job)],"next":"abc"}"#, [:])])
        let page = try await client(stub).listJobs(query: .init(remote: true, limit: 1)).ok.body.json
        XCTAssertEqual(page.items.first?.ats, .greenhouse)
        XCTAssertNil(page.items.first?.postedAt)
        XCTAssertEqual(page.next, "abc")
        XCTAssertEqual(stub.sent.first?.path, "/v1/jobs?remote=true&limit=1")
    }

    func testRateLimitedCarriesRetryAfter() async throws {
        let stub = Stub(["getMe": (.tooManyRequests, #"{"error":"rate_limited"}"#, [HTTPField.Name("retry-after")!: "7"])])
        let r = try await client(stub).getMe()
        guard case .tooManyRequests(let limited) = r else { return XCTFail("expected 429, got \(r)") }
        XCTAssertEqual(limited.headers.retryAfter, "7")
    }
}
