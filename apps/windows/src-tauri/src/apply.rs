// The apply window (WebPage.swift's role): a second WebView2 window that libs/core/src/cdp.ts drives over the DevTools
// protocol. Rust only moves CDP calls and two events; every decision stays in libs/core/src/apply.ts.
// - Navigation: WebPage.allowed's schemes only; a new-window request loads in the same window (career sites open tabs).
// - CDP params are never logged or put in an error: Runtime.evaluate carries the passwords being typed.
// - Devtools are off in release builds. Only the main window may call these commands (main_only).
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use tauri::{webview::NewWindowResponse, AppHandle, Manager, Webview, WebviewUrl, WebviewWindowBuilder};

use crate::nav;

static NEXT: AtomicU32 = AtomicU32::new(1);
const PREFIX: &str = "apply-";

pub fn main_only(w: &Webview) -> Result<(), String> {
    if w.label() == "main" { Ok(()) } else { Err("not allowed from this window".into()) }
}

/// A named profile ("default", "work") keeps its cookies in its own folder; None is a fresh folder, removed on close
/// (WebPage(persistent: false): the self-test needs every check to start signed out).
pub fn profile_name_ok(name: &str) -> bool {
    !name.is_empty() && name.len() <= 40 && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn data_dir(app: &AppHandle, label: &str, profile: Option<&str>) -> Result<PathBuf, String> {
    let root = app.path().app_local_data_dir().map_err(|e| e.to_string())?;
    let dir = match profile {
        Some(p) if profile_name_ok(p) => root.join("apply-profiles").join(p),
        Some(_) => return Err("bad profile name".into()),
        None => {
            let d = root.join("apply-temp").join(format!("{}-{label}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            d
        }
    };
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

#[tauri::command]
pub async fn open_page(app: AppHandle, webview: Webview, profile: Option<String>) -> Result<String, String> {
    main_only(&webview)?;
    let label = format!("{PREFIX}{}", NEXT.fetch_add(1, Ordering::Relaxed));
    let dir = data_dir(&app, &label, profile.as_deref())?;
    let (app2, label2) = (app.clone(), label.clone());
    let w = WebviewWindowBuilder::new(&app, &label, WebviewUrl::External("about:blank".parse().unwrap()))
        .title("Offerlane: apply")
        .inner_size(1200.0, 900.0)
        .data_directory(dir)
        .devtools(cfg!(debug_assertions))
        .on_navigation(nav::allowed)
        .on_new_window(move |url, _| {
            if nav::allowed(&url) {
                if let Some(w) = app2.get_webview_window(&label2) { let _ = w.navigate(url); }
            }
            NewWindowResponse::Deny
        })
        .build()
        .map_err(|e| e.to_string())?;
    cdp::subscribe(&app, &w, &label)?;
    Ok(label)
}

#[tauri::command]
pub async fn close_page(app: AppHandle, webview: Webview, label: String) -> Result<(), String> {
    main_only(&webview)?;
    if !label.starts_with(PREFIX) { return Err("not an apply window".into()); }
    if let Some(w) = app.get_webview_window(&label) { w.destroy().map_err(|e| e.to_string())?; }
    Ok(())
}

/// Removes this run's throwaway profiles (WebView2 holds them until its process ends, so this runs at exit).
pub fn clean_temp(app: &AppHandle) {
    if let Ok(root) = app.path().app_local_data_dir() {
        let _ = std::fs::remove_dir_all(root.join("apply-temp"));
    }
}

#[tauri::command]
pub async fn cdp_send(app: AppHandle, webview: Webview, label: String, method: String, params: serde_json::Value) -> Result<serde_json::Value, String> {
    main_only(&webview)?;
    if !label.starts_with(PREFIX) { return Err("not an apply window".into()); }
    let w = app.get_webview_window(&label).ok_or("the apply window is closed")?;
    cdp::call(&w, method, params).await
}

#[cfg(windows)]
mod cdp {
    use serde_json::{json, Value};
    use std::sync::mpsc;
    use std::time::Duration;
    use tauri::{AppHandle, Emitter, WebviewWindow};
    use webview2_com::{take_pwstr, CallDevToolsProtocolMethodCompletedHandler, DevToolsProtocolEventReceivedEventHandler};
    use windows::core::{HSTRING, PWSTR};

    // waitForLoad's "a navigation has started" signal (cdp.ts). Only frameId goes on to the main window.
    const EVENTS: [&str; 2] = ["Page.frameStartedLoading", "Page.frameStoppedLoading"];

    pub fn subscribe(app: &AppHandle, w: &WebviewWindow, label: &str) -> Result<(), String> {
        let (app, label) = (app.clone(), label.to_string());
        w.with_webview(move |pw| unsafe {
            let Ok(core) = pw.controller().CoreWebView2() else { return };
            for ev in EVENTS {
                let Ok(rx) = core.GetDevToolsProtocolEventReceiver(&HSTRING::from(ev)) else { continue };
                let (app, label) = (app.clone(), label.clone());
                let handler = DevToolsProtocolEventReceivedEventHandler::create(Box::new(move |_, args| {
                    let Some(args) = args else { return Ok(()) };
                    let mut p = PWSTR::null();
                    args.ParameterObjectAsJson(&mut p)?;
                    let params: Value = serde_json::from_str(&take_pwstr(p)).unwrap_or(Value::Null);
                    let _ = app.emit_to("main", "cdp-event", json!({ "label": label, "event": ev, "params": { "frameId": params.get("frameId") } }));
                    Ok(())
                }));
                let mut token = 0i64;
                let _ = rx.add_DevToolsProtocolEventReceived(&handler, &mut token);
            }
        })
        .map_err(|e| e.to_string())
    }

    pub async fn call(w: &WebviewWindow, method: String, params: Value) -> Result<Value, String> {
        let (tx, rx) = mpsc::channel::<Result<String, String>>();
        w.with_webview(move |pw| unsafe {
            let tx2 = tx.clone();
            let r = (|| -> windows::core::Result<()> {
                let core = pw.controller().CoreWebView2()?;
                let done = CallDevToolsProtocolMethodCompletedHandler::create(Box::new(move |hr, json| {
                    // On failure `json` is CDP's {code, message} error, which never echoes params.
                    let _ = tx2.send(hr.map(|_| json.clone()).map_err(|e| format!("{}: {json}", e.code())));
                    Ok(())
                }));
                core.CallDevToolsProtocolMethod(&HSTRING::from(method.as_str()), &HSTRING::from(params.to_string()), &done)
            })();
            if let Err(e) = r { let _ = tx.send(Err(format!("DevTools call failed: {}", e.code()))); }
        })
        .map_err(|e| e.to_string())?;
        let out = tauri::async_runtime::spawn_blocking(move || rx.recv_timeout(Duration::from_secs(30)))
            .await
            .map_err(|e| e.to_string())?
            .map_err(|_| "DevTools call timed out".to_string())??;
        serde_json::from_str(&out).map_err(|_| "DevTools reply was not JSON".into())
    }
}

#[cfg(not(windows))]
mod cdp {
    // The Mac builds the shell for unit tests only; the apply window needs WebView2's DevTools protocol.
    use tauri::{AppHandle, WebviewWindow};
    pub fn subscribe(_: &AppHandle, _: &WebviewWindow, _: &str) -> Result<(), String> { Ok(()) }
    pub async fn call(_: &WebviewWindow, _: String, _: serde_json::Value) -> Result<serde_json::Value, String> {
        Err("the apply window needs WebView2 (Windows)".into())
    }
}

#[cfg(test)]
mod tests {
    use super::profile_name_ok;

    #[test]
    fn profile_names_are_plain_folder_names() {
        for ok in ["default", "work-2"] { assert!(profile_name_ok(ok), "{ok}"); }
        for bad in ["", "..", "a/b", "a\\b", "Work", "c:", &"a".repeat(41)] { assert!(!profile_name_ok(bad), "{bad}"); }
    }
}
