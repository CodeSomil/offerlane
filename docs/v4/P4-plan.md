# P4 Platforms plan (approved by the human 2026-11-16: H1–H5 as proposed)

Scope comes from OFFERLANE_V4.md P4, D2/D3/D4 and docs/WINDOWS_PLAN.md. The order is fixed: Windows spike → Windows app → iOS companion → Android. Nothing else on Windows starts until the spike passes all 14 apply self-tests (App/Sources/Apply/SelfTest.swift `ApplySelfTest`).

## Facts that shape the plan
- This machine is a Mac with no Rust toolchain and no Windows. WebView2 runs only on Windows, so the spike's real run needs a Windows host: a GitHub Actions `windows-latest` job (the repo has no remote yet) or a Windows VM/PC the human runs. HUMAN BLOCKER for the go/no-go itself.
- The Mac apply surface is small. `WebPage` gives load / waitForLoad / `call(fn, args)` in an isolated world / main-world eval / file input / nav policy. `ApplyEngine` (303 lines) holds the decisions. `autofill.js` (169 lines) is reused as is.
- WebView2 and Chromium speak the same DevTools protocol (`Page.createIsolatedWorld`, `Runtime.evaluate` with a contextId, `DOM.setFileInputFiles`). So a driver written against CDP can be proved here on Playwright Chromium, and on Windows only the transport changes.
- P3 already built a full web UI (apps/web) on libs/core (TS ports of Guard, ranking, tailoring, AnswerRules, pipeline, sync).

## Decisions needed before code (human)
H1. Windows architecture. Proposal: Tauri 2 shell = apps/web (same React UI, tokens) + a thin Rust layer for OS-only work: Credential Manager/DPAPI, the WebView2 apply window + CDP transport, files, SQLite later if needed. The apply decisions are ported once to TS (`libs/core/src/apply.ts`) and shared. This replaces WINDOWS_PLAN's 5–6 week "Rust core port" with reuse. Alternative: WINDOWS_PLAN as written (Rust core). Fallback after a NO-GO stays .NET/WinUI 3.
H2. Where the spike runs. Proposal: add a git remote and a `windows-latest` CI job (`spike-windows`) that builds the Tauri app and runs `--selftest`; the human can also run the built exe on a real PC. Without a remote I stop after P4.2 with everything built and runnable, and report.
H3. Dependencies (Protocol 7). Pinned, 14-day minimum age.
| name | license | why | ~size | alternative |
|---|---|---|---|---|
| Rust toolchain via rustup (local + CI) | MIT/Apache-2 | build the Tauri shell | 1 GB dev | build on CI only |
| tauri 2 + tauri-build, @tauri-apps/cli (dev), @tauri-apps/api | MIT/Apache-2 | Windows shell | 15 MB exe | .NET/WinUI 3 |
| webview2-com + windows (crates) | MIT/Apache-2 | CDP calls, DPAPI | in exe | raw COM bindings |
| keyring (crate) | MIT/Apache-2 | Credential Manager round-trip | small | `windows` crate CredWrite directly |
H4. iOS companion data. It needs the user's data, and the Mac doesn't sync yet. Proposal: before iOS, port the SYNC_CRYPTO client to Swift in OfferlaneCore (with the P3 keyring change: AK ‖ key id) and add Mac "Sync now". iOS = SwiftUI on OfferlaneCore, triage (approve/skip) + local notifications. Remote push (APNs) needs the Developer account: HUMAN BLOCKER, so that part is skipped.
H5. Android. Proposal: Tauri 2 Android reusing the Windows shell (one UI for web/Windows/Android), assisted apply only (D4), no Play upload (account: HUMAN BLOCKER). Alternative: an installable PWA of apps/web (least code) or native Kotlin.

## Tasks (one commit each, `v4 P4.<t>`; several sessions)
P4.1 `libs/core/src/apply.ts`: a line-for-line port of ApplyEngine (fill, workdayControls, workday, generic, run, outcomes, isConfirmation), driven by a `Page` interface (load, waitForLoad, call, eval, setFiles, host). There's a Playwright CDP `Page` in a test helper. `apps/web/e2e/apply.e2e.ts` runs the 14 checks from SelfTest.swift on the same SelfTest/*.html pages, one check per test. The vault is an in-memory test fake here.
P4.2 `apps/windows` (Tauri 2): Rust commands for CDP on a second WebView2 window (isolated world, setFileInputFiles), a per-profile user-data folder, the nav allowlist (WebPage.allowed), NewWindowRequested loading in place, no devtools in release, Credential Manager save/read/delete. `--selftest` serves the SelfTest pages on 127.0.0.1, runs apply.ts through the Rust `Page`, prints PASS/FAIL ×14 plus the Credential Manager round-trip, and exits non-zero on any failure. CI job `spike-windows` (H2). → GO/NO-GO (human reads the run).
P4.3 (after GO) Windows app: apps/web inside the shell, AI key and passwords in Credential Manager instead of IndexedDB, the apply window behind the human's click (never submits), the tray icon, Windows toasts, and an unsigned NSIS/MSI build. Signing is a HUMAN BLOCKER (Azure Trusted Signing or EV).
P4.4 Mac sync client (H4) against the P2 API + the web's fixtures, so all clients open each other's blobs.
P4.5 iOS companion target: sign-in, sync pull, Today/triage, local notifications for new matches and stale roles. Simulator UI tests.
P4.6 Android (H5), then the gates, a review and the handoff.

## Gates
1. Spike: 14/14 apply checks + the Credential Manager round-trip on real WebView2 (a Windows run log). The same 14/14 on Playwright Chromium.
2. The Mac `ApplySelfTest` still passes 14/14, and the existing gates stay green (full `scripts/test.sh`, privacy gate, secret scan, brand, contrast).
3. Windows app: web e2e flows pass in the shell; no submit is ever clicked (test).
4. Cross-client sync: Mac, web and iOS each open the others' blobs (shared fixture).
5. A fresh-subagent review has no open High/Medium.

## Not in P4
Store submission and signing (accounts: HUMAN BLOCKER). APNs push. Apply automation on mobile (D4). Replacing the Mac core.
