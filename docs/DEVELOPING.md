# Developing Offerlane

Native SwiftUI app with a Swift core package (`Packages/OfferlaneCore`). Not exported to the public repo.

- Build: `scripts/build.sh [Debug|Release]` · Test: `scripts/test.sh [core|cloud|ui|apply|real|all]`
- CI (`.github/workflows/ci.yml`, every push/PR): contrast, secret scan, OfferlaneCore build (any warning in its own sources or tests fails) + tests, Release build + privacy gate. UI tests and the apply/real self-tests need macOS automation mode, so they run only locally: `scripts/test.sh ui` / `apply` / `real`.
- Cloud (P2, `apps/*`, `libs/*`): `scripts/test.sh cloud` (also part of `all`) needs Node 22+ and network for `npx pnpm@11.28.9`. With Docker Desktop running it starts the local Postgres (`docker compose up -d db`, 127.0.0.1:54329) for the database tests; without Docker they are skipped with a loud warning. CI runs them on Linux with a Postgres service and `OFFERLANE_REQUIRE_DB=1`.
- Package: `scripts/package.sh` → `dist/Offerlane-<version>.dmg`, `.pkg`, `SHA256SUMS.txt` (signing/notarisation via env vars, see the script header)
- README screenshots: `scripts/screenshots.sh` (demo data, light + dark) → docs/screenshots; look at them before committing
- Guides: `docs/GOOGLE_SETUP.md` (Google sign-in/Gmail), `docs/TESTING.md` (clean-machine checklist)
- Plans: `docs/WINDOWS_PLAN.md`, `docs/v4/` (phase plans, sync crypto spec, runbook, extension review)
- Test switches (`OFFERLANE_*` environment variables) work in Debug builds only.
- Stranger setup test (P1.6): the timer starts when the first-run setup opens (after sign-in) and stops on "Find jobs". Read it with `grep "setup timer" ~/Library/Logs/Offerlane/offerlane.log`. The line has per-step seconds, the total, and "under 5 min: yes/no". It stays on this Mac.
- Logic originally ported from the Python prototype in `../Job Agent Kit/`.

## Signed release (needs the Apple Developer ID certificate)
Check first with `scripts/package.sh --dry-run` (prints every step, builds nothing). Then, once:
`xcrun notarytool store-credentials offerlane-notary --apple-id <id> --team-id <TEAMID>` and
`build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys` (prints the EdDSA public key; the private key stays in your Keychain).
Each release:
```
DEVELOPER_ID="Developer ID Application: <Name> (<TEAMID>)" INSTALLER_ID="Developer ID Installer: <Name> (<TEAMID>)" \
NOTARY_PROFILE=offerlane-notary SPARKLE_PUBLIC_KEY=<public key> SPARKLE_DOWNLOAD_PREFIX=https://<host>/ scripts/package.sh
```
Paste `dist/appcast-item.xml` into `docs/appcast.xml`, host it, and set `SUFeedURL` in `project.yml` to its URL (the example.invalid placeholder keeps the in-app check off).
