// Cross-client vectors (v4 P4.4a): TS seals ts_sealed.json, Swift seals swift_sealed.json (SyncVectorTests.swift);
// each side must open the other's. Test-only keys: AK = bytes 0..31, RK = bytes 0xa0..0xaf. Regenerate: OFFERLANE_WRITE_GOLDEN=1.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { formatRecoveryKey, importAccountKey, openBlob, sealBlob, syncAAD, unwrapAccountKey, wrapAccountKey, type SyncKind } from "../src/sync.js";

const FX = new URL("../../../Packages/OfferlaneCore/Tests/OfferlaneCoreTests/Fixtures/sync/", import.meta.url);
const userId = "user-1", keyId = "0123abcd0123abcd";
const ak = Uint8Array.from({ length: 32 }, (_, i) => i), rk = Uint8Array.from({ length: 16 }, (_, i) => 0xa0 + i);
const b64 = (b: Uint8Array) => Buffer.from(b).toString("base64"), unb64 = (s: string) => new Uint8Array(Buffer.from(s, "base64"));
const PLAIN: Array<{ kind: SyncKind; version: number; plaintext: string }> = [
  { kind: "profile", version: 1, plaintext: JSON.stringify({ name: "Zoë Example", city: "Zürich 🇨🇭" }) },
  { kind: "applications", version: 7, plaintext: JSON.stringify({ "gh:acme:1": { status: "applied", updated: "2026-11-16T10:00:00.000Z" } }) },
];
type Vectors = { recoveryKey: string; keyring: { version: number; ringId: string; blob: string }; blobs: Array<{ kind: SyncKind; version: number; keyId: string; plaintext: string; blob: string }> };

describe("sync vectors shared with Swift", () => {
  it("seals ts_sealed.json (or checks it still opens)", async () => {
    const key = await importAccountKey(ak.slice());
    if (process.env.OFFERLANE_WRITE_GOLDEN === "1") {
      const v: Vectors = {
        recoveryKey: formatRecoveryKey(rk),
        keyring: { version: 1, ringId: "rk-1", blob: b64(await wrapAccountKey(ak.slice(), keyId, rk, userId, 1, "rk-1")) },
        blobs: await Promise.all(PLAIN.map(async (p) => ({ ...p, keyId, blob: b64(await sealBlob(key, new TextEncoder().encode(p.plaintext), syncAAD(userId, p.kind, p.version, keyId))) }))),
      };
      writeFileSync(new URL("ts_sealed.json", FX), JSON.stringify(v, null, 2) + "\n");
    }
    await opens(JSON.parse(readFileSync(new URL("ts_sealed.json", FX), "utf8")));
  });

  it("opens what Swift sealed", async () => {
    const f = new URL("swift_sealed.json", FX);
    expect(existsSync(f)).toBe(true);
    await opens(JSON.parse(readFileSync(f, "utf8")));
  });
});

async function opens(v: Vectors) {
  expect(v.recoveryKey).toBe(formatRecoveryKey(rk));
  const ring = await unwrapAccountKey(unb64(v.keyring.blob), rk, userId, v.keyring.version, v.keyring.ringId);
  expect(ring.keyId).toBe(keyId);
  expect(v.blobs.length).toBeGreaterThan(0);
  for (const b of v.blobs) {
    const plain = await openBlob(ring.key, unb64(b.blob), syncAAD(userId, b.kind, b.version, b.keyId));
    expect(new TextDecoder().decode(plain)).toBe(b.plaintext);
    await expect(openBlob(ring.key, unb64(b.blob), syncAAD(userId, b.kind, b.version + 1, b.keyId))).rejects.toThrow();
  }
}
