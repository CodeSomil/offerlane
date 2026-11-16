// P2.8 contract tests: real HTTP through the generated TS client, and every response checked against
// libs/contract/openapi.json (the committed file, not the zod source), status by status, header by header.
import { apiClient } from "@offerlane/contract";
import spec from "@offerlane/contract/openapi.json" with { type: "json" };
import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { z } from "zod";
import { buildApp } from "../src/app.js";
import { dbUsers } from "../src/auth.js";
import { dbReady, migrate } from "../src/db/migrate.js";
import { dbIdempotency } from "../src/idempotency.js";
import { dbJobs } from "../src/jobs.js";
import { dbLimits, DEFAULT_RULES } from "../src/ratelimit.js";
import { dbSync, MAX_CIPHERTEXT } from "../src/sync.js";
import { audience, fakeIssuer, issuer, memorySync, memoryUsers } from "./fakeIssuer.js";
import { adminUrl, freshDatabase } from "./testdb.js";

type Schema = Record<string, unknown>;
type Op = { responses: Record<string, { headers?: Record<string, { required?: boolean; schema: Schema }>; content?: { "application/json": { schema: Schema } } }> };
const paths = spec.paths as unknown as Record<string, Record<string, Op>>;
const iss = await fakeIssuer();

// Inline $refs and close every object: a response field the spec doesn't declare is a contract break too.
function strict(s: unknown): unknown {
  if (Array.isArray(s)) return s.map(strict);
  if (!s || typeof s !== "object") return s;
  const o = s as Schema;
  if (typeof o.$ref === "string") return strict((spec.components.schemas as Record<string, unknown>)[o.$ref.split("/").pop()!]);
  const out = Object.fromEntries(Object.entries(o).map(([k, v]) => [k, strict(v)]));
  return out.type === "object" && out.additionalProperties === undefined ? { ...out, additionalProperties: false } : out;
}
const validator = (s: Schema) => z.fromJSONSchema(strict(s) as Schema);

const all = Object.entries(paths).flatMap(([p, ops]) => Object.entries(ops).flatMap(([m, op]) => Object.keys(op.responses).map((st) => `${m.toUpperCase()} ${p} ${st}`)));
const seen = new Set<string>();

type Result = { response: Response; data?: unknown; error?: unknown };
/** Checks one real response against the spec entry for (method, path, status) and records it as covered.
 * Takes an openapi-fetch result (body already parsed) or a raw fetch Response. */
async function check(method: string, path: string, r: Result | Response) {
  const res = r instanceof Response ? r : r.response;
  const parsed = r instanceof Response ? await r.json() : (r.data ?? r.error);
  const entry = paths[path]?.[method.toLowerCase()]?.responses[String(res.status)];
  expect(entry, `${method} ${path} returned ${res.status}, which the spec doesn't list`).toBeDefined();
  for (const [name, h] of Object.entries(entry!.headers ?? {})) {
    const v = res.headers.get(name);
    if (h.required) expect(v, `${method} ${path} ${res.status}: header ${name}`).not.toBeNull();
    if (v !== null) validator(h.schema).parse(v);
  }
  const schema = entry!.content?.["application/json"].schema;
  if (schema) {
    expect(res.headers.get("content-type")).toMatch(/^application\/json/);
    const body = validator(schema).safeParse(parsed);
    expect(body.error, `${method} ${path} ${res.status}`).toBeUndefined();
  }
  seen.add(`${method} ${path} ${res.status}`);
}

test("the app serves exactly the spec's operations", async () => {
  const app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: memoryUsers(), sync: memorySync(), jobs: async () => ({ items: [], next: null }) });
  await app.ready();
  // printRoutes lists each path with its methods; HEAD is Fastify's automatic twin of GET.
  const routes = app.printRoutes({ commonPrefix: false }).split("\n").flatMap((l) => {
    const m = /(\/\S*) \(([^)]+)\)/.exec(l);
    return m ? m[2]!.split(", ").filter((x) => x !== "HEAD").map((x) => `${x} ${m[1]!.replace(/:(\w+)/g, "{$1}")}`) : [];
  });
  const ops = Object.entries(paths).flatMap(([p, o]) => Object.keys(o).map((m) => `${m.toUpperCase()} ${p}`));
  expect(new Set(routes)).toEqual(new Set(ops));
  await app.close();
});

describe.skipIf(!adminUrl)("contract (real HTTP, Postgres)", () => {
  let db: Awaited<ReturnType<typeof freshDatabase>>;
  let pool: pg.Pool;
  let app: ReturnType<typeof buildApp>;
  let base: string;
  let down = false; // flips /readyz to 503
  const as = async (sub: string) => apiClient(base, { headers: { authorization: `Bearer ${await iss.sign({ sub })}` } });

  beforeAll(async () => {
    db = await freshDatabase();
    await migrate(db.url, "up");
    pool = new pg.Pool({ connectionString: db.url });
    const src = (await pool.query("INSERT INTO job_sources (ats, company_slug, company_name) VALUES ('greenhouse', 'acme', 'Acme') RETURNING id")).rows[0].id;
    for (const [i, day] of [["1", "2026-11-01"], ["2", null]] as const)
      await pool.query(`INSERT INTO jobs (source_id, external_id, url, apply_url, title, company, location, remote, description, posted_at, dedupe_hash)
        VALUES ($1, $2, $3, $3, 'Engineer', 'Acme', 'Remote', true, 'Build things', $4, $2)`, [src, i, `https://boards.example/${i}`, day]);
    const sync = dbSync(pool);
    const ready = dbReady(pool);
    app = buildApp({
      ready: async () => !down && ready(),
      auth: { issuer, audience, jwks: iss.jwks }, users: dbUsers(pool), jobs: dbJobs(pool), idempotency: dbIdempotency(pool),
      // A tiny api bucket so one user can be driven into a 429; the others keep the real rules.
      limits: dbLimits(pool, { ...DEFAULT_RULES, api: { capacity: 2, perSecond: 0.001 } }),
      // "contacts" reads fail, to exercise the 500 path.
      sync: { ...sync, get: async (u, k) => { if (k === "contacts") throw Object.assign(new Error("boom"), { code: "XX000" }); return sync.get(u, k); } },
    });
    base = await app.listen({ port: 0, host: "127.0.0.1" });
  });
  afterAll(async () => {
    await app.close(); await pool.end(); await db.drop();
  });

  test("health and me", async () => {
    await check("GET", "/healthz", (await apiClient(base).GET("/healthz")));
    await check("GET", "/readyz", (await apiClient(base).GET("/readyz")));
    down = true;
    await check("GET", "/readyz", (await apiClient(base).GET("/readyz")));
    down = false;
    const me = await (await as("alice")).GET("/v1/me");
    expect(me.data?.id).toMatch(/\S/);
    await check("GET", "/v1/me", me);
    await check("GET", "/v1/me", (await apiClient(base).GET("/v1/me"))); // no token: 401
    const limited = await as("limited");
    let r;
    do r = await limited.GET("/v1/me"); while (r.response.status === 200);
    await check("GET", "/v1/me", r); // 429 + Retry-After
  });

  test("sync round trip and every error", async () => {
    const c = await as("alice");
    const kind = { params: { path: { kind: "profile" as const } } };
    const body = { keyId: "k1", ciphertext: Buffer.from("opaque").toString("base64") };
    await check("GET", "/v1/sync/{kind}", (await c.GET("/v1/sync/{kind}", kind))); // 404
    const created = await c.PUT("/v1/sync/{kind}", { ...kind, headers: { "if-none-match": "*", "idempotency-key": "c-1" }, body });
    expect(created.data?.version).toBe(1);
    await check("PUT", "/v1/sync/{kind}", created);
    const replay = await c.PUT("/v1/sync/{kind}", { ...kind, headers: { "if-none-match": "*", "idempotency-key": "c-1" }, body });
    expect(replay.response.headers.get("idempotent-replayed")).toBe("true");
    await check("PUT", "/v1/sync/{kind}", replay);
    const got = await c.GET("/v1/sync/{kind}", kind);
    expect(got.data).toEqual({ version: 1, ...body });
    await check("GET", "/v1/sync/{kind}", got);
    await check("GET", "/v1/sync/{kind}", (await c.GET("/v1/sync/{kind}", { params: { path: { kind: "nope" as "profile" } } }))); // 400
    await check("GET", "/v1/sync/{kind}", (await c.GET("/v1/sync/{kind}", { params: { path: { kind: "contacts" } } }))); // 500

    const conflict = await c.PUT("/v1/sync/{kind}", { ...kind, headers: { "if-match": '"v9"' }, body });
    expect(conflict.error).toEqual({ error: "conflict", version: 1 });
    await check("PUT", "/v1/sync/{kind}", conflict);
    await check("PUT", "/v1/sync/{kind}", (await c.PUT("/v1/sync/{kind}", { ...kind, body }))); // 428
    await check("PUT", "/v1/sync/{kind}", (await c.PUT("/v1/sync/{kind}", { ...kind, headers: { "if-match": "v1" }, body }))); // 400
    await check("PUT", "/v1/sync/{kind}", (await c.PUT("/v1/sync/{kind}", {
      ...kind, headers: { "if-match": '"v1"', "idempotency-key": "c-1" }, body, // same key, different request
    }))); // 422
    const big = Buffer.alloc(MAX_CIPHERTEXT + 1).toString("base64");
    await check("PUT", "/v1/sync/{kind}", (await c.PUT("/v1/sync/{kind}", { ...kind, headers: { "if-match": '"v1"' }, body: { keyId: "k1", ciphertext: big } }))); // 413
    await check("PUT", "/v1/sync/{kind}", await fetch(`${base}/v1/sync/profile`, {
      method: "PUT", headers: { authorization: `Bearer ${await iss.sign({ sub: "alice" })}`, "content-type": "application/xml", "if-match": '"v1"' }, body: "x",
    })); // 415
  });

  test("jobs pages and bad filters", async () => {
    const c = await as("alice");
    const p1 = await c.GET("/v1/jobs", { params: { query: { limit: 1, remote: true } } });
    expect(p1.data?.items).toHaveLength(1);
    await check("GET", "/v1/jobs", p1);
    const p2 = await c.GET("/v1/jobs", { params: { query: { limit: 1, cursor: p1.data!.next! } } });
    expect(p2.data?.items[0]?.postedAt).toBeNull();
    await check("GET", "/v1/jobs", p2);
    await check("GET", "/v1/jobs", (await c.GET("/v1/jobs", { params: { query: { cursor: "bogus" } } }))); // 400
  });

  // Runs last (vitest keeps file order): every status the spec promises was produced by the real app at least once.
  test("every documented response was exercised", () => {
    const missing = all.filter((k) => !seen.has(k) && !/ (401|429|500)$/.test(k));
    // The shared 401/429/500 entries are exercised once each above; they are the same code path for every route.
    expect(missing).toEqual([]);
    for (const st of ["401", "429", "500"]) expect([...seen].some((k) => k.endsWith(` ${st}`)), st).toBe(true);
  });
});
