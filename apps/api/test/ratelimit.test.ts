import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { dbUsers } from "../src/auth.js";
import { migrate } from "../src/db/migrate.js";
import { bucketFor, dbLimits } from "../src/ratelimit.js";
import { audience, fakeIssuer, issuer, memorySync } from "./fakeIssuer.js";
import { adminUrl, freshDatabase } from "./testdb.js";

const iss = await fakeIssuer();

test("routes map to buckets", () => {
  expect(bucketFor("/v1/sync/:kind")).toBe("sync");
  expect(bucketFor("/v1/jobs")).toBe("jobs");
  expect(bucketFor("/v1/me")).toBe("api");
  expect(bucketFor(undefined)).toBe("api");
});

describe.skipIf(!adminUrl)("per-user token bucket (Postgres)", () => {
  let db: Awaited<ReturnType<typeof freshDatabase>>;
  let pool: pg.Pool;
  let app: ReturnType<typeof buildApp>;
  const rules = { sync: { capacity: 3, perSecond: 0.5 }, jobs: { capacity: 3, perSecond: 0.5 }, api: { capacity: 2, perSecond: 0.5 } };
  beforeAll(async () => {
    db = await freshDatabase();
    await migrate(db.url, "up");
    pool = new pg.Pool({ connectionString: db.url });
    app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: dbUsers(pool), sync: memorySync(), limits: dbLimits(pool, rules) });
  });
  afterAll(async () => { await app.close(); await pool.end(); await db.drop(); });

  const get = async (url: string, sub = "alice") => app.inject({ method: "GET", url, headers: { authorization: `Bearer ${await iss.sign({ sub })}` } });

  test("the burst is allowed, then 429 with Retry-After", async () => {
    for (let i = 0; i < 3; i++) expect((await get("/v1/sync/profile")).statusCode).toBe(404);
    const r = await get("/v1/sync/profile");
    expect(r.statusCode).toBe(429);
    expect(r.json()).toEqual({ error: "rate_limited" });
    // 0.5 tokens/s: one token takes 2 s; a denied request costs up to one more, so at most 4 s.
    const after = Number(r.headers["retry-after"]);
    expect(after).toBeGreaterThanOrEqual(1);
    expect(after).toBeLessThanOrEqual(4);
  });

  test("buckets are per user and per route class", async () => {
    expect((await get("/v1/sync/profile", "bob")).statusCode).toBe(404); // another user is untouched
    expect((await get("/v1/me")).statusCode).toBe(200); // alice's api bucket is separate from her sync bucket
  });

  test("tokens refill over time", async () => {
    const uid = await dbUsers(pool)(issuer, "dave");
    for (let i = 0; i < 2; i++) await get("/v1/me", "dave");
    expect((await get("/v1/me", "dave")).statusCode).toBe(429);
    await pool.query("UPDATE rate_buckets SET updated_at = now() - interval '10 seconds' WHERE user_id = $1", [uid]);
    expect((await get("/v1/me", "dave")).statusCode).toBe(200);
  });

  test("hammering never pushes a bucket below -1 (a bounded wait)", async () => {
    for (let i = 0; i < 10; i++) await get("/v1/me", "erin");
    const uid = await dbUsers(pool)(issuer, "erin");
    const t = (await pool.query<{ tokens: number }>("SELECT tokens FROM rate_buckets WHERE user_id = $1", [uid])).rows[0]!.tokens;
    expect(t).toBeGreaterThanOrEqual(-1);
  });

  test("an unauthenticated request is a 401 and touches no bucket", async () => {
    const before = (await pool.query("SELECT count(*)::int AS n FROM rate_buckets")).rows[0].n;
    expect((await app.inject({ method: "GET", url: "/v1/me" })).statusCode).toBe(401);
    expect((await pool.query("SELECT count(*)::int AS n FROM rate_buckets")).rows[0].n).toBe(before);
  });
});
