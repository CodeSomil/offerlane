# Offerlane for Windows: plan (no code yet)

The Mac app is SwiftUI (~6k lines of UI) on a Swift core (`OfferlaneCore`, ~6k lines, ~2.3k lines of tests). SwiftUI doesn't run on Windows, so the UI is rewritten whatever we choose. The real question is the *core* and the *apply browser*.

The apply browser is the hard part. It needs:
- an embedded Chromium-class engine;
- script injection into an **isolated world**;
- file-input upload;
- per-profile persistent cookies;
- a navigation policy.

## Options compared
| | **Tauri 2** (Rust + WebView2) | **.NET 8 + WinUI 3** (C#, WebView2) | **Electron** (Node + Chromium) |
|---|---|---|---|
| Installer size | ~10–15 MB (uses the WebView2 runtime in Windows 10/11) | ~60–90 MB self-contained | ~120–180 MB (ships Chromium) |
| Apply browser | Second WebView2 window. Isolated world and file upload through the DevTools protocol (`Page.createIsolatedWorld`, `DOM.setFileInputFiles`) via `webview2-com`. Workable, lowest-level | Same WebView2 features with first-class C# APIs (`CallDevToolsProtocolMethodAsync`). Most direct | Easiest: `webContents.executeJavaScriptInIsolatedWorld`, `debugger` API, session partitions per profile |
| Secrets | `keyring` crate (Credential Manager), `windows` crate for DPAPI | `ProtectedData` (DPAPI) and Credential Manager, built in | `safeStorage` (DPAPI); Credential Manager needs a native module |
| UI | Web UI (React/TS). Design tokens port 1:1; good accessibility with care | Native Fluent controls, Narrator support for free; XAML learning curve | Web UI, same as Tauri |
| Memory / startup | Low / fast | Medium | High / slower |
| Security posture | Small attack surface; Rust core; strict capability allowlist | Mature; good signing and MSIX story | Large surface; must harden (contextIsolation, sandbox, no nodeIntegration) |
| Cross-platform later | Could also replace the Mac app's core | Windows only | Could replace the Mac app entirely (at a UX cost) |

**Also considered: Swift on Windows.** Reuse `OfferlaneCore` as-is behind a C ABI, with a WinUI shell. Swift 6 does ship for Windows, but this core leans on Apple frameworks that don't exist there:
- Security / Keychain
- Network (IMAP, loopback)
- CryptoKit / CommonCrypto
- PDFKit
- LocalAuthentication

On top of that, GRDB's Windows support is unofficial, and packaging the Swift runtime with a C# UI adds a second toolchain to sign and debug. **Not recommended now**; revisit if Swift-on-Windows tooling matures.

## Recommendation: Tauri 2
- **Lean installer**, with the system WebView2 shared by the UI and the apply browser.
- **One Rust core** that could later back the Mac app too (via a C ABI), ending the two-codebases problem.
- **Strong security defaults** that fit Offerlane's promises.
- **Risk:** driving WebView2 through the DevTools protocol from Rust is the least-trodden path. Phase 0 proves it first.
- **Fallback:** if the spike fails, switch the shell to .NET/WinUI 3 and keep the rest of this plan, since the same WebView2 features apply. Electron is the last resort.

## Reuse vs rewrite
| Reused as-is | Ported (same logic, new language) | Rewritten |
|---|---|---|
| `autofill.js` (form filling, Workday controls), ~170 lines | Discovery adapters (Greenhouse, Lever, Ashby, Workable, SmartRecruiters, Workday), matcher, local scoring | All UI (screens, onboarding, Setup Center, Help, tour) |
| All prompts and their versions (`rank-v2`, `tailor-v1`…), the JSON reply shapes, the FakeLLM rules | Ranking, tailoring plan/guard/diff, the answer cache, token budgets | Apply engine glue (the WebView2 driver; the decisions mirror `ApplyEngine`) |
| SQL schema and migrations (SQLite works unchanged; same tables) | AnswerRules, visa/sponsor tagging, email rules and verification-link checks | Keychain → Credential Manager / DPAPI layer |
| Test fixtures (ATS JSON, mock apply sites, resumes, golden set, token budgets) | OAuth (PKCE, ID-token checks, loopback), PBKDF2, lockout | Touch ID → **Windows Hello** (`UserConsentVerifier`) |
| tectonic (official Windows build) + the pre-warmed cache; `LaTeX.esc` rules | IMAP and Gmail clients, MIME parsing | Menu-bar item → system tray icon |
| Branding (SVG logo, colours, contrast-checked tokens), Help text, docs | Resume extraction (PDF via `pdfium`/`pdf-extract`, DOCX via `zip` + XML with the same limits) | Notifications → Windows toast |
| Security review findings (as acceptance tests) | Safe downloader (allowlist, TLS, SHA-256, resume) | Signature check: `WinVerifyTrust` + expected publisher, not Team ID |

## Windows-specific items
- **Secrets:**
  - Credential Manager (generic credentials, per user, DPAPI-protected) for the AI key, IMAP password, Google tokens and career-site passwords.
  - DPAPI `CurrentUser` for the database key, if the database is encrypted. Windows makes this cheap, so do it.
- **WebView2:**
  - Require the Evergreen runtime (preinstalled on Windows 11; bootstrapper for Windows 10).
  - One user-data folder per profile, holding that profile's cookies.
  - `NavigationStarting` gives the scheme allowlist; `NewWindowRequested` loads in place; DevTools are off in Release.
- **Installer:**
  - MSI (WiX) or NSIS through the Tauri bundler, with a per-user install that needs no admin rights.
  - MSIX later for Store and auto-update.
  - Updates: Tauri updater with signed update manifests.
- **Code signing:**
  - Authenticode with an EV certificate or **Azure Trusted Signing** (cheapest; avoids SmartScreen warnings once the publisher has reputation).
  - Sign the app, the installer and the bundled tectonic.
  - Expect SmartScreen warnings for the first weeks.
- **Ollama for Windows:**
  - The official `OllamaSetup.exe` from its GitHub release, checked against its SHA-256 list and then `WinVerifyTrust` with the expected publisher.
  - Run with `/SILENT` after the user agrees.
  - Same local API on `localhost:11434`; same model choices by RAM and disk.
- **Claude Code on Windows:**
  - Native Windows build, installed the same verified way as on the Mac (manifest checksum + publisher signature, then `claude install`).
  - Its exact platform key and requirements (historically Git for Windows) must be checked at implementation time; the Setup Center would offer any missing prerequisite with the same verify-then-run rule.
- **Paths, processes and system checks:**
  - Data in `%APPDATA%\Offerlane\accounts\<id>\`, caches in `%LOCALAPPDATA%`.
  - Processes start through `CreateProcess` argv arrays (never `cmd /c`).
  - Health checks: Windows on ARM vs x64 (instead of Rosetta), free disk, offline.
- **Accessibility:** Narrator, high-contrast themes, text scaling (Settings → Text size), full keyboard navigation. Same contrast script for tokens.

## Phases and effort (one experienced developer; rough)
| Phase | Scope | Weeks |
|---|---|---|
| 0. Spike | Tauri + WebView2: inject `autofill.js` into an isolated world, upload a file, run the 14 apply self-test pages; Credential Manager round-trip | 1–2 |
| 1. Core port | Rust core: models, SQLite store and migrations, discovery adapters, ranking, cache/budgets, tailoring, email, OAuth, passwords. Port the core tests with the same fixtures | 5–6 |
| 2. UI | Design system, sign-in, 4-step first run, Find/Review/Applications/Resumes/Settings, Help, tour | 4–5 |
| 3. Apply engine | WebView2 driver mirroring `ApplyEngine` (never submits; host-bound passwords; verified links) | 2–3 |
| 4. Setup Center and packaging | Verified Claude Code and Ollama installers, health checks, MSI, signing, updater | 2 |
| 5. Hardening and beta | Port SecurityTests and FuzzTests, Narrator pass, clean-VM checklist (`docs/TESTING.md` adapted), private beta | 2–3 |
| **Total** | | **≈16–21 weeks** |

**Not included:** replacing the Mac app's core with the Rust one (2–3 weeks more, optional, after Windows ships).

**Go/no-go after Phase 0:** if WebView2 automation can't pass all 14 apply checks from Rust, switch the shell to .NET/WinUI 3 before Phase 1. The core work can then go to C#, or stay in Rust behind a C ABI.
