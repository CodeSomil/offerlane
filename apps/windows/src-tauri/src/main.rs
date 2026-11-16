// Offerlane for Windows, v4 P4.2 spike: a Tauri 2 shell whose web side (apps/windows/src) runs libs/core's apply engine.
// `offerlane --selftest` serves the mock career sites, runs the 14 apply checks, a Credential Manager round-trip and 3 shell security checks,
// prints PASS/FAIL lines and exits 0 only when every one passes.
// Release builds use the GUI subsystem; with --selftest they write to a redirected stdout or borrow the parent's console.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod apply;
mod nav;
mod serve;
mod toast;
mod vault;

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{webview::NewWindowResponse, AppHandle, Manager, Webview, WebviewUrl, WebviewWindowBuilder};
use vault::Account;

struct SelfTest { base: Option<String> }
static DONE: AtomicBool = AtomicBool::new(false);
const SELFTEST_LIMIT: Duration = Duration::from_secs(600);

#[tauri::command]
fn selftest_base(webview: Webview, state: tauri::State<SelfTest>) -> Result<Option<String>, String> {
    apply::main_only(&webview)?;
    Ok(state.base.clone())
}

#[tauri::command]
fn selftest_log(webview: Webview, state: tauri::State<SelfTest>, line: String) -> Result<(), String> {
    apply::main_only(&webview)?;
    if state.base.is_some() { println!("{line}"); }
    Ok(())
}

#[tauri::command]
fn selftest_done(app: AppHandle, webview: Webview, state: tauri::State<SelfTest>, passed: usize, total: usize) -> Result<(), String> {
    apply::main_only(&webview)?;
    if state.base.is_none() || DONE.swap(true, Ordering::SeqCst) { return Ok(()); }
    let ok = total > 0 && passed == total;
    println!("{} {passed}/{total}", if ok { "SELFTEST PASSED" } else { "SELFTEST FAILED" });
    apply::clean_temp(&app);
    app.exit(if ok { 0 } else { 1 });
    Ok(())
}

#[tauri::command]
fn vault_read(webview: Webview, host: String) -> Result<Option<Account>, String> {
    apply::main_only(&webview)?;
    vault::read(&host)
}

#[tauri::command]
fn vault_save(webview: Webview, host: String, email: String, password: String) -> Result<(), String> {
    apply::main_only(&webview)?;
    vault::save(&host, &Account { email, password })
}

#[tauri::command]
fn vault_delete(webview: Webview, host: String) -> Result<(), String> {
    apply::main_only(&webview)?;
    vault::delete(&host)
}

/// A GUI-subsystem exe starts without a console. A redirected stdout (a CI pipe) already works; otherwise use the parent's.
#[cfg(all(windows, not(debug_assertions)))]
fn console_for_selftest() {
    use windows::Win32::System::Console::{AttachConsole, GetStdHandle, ATTACH_PARENT_PROCESS, STD_OUTPUT_HANDLE};
    // SAFETY: plain Win32 calls with no pointers; failure just leaves output unseen.
    unsafe {
        if GetStdHandle(STD_OUTPUT_HANDLE).map_or(true, |h| h.is_invalid()) { let _ = AttachConsole(ATTACH_PARENT_PROCESS); }
    }
}
#[cfg(not(all(windows, not(debug_assertions))))]
fn console_for_selftest() {}

#[tauri::command]
fn secret_read(webview: Webview, name: String) -> Result<Option<String>, String> {
    apply::main_only(&webview)?;
    vault::secret_read(&name)
}

#[tauri::command]
fn secret_save(webview: Webview, name: String, value: String) -> Result<(), String> {
    apply::main_only(&webview)?;
    vault::secret_save(&name, &value)
}

#[tauri::command]
fn secret_delete(webview: Webview, name: String) -> Result<(), String> {
    apply::main_only(&webview)?;
    vault::secret_delete(&name)
}

/// A sync command: it runs on the main thread, where WinRT's apartment is already set up.
#[tauri::command]
fn notify(webview: Webview, title: String, body: String) -> Result<(), String> {
    apply::main_only(&webview)?;
    toast::show(&title, &body)
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") { let _ = w.unminimize(); let _ = w.show(); let _ = w.set_focus(); }
}

/// The tray icon: Open brings the window back, Quit ends the app.
fn tray(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open Offerlane", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Offerlane", true, None::<&str>)?;
    let mut b = TrayIconBuilder::with_id("main").tooltip("Offerlane").menu(&Menu::with_items(app, &[&open, &quit])?)
        .on_menu_event(|app, e| match e.id.as_ref() { "open" => show_main(app), "quit" => app.exit(0), _ => {} });
    if let Some(i) = app.default_window_icon() { b = b.icon(i.clone()); }
    b.build(app)?;
    Ok(())
}

fn main() {
    let selftest = std::env::args().skip(1).any(|a| a == "--selftest");
    if selftest { console_for_selftest(); }
    toast::set_app_id();
    let base = selftest.then(|| serve::start().expect("could not start the self-test server on 127.0.0.1"));
    tauri::Builder::default()
        .manage(SelfTest { base })
        .invoke_handler(tauri::generate_handler![
            selftest_base, selftest_log, selftest_done, vault_read, vault_save, vault_delete, secret_read, secret_save, secret_delete, notify,
            apply::open_page, apply::close_page, apply::cdp_send
        ])
        .setup(move |app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("Offerlane")
                .inner_size(1100.0, 760.0)
                .devtools(cfg!(debug_assertions))
                .on_navigation(nav::main_allowed)
                .on_new_window(|url, _| { nav::open_outside(&url); NewWindowResponse::Deny })
                .build()?;
            if selftest {
                // A hung page must not hang CI: fail after the limit.
                let handle = app.handle().clone();
                std::thread::spawn(move || {
                    std::thread::sleep(SELFTEST_LIMIT);
                    if !DONE.swap(true, Ordering::SeqCst) {
                        println!("SELFTEST FAILED: no result after {} s", SELFTEST_LIMIT.as_secs());
                        apply::clean_temp(&handle);
                        handle.exit(2);
                    }
                });
            } else {
                apply::clean_temp(app.handle());
                tray(app)?;
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("could not start Offerlane")
        .run(|app, e| if let tauri::RunEvent::Exit = e { apply::clean_temp(app) });
}
