import { describe, expect, it } from "vitest";
import { SYNC_KINDS, SyncCryptoError, canonJSON, formatRecoveryKey, importAccountKey, makeAccountKey, makeKeyId, makeRecoveryKey, mergeRecords, openBlob, parseRecoveryKey,
  sealBlob, syncAAD, unwrapAccountKey, wrapAccountKey } from "../src/sync.js";

const enc = new TextEncoder(), dec = new TextDecoder();
const u = "user-1";

describe("sync crypto (docs/v4/SYNC_CRYPTO.md)", () => {
  it("lists the server's fixed kinds", () => {
    expect(SYNC_KINDS).toEqual(["keyring", "profile", "resumes", "applications", "contacts", "settings"]);
  });

  it("writes 0x01 ‖ nonce ‖ ciphertext ‖ tag and round-trips", async () => {
    const key = await importAccountKey(makeAccountKey());
    const blob = await sealBlob(key, enc.encode("hello"), syncAAD(u, "profile", 1, "k1"));
    expect(blob[0]).toBe(1);
    expect(blob.length).toBe(1 + 12 + 5 + 16);
    expect(dec.decode(await openBlob(key, blob, syncAAD(u, "profile", 1, "k1")))).toBe("hello");
    // fresh nonce each time
    const again = await sealBlob(key, enc.encode("hello"), syncAAD(u, "profile", 1, "k1"));
    expect(Buffer.from(again).equals(Buffer.from(blob))).toBe(false);
  });

  it("fails when the user, kind, version or key id in the AAD changes, or a byte is flipped", async () => {
    const key = await importAccountKey(makeAccountKey());
    const blob = await sealBlob(key, enc.encode("x"), syncAAD(u, "resumes", 3, "k1"));
    for (const ad of [syncAAD("user-2", "resumes", 3, "k1"), syncAAD(u, "profile", 3, "k1"), syncAAD(u, "resumes", 2, "k1"), syncAAD(u, "resumes", 3, "k2")])
      await expect(openBlob(key, blob, ad)).rejects.toBeInstanceOf(SyncCryptoError);
    const bad = blob.slice(); bad[20] = bad[20]! ^ 1;
    await expect(openBlob(key, bad, syncAAD(u, "resumes", 3, "k1"))).rejects.toBeInstanceOf(SyncCryptoError);
    const v2 = blob.slice(); v2[0] = 2;
    await expect(openBlob(key, v2, syncAAD(u, "resumes", 3, "k1"))).rejects.toBeInstanceOf(SyncCryptoError);
    await expect(openBlob(key, blob.slice(0, 20), syncAAD(u, "resumes", 3, "k1"))).rejects.toBeInstanceOf(SyncCryptoError);
  });

  it("keeps the account key non-extractable once imported", async () => {
    const key = await importAccountKey(makeAccountKey());
    expect(key.extractable).toBe(false);
    await expect(crypto.subtle.exportKey("raw", key)).rejects.toThrow();
  });

  it("makes 16-hex key ids", () => {
    expect(makeKeyId()).toMatch(/^[0-9a-f]{16}$/);
  });

  it("shows a 16-byte recovery key as base32 in groups of 4 and reads it back leniently", () => {
    const rk = makeRecoveryKey();
    expect(rk.length).toBe(16);
    const s = formatRecoveryKey(rk);
    expect(s).toMatch(/^([A-Z2-7]{4}-){6}[A-Z2-7]{2}$/);
    expect(parseRecoveryKey(s)).toEqual(rk);
    expect(parseRecoveryKey(` ${s.toLowerCase().replaceAll("-", " ")} `)).toEqual(rk);
    expect(formatRecoveryKey(new Uint8Array(16))).toBe("AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AA");
    expect(formatRecoveryKey(new Uint8Array(16).fill(255))).toBe("7777-7777-7777-7777-7777-7777-74");
  });

  it("refuses a recovery key that is too short, too long, has other letters, or non-zero padding bits", () => {
    const s = formatRecoveryKey(makeRecoveryKey());
    expect(parseRecoveryKey(s.slice(0, -1))).toBeNull();
    expect(parseRecoveryKey(s + "A")).toBeNull();
    expect(parseRecoveryKey(s.replace(/.$/, "1"))).toBeNull();
    expect(parseRecoveryKey("7777-7777-7777-7777-7777-7777-77")).toBeNull(); // padding bits set
    expect(parseRecoveryKey("")).toBeNull();
  });

  it("wraps the account key with the recovery key, bound to the user and keyring version", async () => {
    const ak = makeAccountKey(), rk = makeRecoveryKey();
    const ring = await wrapAccountKey(ak, "0123abcd0123abcd", rk, u, 1, "rk-1");
    const { key: back, keyId } = await unwrapAccountKey(ring, rk, u, 1, "rk-1");
    expect(keyId).toBe("0123abcd0123abcd"); // every device learns the same key id
    expect(back.extractable).toBe(false);
    await expect(wrapAccountKey(ak, "bad id!", rk, u, 1, "rk-1")).rejects.toBeInstanceOf(SyncCryptoError);
    await expect(wrapAccountKey(ak.slice(0, 16), "k1", rk, u, 1, "rk-1")).rejects.toBeInstanceOf(SyncCryptoError);
    const blob = await sealBlob(await importAccountKey(ak), enc.encode("data"), syncAAD(u, "profile", 1, "k1"));
    expect(dec.decode(await openBlob(back, blob, syncAAD(u, "profile", 1, "k1")))).toBe("data");
    await expect(unwrapAccountKey(ring, makeRecoveryKey(), u, 1, "rk-1")).rejects.toBeInstanceOf(SyncCryptoError);
    await expect(unwrapAccountKey(ring, rk, "user-2", 1, "rk-1")).rejects.toBeInstanceOf(SyncCryptoError);
    await expect(unwrapAccountKey(ring, rk, u, 2, "rk-1")).rejects.toBeInstanceOf(SyncCryptoError);
  });

  it("merges record maps: union by id, the newer `updated` wins, a tie goes to the greater canonical JSON on every device", () => {
    const local = { a: { updated: "2026-11-10T00:00:00.000Z", v: "L" }, b: { updated: "2026-11-12T00:00:00.000Z", v: "L" }, c: { updated: "2026-11-01T00:00:00.000Z", v: "L" } };
    const remote = { a: { updated: "2026-11-11T00:00:00.000Z", v: "R" }, b: { updated: "2026-11-11T00:00:00.000Z", v: "R" }, c: { updated: "2026-11-01T00:00:00.000Z", v: "R" }, d: { updated: "", v: "R" } };
    expect(mergeRecords(local, remote)).toEqual({ a: remote.a, b: local.b, c: remote.c, d: remote.d });
    expect(mergeRecords(remote, local)).toEqual(mergeRecords(local, remote)); // both devices agree
    expect(canonJSON({ b: [1, { d: "é", c: null }], a: 0.82 })).toBe('{"a":0.82,"b":[1,{"c":null,"d":"é"}]}');
    expect(mergeRecords(undefined, remote)).toEqual(remote);
    expect(mergeRecords(local, "not a map")).toEqual(local);
  });
});
