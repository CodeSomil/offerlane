# Offerlane for Windows (v4 P4.2 spike)

A Tauri 2 shell. The page (`src/`) runs `libs/core`'s apply engine. Rust (`src-tauri/`) only does what needs Windows:
- the apply window: a second WebView2 window that `cdp.ts` drives over the DevTools protocol;
- the navigation allowlist and new windows loaded in place;
- Credential Manager for apply-account passwords.

## Build and run (Windows)

You need Node 22, rustup (the toolchain is pinned in `src-tauri/rust-toolchain.toml`) and the WebView2 runtime (part of Windows 11).

```sh
npx -y pnpm@11.28.9 install --filter "@offerlane/windows..."
npx -y pnpm@11.28.9 --filter @offerlane/windows build
cd apps/windows/src-tauri
cargo test --locked
cargo build --locked --features tauri/custom-protocol
./target/debug/offerlane.exe --selftest
```

`--selftest` prints 14 `PASS`/`FAIL` apply lines, then the Credential Manager line, then three shell security lines (no IPC from a career page, no file://, no tauri.localhost), then the app's own "Fill in application" path filling a form without submitting it, then `SELFTEST PASSED 19/19`. It exits non-zero if any check fails. The CI job `spike-windows` runs exactly these steps.

## On the Mac

`cargo test` runs the platform-neutral tests (nav allowlist, self-test server, vault names). To type-check the Windows-only code without a Windows machine:

```sh
rustup target add x86_64-pc-windows-msvc
cargo check --target x86_64-pc-windows-msvc
```

This needs an `llvm-rc` on `PATH` for tauri-build's resource step. A stub that writes an empty `.res` is enough for `check`, because nothing is linked.
