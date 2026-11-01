import Foundation

/// One email, reduced to what tracking needs.
public struct MailMessage: Sendable, Hashable {
    public var id: String, from: String, subject: String, snippet: String, raw: String
    public init(id: String, from: String, subject: String, snippet: String, raw: String) {
        self.id = id; self.from = from; self.subject = subject; self.snippet = snippet; self.raw = raw
    }

    /// Parse IMAP `HEADER.FIELDS` + the start of the body.
    public static func parse(seq: Int, header: Data, body: Data) -> MailMessage {
        let h = String(decoding: header, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let unfolded = Re.sub("\n[ \t]+", " ", h)
        func field(_ name: String) -> String {
            Mime.decodeWords(Re.first("(?im)^\(name):[ \t]*(.*)$", unfolded, []) ?? "").trimmingCharacters(in: .whitespaces)
        }
        let raw = String(decoding: body, as: UTF8.self)
        let text = Text.collapse(Re.sub("<[^>]+>", " ", Mime.quotedPrintable(raw)))
        let mid = field("Message-ID")
        return MailMessage(id: mid.isEmpty ? "seq-\(seq)" : mid, from: field("From"), subject: field("Subject"), snippet: String(text.prefix(600)), raw: raw)
    }
}

public enum Mime {
    /// RFC 2047 encoded words: =?utf-8?B?...?= and =?utf-8?Q?...?=
    public static func decodeWords(_ s: String) -> String {
        let joined = Re.sub("\\?=\\s+=\\?", "?==?", s)
        return Re.sub("=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=", joined) { g in
            let charset = (g[1] ?? "utf-8").lowercased(), enc = (g[2] ?? "B").uppercased(), payload = g[3] ?? ""
            var data: Data?
            if enc == "B" { data = Data(base64Encoded: payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)) }
            else { data = qpData(payload.replacingOccurrences(of: "_", with: " ")) }
            guard let d = data else { return g[0] ?? "" }
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            let nsEnc = cfEnc == kCFStringEncodingInvalidId ? String.Encoding.utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            return String(data: d, encoding: nsEnc) ?? String(decoding: d, as: UTF8.self)
        }
    }
    static func qpData(_ s: String) -> Data {
        var out = Data(); var it = Array(s.utf8)[...]
        while let c = it.first {
            it = it.dropFirst()
            if c == UInt8(ascii: "="), it.count >= 2, let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) { out.append(v); it = it.dropFirst(2) }
            else { out.append(c) }
        }
        return out
    }
    /// Quoted-printable bodies: soft line breaks and =XX escapes (best effort; leaves plain text alone).
    public static func quotedPrintable(_ s: String) -> String {
        guard s.contains("=\r\n") || s.contains("=\n") || Re.search("=[0-9A-F]{2}", s, []) else { return s }
        let soft = s.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
        return String(decoding: qpData(soft), as: UTF8.self)
    }
}

/// Inbox watcher: rules classify most mail for free; only ambiguous emails that clearly match an application go to the AI,
/// batched in one call. Ported from track.py.
public struct Tracking: Sendable {
    public let store: Store
    public let ai: AI?
    public let fetch: @Sendable () async throws -> [MailMessage]
    public init(store: Store, ai: AI?, fetch: @escaping @Sendable () async throws -> [MailMessage]) { self.store = store; self.ai = ai; self.fetch = fetch }

    public static let rules: [(JobStatus, String)] = [
        (.offer, "offer letter|pleased to (extend|offer)|extend (you )?an offer"),
        (.rejected, "unfortunately|not (be )?moving forward|move forward with other|decided to (pursue|proceed with) other|not been selected|position has been filled|will not be progressing|regret to inform|other candidates|no longer under consideration"),
        (.assessment, "assessment|hackerrank|codility|codesignal|take[- ]home|coding (challenge|test)|test link"),
        (.interview, "interview|next round|onsite|on-site|meet the team|schedule (a|your)? ?(time|call|conversation)|calendly|your availability"),
        (.screen, "recruiter (call|screen)|phone screen|introductory call|quick chat|initial (call|conversation)"),
        (.acknowledged, "thank(s| you) for (applying|your application|your interest)|application (has been )?(received|submitted)|we('ve| have) received"),
    ]
    static let order: [JobStatus] = [.prefilled, .applied, .acknowledged, .assessment, .screen, .interview, .offer]

    public static func classify(_ t: String) -> JobStatus? { rules.first { Re.search($0.1, t) }?.0 }

    public struct Result: Sendable, Equatable { public var checked = 0, updates = 0, askedAI = 0 }

    public func run() async throws -> Result {
        let mails = try await fetch()
        var res = Result(); res.checked = mails.count
        let fresh = try store.markEmailsSeen(mails.map(\.id))
        let live = try store.jobs(Self.order)
        var ambiguous: [(MailMessage, Job)] = []
        for m in mails where fresh.contains(m.id) {
            let blob = Text.norm("\(m.from) \(m.subject) \(String(m.snippet.prefix(300)))")
            guard let j = live.first(where: { let c = Text.norm($0.company); return !c.isEmpty && Re.search("\\b\(Re.escape(c))\\b", blob, []) }) else { continue }
            if let s = Self.classify("\(m.subject) \(m.snippet)") { res.updates += try apply(j.id, s, subject: m.subject) }
            else { ambiguous.append((m, j)) }
        }
        if !ambiguous.isEmpty, let ai {
            struct Item: Encodable { let mail: String, company: String, subject: String, snippet: String }
            struct Out: Decodable { var mail: String; var status: String }
            let items = ambiguous.prefix(20).map { Item(mail: $0.0.id, company: $0.1.company, subject: $0.0.subject, snippet: String($0.0.snippet.prefix(300))) }
            let json = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
            let out: [Out] = try await ai.json(LLMRequest(prompt: "Classify each job-application email as one of: acknowledged, assessment, screen, interview, offer, rejected, other.\nReturn [{\"mail\":\"\",\"status\":\"\"}].\n" + json,
                                                         maxTokens: 40 * items.count + 100))
            res.askedAI = items.count
            let byMail = Dictionary(ambiguous.map { ($0.0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for o in out { if let s = JobStatus(rawValue: o.status), s == .rejected || Self.order.contains(s), let (m, j) = byMail[o.mail] { res.updates += try apply(j.id, s, subject: m.subject) } }
        }
        try? store.addEvent("run", status: "inbox", source: "email", detail: "\(res.checked) emails checked, \(res.updates) status updates")
        return res
    }

    /// Statuses only move forward; a rejection always applies. A role still "Ready to submit" counts as applied first.
    @discardableResult
    public func apply(_ id: String, _ s: JobStatus, subject: String) throws -> Int {
        guard var j = try store.job(id), let cur = Self.order.firstIndex(of: j.status) else { return 0 }
        guard s == .rejected || (Self.order.firstIndex(of: s) ?? -1) > cur else { return 0 }
        if j.status == .prefilled { j = try store.transition(id, to: .applied, by: "email", detail: "reply received") }
        if j.status != s { try store.transition(id, to: s, by: "email", detail: String(subject.prefix(120))) }
        return 1
    }

    /// Newest account-verification link or code from a career site, matched by a hint (company name or "workday").
    public static func verification(in mails: [MailMessage], hint: String) -> (link: String?, code: String?)? {
        for m in mails.reversed() {
            let h = hint.lowercased()
            guard (m.from + m.subject).lowercased().contains(h) || String(m.raw.prefix(3000)).lowercased().contains(h) else { continue }
            guard Re.search("verif|activat|confirm", m.subject + String(m.raw.prefix(4000))) else { continue }
            let raw = Mime.quotedPrintable(m.raw)
            let link = Re.groups("https?://[^\\s\"'<>]*(verif|activat|confirm)[^\\s\"'<>]*", raw)?.first ?? nil
            let code = Re.groups("\\b(code|verification code)\\D{0,20}(\\d{4,8})\\b", raw)?[2] ?? nil
            return (link, code)
        }
        return nil
    }

    /// IMAP fetch of the last `days` days (newest 300), read-only.
    public static func imapFetch(host: String, port: UInt16 = 993, user: String, password: String, days: Int = 4, bodyBytes: Int = 1500, tls: Bool = true) async throws -> [MailMessage] {
        let c = IMAPClient(host: host, port: port, tls: tls)
        try await c.connect()
        do {
            try await c.login(user: user, password: password)
            try await c.select()
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd-MMM-yyyy"
            let since = f.string(from: Calendar.current.date(byAdding: .day, value: -days, to: Date())!)
            var out: [MailMessage] = []
            for seq in try await c.search("SINCE \(since)").suffix(300) {
                let (h, b) = try await c.fetchHeaderAndBody(seq, bodyBytes: bodyBytes)
                out.append(MailMessage.parse(seq: seq, header: h, body: b))
            }
            await c.logout(); return out
        } catch { await c.logout(); throw error }
    }
}
