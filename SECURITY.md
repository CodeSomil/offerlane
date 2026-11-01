# Security policy

## Reporting a vulnerability
Please report security issues privately through GitHub's **Report a vulnerability** (Security tab → Advisories). Don't open a public issue. You'll get a reply within a week.

## Design
- Secrets (AI API key, email app password, career-site passwords) are stored only in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). They're never written to files, logs or exports.
- Logs redact email addresses, phone numbers and API keys.
- Showing a saved password requires Touch ID or the Mac's password.
- LaTeX runs with tectonic's `--untrusted` mode. The bundled binary is pinned by SHA-256.
- The release script refuses to package a binary containing build-machine paths.
- No telemetry. Network traffic goes only to the chosen AI provider, the public job-board APIs, the career sites you apply to, and (if enabled) your IMAP server and ntfy.sh.
