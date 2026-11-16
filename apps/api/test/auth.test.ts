import { generateKeyPair, SignJWT, UnsecuredJWT } from "jose";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { dbUsers } from "../src/auth.js";
import { migrate } from "../src/db/migrate.js";
import { audience, fakeIssuer, issuer, memorySync, memoryUsers } from "./fakeIssuer.js";
import { adminUrl, freshDatabase } from "./testdb.js";

const iss = await fakeIssuer();
const app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: memoryUsers(), sync: memorySync() });
afterAll(() => app.close());

const me = (authorization?: string) =>
  app.inject({ method: "GET", url: "/v1/me", headers: authorization ? { authorization } : {} });

test("a valid token reaches /v1 and maps to the same user each time", async () => {
  const a = await me(`Bearer ${await iss.sign({ sub: "alice" })}`);
  const b = await me(`Bearer ${await iss.sign({ sub: "alice" })}`);
  const c = await me(`Bearer ${await iss.sign({ sub: "bob" })}`);
  expect(a.statusCode).toBe(200);
  expect(a.json().id).toBe(b.json().id);
  expect(c.json().id).not.toBe(a.json().id);
});

test("the Bearer scheme is case-insensitive", async () => {
  expect((await me(`bearer ${await iss.sign()}`)).statusCode).toBe(200);
});

test("a failing user lookup returns a generic 500, not the error text", async () => {
  const broken = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: async () => { throw new Error("connect ECONNREFUSED 10.0.0.5:5432"); }, sync: memorySync() });
  const res = await broken.inject({ method: "GET", url: "/v1/me", headers: { authorization: `Bearer ${await iss.sign()}` } });
  expect(res.statusCode).toBe(500);
  expect(res.body).not.toContain("10.0.0.5");
  expect(res.json()).toEqual({ error: "internal" });
  await broken.close();
});

test.each([
  ["no header", async () => undefined],
  ["not bearer", async () => `Basic ${await iss.sign()}`],
  ["garbage", async () => "Bearer not.a.jwt"],
  ["wrong audience", async () => `Bearer ${await iss.sign({}, { aud: "someone-else" })}`],
  ["wrong issuer", async () => `Bearer ${await iss.sign({}, { iss: "https://evil.test/" })}`],
  ["expired", async () => `Bearer ${await iss.sign({}, { exp: Math.floor(Date.now() / 1000) - 120 })}`],
  ["alg none", async () => `Bearer ${new UnsecuredJWT({ sub: "x" }).setIssuer(issuer).setAudience(audience).setExpirationTime("5m").encode()}`],
  ["HS256 shared secret", async () => `Bearer ${await new SignJWT({ sub: "x" }).setProtectedHeader({ alg: "HS256" }).setIssuer(issuer).setAudience(audience).setExpirationTime("5m").sign(new TextEncoder().encode("k".repeat(32)))}`],
  ["signed by another key", async () => {
    const { privateKey } = await generateKeyPair("ES256");
    return `Bearer ${await new SignJWT({ sub: "x" }).setProtectedHeader({ alg: "ES256", kid: "k1" }).setIssuer(issuer).setAudience(audience).setExpirationTime("5m").sign(privateKey)}`;
  }],
])("rejects %s with 401", async (_name, header) => {
  const res = await me(await header());
  expect(res.statusCode).toBe(401);
  expect(res.headers["www-authenticate"]).toContain("Bearer");
  expect(res.json()).toEqual({ error: "unauthorized" });
});

describe.skipIf(!adminUrl)("users in Postgres", () => {
  let db: Awaited<ReturnType<typeof freshDatabase>>;
  let pool: pg.Pool;
  beforeAll(async () => {
    db = await freshDatabase();
    await migrate(db.url, "up");
    pool = new pg.Pool({ connectionString: db.url });
  });
  afterAll(async () => { await pool.end(); await db.drop(); });

  test("first sight creates the user, later sights reuse it", async () => {
    const users = dbUsers(pool);
    const a = await users(issuer, "alice");
    expect(await users(issuer, "alice")).toBe(a);
    expect(await users("https://other.test/", "alice")).not.toBe(a);
    expect((await pool.query("SELECT count(*)::int AS n FROM users")).rows[0].n).toBe(2);
  });
});
