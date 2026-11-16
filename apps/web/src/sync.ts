// Sync on the web (P3.7, H3): this device's IndexedDB data, end-to-end encrypted per docs/v4/SYNC_CRYPTO.md
// (@offerlane/core sync.ts). The server only ever gets ciphertext. Signed out, or never set up, nothing leaves the device.
import { apiClient } from "@offerlane/contract/client";
import { SyncCryptoError, formatRecoveryKey, importAccountKey, makeAccountKey, makeKeyId, makeRecoveryKey, mergeRecords, openBlob, parseRecoveryKey,
  sealBlob, syncAAD, unwrapAccountKey, wrapAccountKey, type SyncKind } from "@offerlane/core";
import { bearer } from "./auth.js";
import { delItem, getItem, setItem, updateItem } from "./store.js";

declare const __API_ORIGIN__: string;
export class SyncError extends Error {}

// ---- wire ---------------------------------------------------------------------------------------------------------
export type Blob = { version: number; keyId: string; ciphertext: Uint8Array<ArrayBuffer> };
export type PutResult = { ok: true; version: number } | { ok: false; conflict: true };
export type Remote = {
  me(): Promise<string>;
  get(kind: SyncKind): Promise<Blob | null>;
  /** expected = null: create only (If-None-Match: *); otherwise If-Match: "v<expected>". */
  put(kind: SyncKind, expected: number | null, keyId: string, ciphertext: Uint8Array<ArrayBuffer>): Promise<PutResult>;
};

const b64 = (b: Uint8Array) => { let s = ""; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

const fail = (status: number): never => {
  if (status === 401) throw new SyncError("Your sign-in has expired. Sign in again to sync.");
  if (status === 413) throw new SyncError("This data is too large to sync (over 8 MB).");
  if (status === 429) throw new SyncError("Too many sync requests in a short time. Try again in a minute.");
  throw new SyncError(`The sync service answered ${status}. Try again later.`);
};

/** The real API. Each PUT is one logical write with one Idempotency-Key: a network failure retries with the same key (the
 *  server replays the first answer instead of writing twice); any HTTP answer ends it, so the next write (after a 409 or
 *  another 4xx) gets a new key. */
export function httpRemote(fetchFn: typeof fetch = (...a) => fetch(...a)): Remote {
  const api = apiClient(__API_ORIGIN__, { credentials: "omit", referrerPolicy: "no-referrer", fetch: (r: Request) => fetchFn(r) });
  const auth = () => {
    const t = bearer();
    if (!t) throw new SyncError("Sign in to sync.");
    return { authorization: `Bearer ${t}` };
  };
  const call = async <T>(f: () => Promise<T>, tries = 1): Promise<T> => {
    for (let i = 0; ; i++) {
      try { return await f(); } catch (e) {
        if (e instanceof SyncError || i + 1 >= tries) throw e instanceof SyncError ? e : new SyncError("Couldn't reach the sync service. Check your connection and try again.");
      }
    }
  };
  return {
    async me() {
      const r = await call(() => api.GET("/v1/me", { headers: auth(), signal: AbortSignal.timeout(15_000) }));
      return r.data?.id ?? fail(r.response.status);
    },
    async get(kind) {
      const r = await call(() => api.GET("/v1/sync/{kind}", { params: { path: { kind } }, headers: auth(), signal: AbortSignal.timeout(30_000) }));
      if (r.response.status === 404) return null;
      if (!r.data) return fail(r.response.status);
      return { version: r.data.version, keyId: r.data.keyId, ciphertext: unb64(r.data.ciphertext) };
    },
    async put(kind, expected, keyId, ciphertext) {
      const pre = expected === null ? { "if-none-match": "*" } : { "if-match": `"v${expected}"` };
      const headers = { ...auth(), ...pre, "idempotency-key": crypto.randomUUID() };
      const body = { keyId, ciphertext: b64(ciphertext) };
      const r = await call(() => api.PUT("/v1/sync/{kind}", { params: { path: { kind } }, headers, body, signal: AbortSignal.timeout(60_000) }), 3);
      if (r.response.status === 409) return { ok: false, conflict: true };
      return r.data ? { ok: true, version: r.data.version } : fail(r.response.status);
    },
  };
}

// ---- local state --------------------------------------------------------------------------------------------------
/** What this device synced last, per kind: the version (rollback guard: never accept a lower one) and a digest of the
 *  plaintext both sides agreed on (local data that no longer matches it was edited here since). */
type KindState = { version: number; digest: string };
type State = { userId: string; keyId: string; ak: CryptoKey; kinds: Partial<Record<SyncKind, KindState>>; last?: string };
const STATE = "sync";
const loadState = async (): Promise<State | undefined> => {
  const s = (await getItem(STATE)) as State | undefined;
  return s && typeof s.userId === "string" && s.ak instanceof CryptoKey ? s : undefined;
};

/** IndexedDB key → sync kind. Only what the web app has; contacts/settings are Mac-only for now. */
export const SYNCED: ReadonlyArray<{ kind: SyncKind; key: string; records: boolean }> = [
  { kind: "profile", key: "profile", records: false },
  { kind: "resumes", key: "resume", records: false },
  { kind: "applications", key: "applications", records: true },
];

const enc = new TextEncoder(), dec = new TextDecoder();
const digest = async (s: string) => b64(new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(s))));
const empty = (v: unknown) => v === undefined || v === null;

// ---- setup --------------------------------------------------------------------------------------------------------
export type Setup = "ready" | "new-account" | "needs-key" | "other-account";
export async function setupState(remote: Remote = httpRemote()): Promise<{ setup: Setup; last?: string }> {
  const [userId, s] = await Promise.all([remote.me(), loadState()]);
  if (s) return s.userId === userId ? { setup: "ready", ...(s.last ? { last: s.last } : {}) } : { setup: "other-account" };
  return { setup: (await remote.get("keyring")) ? "needs-key" : "new-account" };
}

/** First device: a new account key, wrapped by a new recovery key into the keyring. Returns the recovery key, shown once. */
export async function createKeyring(remote: Remote = httpRemote()): Promise<string> {
  const userId = await remote.me();
  const ak = makeAccountKey(), rk = makeRecoveryKey(), keyId = makeKeyId();
  try {
    // SHORTCUT: if this tab closes between the PUT and setItem, nobody saw the recovery key and there is no reset flow yet.
    const r = await remote.put("keyring", null, "rk-1", await wrapAccountKey(ak, keyId, rk, userId, 1, "rk-1"));
    if (!r.ok) throw new SyncError("Another device just set up sync for this account. Use its recovery key here instead.");
    await setItem(STATE, { userId, keyId, ak: await importAccountKey(ak), kinds: {} } satisfies State);
    return formatRecoveryKey(rk);
  } finally { ak.fill(0); rk.fill(0); }
}

/** Another device: unwrap the account key with the recovery key the user typed. */
export async function restoreKeyring(text: string, remote: Remote = httpRemote()): Promise<void> {
  const rk = parseRecoveryKey(text);
  if (!rk) throw new SyncError("That isn't a recovery key. It has 26 letters and digits, like ABCD-EFGH-…");
  const userId = await remote.me(), ring = await remote.get("keyring");
  if (!ring) throw new SyncError("This account has no synced data yet.");
  try {
    const { key: ak, keyId } = await unwrapAccountKey(ring.ciphertext, rk, userId, ring.version, ring.keyId);
    await setItem(STATE, { userId, keyId, ak, kinds: {} } satisfies State);
  } catch (e) { throw e instanceof SyncCryptoError ? new SyncError(e.message) : e; }
  finally { rk.fill(0); }
}

/** "Turn off sync on this device": forgets the account key here. Synced data and the other devices are untouched. */
export const forgetSync = () => delItem(STATE);

// ---- sync ---------------------------------------------------------------------------------------------------------
/** Pull, merge, push each kind. Rules: a remote version below the last one seen is refused (rollback). Remote changed and
 *  this device didn't (or this device has nothing yet, or never synced this kind): take the remote. Both changed:
 *  applications merge by record (newer `updated` wins); profile and resume keep this device's edit (last writer wins).
 *  A 409 means another device wrote first: start the kind again, at most 3 times. */
export async function syncNow(remote: Remote = httpRemote(), now = new Date()): Promise<{ pushed: number; pulled: number; replaced: string[] }> {
  const s = await loadState();
  if (!s) throw new SyncError("Sync isn't set up on this device yet.");
  if (s.userId !== (await remote.me())) throw new SyncError("This browser syncs with a different account. Turn sync off here, or sign in with that account.");
  let pushed = 0, pulled = 0;
  const replaced: string[] = [];
  for (const { kind, key, records } of SYNCED) {
    for (let attempt = 0; ; attempt++) {
      if (attempt === 3) throw new SyncError("Another device keeps changing this data. Try again in a moment.");
      const seen = s.kinds[kind] ?? { version: 0, digest: "" };
      const r = await remote.get(kind);
      if ((r?.version ?? 0) < seen.version) throw new SyncError("The sync service sent older data than this device already has, so nothing was changed. Try again later.");
      let remoteText: string | undefined;
      if (r) {
        try { remoteText = dec.decode(await openBlob(s.ak, r.ciphertext, syncAAD(s.userId, kind, r.version, r.keyId))); }
        catch { throw new SyncError("Synced data couldn't be decrypted with this device's key, so nothing was changed. If you reset sync on another device, turn sync off here and enter the new recovery key."); }
      }
      const remoteValue: unknown = remoteText === undefined ? undefined : JSON.parse(remoteText);
      const local = await getItem(key), localText = JSON.stringify(local ?? null);
      const edited = (await digest(localText)) !== seen.digest;
      let next: unknown = local;
      if (r && r.version > seen.version) next = records ? mergeRecords(local, remoteValue) : !edited || empty(local) || seen.version === 0 ? remoteValue : local;
      if (!records && !empty(local) && JSON.stringify(next ?? null) !== localText) {
        // First sync on this device (or remote won): keep what it had, so a restore never silently loses it.
        // SHORTCUT: no restore UI for these backups yet; they stay in IndexedDB under "before-sync:<key>".
        await setItem(`before-sync:${key}`, { saved: now.toISOString(), value: local });
        replaced.push(key);
      }
      if (JSON.stringify(next ?? null) !== localText) {
        // Same transaction rules as the rest of the app; an edit made while we were away merges in (records) or wins (whole).
        next = await updateItem(key, (cur) => (records ? mergeRecords(cur, next) : JSON.stringify(cur ?? null) === localText ? next : cur));
        pulled++;
      }
      const text = JSON.stringify(next ?? null);
      if (empty(next) || text === remoteText) {
        s.kinds[kind] = { version: r?.version ?? 0, digest: await digest(text) };
        break;
      }
      const version = (r?.version ?? 0) + 1;
      const blob = await sealBlob(s.ak, enc.encode(text), syncAAD(s.userId, kind, version, s.keyId));
      const w = await remote.put(kind, r?.version ?? null, s.keyId, blob);
      if (!w.ok) continue;
      if (w.version !== version) throw new SyncError("The sync service numbered this change unexpectedly. Try again later.");
      s.kinds[kind] = { version, digest: await digest(text) };
      pushed++;
      break;
    }
    await setItem(STATE, s);  // per kind: a failure later in the run must not forget what this kind agreed with the server
  }
  s.last = now.toISOString();
  await setItem(STATE, s);
  return { pushed, pulled, replaced };
}
