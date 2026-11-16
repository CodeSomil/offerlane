// WebPage.allowed (App/Sources/Apply/WebPage.swift): the apply window only loads web pages. No file://, no custom app
// schemes (they would hand control to another app), no javascript: URLs.
// On top of the Mac's list: no *.localhost host. WebView2 serves Offerlane's own page at http://tauri.localhost in every
// window, and IPC from that origin counts as local, so a career site must not be able to send the apply window there.
// shortcut: Tauri allows a URL it can't parse without asking us (tauri-runtime-wry on_navigation); Chromium normalises
// URLs first, so revisit only if WebView2 ever hands over raw ones.
pub fn allowed(url: &tauri::Url) -> bool {
    let web = matches!(url.scheme().to_ascii_lowercase().as_str(), "https" | "http" | "about" | "blob" | "data");
    let host = url.host_str().unwrap_or("").trim_end_matches('.').to_ascii_lowercase();
    web && host != "localhost" && !host.ends_with(".localhost")
}

#[cfg(test)]
mod tests {
    use super::allowed;

    #[test]
    fn same_list_as_the_mac() {
        let ok = |u: &str| allowed(&u.parse().unwrap());
        for u in ["https://jobs.example.com/a", "http://127.0.0.1:5173/simple.html", "HTTPS://X.COM", "about:blank", "blob:https://x.com/1", "data:text/html,hi"] { assert!(ok(u), "{u}"); }
        for u in ["file:///C:/Windows/win.ini", "javascript:alert(1)", "ms-settings:privacy", "mailto:a@b.c", "tauri://localhost", "ipc://localhost", "chrome://settings", "edge://settings"] { assert!(!ok(u), "{u}"); }
    }

    #[test]
    fn never_the_apps_own_origin() {
        for u in ["http://tauri.localhost/", "http://TAURI.localhost./x", "http://ipc.localhost/vault_read", "https://localhost/", "http://a.b.localhost:80/"] {
            assert!(!allowed(&u.parse().unwrap()), "{u}");
        }
    }
}
