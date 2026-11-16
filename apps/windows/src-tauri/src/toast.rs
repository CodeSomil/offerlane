// Windows toasts (v4 P4.3e) through WinRT's ToastNotificationManager in the windows crate (no notification plugin).
// A desktop app needs an AppUserModelID for toasts: main.rs sets it for the process, and the installer's Start-menu shortcut
// carries the same id (the bundle identifier). SHORTCUT: unverified without that shortcut (a bare exe, CI); a failed toast is ignored.
pub const APP_ID: &str = "com.somilmanke.offerlane";
const MAX_TITLE: usize = 100;
const MAX_BODY: usize = 300;

/// XML text content: the page's strings must not become toast markup.
pub fn esc(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).map(|c| match c { '&' => "&amp;".into(), '<' => "&lt;".into(), '>' => "&gt;".into(), '"' => "&quot;".into(), '\'' => "&apos;".into(), c => c.to_string() }).collect()
}

pub fn xml(title: &str, body: &str) -> String {
    let cut = |s: &str, n: usize| s.chars().take(n).collect::<String>();
    format!("<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual></toast>", esc(&cut(title, MAX_TITLE)), esc(&cut(body, MAX_BODY)))
}

#[cfg(windows)]
pub fn show(title: &str, body: &str) -> Result<(), String> {
    use windows::core::HSTRING;
    use windows::Data::Xml::Dom::XmlDocument;
    use windows::UI::Notifications::{ToastNotification, ToastNotificationManager};
    let run = || -> windows::core::Result<()> {
        let doc = XmlDocument::new()?;
        doc.LoadXml(&HSTRING::from(xml(title, body)))?;
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_ID))?.Show(&ToastNotification::CreateToastNotification(&doc)?)
    };
    run().map_err(|e| format!("Windows wouldn't show the notification: {}", e.code()))
}

#[cfg(not(windows))]
pub fn show(_: &str, _: &str) -> Result<(), String> { Err("notifications are Windows only".into()) }

/// The process's AppUserModelID, so its toasts are attributed to Offerlane.
#[cfg(windows)]
pub fn set_app_id() {
    // SAFETY: a constant, valid HSTRING; failing only means toasts may be attributed differently.
    unsafe { let _ = windows::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID(&windows::core::HSTRING::from(APP_ID)); }
}
#[cfg(not(windows))]
pub fn set_app_id() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_text_cannot_become_markup() {
        assert_eq!(xml("A & B", "<b>x</b> \"q\" 'a'"),
            "<toast><visual><binding template=\"ToastGeneric\"><text>A &amp; B</text><text>&lt;b&gt;x&lt;/b&gt; &quot;q&quot; &apos;a&apos;</text></binding></visual></toast>");
        assert!(!xml("t", "a\u{0}b\nc").contains('\u{0}'));
        assert_eq!(xml(&"é".repeat(500), "").matches('é').count(), MAX_TITLE);
    }

    #[test]
    fn app_id_is_the_bundle_identifier() {
        let conf: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        assert_eq!(conf["identifier"], APP_ID);
    }
}
