// The shell's page: apps/web (P4.3). With --selftest it instead runs libs/core's 14 apply checks on WebView2 through the Rust CDP bridge, then the
// Credential Manager round-trip and the 3 shell security checks (bridge.ts shellChecks), and reports to the Rust side, which prints the lines and sets the exit code.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { applySelfTest, cdpPage, job, newProfile } from "@offerlane/core";
import autofill from "../../../App/Resources/autofill.js?raw";
import { shellFill } from "./apply.js";
import { cdpBridge, credentialRoundTrip, CredentialVault, memoryApprovals, shellChecks, type ShellPage } from "./bridge.js";

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
    await current.close(); current = undefined;
    const fills = [await noSubmit(base)];
    for (const c of [rt, ...shell, ...fills]) log((c.ok ? "PASS " : "FAIL ") + c.what);
    const all = [...results, rt, ...shell, ...fills];
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

/** Check 19: the app's own "Fill in application" path (platform.fill) fills the form and leaves Submit to the human. */
async function noSubmit(base: string) {
  const what = "Fill in application (the app's button) fills the form and never submits";
  const f = shellFill(invoke, listen, memoryApprovals(), autofill, undefined);
  try {
    const me = newProfile();
    Object.assign(me.personal, { first_name: "Test", last_name: "Person", full_name: "Test Person", email: "test@example.com" });
    const r = await f.fill(job({ company: "Globex", title: "Data Scientist", location: "", url: `${base}/simple.html` }), me, [], false);
    await new Promise((ok) => setTimeout(ok, 1500));  // a submit would replace the form with "Thank you for applying!"
    const left = await f.page()!.eval("document.forms.length === 1 && fn.value === 'Test' && !document.body.innerText.includes('Thank you')");
    return { ok: r.kind === "prefilled" && left === true, what: `${what} (${r.message})` };
  } catch (e) {
    return { ok: false, what: `${what} (${e instanceof Error ? e.message : String(e)})` };
  } finally { await f.close().catch(() => {}); }
}

const base = (await invoke("selftest_base")) as string | null;
if (base) await selftest(base);
else await import("../../web/src/main.js");
