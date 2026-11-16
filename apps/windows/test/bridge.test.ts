import { describe, expect, it } from "vitest";
import { cdpBridge, credentialRoundTrip, CredentialVault, shellChecks, type Invoke, type Listen } from "../src/bridge.js";

function fakeShell() {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const store = new Map<string, { email: string; password: string }>();
  let emit: ((e: { payload: unknown }) => void) | undefined;
  let n = 0;
  const invoke: Invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    const host = args?.host as string;
    switch (cmd) {
      case "open_page": return `apply-${++n}`;
      case "cdp_send": return { echoed: args?.method };
      case "vault_read": return store.get(host) ?? null;
      case "vault_save": store.set(host, { email: args?.email as string, password: args?.password as string }); return null;
      case "vault_delete": store.delete(host); return null;
      default: return null;
    }
  };
  const listen: Listen = async (_event, h) => { emit = h; return () => {}; };
  return { calls, store, invoke, listen, emit: (payload: unknown) => emit?.({ payload }) };
}

describe("cdpBridge", () => {
  it("sends CDP calls to the window it opened, with empty params by default", async () => {
    const s = fakeShell();
    const page = await cdpBridge(s.invoke, s.listen).open();
    expect(page.label).toBe("apply-1");
    expect(await page.send("Page.enable")).toEqual({ echoed: "Page.enable" });
    await page.send("Runtime.evaluate", { expression: "1" });
    expect(s.calls.filter(([c]) => c === "cdp_send").map(([, a]) => a)).toEqual([
      { label: "apply-1", method: "Page.enable", params: {} },
      { label: "apply-1", method: "Runtime.evaluate", params: { expression: "1" } },
    ]);
    await page.close();
    expect(s.calls.at(-1)).toEqual(["close_page", { label: "apply-1" }]);
  });

  it("delivers each window's events only to that window's handlers", async () => {
    const s = fakeShell();
    const bridge = cdpBridge(s.invoke, s.listen);
    const [a, b] = [await bridge.open(), await bridge.open()];
    const seen: string[] = [];
    a.on("Page.frameStartedLoading", (p) => seen.push(`a start ${p.frameId}`));
    b.on("Page.frameStartedLoading", (p) => seen.push(`b start ${p.frameId}`));
    a.on("Page.frameStoppedLoading", (p) => seen.push(`a stop ${p.frameId}`));
    s.emit({ label: "apply-1", event: "Page.frameStartedLoading", params: { frameId: "F1" } });
    s.emit({ label: "apply-2", event: "Page.frameStartedLoading", params: { frameId: "F2" } });
    s.emit({ label: "apply-1", event: "Page.frameStoppedLoading", params: { frameId: "F1" } });
    s.emit({ label: "apply-9", event: "Page.frameStartedLoading", params: {} });
    s.emit("not an object");
    expect(seen).toEqual(["a start F1", "b start F2", "a stop F1"]);
  });
});

describe("CredentialVault", () => {
  it("reads and saves through the shell; approval is per host and company", async () => {
    const s = fakeShell();
    const v = new CredentialVault(s.invoke);
    expect(await v.password("x.test")).toBeNull();
    await v.save("x.test", "Acme", "me@example.com", "pw");
    expect(await v.password("x.test")).toBe("pw");
    expect(await v.accountEmail("x.test")).toBe("me@example.com");
    expect(await v.isApproved("x.test", "Acme")).toBe(false);
    v.approve("x.test", "Acme");
    expect(await v.isApproved("x.test", "Acme")).toBe(true);
    expect(await v.isApproved("x.test", "Globex")).toBe(false);
    await v.forgetSaved();
    expect(s.store.size).toBe(0);
  });

  it("a refused save rejects, so the engine hands over", async () => {
    const v = new CredentialVault(async (cmd) => { if (cmd === "vault_save") throw new Error("Credential Manager refused"); return null; });
    await expect(v.save("x.test", "Acme", "e", "p")).rejects.toThrow("refused");
  });

  it("round-trip check passes on a working store and cleans up", async () => {
    const s = fakeShell();
    expect(await credentialRoundTrip(s.invoke)).toEqual({ ok: true, what: "Credential Manager: save, read back, delete" });
    expect(s.store.size).toBe(0);
  });

  it("round-trip check fails when the read-back differs", async () => {
    const s = fakeShell();
    const lying: Invoke = async (cmd, args) => cmd === "vault_read" ? { email: "x", password: "wrong" } : s.invoke(cmd, args);
    expect((await credentialRoundTrip(lying)).ok).toBe(false);
  });
});

describe("shellChecks", () => {
  // A fake apply window: Runtime.evaluate answers by expression; navigations only "happen" when `obeys` says so.
  function fakePage(o: { ipc: "none" | "refused" | "allowed"; obeys: (url: string) => boolean }) {
    let url = "";
    const send = async (method: string, params: Record<string, unknown> = {}) => {
      if (method === "Page.getFrameTree") return { frameTree: { frame: { id: "F", url } } };
      if (method === "Page.navigate") { url = params.url as string; return {}; }
      if (method === "Runtime.evaluate") {
        const e = params.expression as string;
        if (e.includes("__TAURI_INTERNALS__")) return { result: { value: o.ipc === "none" ? "no ipc" : o.ipc === "refused" ? "refused" : "ALLOWED" } };
        const to = /location\.href = (".*?");/.exec(e)?.[1];
        if (to && o.obeys(JSON.parse(to))) url = JSON.parse(to);
        return { result: { value: null } };
      }
      return {};
    };
    return { label: "apply-1", send, on: () => {}, close: async () => {} };
  }
  const base = "http://127.0.0.1:9";

  it("passes when the page has no IPC power and both escapes are blocked", async () => {
    const r = await shellChecks(fakePage({ ipc: "refused", obeys: () => false }), base, 0);
    expect(r.map((c) => c.ok)).toEqual([true, true, true]);
  });

  it("fails when a career page can call a command", async () => {
    const r = await shellChecks(fakePage({ ipc: "allowed", obeys: () => false }), base, 0);
    expect(r[0]).toEqual({ ok: false, what: expect.stringContaining("IPC") });
  });

  it("fails when the window follows a file:// or tauri.localhost link", async () => {
    const r = await shellChecks(fakePage({ ipc: "none", obeys: (u) => !u.startsWith("http://127") }), base, 0);
    expect(r.map((c) => c.ok)).toEqual([true, false, false]);
  });
});
