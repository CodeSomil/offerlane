import "fake-indexeddb/auto";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SyncKind } from "@offerlane/core";
import { SyncError, createKeyring, forgetSync, httpRemote, restoreKeyring, setupState, syncNow, type Blob, type Remote } from "../src/sync.js";
import { delItem, getItem, setItem } from "../src/store.js";

/** The server's compare-and-set rules (apps/api memorySync), plus hooks to misbehave. */
type Memory = Remote & { rows: Map<SyncKind, Blob>; puts: SyncKind[]; userId: string; conflicts: number; serve: ((k: SyncKind) => Blob | null | undefined) | undefined };
function memoryRemote(userId = "u1"): Memory {
  const rows = new Map<SyncKind, Blob>();
  const puts: SyncKind[] = [];
  const r: Memory = {
    rows, puts, userId, conflicts: 0, serve: undefined as ((k: SyncKind) => Blob | null | undefined) | undefined,
    async me() { return r.userId; },
    async get(k: SyncKind) { const o = r.serve?.(k); if (o !== undefined) return o; const b = rows.get(k); return b ? { ...b, ciphertext: b.ciphertext.slice() } : null; },
    async put(k: SyncKind, expected: number | null, keyId: string, ciphertext: Uint8Array<ArrayBuffer>) {
      puts.push(k);
      if (r.conflicts > 0) { r.conflicts--; return { ok: false as const, conflict: true as const }; }
      const cur = rows.get(k)?.version ?? null;
      if (cur !== expected) return { ok: false as const, conflict: true as const };
      const version = (cur ?? 0) + 1;
      rows.set(k, { version, keyId, ciphertext });
      return { ok: true as const, version };
    },
  };
  return r;
}
const rec = (id: string, status: string, updated: string) => ({ job: { id, company: "Acme", title: "Analyst" }, status, score: 50, created: updated, updated });
/** A fresh device: nothing local, no sync state. */
const wipe = async () => { for (const k of ["profile", "resume", "applications", "sync"]) await delItem(k); };
const plaintextIn = (r: Memory, needle: string) =>
  [...r.rows.values()].some((b) => Buffer.from(b.ciphertext).toString("latin1").includes(needle));

afterEach(async () => { await wipe(); vi.unstubAllGlobals(); });

describe("sync engine (P3.7)", () => {
  it("first device makes the keyring; a second device with the recovery key gets everything; the server sees ciphertext only", async () => {
    const remote = memoryRemote();
    expect((await setupState(remote)).setup).toBe("new-account");
    await setItem("profile", { personal: { name: "Jane Canary" } });
    await setItem("resume", { headline: "Forecasting lead" });
    await setItem("applications", { a: rec("a", "tailoring", "2026-11-10T00:00:00.000Z") });
    const rk = await createKeyring(remote);
    expect(rk).toMatch(/^([A-Z2-7]{4}-){6}[A-Z2-7]{2}$/);
    expect((await setupState(remote)).setup).toBe("ready");
    expect(await syncNow(remote)).toMatchObject({ pushed: 3, pulled: 0 });
    expect(await syncNow(remote)).toMatchObject({ pushed: 0, pulled: 0 }); // nothing changed: no writes
    expect(plaintextIn(remote, "Jane Canary") || plaintextIn(remote, "Forecasting")).toBe(false);

    await wipe();
    expect((await setupState(remote)).setup).toBe("needs-key");
    await expect(restoreKeyring("AAAA-AAAA", remote)).rejects.toThrow(/isn't a recovery key/);
    await expect(restoreKeyring("AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AA", remote)).rejects.toThrow(/doesn't open/);
    await restoreKeyring(rk.toLowerCase(), remote);
    expect(await syncNow(remote)).toMatchObject({ pushed: 0, pulled: 3 });
    expect(await getItem("profile")).toEqual({ personal: { name: "Jane Canary" } });
    expect((await getItem("applications") as Record<string, unknown>).a).toMatchObject({ status: "tailoring" });
  });

  it("both devices changed: applications merge by record, the newer `updated` wins", async () => {
    const remote = memoryRemote();
    await setItem("applications", { a: rec("a", "tailoring", "2026-11-10T00:00:00.000Z"), b: rec("b", "found", "2026-11-10T00:00:00.000Z") });
    const rk = await createKeyring(remote);
    await syncNow(remote);
    const deviceA = await getItem("sync");
    // Device B restores, changes b and pushes.
    await wipe(); await restoreKeyring(rk, remote); await syncNow(remote);
    await setItem("applications", { ...(await getItem("applications") as object), b: rec("b", "tailoring", "2026-11-12T00:00:00.000Z") });
    await syncNow(remote);
    // Back on device A (its state and its own edit of a), A syncs: B's b and A's a both survive.
    await setItem("sync", deviceA);
    await setItem("applications", { a: rec("a", "review", "2026-11-13T00:00:00.000Z"), b: rec("b", "found", "2026-11-10T00:00:00.000Z") });
    expect(await syncNow(remote)).toMatchObject({ pushed: 1, pulled: 1 });
    const apps = await getItem("applications") as Record<string, { status: string }>;
    expect([apps.a!.status, apps.b!.status]).toEqual(["review", "tailoring"]);
  });

  it("a 409 starts the kind again; three in a row stop with a plain message", async () => {
    const remote = memoryRemote();
    await createKeyring(remote);
    await setItem("profile", { personal: { name: "J" } });
    remote.conflicts = 1;
    expect((await syncNow(remote)).pushed).toBe(1);
    expect(remote.puts.filter((k) => k === "profile")).toHaveLength(2);
    await setItem("profile", { personal: { name: "K" } });
    remote.conflicts = 3;
    await expect(syncNow(remote)).rejects.toThrow(/keeps changing/);
  });

  it("refuses an older version than it has seen (rollback) and a changed blob, and changes nothing locally", async () => {
    const remote = memoryRemote();
    await createKeyring(remote);
    await setItem("profile", { v: 1 }); await syncNow(remote);
    const v1 = remote.rows.get("profile")!;
    await setItem("profile", { v: 2 }); await syncNow(remote);
    remote.serve = (k) => (k === "profile" ? v1 : undefined);
    await expect(syncNow(remote)).rejects.toThrow(/older data/);
    remote.serve = (k) => { if (k !== "profile") return undefined; const b = remote.rows.get(k)!; const c = b.ciphertext.slice(); c[20] = c[20]! ^ 1; return { ...b, ciphertext: c }; };
    await expect(syncNow(remote)).rejects.toThrow(/couldn't be decrypted/);
    expect(await getItem("profile")).toEqual({ v: 2 });
  });

  it("a failure partway through keeps what the finished kinds agreed, so the next sync doesn't overwrite another device", async () => {
    const remote = memoryRemote();
    const rk = await createKeyring(remote);
    await setItem("profile", { v: "A1" }); await setItem("resume", { r: 1 });
    await syncNow(remote);
    await setItem("profile", { v: "A2" }); await setItem("resume", { r: 2 });
    remote.conflicts = 3; remote.serve = undefined;
    // profile pushes (v2), then resumes hits the 409 limit
    const put = remote.put.bind(remote);
    remote.put = async (k, e, id, c) => (k === "profile" ? (remote.conflicts = 0, put(k, e, id, c)).finally(() => { remote.conflicts = 3; }) : put(k, e, id, c));
    await expect(syncNow(remote)).rejects.toThrow(/keeps changing/);
    remote.put = put; remote.conflicts = 0;
    expect(remote.rows.get("profile")!.version).toBe(2);
    const afterFailure = await getItem("sync");
    // Device B restores and changes the profile (v3).
    await wipe(); await restoreKeyring(rk, remote); await syncNow(remote);
    await setItem("profile", { v: "B3" }); await syncNow(remote);
    expect(remote.rows.get("profile")!.version).toBe(3);
    // Back on A, which didn't touch the profile since its v2 push: it takes B's edit instead of pushing A2 again.
    await setItem("sync", afterFailure); await setItem("profile", { v: "A2" }); await setItem("resume", { r: 2 });
    await syncNow(remote);
    expect(await getItem("profile")).toEqual({ v: "B3" });
  });

  it("every device uses the account key's one key id (it travels in the keyring)", async () => {
    const remote = memoryRemote();
    const rk = await createKeyring(remote);
    const a = (await getItem("sync") as { keyId: string }).keyId;
    await wipe(); await restoreKeyring(rk, remote);
    expect((await getItem("sync") as { keyId: string }).keyId).toBe(a);
  });

  it("a first sync that replaces this device's profile keeps a copy; a vanished blob after a seen version is refused", async () => {
    const remote = memoryRemote();
    const rk = await createKeyring(remote);
    await setItem("profile", { who: "remote" }); await syncNow(remote);
    await wipe(); await restoreKeyring(rk, remote);
    await setItem("profile", { who: "this device" });
    const r = await syncNow(remote);
    expect(r.replaced).toEqual(["profile"]);
    expect(await getItem("profile")).toEqual({ who: "remote" });
    expect(await getItem("before-sync:profile")).toMatchObject({ value: { who: "this device" } });
    remote.serve = (k) => (k === "profile" ? null : undefined);
    await expect(syncNow(remote)).rejects.toThrow(/older data/);
    await delItem("before-sync:profile");
  });

  it("knows a browser set up for another account, and forgetting sync clears only this device", async () => {
    const remote = memoryRemote();
    await createKeyring(remote);
    remote.userId = "u2";
    expect((await setupState(remote)).setup).toBe("other-account");
    await expect(syncNow(remote)).rejects.toThrow(/different account/);
    await forgetSync();
    expect((await setupState(remote)).setup).toBe("needs-key"); // the server's keyring is untouched (u2 sees u1's map here)
  });
});

describe("httpRemote Idempotency-Key", () => {
  const signedIn = () => {
    const m = new Map([["offerlane-session", JSON.stringify({ token: "T", sub: "s", expires: Date.now() + 3_600_000 })]]);
    vi.stubGlobal("sessionStorage", { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => m.set(k, v), removeItem: (k: string) => m.delete(k) });
  };
  it("reuses the key when the network fails, uses a new one for the next write, and sends the precondition", async () => {
    signedIn();
    const seen: Request[] = [];
    let n = 0;
    const remote = httpRemote(async (r) => {
      seen.push(r as Request);
      n++;
      if (n === 1) throw new TypeError("network down");
      if (n === 2) return Response.json({ version: 1 });
      return Response.json({ error: "conflict", version: 1 }, { status: 409 });
    });
    expect(await remote.put("profile", null, "k1", new Uint8Array([1, 2, 3]))).toEqual({ ok: true, version: 1 });
    expect(await remote.put("profile", 1, "k1", new Uint8Array([4]))).toEqual({ ok: false, conflict: true });
    const keys = seen.map((r) => r.headers.get("idempotency-key"));
    expect(keys[0]).toBeTruthy();
    expect(keys[1]).toBe(keys[0]);
    expect(keys[2]).not.toBe(keys[0]);
    expect(seen[0]!.headers.get("if-none-match")).toBe("*");
    expect(seen[2]!.headers.get("if-match")).toBe('"v1"');
    expect(seen[0]!.headers.get("authorization")).toBe("Bearer T");
    expect(await seen[1]!.json()).toEqual({ keyId: "k1", ciphertext: "AQID" });
  });
  it("says plainly when signed out, expired, or offline", async () => {
    await expect(httpRemote(async () => Response.json({})).me()).rejects.toThrow(/Sign in to sync/);
    signedIn();
    await expect(httpRemote(async () => new Response("", { status: 401 })).me()).rejects.toThrow(/expired/);
    await expect(httpRemote(async () => { throw new TypeError("x"); }).get("profile")).rejects.toBeInstanceOf(SyncError);
  });
});
