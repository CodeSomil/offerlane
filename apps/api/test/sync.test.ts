import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { dbUsers } from "../src/auth.js";
import { migrate } from "../src/db/migrate.js";
import { dbSync, MAX_CIPHERTEXT } from "../src/sync.js";
import { audience, fakeIssuer, issuer, memorySync, memoryUsers } from "./fakeIssuer.js";
import { adminUrl, freshDatabase } from "./testdb.js";

const iss = await fakeIssuer();
const b64 = (s: string | Buffer) => Buffer.from(s).toString("base64");

// The same HTTP rules must hold for the in-memory store and for Postgres.
function suite(name: string, setup: () => Promise<{ deps: Pick<Parameters<typeof buildApp>[0], "users" | "sync">; done: () => Promise<void> }>, skip = false) {
  describe.skipIf(skip)(name, () => {
    let app: ReturnType<typeof buildApp>;
    let done: () => Promise<void>;
    beforeAll(async () => {
      const s = await setup();
      done = s.done;
      app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, ...s.deps });
    });
    afterAll(async () => { await app.close(); await done(); });

    const call = async (method: "GET" | "PUT", kind: string, opts: { sub?: string; headers?: Record<string, string>; body?: unknown } = {}) =>
      app.inject({
        method, url: `/v1/sync/${kind}`,
        headers: { authorization: `Bearer ${await iss.sign({ sub: opts.sub ?? "alice" })}`, ...opts.headers },
        ...(opts.body === undefined ? {} : { payload: opts.body as object }),
      });
    const blob = (text: string, keyId = "k1") => ({ keyId, ciphertext: b64(text) });

    test("404 before anything is stored", async () => {
      expect((await call("GET", "profile")).statusCode).toBe(404);
    });

    test("create, read back, then replace with If-Match", async () => {
      const c = await call("PUT", "resumes", { headers: { "if-none-match": "*" }, body: blob("one") });
      expect(c.statusCode).toBe(200);
      expect(c.json()).toEqual({ version: 1 });
      expect(c.headers.etag).toBe('"v1"');

      const g = await call("GET", "resumes");
      expect(g.statusCode).toBe(200);
      expect(g.headers.etag).toBe('"v1"');
      expect(g.json()).toEqual({ version: 1, keyId: "k1", ciphertext: b64("one") });

      const r = await call("PUT", "resumes", { headers: { "if-match": '"v1"' }, body: blob("two", "k2") });
      expect(r.json()).toEqual({ version: 2 });
      expect((await call("GET", "resumes")).json()).toEqual({ version: 2, keyId: "k2", ciphertext: b64("two") });
    });

    test("a stale If-Match or a second create is a 409 with the current version", async () => {
      await call("PUT", "contacts", { headers: { "if-none-match": "*" }, body: blob("a") });
      await call("PUT", "contacts", { headers: { "if-match": '"v1"' }, body: blob("b") });
      const stale = await call("PUT", "contacts", { headers: { "if-match": '"v1"' }, body: blob("c") });
      expect(stale.statusCode).toBe(409);
      expect(stale.json()).toEqual({ error: "conflict", version: 2 });
      const again = await call("PUT", "contacts", { headers: { "if-none-match": "*" }, body: blob("d") });
      expect(again.statusCode).toBe(409);
      expect(again.json()).toEqual({ error: "conflict", version: 2 });
      const none = await call("PUT", "settings", { headers: { "if-match": '"v1"' }, body: blob("e") });
      expect(none.statusCode).toBe(409);
      expect(none.json()).toEqual({ error: "conflict", version: null });
      expect((await call("GET", "contacts")).json().ciphertext).toBe(b64("b"));
    });

    test("two writers on the same version: exactly one wins", async () => {
      await call("PUT", "applications", { headers: { "if-none-match": "*" }, body: blob("base") });
      const res = await Promise.all(["x", "y", "z"].map((t) => call("PUT", "applications", { headers: { "if-match": '"v1"' }, body: blob(t) })));
      expect(res.map((r) => r.statusCode).sort()).toEqual([200, 409, 409]);
    });

    test("users can't see each other's blobs", async () => {
      await call("PUT", "keyring", { sub: "bob", headers: { "if-none-match": "*" }, body: blob("bob's") });
      expect((await call("GET", "keyring", { sub: "carol" })).statusCode).toBe(404);
      const c = await call("PUT", "keyring", { sub: "carol", headers: { "if-none-match": "*" }, body: blob("carol's") });
      expect(c.json()).toEqual({ version: 1 });
      expect((await call("GET", "keyring", { sub: "bob" })).json().ciphertext).toBe(b64("bob's"));
    });

    test("a missing precondition is 428; a malformed or doubled one is 400", async () => {
      expect((await call("PUT", "profile", { body: blob("p") })).statusCode).toBe(428);
      expect((await call("PUT", "profile", { headers: { "if-match": "v1" }, body: blob("p") })).statusCode).toBe(400);
      expect((await call("PUT", "profile", { headers: { "if-match": '"v0"' }, body: blob("p") })).statusCode).toBe(400);
      expect((await call("PUT", "profile", { headers: { "if-match": '"v1"', "if-none-match": "*" }, body: blob("p") })).statusCode).toBe(400);
    });

    test.each([
      ["kind with capitals", "Profile", blob("p")],
      ["kind too long", "a".repeat(33), blob("p")],
      ["kind not in the spec's list", "a1", blob("p")],
      ["keyId with odd characters", "profile", { keyId: "k\u0000 me@x.com", ciphertext: b64("p") }],
      ["not base64", "profile", { keyId: "k1", ciphertext: "not base64!" }],
      ["empty ciphertext", "profile", { keyId: "k1", ciphertext: "" }],
      ["keyId too long", "profile", { keyId: "k".repeat(65), ciphertext: b64("p") }],
      ["extra field", "profile", { ...blob("p"), plaintext: "hi" }],
    ])("400 for %s", async (_n, kind, body) => {
      expect((await call("PUT", kind, { headers: { "if-none-match": "*" }, body })).statusCode).toBe(400);
    });

    test("over the 8 MiB cap is 413", async () => {
      const big = { keyId: "k1", ciphertext: Buffer.alloc(MAX_CIPHERTEXT + 1).toString("base64") };
      const r = await call("PUT", "profile", { headers: { "if-none-match": "*" }, body: big });
      expect(r.statusCode).toBe(413);
      expect(r.json()).toEqual({ error: "too_large" });
      // Over the body limit itself: rejected while parsing, same body.
      const huge = await call("PUT", "profile", { headers: { "if-none-match": "*" }, body: { keyId: "k1", ciphertext: "A".repeat(12 << 20) } });
      expect(huge.statusCode).toBe(413);
      expect(huge.json()).toEqual({ error: "too_large" });
      const exact = { keyId: "k1", ciphertext: Buffer.alloc(MAX_CIPHERTEXT).toString("base64") };
      expect((await call("PUT", "profile", { headers: { "if-none-match": "*" }, body: exact })).statusCode).toBe(200);
    });
  });
}

test("an unknown kind is 400 on GET too", async () => {
  const app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: memoryUsers(), sync: memorySync() });
  const r = await app.inject({ method: "GET", url: "/v1/sync/a1", headers: { authorization: `Bearer ${await iss.sign()}` } });
  expect(r.statusCode).toBe(400);
  await app.close();
});

test("an unauthenticated 12 MiB PUT is a 401 before the body is read", async () => {
  const app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: memoryUsers(), sync: memorySync() });
  const r = await app.inject({ method: "PUT", url: "/v1/sync/profile", headers: { "if-none-match": "*" }, payload: { keyId: "k1", ciphertext: "A".repeat(12 << 20) } });
  expect(r.statusCode).toBe(401);
  await app.close();
});

test("a failing store gives a generic 500 on GET and PUT", async () => {
  const boom = async () => { throw new Error("violates check constraint, row contains secret-bytes"); };
  const app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: memoryUsers(), sync: { get: boom, put: boom } });
  const headers = { authorization: `Bearer ${await iss.sign()}`, "if-none-match": "*" };
  for (const r of [
    await app.inject({ method: "GET", url: "/v1/sync/profile", headers }),
    await app.inject({ method: "PUT", url: "/v1/sync/profile", headers, payload: { keyId: "k1", ciphertext: b64("p") } }),
  ]) {
    expect(r.statusCode).toBe(500);
    expect(r.json()).toEqual({ error: "internal" });
  }
  await app.close();
});

suite("sync over HTTP (memory store)", async () => ({ deps: { users: memoryUsers(), sync: memorySync() }, done: async () => {} }));

suite("sync over HTTP (Postgres)", async () => {
  const db = await freshDatabase();
  await migrate(db.url, "up");
  const pool = new pg.Pool({ connectionString: db.url });
  return { deps: { users: dbUsers(pool), sync: dbSync(pool) }, done: async () => { await pool.end(); await db.drop(); } };
}, !adminUrl);

