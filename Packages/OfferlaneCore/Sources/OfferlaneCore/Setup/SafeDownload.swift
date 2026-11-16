import Foundation
import CryptoKit

/// Which URLs installers may fetch: HTTPS only, exact host match against an allowlist, size-capped.
public struct DownloadPolicy: Sendable {
    public var allowedHosts: Set<String>
    public var maxBytes: Int64

    public init(allowedHosts: Set<String>, maxBytes: Int64) { self.allowedHosts = allowedHosts; self.maxBytes = maxBytes }

    /// The official release hosts for Claude Code and Ollama (Ollama's releases are served by GitHub).
    public static let installers = DownloadPolicy(allowedHosts: [
        "downloads.claude.ai",
        "api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
    ], maxBytes: 1_500_000_000)

    public func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }
}

public enum DownloadError: LocalizedError, Equatable {
    case blockedHost(String)
    case httpStatus(Int)
    case checksumMismatch
    case tooLarge
    case offline
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .blockedHost: "The download tried to come from a website Offerlane doesn't trust, so it was stopped. Try again later."
        case .httpStatus(let c): c == 404 ? "The download isn't available right now. Try again later." : "The download server had a problem (error \(c)). Try again in a few minutes."
        case .checksumMismatch: "The download was damaged or changed on the way, so it wasn't used. Try again."
        case .tooLarge: "The download was much bigger than expected, so it was stopped. Try again later."
        case .offline: "You're not connected to the internet. Connect, then try again."
        case .network(let why): "The download stopped (\(why)). Try again; it continues where it left off."
        }
    }

    static func from(_ error: Error) -> Error {
        if error is CancellationError || error is DownloadError { return error }
        guard let u = error as? URLError else { return error }
        switch u.code {
        case .cancelled: return CancellationError()
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return DownloadError.offline
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
            return DownloadError.network("the secure connection couldn't be checked")
        default: return DownloadError.network(u.localizedDescription.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
    }
}

/// Downloads installers safely:
/// - allowlisted HTTPS hosts only, also checked on every redirect and on the final URL;
/// - TLS 1.2+ through an ephemeral session (no cookies, no cache);
/// - SHA-256 checked before the file is handed back, and a mismatch deletes it;
/// - resumable: an interrupted or cancelled download keeps its `.partial` file and continues with a Range request.
/// Files live in one folder that `cleanup` empties of anything stale.
public final class SafeDownloader: @unchecked Sendable {
    public let policy: DownloadPolicy
    public let directory: URL
    let configuration: URLSessionConfiguration

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return TestHooks.env["OFFERLANE_HOME"] != nil
            ? Paths.base.appendingPathComponent("Downloads", isDirectory: true)
            : caches.appendingPathComponent("com.somilmanke.Offerlane/Downloads", isDirectory: true)
    }

    public init(policy: DownloadPolicy = .installers, directory: URL = SafeDownloader.defaultDirectory,
                configuration: URLSessionConfiguration? = nil) {
        self.policy = policy; self.directory = directory
        let c = configuration ?? .ephemeral
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        c.httpCookieStorage = nil; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        self.configuration = c
    }

    /// A small text/JSON file (version numbers, manifests, checksum lists), held in memory.
    public func data(_ url: URL, maxBytes: Int = 4 << 20) async throws -> Data {
        guard policy.allows(url) else { throw DownloadError.blockedHost(url.host ?? "") }
        let guardDelegate = RedirectGuard(policy: policy)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            var request = URLRequest(url: url); request.setValue("Offerlane/\(OfferlaneCore.version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request, delegate: guardDelegate)
            if let host = guardDelegate.blocked { throw DownloadError.blockedHost(host) }
            guard policy.allows(response.url) else { throw DownloadError.blockedHost(response.url?.host ?? "") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw DownloadError.httpStatus(status) }
            guard data.count <= maxBytes else { throw DownloadError.tooLarge }
            return data
        } catch {
            if let host = guardDelegate.blocked { throw DownloadError.blockedHost(host) }
            throw DownloadError.from(error)
        }
    }

    public func partialURL(_ name: String) -> URL { directory.appendingPathComponent(Self.safe(name) + ".partial") }
    /// Bytes already on disk from an earlier, unfinished attempt (0 if none).
    public func partialBytes(_ name: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: partialURL(name).path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
    /// Forget an unfinished download.
    public func discard(_ name: String) {
        try? FileManager.default.removeItem(at: partialURL(name))
        try? FileManager.default.removeItem(at: etagURL(name))
    }

    /// Downloads `url` into the downloads folder as `name`, resuming an earlier partial download, and returns the
    /// finished file only if its SHA-256 matches `sha256`. The caller owns (and must delete) the returned file.
    /// `progress(done, total)` reports bytes; total is 0 when unknown.
    public func download(_ url: URL, name: String, sha256: String, expectedSize: Int64? = nil,
                         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
        guard policy.allows(url) else { throw DownloadError.blockedHost(url.host ?? "") }
        let want = sha256.lowercased()
        guard want.count == 64, want.allSatisfy(\.isHexDigit) else { throw DownloadError.checksumMismatch }
        if let expectedSize, expectedSize > policy.maxBytes { throw DownloadError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = partialURL(name)
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        var offset = partialBytes(name)
        if let expectedSize, offset > expectedSize { discard(name); FileManager.default.createFile(atPath: partial.path, contents: nil); offset = 0 }

        if expectedSize == nil || offset < expectedSize! {
            var request = URLRequest(url: url)
            request.setValue("Offerlane/\(OfferlaneCore.version)", forHTTPHeaderField: "User-Agent")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                if let etag = try? String(contentsOf: etagURL(name), encoding: .utf8) { request.setValue(etag, forHTTPHeaderField: "If-Range") }
            }
            let stream = try StreamToFile(file: partial, offset: offset, policy: policy, expectedSize: expectedSize, progress: progress)
            let session = URLSession(configuration: configuration, delegate: stream, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let task = session.dataTask(with: request)
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                        stream.continuation = c
                        task.resume()
                    }
                } onCancel: { task.cancel() }
            } catch {
                if let etag = stream.etag { try? etag.write(to: etagURL(name), atomically: true, encoding: .utf8) }
                if Task.isCancelled { throw CancellationError() }
                if case DownloadError.tooLarge = error { discard(name) }
                throw DownloadError.from(error)
            }
            if let etag = stream.etag { try? etag.write(to: etagURL(name), atomically: true, encoding: .utf8) }
        }

        let size = partialBytes(name)
        guard try Self.sha256(of: partial) == want, expectedSize.map({ $0 == size }) ?? true else {
            discard(name); throw DownloadError.checksumMismatch
        }
        let done = directory.appendingPathComponent(UUID().uuidString + "-" + Self.safe(name))
        try FileManager.default.moveItem(at: partial, to: done)
        try? FileManager.default.removeItem(at: etagURL(name))
        progress(size, size)
        return done
    }

    /// Removes leftovers: finished files and extraction folders always; partial downloads after `olderThan`.
    @discardableResult
    public static func cleanup(directory: URL = SafeDownloader.defaultDirectory, partialsOlderThan age: TimeInterval = 7 * 86_400,
                               now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        for item in items {
            let isPartial = item.pathExtension == "partial" || item.pathExtension == "etag"
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if !isPartial || now.timeIntervalSince(modified) > age { if (try? fm.removeItem(at: item)) != nil { removed += 1 } }
        }
        return removed
    }

    public static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func etagURL(_ name: String) -> URL { directory.appendingPathComponent(Self.safe(name) + ".etag") }
    static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || ".-_".contains($0) ? $0 : "_" }).prefix(120).description
    }
}

/// Refuses any redirect that leaves the allowlist (or drops HTTPS) and remembers which host it was.
class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: DownloadPolicy
    private let lock = NSLock()
    private var _blocked: String?
    var blocked: String? { lock.withLock { _blocked } }
    init(policy: DownloadPolicy) { self.policy = policy }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if policy.allows(request.url) { completionHandler(request); return }
        lock.withLock { _blocked = request.url?.host ?? request.url?.absoluteString ?? "?" }
        task.cancel()
        completionHandler(nil)
    }
}

/// Session delegate that appends the body to the partial file as it arrives.
final class StreamToFile: RedirectGuard, URLSessionDataDelegate, @unchecked Sendable {
    let handle: FileHandle
    let expectedSize: Int64?
    let progress: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var offset: Int64
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var lastReport: Int64 = 0
    private var failure: Error?
    private(set) var etag: String?

    init(file: URL, offset: Int64, policy: DownloadPolicy, expectedSize: Int64?, progress: @escaping @Sendable (Int64, Int64) -> Void) throws {
        handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        self.offset = offset; self.expectedSize = expectedSize; self.progress = progress
        super.init(policy: policy)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard policy.allows(response.url) else {
            fail(DownloadError.blockedHost(response.url?.host ?? "")); completionHandler(.cancel); return
        }
        switch status {
        case 206: break
        case 200:
            // The server sent the whole file (no resume support, or the file changed): start over.
            do { try handle.truncate(atOffset: 0) } catch { fail(error); completionHandler(.cancel); return }
            offset = 0
        case 416 where offset > 0:
            // Nothing left to send: the partial is already complete. The checksum decides.
            total = offset; completionHandler(.cancel); fail(nil); return
        default:
            fail(DownloadError.httpStatus(status)); completionHandler(.cancel); return
        }
        etag = http?.value(forHTTPHeaderField: "ETag")
        let length = response.expectedContentLength
        total = length > 0 ? offset + length : (expectedSize ?? 0)
        if total > policy.maxBytes || (expectedSize.map { total > 0 && total > $0 } ?? false) {
            fail(DownloadError.tooLarge); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle.write(contentsOf: data) } catch { fail(error); dataTask.cancel(); return }
        written += Int64(data.count)
        let done = offset + written
        if done > policy.maxBytes || (expectedSize.map { done > $0 } ?? false) { fail(DownloadError.tooLarge); dataTask.cancel(); return }
        if done - lastReport >= 256 << 10 { lastReport = done; progress(done, total) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.synchronize(); try? handle.close()
        let c = continuation; continuation = nil
        if let host = blocked { c?.resume(throwing: DownloadError.blockedHost(host)); return }
        if let failure { c?.resume(throwing: failure); return }
        if finishedEarly { c?.resume(); return }
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    private var finishedEarly = false
    private func fail(_ error: Error?) {
        if let error { if failure == nil { failure = error } } else { finishedEarly = true }
    }
}
