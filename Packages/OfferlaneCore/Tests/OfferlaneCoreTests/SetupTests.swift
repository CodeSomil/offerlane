import XCTest
import CryptoKit
@testable import OfferlaneCore

/// A fake release server: plays the official download hosts so the installers can be tested offline,
/// including redirects, resume (Range), dropped connections, bad checksums and slow responses.
final class MockReleaseServer: URLProtocol, @unchecked Sendable {
    enum Route {
        case file(Data, etag: String? = nil, ranges: Bool = true, dropAfter: Int? = nil, chunkDelay: useconds_t = 0)
        case redirect(String)
        case status(Int)
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var log: [(url: String, range: String?)] = []
    static func reset() { lock.withLock { routes = [:]; log = [] } }
    static func route(_ url: String, _ r: Route) { lock.withLock { routes[url] = r } }
    static var requests: [(url: String, range: String?)] { lock.withLock { log } }
    static func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockReleaseServer.self]; return c
    }

    private let stopped = Box(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped.value = true }

    override func startLoading() {
        let url = request.url!, key = url.absoluteString
        let range = request.value(forHTTPHeaderField: "Range")
        let route = Self.lock.withLock { () -> Route? in Self.log.append((key, range)); return Self.routes[key] }
        DispatchQueue.global().async { [self] in
            func respond(_ status: Int, _ headers: [String: String]) {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                                    cacheStoragePolicy: .notAllowed)
            }
            switch route {
            case nil, .status?:
                var code = 404; if case .status(let c)? = route { code = c }
                respond(code, [:]); client?.urlProtocolDidFinishLoading(self)
            case .redirect(let to)?:
                let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: to)!), redirectResponse: resp)
            case .file(let body, let etag, let ranges, let dropAfter, let delay)?:
                var start = 0
                var headers = etag.map { ["ETag": $0] } ?? [:]
                if ranges, let range, let n = Int(range.dropFirst(6).dropLast()), n <= body.count {
                    start = n
                    headers["Content-Range"] = "bytes \(n)-\(body.count - 1)/\(body.count)"
                    headers["Content-Length"] = "\(body.count - n)"
                    respond(206, headers)
                } else {
                    headers["Content-Length"] = "\(body.count)"
                    respond(200, headers)
                }
                var sent = 0, i = start
                while i < body.count {
                    if stopped.value { return }
                    let end = min(i + 64 << 10, body.count)
                    if let dropAfter, sent + (end - i) > dropAfter {
                        client?.urlProtocol(self, didLoad: body.subdata(in: i..<(i + dropAfter - sent)))
                        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
                    }
                    client?.urlProtocol(self, didLoad: body.subdata(in: i..<end)); sent += end - i; i = end
                    if delay > 0 { usleep(delay) }
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
}

final class SetupTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        MockReleaseServer.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("offerlane-setup-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func downloader(_ policy: DownloadPolicy = .installers) -> SafeDownloader {
        SafeDownloader(policy: policy, directory: dir.appendingPathComponent("dl"), configuration: MockReleaseServer.config())
    }
    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    static func blob(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }
    func leftovers() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("dl").path)) ?? [] }

    // MARK: policy

    func testPolicyAllowsOnlyHTTPSAllowlistedHosts() {
        let p = DownloadPolicy.installers
        XCTAssertTrue(p.allows(URL(string: "https://downloads.claude.ai/claude-code-releases/latest")))
        XCTAssertTrue(p.allows(URL(string: "https://GitHub.com/ollama/ollama/releases/download/v1/x.zip")))
        XCTAssertFalse(p.allows(URL(string: "http://downloads.claude.ai/latest")), "plain HTTP")
        XCTAssertFalse(p.allows(URL(string: "https://downloads.claude.ai.evil.example/latest")), "look-alike host")
        XCTAssertFalse(p.allows(URL(string: "https://evil.example/?u=https://github.com")))
        XCTAssertFalse(p.allows(URL(string: "https://user:pw@github.com/x")), "credentials in URL")
        XCTAssertFalse(p.allows(URL(string: "file:///etc/passwd")))
        XCTAssertFalse(p.allows(nil))
    }

    // MARK: downloader

    func testDownloadVerifiesChecksumAndReportsProgress() async throws {
        let body = Self.blob(1_500_000)
        MockReleaseServer.route("https://github.com/a/b.zip", .file(body))
        let seen = Box<Int64>(0)
        let file = try await downloader().download(URL(string: "https://github.com/a/b.zip")!, name: "b.zip", sha256: Self.sha(body),
                                                   expectedSize: Int64(body.count)) { done, _ in seen.value = done }
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(seen.value, Int64(body.count))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(leftovers(), [], "no partial or etag files left behind")
    }

    func testChecksumMismatchDeletesTheFile() async throws {
        MockReleaseServer.route("https://github.com/a/b.zip", .file(Self.blob(300_000)))
        do {
            _ = try await downloader().download(URL(string: "https://github.com/a/b.zip")!, name: "b.zip", sha256: String(repeating: "0", count: 64))
            XCTFail("tampered download accepted")
        } catch { XCTAssertEqual(error as? DownloadError, .checksumMismatch) }
        XCTAssertEqual(leftovers(), [], "rejected bytes are deleted")
    }

    func testRedirectToUnlistedHostIsBlocked() async throws {
        MockReleaseServer.route("https://github.com/a/b.zip", .redirect("https://evil.example/b.zip"))
        MockReleaseServer.route("https://evil.example/b.zip", .file(Data("evil".utf8)))
        do {
            _ = try await downloader().download(URL(string: "https://github.com/a/b.zip")!, name: "b.zip", sha256: Self.sha(Data("evil".utf8)))
            XCTFail("redirect off the allowlist followed")
        } catch { XCTAssertEqual(error as? DownloadError, .blockedHost("evil.example")) }
        XCTAssertFalse(MockReleaseServer.requests.contains { $0.url.contains("evil.example") }, "the unlisted host is never contacted")
        do {
            _ = try await downloader().data(URL(string: "https://github.com/a/b.zip")!)
            XCTFail("redirect off the allowlist followed")
        } catch { XCTAssertEqual(error as? DownloadError, .blockedHost("evil.example")) }
    }

    func testRedirectToHTTPIsBlockedAndAllowlistedRedirectWorks() async throws {
        let body = Self.blob(10_000)
        MockReleaseServer.route("https://github.com/a/plain", .redirect("http://release-assets.githubusercontent.com/x"))
        MockReleaseServer.route("https://github.com/a/ok", .redirect("https://release-assets.githubusercontent.com/x"))
        MockReleaseServer.route("https://release-assets.githubusercontent.com/x", .file(body))
        do { _ = try await downloader().data(URL(string: "https://github.com/a/plain")!); XCTFail("downgraded to HTTP") }
        catch { XCTAssertEqual(error as? DownloadError, .blockedHost("release-assets.githubusercontent.com")) }
        let file = try await downloader().download(URL(string: "https://github.com/a/ok")!, name: "ok", sha256: Self.sha(body))
        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    func testStartingURLOffTheAllowlistIsRefusedWithoutAnyRequest() async {
        do { _ = try await downloader().data(URL(string: "https://example.com/x")!); XCTFail() }
        catch { XCTAssertEqual(error as? DownloadError, .blockedHost("example.com")) }
        XCTAssertTrue(MockReleaseServer.requests.isEmpty)
    }

    func testServerErrorsBecomePlainEnglish() async {
        MockReleaseServer.route("https://github.com/missing", .status(404))
        MockReleaseServer.route("https://github.com/broken", .status(503))
        do { _ = try await downloader().data(URL(string: "https://github.com/missing")!); XCTFail() }
        catch { XCTAssertEqual(error as? DownloadError, .httpStatus(404)); XCTAssertEqual(error.localizedDescription, "The download isn't available right now. Try again later.") }
        do { _ = try await downloader().download(URL(string: "https://github.com/broken")!, name: "x", sha256: String(repeating: "a", count: 64)); XCTFail() }
        catch { XCTAssertEqual(error as? DownloadError, .httpStatus(503)) }
        XCTAssertEqual(DownloadError.from(URLError(.notConnectedToInternet)) as? DownloadError, .offline)
        XCTAssertTrue(DownloadError.from(URLError(.serverCertificateUntrusted)).localizedDescription.contains("secure connection"))
    }

    func testDroppedConnectionResumesWithRange() async throws {
        let body = Self.blob(900_000)
        let url = URL(string: "https://github.com/a/big.zip")!
        MockReleaseServer.route(url.absoluteString, .file(body, etag: "\"v1\"", dropAfter: 400_000, chunkDelay: 5_000))
        let d = downloader()
        do { _ = try await d.download(url, name: "big.zip", sha256: Self.sha(body)); XCTFail("drop not reported") }
        catch { guard case .network? = error as? DownloadError else { return XCTFail("\(error)") } }
        let kept = d.partialBytes("big.zip")
        XCTAssertGreaterThan(kept, 0, "the bytes received so far are kept"); XCTAssertLessThanOrEqual(kept, 400_000)

        MockReleaseServer.route(url.absoluteString, .file(body, etag: "\"v1\""))
        let file = try await d.download(url, name: "big.zip", sha256: Self.sha(body))
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(MockReleaseServer.requests.last?.range, "bytes=\(kept)-", "second attempt asked only for the rest")
    }

    func testServerWithoutRangeSupportRestartsCleanly() async throws {
        let body = Self.blob(500_000)
        let url = URL(string: "https://github.com/a/norange.zip")!
        MockReleaseServer.route(url.absoluteString, .file(body, ranges: false, dropAfter: 200_000, chunkDelay: 5_000))
        let d = downloader()
        _ = try? await d.download(url, name: "n.zip", sha256: Self.sha(body))
        XCTAssertGreaterThan(d.partialBytes("n.zip"), 0)
        MockReleaseServer.route(url.absoluteString, .file(body, ranges: false))
        let file = try await d.download(url, name: "n.zip", sha256: Self.sha(body))
        XCTAssertEqual(try Data(contentsOf: file), body, "a full 200 reply replaces the partial instead of appending to it")
    }

    func testCancelKeepsPartialThenDiscardRemovesIt() async throws {
        let body = Self.blob(3_000_000)
        let url = URL(string: "https://github.com/a/slow.zip")!
        MockReleaseServer.route(url.absoluteString, .file(body, chunkDelay: 20_000))
        let d = downloader()
        let task = Task { try await d.download(url, name: "slow.zip", sha256: Self.sha(body)) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancel ignored") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let kept = d.partialBytes("slow.zip")
        XCTAssertGreaterThan(kept, 0); XCTAssertLessThan(kept, Int64(body.count))
        d.discard("slow.zip")
        XCTAssertEqual(d.partialBytes("slow.zip"), 0)
        XCTAssertEqual(leftovers(), [])
    }

    func testOversizedDownloadIsStopped() async throws {
        let body = Self.blob(200_000)
        MockReleaseServer.route("https://github.com/a/huge", .file(body))
        let small = DownloadPolicy(allowedHosts: ["github.com"], maxBytes: 100_000)
        do { _ = try await downloader(small).download(URL(string: "https://github.com/a/huge")!, name: "h", sha256: Self.sha(body)); XCTFail() }
        catch { XCTAssertEqual(error as? DownloadError, .tooLarge) }
        XCTAssertEqual(leftovers(), [])
        do { _ = try await downloader().download(URL(string: "https://github.com/a/huge")!, name: "h2", sha256: Self.sha(body), expectedSize: 1000); XCTFail() }
        catch { XCTAssertEqual(error as? DownloadError, .tooLarge, "bigger than the manifest says") }
    }

    func testCleanupRemovesStaleFiles() throws {
        let d = dir.appendingPathComponent("dl"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let fresh = d.appendingPathComponent("fresh.partial"), old = d.appendingPathComponent("old.partial"), done = d.appendingPathComponent("x-done.zip")
        for f in [fresh, old, done] { FileManager.default.createFile(atPath: f.path, contents: Data("x".utf8)) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: old.path)
        XCTAssertEqual(SafeDownloader.cleanup(directory: d), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: d.path), ["fresh.partial"], "a recent partial is kept so it can resume")
    }

    // MARK: Claude installer

    func serveClaude(binary: Data, checksum: String? = nil, latest: String = "9.9.9") {
        let base = "https://downloads.claude.ai/claude-code-releases"
        MockReleaseServer.route("\(base)/latest", .file(Data((latest + "\n").utf8)))
        let manifest = #"{"version":"9.9.9","platforms":{"darwin-arm64":{"binary":"claude","checksum":"\#(checksum ?? Self.sha(binary))","size":\#(binary.count)},"linux-x64":{"checksum":"\#(String(repeating: "1", count: 64))"}}}"#
        MockReleaseServer.route("\(base)/9.9.9/manifest.json", .file(Data(manifest.utf8)))
        MockReleaseServer.route("\(base)/9.9.9/darwin-arm64/claude", .file(binary))
    }

    /// A stand-in "claude" that records that it was run.
    func fakeClaude() -> (Data, URL) {
        let marker = dir.appendingPathComponent("ran-install")
        return (Data("#!/bin/sh\necho \"$1\" > '\(marker.path)'\n".utf8), marker)
    }

    func testClaudeInstallRunsOnlyAfterChecksumAndSignature() async throws {
        let (script, marker) = fakeClaude()
        serveClaude(binary: script)
        let checked = Box<[String]>([])
        let phases = Box<[String]>([])
        let exe = try await ClaudeSetup.install(downloader: downloader(), platform: "darwin-arm64",
                                                verifySignature: { url, team in
                                                    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing ran before the signature check")
                                                    checked.value.append(team)
                                                },
                                                locate: { FileManager.default.fileExists(atPath: marker.path) ? marker : nil },
                                                phase: { p in phases.value.append("\(p)") })
        XCTAssertEqual(checked.value, [CodeSignature.Team.anthropic])
        XCTAssertEqual(try String(contentsOf: exe, encoding: .utf8), "install\n", "ran `claude install`")
        XCTAssertEqual(phases.value.first, "checking"); XCTAssertEqual(phases.value.last, "installing")
        XCTAssertEqual(leftovers(), [], "downloaded binary deleted after install")
    }

    func testClaudeInstallNeverRunsATamperedBinary() async throws {
        let (script, marker) = fakeClaude()
        serveClaude(binary: script, checksum: Self.sha(Data("something else".utf8)))
        do {
            _ = try await ClaudeSetup.install(downloader: downloader(), platform: "darwin-arm64", verifySignature: { _, _ in }, locate: { nil })
            XCTFail("tampered binary accepted")
        } catch { XCTAssertEqual(error as? DownloadError, .checksumMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(leftovers(), [])
    }

    func testClaudeInstallNeverRunsAnUnsignedBinary() async throws {
        let (script, marker) = fakeClaude()
        serveClaude(binary: script)
        do {
            _ = try await ClaudeSetup.install(downloader: downloader(), platform: "darwin-arm64",
                                              verifySignature: { url, team in try CodeSignature.verify(url, teamID: team) }, locate: { nil })
            XCTFail("unsigned binary accepted")
        } catch { XCTAssertEqual(error as? CodeSignature.Failure, .unsigned) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(leftovers(), [], "rejected binary deleted")
    }

    func testClaudeVersionMustLookLikeAVersion() async {
        serveClaude(binary: Data("x".utf8), latest: "<html>blocked</html>")
        do { _ = try await ClaudeSetup.latestRelease(downloader: downloader(), platform: "darwin-arm64"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("didn't answer properly"), error.localizedDescription) }
        XCTAssertFalse(MockReleaseServer.requests.contains { $0.url.contains("manifest") }, "no manifest fetched for a bad version")
    }

    func testClaudeManifestParsing() throws {
        let good = Data(#"{"version":"1.2.3","platforms":{"darwin-x64":{"checksum":"\#(String(repeating: "AB", count: 32))","size":5}}}"#.utf8)
        XCTAssertEqual(try ClaudeSetup.parseManifest(good, version: "1.2.3", platform: "darwin-x64"),
                       .init(version: "1.2.3", platform: "darwin-x64", sha256: String(repeating: "ab", count: 32), size: 5))
        XCTAssertThrowsError(try ClaudeSetup.parseManifest(good, version: "1.2.3", platform: "darwin-arm64"), "missing platform")
        XCTAssertThrowsError(try ClaudeSetup.parseManifest(good, version: "9.9.9", platform: "darwin-x64"), "manifest for another version")
        let short = Data(#"{"platforms":{"darwin-x64":{"checksum":"abc"}}}"#.utf8)
        XCTAssertThrowsError(try ClaudeSetup.parseManifest(short, version: "1.2.3", platform: "darwin-x64"), "not a SHA-256")
    }

    // MARK: Ollama installer

    func makeFakeOllamaZip() throws -> Data {
        let src = dir.appendingPathComponent("src/Ollama.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: src.appendingPathComponent("Info.plist"))
        let zip = dir.appendingPathComponent("o.zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", dir.appendingPathComponent("src/Ollama.app").path, zip.path]
        try p.run(); p.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    func serveOllama(zip: Data, sum: String? = nil) {
        MockReleaseServer.route(OllamaSetup.latestReleaseAPI.absoluteString, .file(Data(#"{"tag_name":"v9.9.9","body":"notes"}"#.utf8)))
        let sums = "\(String(repeating: "1", count: 64))  ./Ollama.dmg\n\(sum ?? Self.sha(zip))  ./Ollama-darwin.zip\n"
        MockReleaseServer.route("https://github.com/ollama/ollama/releases/download/v9.9.9/sha256sum.txt", .file(Data(sums.utf8)))
        MockReleaseServer.route("https://github.com/ollama/ollama/releases/download/v9.9.9/Ollama-darwin.zip", .redirect("https://release-assets.githubusercontent.com/o"))
        MockReleaseServer.route("https://release-assets.githubusercontent.com/o", .file(zip))
    }

    func testOllamaInstallVerifiesBeforeCopying() async throws {
        serveOllama(zip: try makeFakeOllamaZip())
        let apps = dir.appendingPathComponent("Applications")
        let checked = Box<[String]>([]), launched = Box(false)
        let dest = try await OllamaSetup.install(downloader: downloader(), folders: [apps], verifySignature: { url, team in
            checked.value.append(url.path.hasPrefix(apps.path) ? "installed" : "download")
            XCTAssertEqual(team, CodeSignature.Team.ollama)
        }, launch: { launched.value = true })
        XCTAssertEqual(dest.path, apps.appendingPathComponent("Ollama.app").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertEqual(checked.value, ["download", "installed"], "checked before copying, and the copy again")
        XCTAssertTrue(launched.value)
        XCTAssertEqual(leftovers(), [], "zip and unpacked folder removed")
    }

    func testOllamaInstallRefusesBadSignatureAndChecksum() async throws {
        let zip = try makeFakeOllamaZip()
        let apps = dir.appendingPathComponent("Applications")
        serveOllama(zip: zip)
        do {
            _ = try await OllamaSetup.install(downloader: downloader(), folders: [apps], launch: { XCTFail("launched") })
            XCTFail("unsigned app installed")
        } catch { XCTAssertEqual(error as? CodeSignature.Failure, .unsigned) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: apps.appendingPathComponent("Ollama.app").path))
        XCTAssertEqual(leftovers(), [])

        serveOllama(zip: zip, sum: Self.sha(Data("other".utf8)))
        do {
            _ = try await OllamaSetup.install(downloader: downloader(), folders: [apps], verifySignature: { _, _ in }, launch: {})
            XCTFail("bad checksum installed")
        } catch { XCTAssertEqual(error as? DownloadError, .checksumMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: apps.appendingPathComponent("Ollama.app").path))
    }

    func testChecksumListParsing() {
        let sums = "da3189f87034d224beb0708d77b95180bc03872f6e269d59bd888a216055c58a  ./Ollama-darwin.zip\nzz  ./x\nabc *Ollama.dmg\n"
        XCTAssertEqual(OllamaSetup.checksum(in: sums, for: "Ollama-darwin.zip"), "da3189f87034d224beb0708d77b95180bc03872f6e269d59bd888a216055c58a")
        XCTAssertNil(OllamaSetup.checksum(in: sums, for: "Ollama.dmg"), "not a SHA-256")
        XCTAssertNil(OllamaSetup.checksum(in: sums, for: "Ollama"))
    }

    func testModelRecommendationUsesMemoryAndDisk() {
        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(OllamaSetup.recommended(ramBytes: 8 * gib).name, "qwen3.5:4b")
        XCTAssertEqual(OllamaSetup.recommended(ramBytes: 16 * gib).name, "qwen3.5:9b")
        XCTAssertEqual(OllamaSetup.recommended(ramBytes: 64 * gib).name, "qwen3.5:27b")
        XCTAssertEqual(OllamaSetup.recommended(ramBytes: 64 * gib, freeDisk: 15_000_000_000).name, "qwen3.5:9b", "large model doesn't fit")
        XCTAssertEqual(OllamaSetup.recommended(ramBytes: 64 * gib, freeDisk: 1_000_000_000).name, "qwen3.5:4b")
        XCTAssertEqual(OllamaSetup.recommended(ramBytes: 8 * gib, freeDisk: 500_000_000_000).name, "qwen3.5:4b", "disk never raises it above memory")
    }

    // MARK: signatures

    func testUnsignedAndForeignSignaturesAreRejected() throws {
        let text = dir.appendingPathComponent("notcode"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: text)
        XCTAssertThrowsError(try CodeSignature.verify(text, teamID: CodeSignature.Team.ollama)) { XCTAssertEqual($0 as? CodeSignature.Failure, .unsigned) }

        // Apple's own tools are validly signed, but not by Anthropic or Ollama.
        let ls = URL(fileURLWithPath: "/bin/ls")
        XCTAssertNoThrow(try CodeSignature.verify(ls, requirement: "anchor apple"))
        XCTAssertThrowsError(try CodeSignature.verify(ls, teamID: CodeSignature.Team.anthropic)) {
            XCTAssertEqual($0 as? CodeSignature.Failure, .wrongPublisher(found: nil))
            XCTAssertTrue($0.localizedDescription.contains("wasn't signed by the company that makes it"))
        }

        // Ad-hoc signed (anyone can do this): rejected.
        let copy = dir.appendingPathComponent("adhoc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: copy)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); p.arguments = ["-s", "-", "-f", copy.path]
        p.standardError = FileHandle.nullDevice; try p.run(); p.waitUntilExit()
        XCTAssertThrowsError(try CodeSignature.verify(copy, teamID: CodeSignature.Team.anthropic))

        // A genuinely signed file changed by one byte: rejected.
        let tampered = dir.appendingPathComponent("tampered")
        try FileManager.default.copyItem(at: ls, to: tampered)
        XCTAssertNoThrow(try CodeSignature.verify(tampered, requirement: "anchor apple"), "an exact copy still verifies")
        let h = try FileHandle(forWritingTo: tampered); try h.seek(toOffset: 40_000); try h.write(contentsOf: Data([0xAB])); try h.close()
        XCTAssertThrowsError(try CodeSignature.verify(tampered, requirement: "anchor apple")) {
            guard case .invalid? = $0 as? CodeSignature.Failure else { return XCTFail("\($0)") }
        }
    }

    /// The real thing, when Claude Code is installed on this Mac.
    func testInstalledClaudeCarriesAnthropicsSignature() throws {
        guard let exe = ClaudeSetup.locate()?.resolvingSymlinksInPath() else { throw XCTSkip("Claude Code not installed") }
        XCTAssertNoThrow(try CodeSignature.verify(exe, teamID: CodeSignature.Team.anthropic))
        XCTAssertEqual(CodeSignature.teamID(of: exe), CodeSignature.Team.anthropic)
        XCTAssertThrowsError(try CodeSignature.verify(exe, teamID: CodeSignature.Team.ollama))
    }

    /// The real Ollama release: set OFFERLANE_TEST_OLLAMA_APP to an unpacked Ollama.app (or one in /Applications is used).
    func testRealOllamaAppCarriesOllamasSignature() throws {
        let path = ProcessInfo.processInfo.environment["OFFERLANE_TEST_OLLAMA_APP"] ?? "/Applications/Ollama.app"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no Ollama.app to check") }
        let app = URL(fileURLWithPath: path)
        XCTAssertNoThrow(try CodeSignature.verify(app, teamID: CodeSignature.Team.ollama))
        XCTAssertThrowsError(try CodeSignature.verify(app, teamID: CodeSignature.Team.anthropic))
    }

    // MARK: health

    func testHealthNamesEachProblemWithAFix() {
        var f = Health.Facts()
        XCTAssertEqual(Health.evaluate(f).first?.fix, .chooseAI)
        f.provider = .claudeCLI
        XCTAssertEqual(Health.ai(f).fix, .installClaude)
        f.claudeInstalled = true
        XCTAssertEqual(Health.ai(f).fix, .signInClaude); XCTAssertFalse(Health.Fix.signInClaude.automatic)
        f.claudeSignedIn = true
        XCTAssertEqual(Health.ai(f).status, .ok)
        f = Health.Facts(); f.provider = .ollama; f.ollamaModel = "qwen3.5:9b"
        XCTAssertEqual(Health.ai(f).fix, .installOllama)
        f.ollamaInstalled = true; XCTAssertEqual(Health.ai(f).fix, .startOllama)
        f.ollamaRunning = true; XCTAssertEqual(Health.ai(f).fix, .downloadModel("qwen3.5:9b")); XCTAssertTrue(Health.ai(f).fix!.automatic)
        f.ollamaHasModel = true; XCTAssertEqual(Health.ai(f).status, .ok)
        f = Health.Facts(); f.provider = .anthropic
        XCTAssertEqual(Health.ai(f).fix, .enterAPIKey)
        f.testAI = true; f.provider = .none
        XCTAssertEqual(Health.ai(f).status, .ok)
    }

    func testHealthSystemChecks() {
        var f = Health.Facts(); f.testAI = true
        XCTAssertEqual(Health.overall(Health.evaluate(f)), .ok)
        XCTAssertEqual(Health.summary(Health.evaluate(f)), "All set")

        f.online = false; f.freeDisk = 1_000_000_000; f.translated = true
        let items = Health.evaluate(f)
        XCTAssertEqual(Health.overall(items), .problem)
        XCTAssertEqual(Health.summary(items), "3 things need attention")
        XCTAssertEqual(items.first { $0.id == "internet" }?.fix, .recheck)
        XCTAssertTrue(items.first { $0.id == "disk" }!.message.hasPrefix("Only 1.0 GB free."))
        XCTAssertEqual(items.first { $0.id == "mac" }?.fix, .rosettaHelp)

        f = Health.Facts(); f.testAI = true; f.freeDisk = 6_000_000_000; f.chip = .intel; f.latexEngine = false
        let warn = Health.evaluate(f)
        XCTAssertEqual(warn.first { $0.id == "disk" }?.status, .warning)
        XCTAssertEqual(warn.first { $0.id == "mac" }?.status, .ok)
        XCTAssertEqual(warn.first { $0.id == "pdf" }?.status, .info, "missing LaTeX engine has a fallback")
        XCTAssertEqual(Health.summary(warn), "1 thing needs attention")

        f.provider = .ollama; f.testAI = false; f.online = false
        XCTAssertEqual(Health.evaluate(f).first { $0.id == "internet" }?.status, .warning, "a local AI still works offline")
        XCTAssertEqual(Health.evaluate(f).first { $0.id == "mac" }?.status, .info)
        for item in Health.evaluate(f) { XCTAssertFalse(item.message.isEmpty); XCTAssertFalse(item.message.contains("Error")) }
    }

    func testHardwareSnapshot() {
        let hw = SystemCheck.hardware
        XCTAssertEqual(hw.ramBytes, SystemCheck.ramBytes)
        XCTAssertGreaterThan(hw.cores, 0); XCTAssertGreaterThanOrEqual(hw.macOSMajor, 14); XCTAssertGreaterThan(hw.freeDiskBytes, 0)
        let gib: UInt64 = 1 << 30
        let mac = { (ram: UInt64) in SystemCheck.Hardware(ramBytes: ram, chip: .appleSilicon, cores: 8, freeDiskBytes: 0, macOSMajor: 26) }
        XCTAssertTrue(mac(8 * gib).isLowMemory); XCTAssertFalse(mac(16 * gib).isLowMemory)
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var _value: T
    init(_ v: T) { _value = v }
    var value: T { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
}
