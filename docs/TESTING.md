# Testing Offerlane

## Automated
| Command | What it covers |
|---|---|
| `scripts/test.sh core` | OfferlaneCore unit and integration tests. `SetupTests` replays the official download hosts with a mock server, covering: allowlist and redirects, HTTPS only, checksum mismatch, dropped connection then resume, cancel, oversized download, cleanup, Claude and Ollama installers that refuse tampered or unsigned files, real signature checks, and health rules. |
| `scripts/test.sh ui` | XCUITest: onboarding, Find, Review, Applications, Settings, sign-in, the Setup Center (sidebar health, problem messages, Repair Everything), launch time and scrolling. |
| `scripts/test.sh apply` | In-app apply engine against the bundled mock career sites. |
| `scripts/test.sh all` | All of the above. Must pass before every commit. |

Opt-in checks:
- `OFFERLANE_TEST_OLLAMA_APP=/path/Ollama.app` verifies a real Ollama download's signature. Without it, the test uses `/Applications/Ollama.app` when present.
- The Claude Code signature test runs whenever Claude Code is installed.

UI tests can force health states with `OFFERLANE_HEALTH=ok` or any combination of `offline,lowdisk,rosetta,noai`.

## Clean-machine checklist (manual, before a release)
Use a fresh macOS user account or a VM with no Claude Code, no Ollama and no `~/Library/Application Support/Offerlane`. Tick each item:

**First run**
- [ ] Open the DMG and drag Offerlane to Applications. Unsigned builds (ad hoc, as in 0.2.0): the first open needs Control-click → Open, or System Settings → Privacy & Security → Open Anyway. After that it opens normally. Notarized builds open with no warning.
- [ ] The welcome screen appears and a profile can be created. You never need to open Terminal or a browser, except for the Claude sign-in page.

**Claude account path**
- [ ] AI step → Claude account → **Install**. The progress bar moves; the status goes "Finding the latest version…" → "Downloading…" → "Checking it's the genuine Claude Code…" → "Setting up…".
- [ ] Turn Wi-Fi off mid-download. You see a plain-English error with **Try Again**. Turn Wi-Fi on and click Try Again: the download continues from where it stopped and doesn't restart at 0%.
- [ ] Click **Cancel** mid-download, then **Install** again: it continues.
- [ ] **Sign In…** opens Claude's sign-in, the sheet closes by itself, and the step shows "Connected".
- [ ] `~/Library/Caches/com.somilmanke.Offerlane/Downloads` is empty afterwards.

**Ollama path**
- [ ] AI step → Ollama → **Install Ollama…**. The dialog explains the download (~230 MB). Ollama.app lands in /Applications (or ~/Applications for a standard user) and starts.
- [ ] The recommended model matches RAM: 8 GB → 4b, 16 GB → 9b, 32 GB+ → 27b. On a nearly full disk it steps down, or explains how much space is needed.
- [ ] **Download Model** shows live progress. **Cancel**, then **Resume Download** continues where it stopped. When the download finishes, the test prompt runs and shows "Connected".
- [ ] Manage Ollama → **Remove** a model frees its space. **Uninstall Ollama…** moves it to the Trash. The "Also remove downloaded models" option also trashes `~/.ollama/models`.

**Claude API key path**
- [ ] Paste a key, then **Test Key** → Connected. A wrong key gives a plain-English error with **Try Again**.

**Health and repair**
- [ ] With everything set up, the sidebar footer shows the AI name with a green dot.
- [ ] Quit Ollama (if used). Re-activate Offerlane: the footer says "1 thing needs attention". Click it → Setup Center → **Repair Everything** starts Ollama and reports "Everything is working".
- [ ] Turn Wi-Fi off: the Internet row explains you're offline and offers **Try Again**.
- [ ] Fill the disk to under 2 GB free: the Storage row is red, and **Show Storage** opens System Settings → Storage.
- [ ] On Apple silicon, tick "Open using Rosetta" in Offerlane's Get Info: "This Mac" warns, and **Show Me How** reveals the app in the Finder with instructions.
- [ ] On an Intel Mac with Ollama chosen, "This Mac" notes that Claude is faster.

**Bundled pieces**
- [ ] A LaTeX resume renders to PDF offline (bundled engine and pre-warmed cache).
- [ ] Auto-apply opens career sites in the built-in browser with no extra install.

**Errors**
- [ ] No screen shows a stack trace, raw error code or Terminal command. Every error has a **Try Again** or **Fix it** style button.
