import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { dbUsers } from "../src/auth.js";
import { migrate } from "../src/db/migrate.js";
import { dbIdempotency, pruneIdempotency } from "../src/idempotency.js";
import { audience, fakeIssuer, issuer, memorySync } from "./fakeIssuer.js";
import { adminUrl, freshDatabase } from "./testdb.js";

const iss = await fakeIssuer();
const blob = (s: string) => ({ keyId: "k1", ciphertext: Buffer.from(s).toString("base64") });

describe.skipIf(!adminUrl)("Idempotency-Key (Postgres)", () => {
  let db: Awaited<ReturnType<typeof freshDatabase>>;
  let pool: pg.Pool;
  let app: ReturnType<typeof buildApp>;
  beforeAll(async () => {
    db = await freshDatabase();
    await migrate(db.url, "up");
    pool = new pg.Pool({ connectionString: db.url });
    app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: dbUsers(pool), sync: memorySync(), idempotency: dbIdempotency(pool) });
  });
  afterAll(async () => { await app.close(); await pool.end(); await db.drop(); });

  const put = async (kind: string, key: string | undefined, body: unknown, headers: Record<string, string> = { "if-none-match": "*" }, sub = "alice") =>
    app.inject({
      method: "PUT", url: `/v1/sync/${kind}`, payload: body as object,
      headers: { authorization: `Bearer ${await iss.sign({ sub })}`, ...headers, ...(key === undefined ? {} : { "idempotency-key": key }) },
    });

  test("a retried PUT replays the first response instead of running again", async () => {
    const a = await put("profile", "k-1", blob("one"));
    expect(a.statusCode).toBe(200);
    expect(a.json()).toEqual({ version: 1 });
    // Without the key, the same create would now be a 409 (the blob exists). With it, it's the stored 200.
    const b = await put("profile", "k-1", blob("one"));
    expect(b.statusCode).toBe(200);
    expect(b.json()).toEqual({ version: 1 });
    expect(b.headers.etag).toBe(a.headers.etag);
    expect(b.headers["idempotent-replayed"]).toBe("true");
    expect((await put("profile", undefined, blob("one"))).statusCode).toBe(409);
  });

  test("the same key with a different request is a 422", async () => {
    expect((await put("settings", "k-2", blob("a"))).statusCode).toBe(200);
    const r = await put("settings", "k-2", blob("b"));
    expect(r.statusCode).toBe(422);
    expect(r.json()).toEqual({ error: "idempotency_key_reused" });
  });

  test("keys are per user", async () => {
    expect((await put("contacts", "shared", blob("x"), undefined, "alice")).statusCode).toBe(200);
    const r = await put("contacts", "shared", blob("x"), undefined, "bob");
    expect(r.statusCode).toBe(200);
    expect(r.headers["idempotent-replayed"]).toBeUndefined();
  });

  test("a key still in flight is a 409; a stale in-flight claim is taken over", async () => {
    const uid = await dbUsers(pool)(issuer, "alice");
    await pool.query("INSERT INTO idempotency_keys (user_id, key, request_hash) VALUES ($1, 'busy', 'h')", [uid]);
    const r = await put("keyring", "busy", blob("k"));
    expect(r.statusCode).toBe(409);
    expect(r.json()).toEqual({ error: "idempotency_key_in_flight" });
    await pool.query("UPDATE idempotency_keys SET created_at = now() - interval '10 minutes' WHERE key = 'busy'");
    expect((await put("keyring", "busy", blob("k"))).statusCode).toBe(200);
  });

  test("an expired key (over 24 h) is reusable, and pruning deletes it", async () => {
    expect((await put("applications", "old", blob("1"))).statusCode).toBe(200);
    await pool.query("UPDATE idempotency_keys SET created_at = now() - interval '25 hours' WHERE key = 'old'");
    const r = await put("applications", "old", blob("2"), { "if-match": '"v1"' });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ version: 2 });
    await pool.query("UPDATE idempotency_keys SET created_at = now() - interval '25 hours' WHERE key = 'old'");
    expect(await pruneIdempotency(pool)).toBeGreaterThanOrEqual(1);
    expect((await pool.query("SELECT 1 FROM idempotency_keys WHERE key = 'old'")).rowCount).toBe(0);
  });

  test("a bad key is a 400 and nothing is stored", async () => {
    for (const key of ["", "has space", "x".repeat(256)]) {
      const r = await put("resumes", key, blob("r"));
      expect(r.statusCode, JSON.stringify(key)).toBe(400);
      expect(r.json()).toEqual({ error: "bad_idempotency_key" });
    }
  });

  test("a 5xx releases the key, so the retry runs for real", async () => {
    let fail = true;
    const inner = memorySync();
    const flaky = { get: inner.get, put: (...a: Parameters<typeof inner.put>) => { if (fail) throw new Error("db down"); return inner.put(...a); } };
    const app2 = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: dbUsers(pool), sync: flaky, idempotency: dbIdempotency(pool) });
    const go = async () => app2.inject({ method: "PUT", url: "/v1/sync/profile", payload: blob("p"),
      headers: { authorization: `Bearer ${await iss.sign({ sub: "carol" })}`, "if-none-match": "*", "idempotency-key": "flaky" } });
    expect((await go()).statusCode).toBe(500);
    fail = false;
    const r = await go();
    expect(r.statusCode).toBe(200);
    expect(r.headers["idempotent-replayed"]).toBeUndefined();
    await app2.close();
  });

  test("a failed save still returns the real answer (the write committed)", async () => {
    const real = dbIdempotency(pool);
    const app2 = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: dbUsers(pool), sync: memorySync(),
      idempotency: { ...real, save: async () => { throw Object.assign(new Error("pool exhausted"), { code: "53300" }); } } });
    const r = await app2.inject({ method: "PUT", url: "/v1/sync/profile", payload: blob("p"),
      headers: { authorization: `Bearer ${await iss.sign({ sub: "frank" })}`, "if-none-match": "*", "idempotency-key": "save-fails" } });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ version: 1 });
    await app2.close();
  });

  test("a request that lost its claim to a stale takeover can't overwrite or delete the new claim", async () => {
    const store = dbIdempotency(pool);
    const uid = await dbUsers(pool)(issuer, "grace");
    const a = await store.claim(uid, "slow", "h1");
    expect(a.state).toBe("new");
    await pool.query("UPDATE idempotency_keys SET created_at = now() - interval '10 minutes' WHERE user_id = $1", [uid]);
    const b = await store.claim(uid, "slow", "h1");
    expect(b.state).toBe("new");
    const tokenA = (a as { token: string }).token;
    await store.save(uid, "slow", tokenA, { status: 200, body: "{\"from\":\"A\"}" });
    await store.release(uid, "slow", tokenA);
    expect(await store.claim(uid, "slow", "h1")).toEqual({ state: "busy" }); // B's claim is untouched
    await store.save(uid, "slow", (b as { token: string }).token, { status: 200, body: "{\"from\":\"B\"}" });
    expect(await store.claim(uid, "slow", "h1")).toEqual({ state: "replay", stored: { status: 200, body: "{\"from\":\"B\"}" } });
  });

  test("claim tokens round-trip under a non-ISO DateStyle and TimeZone", async () => {
    const odd = new pg.Pool({ connectionString: db.url, max: 1, options: "-c DateStyle=SQL,DMY -c TimeZone=Asia/Kolkata" });
    try {
      expect((await odd.query("SHOW DateStyle")).rows[0].DateStyle).toBe("SQL, DMY");
      const store = dbIdempotency(odd);
      const uid = await dbUsers(odd)(issuer, "heidi");
      const c = await store.claim(uid, "tz", "h");
      await store.save(uid, "tz", (c as { token: string }).token, { status: 200, body: "{}" });
      expect(await store.claim(uid, "tz", "h")).toEqual({ state: "replay", stored: { status: 200, body: "{}" } });
    } finally { await odd.end(); }
  });

  test("the stored response never holds the ciphertext", async () => {
    expect((await put("resumes", "secret", blob("CANARY-IDEM-RESUME"))).statusCode).toBe(200);
    const rows = (await pool.query<{ response: Buffer | null; request_hash: string }>("SELECT response, request_hash FROM idempotency_keys")).rows;
    const all = rows.map((r) => (r.response?.toString() ?? "") + r.request_hash).join("\n");
    expect(all).not.toContain("CANARY-IDEM-RESUME");
    expect(all).not.toContain(Buffer.from("CANARY-IDEM-RESUME").toString("base64"));
  });
});
