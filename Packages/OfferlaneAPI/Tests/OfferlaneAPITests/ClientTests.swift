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

/// SyncHTTP (P4.4b): the wire the Mac sync engine uses.
final class SyncHTTPTests: XCTestCase {
    private final class Flaky: ClientTransport, @unchecked Sendable {
        var sent: [HTTPRequest] = [], fails: Int
        let status: HTTPResponse.Status, json: String
        init(fails: Int, _ status: HTTPResponse.Status, _ json: String) { self.fails = fails; self.status = status; self.json = json }
        func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
            sent.append(request)
            if fails > 0 { fails -= 1; throw URLError(.networkConnectionLost) }
            return (HTTPResponse(status: status, headerFields: [.contentType: "application/json", HTTPField.Name("etag")!: #""v4""#, HTTPField.Name("www-authenticate")!: "Bearer"]), HTTPBody(json))
        }
    }
    private func sync(_ t: Flaky) -> SyncHTTP { SyncHTTP(client: .offerlane(serverURL: URL(string: "https://api.test")!, transport: t, token: { "tok" })) }

    func testPutRetriesANetworkFailureWithTheSameIdempotencyKey() async throws {
        let t = Flaky(fails: 2, .ok, #"{"version":4}"#)
        let r = try await sync(t).put("profile", expected: 3, keyId: "k1", ciphertext: Data([1, 2]))
        XCTAssertEqual(r, .ok(version: 4))
        XCTAssertEqual(t.sent.count, 3)
        let keys = Set(t.sent.map { $0.headerFields[HTTPField.Name("idempotency-key")!] })
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(t.sent[0].headerFields[HTTPField.Name("if-match")!], #""v3""#)
    }

    func testCreateConflictMissingAndErrors() async throws {
        let created = Flaky(fails: 0, .conflict, #"{"error":"conflict","version":1}"#)
        let r = try await sync(created).put("keyring", expected: nil, keyId: "rk-1", ciphertext: Data([1]))
        XCTAssertEqual(r, .conflict)
        XCTAssertEqual(created.sent[0].headerFields[HTTPField.Name("if-none-match")!], "*")
        let missing = try await sync(Flaky(fails: 0, .notFound, #"{"error":"not_found"}"#)).get("profile")
        XCTAssertNil(missing)
        let got = try await sync(Flaky(fails: 0, .ok, #"{"version":2,"keyId":"k1","ciphertext":"AQI="}"#)).get("resumes")
        XCTAssertEqual(got?.ciphertext, Data([1, 2]))
        do { _ = try await sync(Flaky(fails: 0, .unauthorized, #"{"error":"unauthorized"}"#)).me(); XCTFail() }
        catch let e as SyncHTTP.Failure { XCTAssertTrue(e.message.contains("expired")) }
        do { _ = try await sync(Flaky(fails: 3, .ok, "{}")).put("profile", expected: 1, keyId: "k", ciphertext: Data()); XCTFail() }
        catch let e as SyncHTTP.Failure { XCTAssertEqual(e, SyncHTTP.offline) }
        do { _ = try await sync(Flaky(fails: 0, .ok, "{}")).get("nope"); XCTFail() } catch {}
        let plain = SyncHTTP(client: .offerlane(serverURL: URL(string: "http://api.test")!, transport: Flaky(fails: 0, .ok, "{}"), token: { "tok" }))
        do { _ = try await plain.me(); XCTFail() } catch let e as SyncHTTP.Failure { XCTAssertTrue(e.message.contains("secure connection")) }
        do { _ = try await sync(Flaky(fails: 0, .ok, "{}")).get("profile"); XCTFail() }
        catch let e as SyncHTTP.Failure { XCTAssertEqual(e, SyncHTTP.unreadable, "a bad answer is not 'offline'") }
    }
}
