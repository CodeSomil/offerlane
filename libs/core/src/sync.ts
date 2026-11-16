// End-to-end encrypted sync, client side (docs/v4/SYNC_CRYPTO.md, D3). WebCrypto only, so it runs in browsers and Node.
// The server sees ciphertext, kind names, versions and key ids; nothing here ever sends a key or plaintext.
const { subtle } = globalThis.crypto;
const enc = new TextEncoder();

export const SYNC_KINDS = ["keyring", "profile", "resumes", "applications", "contacts", "settings"] as const;
export type SyncKind = (typeof SYNC_KINDS)[number];

export class SyncCryptoError extends Error {}

type Bytes = Uint8Array<ArrayBuffer>;
const random = (n: number): Bytes => crypto.getRandomValues(new Uint8Array(n));

export const syncAAD = (userId: string, kind: SyncKind, version: number, keyId: string): Bytes =>
  enc.encode(`offerlane-sync-v1|${userId}|${kind}|${version}|${keyId}`);

export const makeAccountKey = (): Bytes => random(32);
export const makeRecoveryKey = (): Bytes => random(16);
export const makeKeyId = (): string => Array.from(random(8), (b) => b.toString(16).padStart(2, "0")).join("");

/** The account key as a non-extractable AES-GCM key (IndexedDB can store it; script can't read it back). */
export const importAccountKey = (raw: Bytes): Promise<CryptoKey> =>
  subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);

/** 0x01 ‖ nonce (12) ‖ AES-256-GCM ciphertext ‖ tag (16). */
export async function sealBlob(key: CryptoKey, plaintext: Bytes, aad: Bytes): Promise<Bytes> {
  const nonce = random(12);
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad }, key, plaintext));
  const out = new Uint8Array(13 + ct.length);
  out[0] = 1; out.set(nonce, 1); out.set(ct, 13);
  return out;
}

export async function openBlob(key: CryptoKey, blob: Bytes, aad: Bytes): Promise<Bytes> {
  if (blob.length < 13 + 16 || blob[0] !== 1) throw new SyncCryptoError("This synced data isn't in a format this version can read.");
  try {
    return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv: blob.slice(1, 13), additionalData: aad }, key, blob.slice(13)));
  } catch { throw new SyncCryptoError("This synced data couldn't be decrypted: wrong key, or it was changed."); }
}

// RFC 4648 base32 without padding: 16 bytes → 26 letters, shown in groups of 4.
const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
export function formatRecoveryKey(rk: Bytes): string {
  let bits = 0, acc = 0, s = "";
  for (const b of rk) {
    acc = (acc << 8) | b; bits += 8;
    while (bits >= 5) { s += B32[(acc >> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) s += B32[(acc << (5 - bits)) & 31];
  return s.match(/.{1,4}/g)!.join("-");
}
/** Case, spaces and dashes don't matter. Anything else (wrong length, other letters, set padding bits) is null. */
export function parseRecoveryKey(text: string): Bytes | null {
  const s = text.toUpperCase().replace(/[\s-]/g, "");
  if (s.length !== 26) return null;
  const out = new Uint8Array(16);
  let bits = 0, acc = 0, i = 0;
  for (const c of s) {
    const v = B32.indexOf(c);
    if (v < 0) return null;
    acc = ((acc << 5) | v) & 0xfff; bits += 5;
    if (bits >= 8) { out[i++] = (acc >> (bits - 8)) & 255; bits -= 8; }
  }
  return (acc & ((1 << bits) - 1)) === 0 ? out : null;
}

async function recoveryKEK(rk: Bytes, userId: string): Promise<CryptoKey> {
  const ikm = await subtle.importKey("raw", rk, "HKDF", false, ["deriveKey"]);
  return subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: enc.encode(userId), info: enc.encode("offerlane-recovery-v1") },
    ikm, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}
const KEY_ID = /^[A-Za-z0-9_-]{1,64}$/;
/** The keyring blob: the raw account key ‖ its key id (ASCII), sealed under the recovery-key KEK (kind "keyring",
 *  blob key id "rk-<n>"), so every device uses the same key id for the same account key. */
export async function wrapAccountKey(ak: Bytes, akId: string, rk: Bytes, userId: string, version: number, ringId: string): Promise<Bytes> {
  if (ak.length !== 32 || !KEY_ID.test(akId)) throw new SyncCryptoError("Bad account key or key id.");
  const plain = new Uint8Array(32 + akId.length);
  plain.set(ak); plain.set(enc.encode(akId), 32);
  try { return await sealBlob(await recoveryKEK(rk, userId), plain, syncAAD(userId, "keyring", version, ringId)); } finally { plain.fill(0); }
}
export async function unwrapAccountKey(ring: Bytes, rk: Bytes, userId: string, version: number, ringId: string): Promise<{ key: CryptoKey; keyId: string }> {
  const raw = await openBlob(await recoveryKEK(rk, userId), ring, syncAAD(userId, "keyring", version, ringId))
    .catch(() => { throw new SyncCryptoError("That recovery key doesn't open this account's synced data."); });
  try {
    const keyId = new TextDecoder().decode(raw.subarray(32));
    if (raw.length < 33 || !KEY_ID.test(keyId)) throw new SyncCryptoError("This account's keyring isn't in a format this version can read.");
    return { key: await importAccountKey(raw.slice(0, 32)), keyId };
  } finally { raw.fill(0); }
}

const isMap = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const stamp = (v: unknown) => (isMap(v) && typeof v.updated === "string" ? v.updated : "");
/** JSON with sorted keys: one spelling per value, the same the Mac writes (Swift SyncEngine.canon), for the merge tie-break. */
export const canonJSON = (v: unknown): string =>
  Array.isArray(v) ? `[${v.map(canonJSON).join(",")}]`
    : isMap(v) ? `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonJSON(v[k])}`).join(",")}}`
      : JSON.stringify(v ?? null);
/** Record maps (applications): union by id; the newer ISO `updated` wins. On a tie the greater canonical JSON wins, so every
 *  device picks the same record (a "local wins" tie made two devices that edited in the same second swap forever). Never deleted. */
export function mergeRecords(local: unknown, remote: unknown): Record<string, unknown> {
  const out: Record<string, unknown> = isMap(remote) ? { ...remote } : {};
  if (isMap(local)) for (const [id, l] of Object.entries(local)) {
    if (!(id in out)) { out[id] = l; continue; }
    const a = stamp(l), b = stamp(out[id]);
    if (a > b || (a === b && canonJSON(l) > canonJSON(out[id]))) out[id] = l;
  }
  return out;
}
