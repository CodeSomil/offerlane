import Foundation

/// Optional phone push through ntfy.sh with a private random topic (the user subscribes in the ntfy app).
public enum Ntfy {
    public static func url(topic: String) -> URL { URL(string: "https://ntfy.sh/\(topic)")! }

    public static func send(topic: String, title: String, message: String, click: URL? = nil, session: URLSession = .shared) async throws {
        var r = URLRequest(url: url(topic: topic)); r.httpMethod = "POST"; r.timeoutInterval = 15
        r.setValue(title, forHTTPHeaderField: "Title")
        if let click { r.setValue(click.absoluteString, forHTTPHeaderField: "Click") }
        r.httpBody = Data(message.utf8)
        let (_, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.unreachable("ntfy.sh didn't accept the message.") }
    }
}
