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

/// The sign-in provider the main window may visit (auth.ts sends the whole page there and back, code + PKCE).
/// SHORTCUT: the dev issuer, apps/web/vite.config.ts's default; the real provider (P2 H2) changes both (test/shell.test.ts pins them).
pub const SIGN_IN: &[&str] = &["http://localhost:9000"];

/// The main window holds the IPC, so it only shows Offerlane's own page (tauri.localhost on Windows) and the sign-in pages.
pub fn main_allowed(url: &tauri::Url) -> bool {
    is_app(url) || SIGN_IN.contains(&url.origin().ascii_serialization().as_str())
}

/// Offerlane's own origin, including its blob: URLs (draft.ts downloads); a blob URL's origin is the page that made it.
pub fn is_app(url: &tauri::Url) -> bool {
    if url.scheme() == "tauri" { return url.host_str() == Some("localhost"); }
    matches!(url.origin().ascii_serialization().as_str(), "http://tauri.localhost" | "https://tauri.localhost")
}

/// A link the main window opens (a job posting, "Get a key"): web pages go to the default browser, nothing else.
pub fn open_outside(url: &tauri::Url) {
    if matches!(url.scheme(), "http" | "https") && allowed(url) { imp::open(url.as_str()) }
}

#[cfg(windows)]
mod imp {
    use windows::core::{w, HSTRING, PCWSTR};
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    // SAFETY: every pointer is a live HSTRING or null; the scheme was checked to be http(s), so this only starts a browser.
    pub fn open(url: &str) { unsafe { ShellExecuteW(None, w!("open"), &HSTRING::from(url), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL); } }
}

#[cfg(not(windows))]
mod imp { pub fn open(_: &str) {} }

#[cfg(test)]
mod tests {
    use super::{allowed, main_allowed};

    #[test]
    fn main_window_stays_home() {
        let ok = |u: &str| main_allowed(&u.parse().unwrap());
        for u in ["http://tauri.localhost/index.html", "https://tauri.localhost/#/find", "tauri://localhost/", "http://localhost:9000/authorize?x=1", "blob:http://tauri.localhost/1-2"] { assert!(ok(u), "{u}"); }
        for u in ["blob:https://evil.com/1", "https://jobs.example.com/", "http://localhost:9001/", "http://localhost:9000@evil.com/", "http://tauri.localhost.evil.com/", "file:///C:/x", "about:blank", "data:text/html,hi", "javascript:alert(1)"] { assert!(!ok(u), "{u}"); }
    }

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
