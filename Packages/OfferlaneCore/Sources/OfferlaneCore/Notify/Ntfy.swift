import Foundation

/// Optional phone push through ntfy.sh with a private random topic (the user subscribes in the ntfy app).
public enum Ntfy {
    /// The topic is reduced to letters, digits, "-" and "_", so any typed value gives a valid address.
    public static func url(topic: String) -> URL {
        let safe = String(topic.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }.map(Character.init))
        return URL(string: "https://ntfy.sh/\(safe.isEmpty ? "offerlane" : safe)")!
    }

    public static func send(topic: String, title: String, message: String, click: URL? = nil, session: URLSession = .shared) async throws {
        var r = URLRequest(url: url(topic: topic)); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue(title, forHTTPHeaderField: "Title")
        if let click { r.setValue(click.absoluteString, forHTTPHeaderField: "Click") }
        r.httpBody = Data(message.utf8)
        let (_, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.unreachable("ntfy.sh didn't accept the message.") }
    }
}
