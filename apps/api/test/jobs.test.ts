import type { FastifyInstance } from "fastify";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { dbJobs } from "../src/jobs.js";
import { migrate } from "../src/db/migrate.js";
import { audience, fakeIssuer, issuer, memorySync, memoryUsers } from "./fakeIssuer.js";
import { adminUrl, freshDatabase } from "./testdb.js";

describe.skipIf(!adminUrl)("GET /v1/jobs", () => {
  let db: Awaited<ReturnType<typeof freshDatabase>>, pool: pg.Pool, app: FastifyInstance, token: string;
  beforeAll(async () => {
    db = await freshDatabase();
    await migrate(db.url, "up");
    pool = new pg.Pool({ connectionString: db.url });
    const iss = await fakeIssuer();
    token = await iss.sign();
    app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: memoryUsers(), sync: memorySync(), jobs: dbJobs(pool) });
    const src = async (ats: string, slug: string) => (await pool.query("INSERT INTO job_sources (ats, company_slug) VALUES ($1, $2) RETURNING id", [ats, slug])).rows[0].id;
    const gh = await src("greenhouse", "acme"), lv = await src("lever", "beta");
    const job = (source: number, n: number, title: string, location: string, remote: boolean, posted: string | null, desc = "") =>
      pool.query(`INSERT INTO jobs (source_id, external_id, url, title, company, location, remote, description, posted_at, dedupe_hash)
                  VALUES ($1, $2, $2, $3, $4, $5, $6, $7, $8, $2)`, [source, `https://x/${n}`, title, source === gh ? "Acme" : "Beta", location, remote, desc, posted]);
    await job(gh, 1, "Data Engineer", "New York", false, "2026-11-10", "Spark and Kafka pipelines");
    await job(gh, 2, "Product Designer", "Remote (US)", true, "2026-11-09");
    await job(lv, 3, "Senior Data Scientist", "London 100%_off", false, "2026-11-10");
    await job(lv, 4, "Backend Engineer", "Berlin", false, null);
    await job(lv, 5, "Backend Engineer", "Berlin", false, null);
    await job(gh, 6, "Data Engineer (copy)", "New York", false, "2026-11-11");
    await pool.query("UPDATE jobs SET duplicate_of = (SELECT id FROM jobs WHERE url = 'https://x/1') WHERE url = 'https://x/6'");
  });
  afterAll(async () => { await app?.close(); await pool?.end(); await db?.drop(); });

  const get = (qs = "", auth = true) => app.inject({ method: "GET", url: `/v1/jobs${qs}`, headers: auth ? { authorization: `Bearer ${token}` } : {} });
  const urls = async (qs: string) => { const r = await get(qs); expect(r.statusCode, r.body).toBe(200); return r.json().items.map((j: { url: string }) => j.url.slice(10)); };

  test("needs a token", async () => {
    expect((await get("", false)).statusCode).toBe(401);
  });

  test("newest first, nulls last, duplicates hidden, item shape", async () => {
    const r = await get();
    expect(r.json().items.map((j: { url: string }) => j.url.slice(10))).toEqual(["3", "1", "2", "5", "4"]);
    expect(r.json().items[1]).toEqual({ id: expect.any(String), ats: "greenhouse", title: "Data Engineer", company: "Acme", location: "New York", remote: false,
      url: "https://x/1", applyUrl: "", description: "Spark and Kafka pipelines", postedAt: "2026-11-10" });
    expect(r.json().next).toBeNull();
  });

  test("each filter", async () => {
    expect(await urls("?q=data")).toEqual(["3", "1"]);
    expect(await urls("?q=kafka")).toEqual(["1"]); // description is searched too
    expect(await urls("?q=engineer%20-backend")).toEqual(["1"]);
    expect(await urls("?location=new%20york")).toEqual(["1"]);
    expect(await urls("?location=100%25_")).toEqual(["3"]); // % and _ are literal
    expect(await urls("?location=0%25")).toEqual(["3"]);
    expect(await urls("?location=%25")).toEqual(["3"]);
    expect(await urls("?remote=true")).toEqual(["2"]);
    expect(await urls("?ats=lever")).toEqual(["3", "5", "4"]);
    expect(await urls("?posted_since=2026-11-10")).toEqual(["3", "1"]);
    expect(await urls("?ats=greenhouse&q=designer&remote=true")).toEqual(["2"]);
  });

  test("the cursor walks every row once, across equal dates and nulls", async () => {
    const seen: string[] = [];
    let cursor: string | null = "";
    while (cursor !== null) {
      const r = await get(`?limit=2${cursor ? `&cursor=${cursor}` : ""}`);
      expect(r.statusCode).toBe(200);
      seen.push(...r.json().items.map((j: { url: string }) => j.url.slice(10)));
      cursor = r.json().next;
    }
    expect(seen).toEqual(["3", "1", "2", "5", "4"]);
  });

  test("bad input is a 400, never a 500", async () => {
    const bad = (x: unknown) => Buffer.from(JSON.stringify(x)).toString("base64url");
    for (const qs of ["?cursor=nope", `?cursor=${bad(["2026-11-10", "1"])}`, `?cursor=${bad([null, "0"])}`, `?cursor=${bad([null, 1])}`, `?cursor=${bad(["x", "1", 3])}`,
      `?cursor=${bad([null, "9999999999999999999"])}`, `?cursor=${bad(["2026-13-40 99:00:00+00", "1"])}`, `?cursor=${bad(["2026-02-30 00:00:00+00", "1"])}`, "?posted_since=0000-01-01", "?limit=0", "?limit=101", "?ats=bamboo", "?posted_since=2026-02-31", "?posted_since=11/10/2026", "?remote=maybe", "?other=1", `?q=${"a".repeat(201)}`])
      expect((await get(qs)).statusCode, qs).toBe(400);
    expect((await get(`?cursor=${bad(["2026-11-10 00:00:00+00", "999"])}`)).statusCode).toBe(200);
    expect((await get("?q=%22%26%7C!(")).statusCode).toBe(200); // websearch syntax never errors
  });
});
