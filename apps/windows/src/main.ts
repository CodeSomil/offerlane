// The shell's page: apps/web (P4.3). With --selftest it instead runs libs/core's 14 apply checks on WebView2 through the Rust CDP bridge, then the
// Credential Manager round-trip and the 3 shell security checks (bridge.ts shellChecks), and reports to the Rust side, which prints the lines and sets the exit code.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { applySelfTest, cdpPage } from "@offerlane/core";
import autofill from "../../../App/Resources/autofill.js?raw";
import { cdpBridge, credentialRoundTrip, CredentialVault, shellChecks, type ShellPage } from "./bridge.js";

let status: HTMLElement, out: HTMLElement;
// Lines go out in order and are all delivered before selftest_done exits the process.
let sent: Promise<unknown> = Promise.resolve();
const log = (line: string) => { out.textContent += line + "\n"; sent = sent.then(() => invoke("selftest_log", { line })).catch(() => {}); };

async function selftest(base: string) {
  const main = document.body.appendChild(document.createElement("main"));
  status = main.appendChild(document.createElement("p"));
  out = main.appendChild(document.createElement("pre"));
  status.textContent = "Running the apply self-test…";
  const bridge = cdpBridge(invoke, listen);
  const vault = new CredentialVault(invoke);
  let current: ShellPage | undefined;
  let passed = 0, total = 0;
  try {
    const results = await applySelfTest({
      base, vault, log,
      // A fresh window (fresh profile folder) per check, like WebPage(persistent: false); the last one closes the one before.
      newPage: async () => { await current?.close(); current = await bridge.open(); return cdpPage(current.send, autofill, current.on); },
    });
    const rt = await credentialRoundTrip(invoke);
    await current?.close(); current = await bridge.open();
    const shell = await shellChecks(current, base);
    for (const c of [rt, ...shell]) log((c.ok ? "PASS " : "FAIL ") + c.what);
    const all = [...results, rt, ...shell];
    total = results.length === 14 ? all.length : 0; // a short list is a failure, not a pass
    passed = all.filter((r) => r.ok).length;
  } catch (e) {
    log(`FAIL the self-test stopped: ${e instanceof Error ? e.message : String(e)}`);
  } finally {
    await current?.close().catch(() => {});
    await vault.forgetSaved().catch(() => log("FAIL could not delete the self-test's saved passwords"));
  }
  status.textContent = `Self-test: ${passed}/${total}`;
  await sent;
  await invoke("selftest_done", { passed, total });
}

const base = (await invoke("selftest_base")) as string | null;
if (base) await selftest(base);
else await import("../../web/src/main.js");
