// IndexedDB key/value store for the web app (P3.4, H3). Everything stays on this device.
import type { AIConfig } from "@offerlane/core";
import { platform } from "./platform.js";

const req = <T>(r: IDBRequest<T>) => new Promise<T>((ok, fail) => { r.onsuccess = () => ok(r.result); r.onerror = () => fail(r.error); });
let db: Promise<IDBDatabase> | undefined;
function open() {
  if (!db) {
    const r = indexedDB.open("offerlane", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("kv");
    r.onblocked = () => console.warn("Offerlane storage is busy in another tab.");
    db = req(r).then((d) => { d.onversionchange = () => { d.close(); db = undefined; }; return d; },
      (e: unknown) => { db = undefined; throw e; });  // retry next call instead of caching the failure
  }
  return db;
}
async function kv(mode: IDBTransactionMode) { return (await open()).transaction("kv", mode).objectStore("kv"); }

export const getItem = async (k: string): Promise<unknown> => req((await kv("readonly")).get(k));
export const setItem = async (k: string, v: unknown) => { await req((await kv("readwrite")).put(v, k)); };
export const delItem = async (k: string) => { await req((await kv("readwrite")).delete(k)); };
/** Read, change and write one value in a single readwrite transaction, so overlapping updates (or two tabs) can't drop
 *  each other's writes. `f` must be synchronous; if it throws, nothing is written and the promise rejects with its error. */
export async function updateItem<T>(k: string, f: (old: unknown) => T): Promise<T> {
  const s = await kv("readwrite");
  return new Promise<T>((ok, fail) => {
    let out: T, err: unknown;
    s.transaction.oncomplete = () => ok(out);
    s.transaction.onabort = () => fail(err ?? s.transaction.error);
    const g = s.get(k);
    g.onsuccess = () => {
      try { out = f(g.result); } catch (e) { err = e; s.transaction.abort(); return; }
      s.put(out, k);
    };
  });
}

/** "Remember on this device": the AI config is AES-GCM encrypted under a non-extractable WebCrypto key kept beside it,
 *  so a copy of the stored bytes alone is useless and page script can use the key but never read it out. */
export async function rememberAI(c: AIConfig) {
  if (platform.secrets) return platform.secrets.save(c);  // the Windows shell: Credential Manager
  let wrap = (await getItem("ai-wrap")) as CryptoKey | undefined;
  if (!wrap) { wrap = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]); await setItem("ai-wrap", wrap); }
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, wrap, new TextEncoder().encode(JSON.stringify(c))));
  await setItem("ai", { iv, ct });
}

export async function loadAI(): Promise<AIConfig | undefined> {
  if (platform.secrets) return platform.secrets.load();
  const wrap = (await getItem("ai-wrap")) as CryptoKey | undefined;
  const box = (await getItem("ai")) as { iv: Uint8Array<ArrayBuffer>; ct: Uint8Array<ArrayBuffer> } | undefined;
  if (!wrap || !box) return undefined;
  try {
    return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: box.iv }, wrap, box.ct))) as AIConfig;
  } catch {
    await forgetAI();  // tampered or from a lost wrapping key: ask for the key again
    return undefined;
  }
}

export async function forgetAI() { await platform.secrets?.forget(); await delItem("ai"); await delItem("ai-wrap"); }
