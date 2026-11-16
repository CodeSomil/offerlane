// The web side of the Tauri shell (v4 P4.2): CDPSend/CDPOn for libs/core/src/cdp.ts over the Rust commands in
// src-tauri/src/apply.rs, and an ApplyVault over Credential Manager (src-tauri/src/vault.rs).
import type { ApplyVault, CDPOn, CDPSend } from "@offerlane/core";

export type Invoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;
export type Listen = (event: string, handler: (e: { payload: unknown }) => void) => Promise<unknown>;
type Handler = (params: { frameId?: string }) => void;
export type ShellPage = { label: string; send: CDPSend; on: CDPOn; close: () => Promise<void> };

/** One listener for every apply window; each event goes only to the handlers of the window it came from. */
export function cdpBridge(invoke: Invoke, listen: Listen) {
  const handlers = new Map<string, Handler[]>(); // `${label}\n${event}`
  const ready = listen("cdp-event", ({ payload }) => {
    if (typeof payload !== "object" || payload === null) return;
    const p = payload as { label?: unknown; event?: unknown; params?: { frameId?: string } };
    for (const h of handlers.get(`${String(p.label)}\n${String(p.event)}`) ?? []) h(p.params ?? {});
  });
  return {
    async open(profile?: string): Promise<ShellPage> {
      await ready;
      const label = (await invoke("open_page", profile === undefined ? {} : { profile })) as string;
      return {
        label,
        send: (method, params = {}) => invoke("cdp_send", { label, method, params }),
        on: (event, h) => { const k = `${label}\n${event}`; handlers.set(k, [...(handlers.get(k) ?? []), h]); },
        close: async () => {
          for (const k of [...handlers.keys()]) if (k.startsWith(`${label}\n`)) handlers.delete(k);
          await invoke("close_page", { label });
        },
      };
    },
  };
}

type Account = { email: string; password: string } | null;

/**
 * Passwords and sign-in emails per host in Credential Manager. SHORTCUT: company approval is in memory (the self-test
 * approves explicitly); P4.3 stores it with the app's other settings, as Vault.swift does.
 */
export class CredentialVault implements ApplyVault {
  private readonly approvals = new Set<string>();
  private readonly saved = new Set<string>();
  constructor(private readonly invoke: Invoke) {}
  private async account(host: string) { return (await this.invoke("vault_read", { host })) as Account; }
  async password(host: string) { return (await this.account(host))?.password ?? null; }
  async accountEmail(host: string) { return (await this.account(host))?.email ?? null; }
  async save(host: string, _company: string, email: string, password: string) {
    await this.invoke("vault_save", { host, email, password });
    this.saved.add(host);
  }
  async isApproved(host: string, company: string) { return this.approvals.has(`${host}\n${company}`); }
  approve(host: string, company: string) { this.approvals.add(`${host}\n${company}`); }
  /** Self-test cleanup: deletes every entry this vault wrote. */
  async forgetSaved() { for (const h of this.saved) await this.invoke("vault_delete", { host: h }); this.saved.clear(); }
}

/** The spike's 15th check: a secret survives a save, reads back exactly, and is gone after delete. */
export async function credentialRoundTrip(invoke: Invoke): Promise<{ ok: boolean; what: string }> {
  const what = "Credential Manager: save, read back, delete";
  const host = "offerlane-selftest.invalid";
  const want = { email: "selftest@example.com", password: `St-${crypto.randomUUID()}-Ä!` };
  try {
    await invoke("vault_delete", { host });
    await invoke("vault_save", { host, ...want });
    const got = (await invoke("vault_read", { host })) as Account;
    await invoke("vault_delete", { host });
    const gone = (await invoke("vault_read", { host })) as Account;
    return { ok: got?.email === want.email && got?.password === want.password && gone === null, what };
  } catch {
    return { ok: false, what };
  }
}

type Evaluated = { result?: { value?: unknown } };
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * Checks 16–18, on the real WebView2 window: the career page (main world, its own scripts' view) can't call Offerlane's
 * commands, and can't send the apply window to a file:// URL or to Offerlane's own origin (tauri.localhost).
 */
export async function shellChecks(page: ShellPage, base: string, settleMs = 1500): Promise<{ ok: boolean; what: string }[]> {
  const start = `${base}/simple.html`;
  const url = async () => ((await page.send("Page.getFrameTree")) as { frameTree: { frame: { url: string } } }).frameTree.frame.url;
  const evalMain = async (expression: string) =>
    ((await page.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })) as Evaluated).result?.value;
  const home = async () => { await page.send("Page.navigate", { url: start }); await sleep(settleMs); };
  await page.send("Page.enable");
  await home();
  const ipc = await evalMain(`(async () => { const i = window.__TAURI_INTERNALS__; if (!i) return "no ipc";
    try { await i.invoke("vault_read", { host: "offerlane-selftest.invalid" }); return "ALLOWED"; } catch { return "refused"; } })()`);
  const out = [{ ok: ipc !== "ALLOWED", what: "a career page gets no IPC power (vault_read is refused)" }];
  for (const [to, what] of [["file:///C:/Windows/win.ini", "a career page can't open a file:// URL"], ["http://tauri.localhost/", "a career page can't load Offerlane's own origin"]] as const) {
    await home();
    await evalMain(`location.href = ${JSON.stringify(to)}; null`);
    await sleep(settleMs);
    out.push({ ok: (await url()) === start, what });
  }
  return out;
}
