import Foundation
import Network

/// A small IMAP client over Network.framework (TLS on 993): LOGIN, SELECT, SEARCH, FETCH, LOGOUT.
/// Enough for reading recruiter replies and verification links with an app password.
public actor IMAPClient {
    public let host: String, port: UInt16, tls: Bool
    private var conn: NWConnection?
    private var buffer = Data()
    private var tagN = 0

    public init(host: String, port: UInt16 = 993, tls: Bool = true) { self.host = host; self.port = port; self.tls = tls }

    public struct Response: Sendable {
        public var lines: [String]
        /// Literal payloads ({n}), in order.
        public var literals: [Data]
        public var status: String
        public var text: String
    }

    public func connect(timeout: TimeInterval = 20) async throws {
        let params: NWParameters = tls ? .tls : .tcp
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        conn = c
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ProcessRunner.Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e), .waiting(let e):
                    once.run { cont.resume(throwing: IMAPError.connect("Can't reach \(self.host): \(e.localizedDescription)")) }
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.run { cont.resume(throwing: IMAPError.connect("Timed out connecting to \(self.host).")) } }
        }
        let greeting = try await readLine()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else { throw IMAPError.protocolError(greeting) }
    }

    public func login(user: String, password: String) async throws {
        let r = try await command("LOGIN \(Self.quote(user)) \(Self.quote(password))")
        guard r.status == "OK" else {
            throw IMAPError.auth("The mail server rejected the sign-in (\(r.text)). Check the address and use an app password, not your normal password.")
        }
    }

    /// Returns the number of messages.
    @discardableResult
    public func select(_ mailbox: String = "INBOX", readOnly: Bool = true) async throws -> Int {
        let r = try await command("\(readOnly ? "EXAMINE" : "SELECT") \(Self.quote(mailbox))")
        guard r.status == "OK" else { throw IMAPError.protocolError(r.text) }
        return r.lines.compactMap { Int(Re.first("^\\* (\\d+) EXISTS", $0, []) ?? "") }.first ?? 0
    }

    public func search(_ criteria: String) async throws -> [Int] {
        let r = try await command("SEARCH \(criteria)")
        guard r.status == "OK" else { throw IMAPError.protocolError(r.text) }
        return r.lines.filter { $0.hasPrefix("* SEARCH") }.flatMap { $0.dropFirst(8).split(separator: " ").compactMap { Int($0) } }
    }

    /// FETCH one message's headers and the first `bodyBytes` of its text, without marking it read.
    public func fetchHeaderAndBody(_ seq: Int, bodyBytes: Int = 1500) async throws -> (header: Data, body: Data) {
        let r = try await command("FETCH \(seq) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)] BODY.PEEK[TEXT]<0.\(bodyBytes)>)")
        guard r.status == "OK" else { throw IMAPError.protocolError(r.text) }
        return (r.literals.first ?? Data(), r.literals.count > 1 ? r.literals[1] : Data())
    }

    public func logout() async {
        _ = try? await command("LOGOUT"); conn?.cancel(); conn = nil
    }

    // MARK: protocol plumbing

    public func command(_ cmd: String) async throws -> Response {
        guard let conn else { throw IMAPError.connect("Not connected.") }
        tagN += 1; let tag = "a\(tagN)"
        try await send(conn, Data("\(tag) \(cmd)\r\n".utf8))
        var lines: [String] = [], literals: [Data] = []
        while true {
            var line = try await readLine()
            // A line ending in {n} is followed by n raw bytes, then the rest of the line.
            while let n = Int(Re.first("\\{(\\d+)\\}$", line, []) ?? "") {
                literals.append(try await readBytes(n))
                line += "<literal>" + (try await readLine())
            }
            if line.hasPrefix(tag + " ") {
                let rest = line.dropFirst(tag.count + 1)
                let status = String(rest.prefix { $0 != " " })
                return Response(lines: lines, literals: literals, status: status, text: String(rest.dropFirst(status.count)).trimmingCharacters(in: .whitespaces))
            }
            lines.append(line)
        }
    }

    private func send(_ c: NWConnection, _ d: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: d, completion: .contentProcessed { e in if let e { cont.resume(throwing: e) } else { cont.resume() } })
        }
    }

    private func fill() async throws {
        guard let conn else { throw IMAPError.connect("Not connected.") }
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                if let err { cont.resume(throwing: err) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if done { cont.resume(throwing: IMAPError.connect("The mail server closed the connection.")) }
                else { cont.resume(returning: Data()) }
            }
        }
        buffer.append(chunk)
    }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.firstRange(of: Data("\r\n".utf8)) {
                let line = buffer[buffer.startIndex..<r.lowerBound]; buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let d = buffer.prefix(n); buffer.removeFirst(n); return Data(d)
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// Connect, sign in, open the inbox and sign out: the Email step's "Test Connection".
    public static func test(host: String, port: UInt16 = 993, user: String, password: String) async throws -> Int {
        let c = IMAPClient(host: host, port: port)
        try await c.connect(); defer { Task { await c.logout() } }
        try await c.login(user: user, password: password)
        return try await c.select()
    }
}

public enum IMAPError: LocalizedError, Equatable {
    case connect(String), auth(String), protocolError(String)
    public var errorDescription: String? {
        switch self {
        case .connect(let m), .auth(let m): m
        case .protocolError(let m): "Unexpected reply from the mail server: \(m.prefix(160))"
        }
    }
}

/// Provider presets for the Email step.
public struct MailPreset: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String, name: String, host: String, help: String
    public static let all: [MailPreset] = [
        .init(key: "gmail", name: "Gmail", host: "imap.gmail.com", help: "https://support.google.com/accounts/answer/185833"),
        .init(key: "outlook", name: "Outlook", host: "outlook.office365.com", help: "https://support.microsoft.com/account-billing/5896ed9b-4263-e681-128a-a6f2979a7944"),
        .init(key: "icloud", name: "iCloud", host: "imap.mail.me.com", help: "https://support.apple.com/102654"),
        .init(key: "custom", name: "Other", host: "", help: ""),
    ]
}
