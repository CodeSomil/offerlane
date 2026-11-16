import Foundation

/// Read-only Gmail access (Gmail API, `gmail.readonly`). Lists recent mail with headers only
/// (`format=metadata`) and fetches a body only for messages that need one (verification links).
/// Available only while the Google project is in Testing mode; IMAP stays the default.
public struct GmailClient: Sendable {
    public let transport: any HTTPTransport
    /// Returns a valid access token, refreshing it when needed.
    public let accessToken: @Sendable () async throws -> String
    public var api = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!

    public init(transport: any HTTPTransport = URLSessionTransport(), accessToken: @escaping @Sendable () async throws -> String) {
        self.transport = transport; self.accessToken = accessToken
    }

    /// Messages from the last `days` days (newest `limit`). `needsBody` picks the ones whose body is downloaded.
    public func fetch(days: Int = 4, limit: Int = 100, needsBody: @Sendable (MailMessage) -> Bool = { _ in false }) async throws -> [MailMessage] {
        let list = try await get("messages", ["q": "newer_than:\(max(1, days))d", "maxResults": "\(min(limit, 500))"])
        let ids = ((list["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        var out: [MailMessage] = []
        for id in ids {
            let m = try await get("messages/\(id)", ["format": "metadata", "metadataHeaders": "From,Subject,Date"])
            var mail = Self.message(m)
            if needsBody(mail) {
                let full = try await get("messages/\(id)", ["format": "full"])
                mail.raw = "Subject: \(mail.subject)\nFrom: \(mail.from)\n\n" + Self.bodyText(full["payload"] as? [String: Any] ?? [:])
            }
            out.append(mail)
        }
        return out
    }

    static func message(_ m: [String: Any]) -> MailMessage {
        let headers = ((m["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func h(_ n: String) -> String { headers.first { ($0["name"] as? String)?.lowercased() == n.lowercased() }?["value"] as? String ?? "" }
        let snippet = Self.unescape(m["snippet"] as? String ?? "")
        return MailMessage(id: "gmail:" + (m["id"] as? String ?? ""), from: h("From"), subject: h("Subject"), snippet: snippet,
                           raw: "Subject: \(h("Subject"))\nFrom: \(h("From"))\n\n\(snippet)")
    }

    /// Plain text from a MIME payload: text/plain parts first, else text/html with tags stripped.
    static func bodyText(_ payload: [String: Any]) -> String {
        var plain: [String] = [], html: [String] = []
        func walk(_ p: [String: Any]) {
            let type = (p["mimeType"] as? String ?? "").lowercased()
            if let data = (p["body"] as? [String: Any])?["data"] as? String, let d = Base64URL.decode(data) {
                let t = String(decoding: d, as: UTF8.self)
                if type == "text/plain" { plain.append(t) } else if type == "text/html" { html.append(t) }
            }
            for part in (p["parts"] as? [[String: Any]]) ?? [] { walk(part) }
        }
        walk(payload)
        if !plain.isEmpty { return String(plain.joined(separator: "\n").prefix(20_000)) }
        // Keep href targets so verification links survive tag stripping.
        let joined = html.joined(separator: "\n")
        let withLinks = Re.sub("<a[^>]+href=\"([^\"]+)\"[^>]*>", " $1 ", joined)
        return String(unescape(Re.sub("<[^>]+>", " ", withLinks)).prefix(20_000))
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var c = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        for (k, v) in query.sorted(by: { $0.key < $1.key }) {
            if k == "metadataHeaders" { items += v.split(separator: ",").map { URLQueryItem(name: k, value: String($0)) } }
            else { items.append(URLQueryItem(name: k, value: v)) }
        }
        c.queryItems = items
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (d, resp): (Data, HTTPURLResponse)
        do { (d, resp) = try await transport.send(r) } catch { throw OAuthError.network(error.localizedDescription) }
        if resp.statusCode == 401 { throw OAuthError.revoked }
        guard resp.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw OAuthError.http(resp.statusCode, "gmail")
        }
        return json
    }
}

/// Keeps a Google access token fresh and stores rotated tokens in Keychain.
public actor GoogleTokenProvider {
    let oauth: GoogleOAuth
    let accounts: AccountStore
    let accountID: String
    public init(oauth: GoogleOAuth, accounts: AccountStore, accountID: String) {
        self.oauth = oauth; self.accounts = accounts; self.accountID = accountID
    }
    public func token(now: Date = Date()) async throws -> String {
        guard var t = accounts.googleTokens(for: accountID) else { throw OAuthError.revoked }
        if t.accessExpiry > now && !t.accessToken.isEmpty { return t.accessToken }
        do { t = try await oauth.refresh(t) }
        catch OAuthError.revoked { accounts.deleteGoogleTokens(for: accountID); throw OAuthError.revoked }
        try accounts.saveGoogleTokens(t, for: accountID)
        return t.accessToken
    }
}
