// Apply-account passwords in Windows Credential Manager (generic credentials, this user only), as Vault.swift keeps them in
// the Keychain: one entry per career-site host holding {email, password}. The windows crate's CredWriteW/CredReadW/CredDeleteW
// directly (the P4 H3 alternative to the keyring crate, already in the build through wry). Passwords are never logged.
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, PartialEq, Clone)]
pub struct Account { pub email: String, pub password: String }

/// Credential Manager target name for a host, or None for anything that isn't a plain host[:port].
pub fn target(host: &str) -> Option<String> {
    let ok = !host.is_empty() && host.len() <= 253
        && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':' | '[' | ']'));
    ok.then(|| format!("Offerlane/apply/{}", host.to_ascii_lowercase()))
}

pub fn read(host: &str) -> Result<Option<Account>, String> {
    // about:blank / data: pages have no host: nothing saved there (Vault.swift returns nil), so the engine hands over.
    if host.is_empty() { return Ok(None); }
    let t = target(host).ok_or("bad host")?;
    match imp::read(&t)? {
        None => Ok(None),
        Some(blob) => serde_json::from_slice(&blob).map(Some).map_err(|_| "unreadable credential".into()),
    }
}

pub fn save(host: &str, account: &Account) -> Result<(), String> {
    let t = target(host).ok_or("bad host")?;
    let blob = serde_json::to_vec(account).map_err(|e| e.to_string())?;
    imp::write(&t, &account.email, &blob)
}

pub fn delete(host: &str) -> Result<(), String> { imp::delete(&target(host).ok_or("bad host")?) }

/// Offerlane's own secrets under fixed names: "ai" is the remembered AI config (provider, key, models) as JSON.
pub fn secret_target(name: &str) -> Option<String> { matches!(name, "ai").then(|| format!("Offerlane/secret/{name}")) }
/// CRED_MAX_CREDENTIAL_BLOB_SIZE (5 * 512 bytes).
const MAX_SECRET: usize = 2560;

pub fn secret_save(name: &str, value: &str) -> Result<(), String> {
    let t = secret_target(name).ok_or("unknown secret")?;
    if value.len() > MAX_SECRET { return Err("too long for Credential Manager".into()); }
    imp::write(&t, "offerlane", value.as_bytes())
}

pub fn secret_read(name: &str) -> Result<Option<String>, String> {
    let t = secret_target(name).ok_or("unknown secret")?;
    Ok(imp::read(&t)?.and_then(|b| String::from_utf8(b).ok()))
}

pub fn secret_delete(name: &str) -> Result<(), String> { imp::delete(&secret_target(name).ok_or("unknown secret")?) }

#[cfg(windows)]
mod imp {
    use windows::core::{HSTRING, PWSTR};
    use windows::Win32::Foundation::ERROR_NOT_FOUND;
    use windows::Win32::Security::Credentials::{CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC};

    fn not_found(e: &windows::core::Error) -> bool { e.code() == ERROR_NOT_FOUND.to_hresult() }

    pub fn write(target: &str, user: &str, blob: &[u8]) -> Result<(), String> {
        let (t, u) = (HSTRING::from(target), HSTRING::from(user));
        let mut blob = blob.to_vec(); // CREDENTIALW wants a *mut
        let c = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: PWSTR(t.as_ptr() as *mut _),
            UserName: PWSTR(u.as_ptr() as *mut _),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            ..Default::default()
        };
        unsafe { CredWriteW(&c, 0) }.map_err(|e| format!("Credential Manager refused: {}", e.code()))
    }

    pub fn read(target: &str) -> Result<Option<Vec<u8>>, String> {
        let mut p: *mut CREDENTIALW = std::ptr::null_mut();
        match unsafe { CredReadW(&HSTRING::from(target), CRED_TYPE_GENERIC, None, &mut p) } {
            Ok(()) => unsafe {
                let c = &*p;
                // Another tool may have written an empty entry under this name: a null blob is not a valid slice.
                let v = if c.CredentialBlob.is_null() || c.CredentialBlobSize == 0 { Vec::new() }
                    else { std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize).to_vec() };
                CredFree(p as *const _);
                Ok(Some(v))
            },
            Err(e) if not_found(&e) => Ok(None),
            Err(e) => Err(format!("Credential Manager refused: {}", e.code())),
        }
    }

    pub fn delete(target: &str) -> Result<(), String> {
        match unsafe { CredDeleteW(&HSTRING::from(target), CRED_TYPE_GENERIC, None) } {
            Ok(()) => Ok(()),
            Err(e) if not_found(&e) => Ok(()),
            Err(e) => Err(format!("Credential Manager refused: {}", e.code())),
        }
    }
}

#[cfg(not(windows))]
mod imp {
    // The shell builds on the Mac for its unit tests only; there is no store here, so the engine hands over (as on a refusal).
    const NO: &str = "Credential Manager is Windows only";
    pub fn write(_: &str, _: &str, _: &[u8]) -> Result<(), String> { Err(NO.into()) }
    pub fn read(_: &str) -> Result<Option<Vec<u8>>, String> { Err(NO.into()) }
    pub fn delete(_: &str) -> Result<(), String> { Err(NO.into()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_names() {
        assert_eq!(target("Jobs.Example.com").as_deref(), Some("Offerlane/apply/jobs.example.com"));
        assert_eq!(target("127.0.0.1:5173").as_deref(), Some("Offerlane/apply/127.0.0.1:5173"));
        assert_eq!(target("[::1]:80").as_deref(), Some("Offerlane/apply/[::1]:80"));
        assert_eq!(read("").unwrap(), None);
        for bad in ["", "a/b", "a b", "*", "x\u{0}y", "é.com", &"a".repeat(254)] { assert!(target(bad).is_none(), "{bad:?}"); }
    }

    #[test]
    fn secret_names() {
        assert_eq!(secret_target("ai").as_deref(), Some("Offerlane/secret/ai"));
        for bad in ["", "AI", "ai/x", "../apply/x", "other"] { assert!(secret_target(bad).is_none(), "{bad:?}"); }
        assert!(secret_save("ai", &"x".repeat(MAX_SECRET + 1)).unwrap_err().contains("too long"));
        assert!(secret_read("nope").is_err());
    }

    // The real store: Windows only (CI's spike-windows job runs `cargo test`). A fixed host under .invalid never names a real site.
    #[cfg(windows)]
    #[test]
    fn credential_manager_round_trip() {
        let host = "offerlane-unit-test.invalid";
        let a = Account { email: "t@example.com".into(), password: "pw-Ä1!".into() };
        delete(host).unwrap();
        assert_eq!(read(host).unwrap(), None);
        save(host, &a).unwrap();
        assert_eq!(read(host).unwrap(), Some(a));
        delete(host).unwrap();
        assert_eq!(read(host).unwrap(), None);
    }

    #[cfg(windows)]
    #[test]
    fn secret_round_trip() {
        // The real "ai" entry belongs to the user: keep what is there and put it back.
        let before = secret_read("ai").unwrap();
        secret_save("ai", r#"{"provider":"openrouter","key":"sk-or-Ä"}"#).unwrap();
        assert_eq!(secret_read("ai").unwrap().as_deref(), Some(r#"{"provider":"openrouter","key":"sk-or-Ä"}"#));
        secret_delete("ai").unwrap();
        assert_eq!(secret_read("ai").unwrap(), None);
        if let Some(v) = before { secret_save("ai", &v).unwrap(); }
    }
}
