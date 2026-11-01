import Foundation
import WebKit
import OfferlaneCore

/// The Apply browser: one WKWebView with a persistent cookie store (logins persist), a standard Safari user agent,
/// and the autofill script injected into every frame.
@MainActor
final class WebPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    private(set) var loading = false
    private static let storeID = UUID(uuidString: "6A0B3C1E-5D2F-4E8A-9B7C-1F2E3D4C5B6A")!
    static let script: String = (try? String(contentsOf: Bundle.main.url(forResource: "autofill", withExtension: "js")!, encoding: .utf8)) ?? ""

    init(persistent: Bool = true) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = persistent ? WKWebsiteDataStore(forIdentifier: Self.storeID) : .nonPersistent()
        cfg.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: cfg)
        web.customUserAgent = HTTP.userAgent
        web.isInspectable = true
        super.init()
        web.navigationDelegate = self; web.uiDelegate = self
    }

    var url: URL? { web.url }
    var host: String { guard let u = web.url, let h = u.host else { return "" }; return u.port.map { "\(h):\($0)" } ?? h }

    func load(_ url: URL) async { loading = true; web.load(URLRequest(url: url)); await waitForLoad() }

    func waitForLoad(timeout: TimeInterval = 20) async {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 150_000_000)
        while Date() < end {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        loading = false
    }

    /// Calls window.__ja.<fn>(...args) in the page and returns its JSON result.
    @discardableResult
    func call(_ fn: String, _ args: [Any] = []) async -> JSONValue {
        let body = "if (!window.__ja) { eval(src); } const r = await window.__ja[fn](...args); return JSON.stringify(r === undefined ? null : r);"
        do {
            let out = try await web.callAsyncJavaScript(body, arguments: ["fn": fn, "args": args, "src": Self.script], in: nil, contentWorld: .page)
            guard let s = out as? String else { return .null }
            return (try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))) ?? .null
        } catch {
            Log.info("js \(fn): \(error.localizedDescription)")
            return .null
        }
    }
    func bool(_ fn: String, _ args: [Any] = []) async -> Bool { if case .bool(true) = await call(fn, args) { return true }; return false }
    func string(_ fn: String, _ args: [Any] = []) async -> String { (await call(fn, args)).string ?? "" }

    func fields() async -> [FormField] {
        let v = await call("collect")
        guard let data = try? JSONEncoder().encode(v) else { return [] }
        return (try? JSONDecoder().decode([FormField].self, from: data)) ?? []
    }

    /// Plain JavaScript in the page (self-tests read mock-site state with this).
    func eval(_ js: String) async -> Any? { try? await web.evaluateJavaScript(js) }

    // Navigation delegate
    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { loading = true }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loading = false }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { loading = false }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { loading = false }
    /// Links that open a new window load in place, so the agent keeps one page.
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { w.load(URLRequest(url: u)) }
        return nil
    }
}
