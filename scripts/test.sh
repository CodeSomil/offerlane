#!/bin/bash
# Run every automated test: OfferlaneCore unit + integration tests, then UI tests.
# Usage: scripts/test.sh [core|cloud|web|ui|apply|real|all]
#   core:  OfferlaneCore (Swift) + its TypeScript port's parity test (libs/core)
#   cloud: the TypeScript workspace (apps/*, libs/*): frozen install, typecheck, contract drift check, vitest
#   web:   apps/web end to end (Playwright + axe, Chromium) against the built app with stubbed AI hosts, then the extension e2e
#   apply: in-app apply engine against the bundled mock sites (WebKit needs the app process)
#   real:  real-site smoke tests (Greenhouse, Lever, Ashby, Workday); nothing is submitted, no accounts created
set -euo pipefail
cd "$(dirname "$0")/.."
WHAT="${1:-all}"
if [[ "$WHAT" == core || "$WHAT" == all ]]; then
  python3 scripts/gen_tokens.py --check
  python3 scripts/check_contrast.py
  scripts/scan_secrets.sh
  scripts/test_package_dryrun.sh
  scripts/check_brand.sh
  # Any compiler warning in OfferlaneCore's own sources or tests fails the run (dependency warnings are ignored).
  # SHORTCUT: a warm local .build only re-reports warnings for files it recompiles; CI builds clean, so it catches all. Upgrade to
  # per-target warnings-as-errors in Package.swift when the tools version allows it.
  log="$(mktemp)"
  (cd Packages/OfferlaneCore && swift build --build-tests 2>&1) > "$log" || { tail -n 30 "$log"; exit 1; }
  if grep -E '/OfferlaneCore/(Sources|Tests)/.*warning:' "$log"; then echo "error: OfferlaneCore has compiler warnings" >&2; exit 1; fi
  rm -f "$log"
  (cd Packages/OfferlaneCore && swift test 2>&1 | tail -n 30)
  # P3.2 gate: libs/core (TypeScript) must give what the Swift core gives for the same Fixtures/core files.
  log="$(mktemp)"
  { npx -y pnpm@11.28.9 install --frozen-lockfile --filter @offerlane/core... --reporter=silent && npx -y pnpm@11.28.9 -s --filter @offerlane/core test; } > "$log" 2>&1 || { tail -n 60 "$log"; exit 1; }
  grep -E "Test Files|Tests " "$log"; rm -f "$log"
  # P2.8: the Swift API client is generated from libs/contract/openapi.json at build time; its tests use a stub transport.
  (cd Packages/OfferlaneAPI && swift test 2>&1 | grep -E "error:|Executed .* tests|Test run with" | tail -n 8)
  # P1.2 gate: the model qualification suite passes offline (live runs are opt-in, see docs/PROVIDERS.md).
  (cd Packages/OfferlaneCore && mc="$(mktemp -d)" && swift run -q offerlane-modelcheck --offline --out "$mc/models.json" > "$mc/out.txt"; head -n 1 "$mc/out.txt"; rm -rf "$mc")
fi
if [[ "$WHAT" == cloud || "$WHAT" == all ]]; then
  pnpm() { npx -y pnpm@11.28.9 "$@"; }  # the version in package.json; Node 25+ no longer ships corepack
  pnpm install --frozen-lockfile --reporter=silent
  # Database tests need docker-compose's db; without Docker they are skipped with a loud warning (CI sets its own URL).
  if [[ -z "${OFFERLANE_TEST_DATABASE_URL:-}" ]] && docker info >/dev/null 2>&1; then
    docker compose up -d --wait db >/dev/null 2>&1 || { echo "error: docker compose could not start the db" >&2; exit 1; }
    export OFFERLANE_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54329/offerlane
  fi
  pnpm -s typecheck
  # P2.8 gate: libs/contract/openapi.json and the TS client types must match the zod schemas.
  pnpm -s --filter @offerlane/contract gen --check
  log="$(mktemp)"
  pnpm -s test > "$log" 2>&1 || { tail -n 60 "$log"; exit 1; }
  grep -E "SKIPPING|Test Files|Tests " "$log"; rm -f "$log"
  # P4.2: the Windows shell's Rust tests. Linux CI lacks Tauri's GTK libraries, so they run on the Mac and in spike-windows.
  if [[ "$(uname)" == Darwin ]]; then
    if command -v cargo >/dev/null || [[ -x "$HOME/.cargo/bin/cargo" ]]; then
      (cd apps/windows && npx -y pnpm@11.28.9 -s build >/dev/null && cd src-tauri && PATH="$HOME/.cargo/bin:$PATH" cargo test --locked > "$log" 2>&1 || { tail -n 40 "$log"; exit 1; }; grep "test result" "$log"; rm -f "$log")
    else echo "SKIPPING apps/windows Rust tests: no cargo (rustup, see apps/windows/README.md)"; fi
  fi
fi
if [[ "$WHAT" == web || "$WHAT" == all ]]; then
  pnpm() { npx -y pnpm@11.28.9 "$@"; }
  pnpm install --frozen-lockfile --reporter=silent
  (cd apps/web && npx playwright install chromium >/dev/null && timeout 600 npx playwright test 2>&1 | tail -n 30; exit "${PIPESTATUS[0]}")
  # P3.8: the unpacked extension (test build) beside the built web app.
  (cd apps/extension && timeout 600 npx playwright test 2>&1 | tail -n 30; exit "${PIPESTATUS[0]}")
  # P3.9: what ships (the built bundle, not only src/) has no code-from-strings (store rule: no remote or dynamic code).
  if grep -rlE '\beval\(|new Function|importScripts' apps/extension/dist-test; then echo "dynamic code in the extension bundle"; exit 1; fi
fi
if [[ "$WHAT" == ui || "$WHAT" == all ]]; then
  command -v xcodegen >/dev/null && xcodegen generate --quiet
  xcodebuild -project Offerlane.xcodeproj -scheme Offerlane -derivedDataPath build/DerivedData -skipPackagePluginValidation \
    -destination 'platform=macOS' test -quiet
fi
APP="build/DerivedData/Build/Products/Debug/Offerlane.app/Contents/MacOS/Offerlane"
selftest() {  # $1 = apply | real
  [[ -x "$APP" ]] || scripts/build.sh Debug >/dev/null
  local home; home="$(mktemp -d)"
  env OFFERLANE_HOME="$home" OFFERLANE_FAKE_AI=1 OFFERLANE_ONBOARDED=1 OFFERLANE_SELFTEST="$1" "$APP" 2>/dev/null | grep -E "PASS|FAIL|SMOKE|answers|simple form"
  local code=${PIPESTATUS[0]}; rm -rf "$home"; return "$code"
}
if [[ "$WHAT" == apply || "$WHAT" == all ]]; then selftest apply; fi
if [[ "$WHAT" == real ]]; then selftest real; fi
echo "Tests finished."
