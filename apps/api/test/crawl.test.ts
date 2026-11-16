import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import * as ats from "../src/ats.js";
import { crawlDue, crawlSource, dedupeHash, embed, NEAR, normalize, validDay, webURL, type Source } from "../src/crawl.js";
import { migrate } from "../src/db/migrate.js";
import { adminUrl, freshDatabase } from "./testdb.js";

const pace = ats.pacer(0, 0);
const cosine = (a: number[], b: number[]) => 1 - a.reduce((s, x, i) => s + x * b[i]!, 0);

test("normalize, dedupeHash and embed", () => {
  expect(normalize("Sr. Engineer – Zürich (Remote)")).toBe("sr engineer zurich remote");
  expect(dedupeHash("Data Engineer", "Acme", "NYC")).toBe(dedupeHash(" data  engineer!", "ACME", "nyc"));
  expect(dedupeHash("Data Engineer", "Acme", "NYC")).not.toBe(dedupeHash("Data Engineer", "Acme", "SF"));
  const a = embed("Senior Data Engineer", "New York");
  expect(Math.hypot(...a)).toBeCloseTo(1);
  expect(cosine(a, embed("Senior Data Engineer", "New York, NY"))).toBeLessThan(NEAR);
  expect(cosine(a, embed("Product Designer", "London"))).toBeGreaterThan(0.5);
  expect(cosine(a, embed("Senior Data Engineer II", "New York"))).toBeGreaterThan(NEAR);
  expect(embed("", "")).toEqual(new Array(256).fill(0));
  expect(["2026-11-10", "2026-02-30", "Jun 5, 202", "0000-00-00", "1969-12-31", null].map(validDay)).toEqual(["2026-11-10", null, null, null, null, null]);
  expect(["https://a/1", "http://a", "javascript:alert(1)", "data:text/html,x", "/rel", ""].map(webURL)).toEqual(["https://a/1", "http://a", null, null, null, null]);
});

type Board = { title: string; location?: string; url: string }[];
// A Lever-shaped board server: slug → postings, with an ETag per slug.
function lever(boards: Record<string, Board>, calls: string[] = []): ats.Fetch {
  return async (url, init) => {
    calls.push(url);
    const slug = decodeURIComponent(new URL(url).pathname.split("/").pop()!);
    const b = boards[slug];
    if (!b) return new Response("", { status: 404 });
    const etag = `"${JSON.stringify(b).length}"`;
    if ((init.headers as Record<string, string>)["If-None-Match"] === etag) return new Response(null, { status: 304 });
    const body = b.map((p, i) => ({ id: String(i), text: p.title, hostedUrl: p.url, applyUrl: `${p.url}/apply`, categories: { location: p.location ?? "" }, createdAt: 1762819200000 }));
    return new Response(JSON.stringify(body), { status: 200, headers: { ETag: etag } });
  };
}

describe.skipIf(!adminUrl)("crawl", () => {
  let db: Awaited<ReturnType<typeof freshDatabase>>, pool: pg.Pool;
  beforeAll(async () => {
    db = await freshDatabase();
    await migrate(db.url, "up");
    pool = new pg.Pool({ connectionString: db.url });
  });
  afterAll(async () => { await pool?.end(); await db?.drop(); });

  const source = async (a: ats.Ats, slug: string, name: string | null = null): Promise<Source> =>
    (await pool.query<Source>("INSERT INTO job_sources (ats, company_slug, company_name) VALUES ($1, $2, $3) RETURNING id, ats, company_slug, company_name, etag, last_modified", [a, slug, name])).rows[0]!;
  const reload = async (id: number) => (await pool.query<Source>("SELECT id, ats, company_slug, company_name, etag, last_modified FROM job_sources WHERE id = $1", [id])).rows[0]!;
  const jobs = async (id: number) =>
    (await pool.query("SELECT url, apply_url, title, company, location, remote, posted_at, duplicate_of FROM jobs WHERE source_id = $1 ORDER BY id", [id])).rows;
  const runs = async (id: number) => (await pool.query("SELECT status, found, error FROM crawl_runs WHERE source_id = $1 ORDER BY id", [id])).rows;

  test("insert, re-crawl without duplicates, 304 skip, closed postings removed", async () => {
    const boards: Record<string, Board> = { acme: [
      { title: "Data Engineer", location: "Remote - US", url: "https://jobs.lever.co/acme/1" },
      { title: "Designer", location: "London", url: "https://jobs.lever.co/acme/2" },
      { title: "Designer", location: "London", url: "https://jobs.lever.co/acme/2" }, // listed twice
    ] };
    const calls: string[] = [];
    const f = lever(boards, calls);
    let s = await source("lever", "acme", "Acme Inc");
    expect(await crawlSource(pool, s, { fetch: f, pace })).toEqual({ status: "ok", found: 2 });
    const first = await jobs(s.id);
    expect(first.map((j) => [j.title, j.company, j.remote, j.apply_url])).toEqual([
      ["Data Engineer", "Acme Inc", true, "https://jobs.lever.co/acme/1/apply"], ["Designer", "Acme Inc", false, "https://jobs.lever.co/acme/2/apply"]]);
    expect(first[0].posted_at).toEqual(new Date("2025-11-11T00:00:00Z"));

    s = await reload(s.id);
    expect(s.etag).toMatch(/^"\d+"$/);
    expect(await crawlSource(pool, s, { fetch: f, pace })).toEqual({ status: "ok", found: null }); // 304
    expect(await jobs(s.id)).toHaveLength(2);

    boards.acme = [{ title: "Data Engineer II", location: "Remote - US", url: "https://jobs.lever.co/acme/1" }];
    expect(await crawlSource(pool, s, { fetch: f, pace })).toEqual({ status: "ok", found: 1 });
    expect((await jobs(s.id)).map((j) => j.title)).toEqual(["Data Engineer II"]);
    expect((await runs(s.id)).map((r) => r.status)).toEqual(["ok", "ok", "ok"]);
  });

  test("a board that is down keeps its jobs; Workable/Workday sources are refused without a request", async () => {
    const calls: string[] = [];
    const s = await source("lever", "flaky", "Flaky");
    await crawlSource(pool, s, { fetch: lever({ flaky: [{ title: "SRE", url: "https://jobs.lever.co/flaky/1" }] }), pace });
    expect(await crawlSource(pool, s, { fetch: lever({}, calls), pace })).toEqual({ status: "failed", found: null });
    expect(await jobs(s.id)).toHaveLength(1);
    expect((await runs(s.id)).at(-1)).toEqual({ status: "failed", found: null, error: "unavailable" });

    const n = calls.length;
    for (const a of ["workable", "workday"] as const) {
      const w = await source(a, `https://x.wd1.myworkdayjobs.com/${a}`);
      expect(await crawlSource(pool, w, { fetch: lever({}, calls), pace })).toEqual({ status: "refused", found: null });
      expect(await runs(w.id)).toEqual([{ status: "refused", found: null, error: "ats not enabled" }]);
    }
    expect(calls).toHaveLength(n);
  });

  test("exact and near duplicates across sources are marked; distinct roles are not", async () => {
    const a = await source("lever", "dupe-a", "Dupe Co");
    const b = await source("lever", "dupe-b", "Dupe Co");
    const other = await source("lever", "dupe-c", "Other Co");
    const f = lever({
      "dupe-a": [{ title: "Backend Engineer", location: "Berlin", url: "https://a/1" }, { title: "Senior Platform Engineer, Payments", location: "Berlin", url: "https://a/2" }],
      "dupe-b": [
        { title: "backend engineer", location: "BERLIN", url: "https://b/1" }, // exact (normalised)
        { title: "Senior Platform Engineer - Payments", location: "Berlin, Germany", url: "https://b/2" }, // near: hash differs, vector close
        { title: "Recruiter", location: "Berlin", url: "https://b/3" }, // distinct
        { title: "Backend Engineer II", location: "Berlin", url: "https://b/4" }, // another level is another role
      ],
      "dupe-c": [{ title: "Backend Engineer", location: "Berlin", url: "https://c/1" }], // same title, other company
    });
    for (const s of [a, b, other]) await crawlSource(pool, s, { fetch: f, pace });
    const [a1, a2] = (await pool.query("SELECT id FROM jobs WHERE source_id = $1 ORDER BY id", [a.id])).rows.map((r) => String(r.id));
    expect((await jobs(b.id)).map((j) => j.duplicate_of)).toEqual([a1, a2, null, null]);
    expect((await jobs(other.id)).map((j) => j.duplicate_of)).toEqual([null]);
    // When the original closes, its copy shows again on the next crawl of the copy's source.
    await crawlSource(pool, await reload(a.id), { fetch: lever({ "dupe-a": [{ title: "Unrelated", url: "https://a/9" }] }), pace });
    expect((await jobs(b.id)).map((j) => j.duplicate_of)).toEqual([null, null, null, null]);
  });

  test("bad dates and non-web URLs from a board don't fail it", async () => {
    const s = await source("greenhouse", "messy", "Messy");
    const f: ats.Fetch = async () => new Response(JSON.stringify({ jobs: [
      { id: 1, title: "A", absolute_url: "https://x/a", updated_at: "2026-02-30T00:00:00Z", location: { name: "" } },
      { id: 2, title: "B", absolute_url: "javascript:alert(1)", updated_at: "2026-11-01", location: { name: "" } },
    ] }), { status: 200 });
    expect(await crawlSource(pool, s, { fetch: f, pace })).toEqual({ status: "ok", found: 1 });
    expect((await jobs(s.id)).map((j) => [j.url, j.posted_at])).toEqual([["https://x/a", null]]);
  });

  test("an incomplete board (SmartRecruiters past SR_MAX) closes nothing", async () => {
    const s = await source("smartrecruiters", "huge", "Huge");
    const board = (ids: number[]) => ({ totalFound: 9999, content: ids.map((i) => ({ id: String(i), name: `R${i}`, location: {} })) });
    let ids = Array.from({ length: 100 }, (_, i) => i);
    const f: ats.Fetch = async (url) => {
      const off = Number(new URL(url).searchParams.get("offset"));
      return new Response(JSON.stringify(board(ids.slice(0, 100).map((i) => i + off))), { status: 200 });
    };
    expect(await crawlSource(pool, s, { fetch: f, pace })).toEqual({ status: "ok", found: ats.SR_MAX });
    ids = ids.map((i) => i + 1_000_000);
    await crawlSource(pool, s, { fetch: f, pace });
    expect(await jobs(s.id)).toHaveLength(2 * ats.SR_MAX);
  });

  test("two crawlers running at once claim each due source once", async () => {
    await pool.query("UPDATE job_sources SET last_crawled_at = now()");
    const ids = [await source("lever", "race1"), await source("lever", "race2"), await source("lever", "race3")].map((s) => s.id);
    const f: ats.Fetch = async () => { await new Promise((r) => setTimeout(r, 20)); return new Response("[]", { status: 200 }); };
    const [x, y] = await Promise.all([crawlDue(pool, { fetch: f, pace }), crawlDue(pool, { fetch: f, pace })]);
    expect(x.length + y.length).toBe(3);
    const n = await pool.query("SELECT source_id, count(*)::int AS n FROM crawl_runs WHERE source_id = ANY($1) GROUP BY 1", [ids]);
    expect(n.rows.map((r) => r.n)).toEqual([1, 1, 1]);
    const stopped = new AbortController(); stopped.abort();
    await pool.query("UPDATE job_sources SET last_crawled_at = NULL WHERE id = ANY($1)", [ids]);
    expect(await crawlDue(pool, { fetch: f, pace, signal: stopped.signal })).toEqual([]);
  });

  test("crawlDue takes only enabled, due, crawlable sources", async () => {
    await pool.query("UPDATE job_sources SET last_crawled_at = now()");
    const due = await source("greenhouse", "due");
    const off = await source("lever", "off");
    await pool.query("UPDATE job_sources SET enabled = false WHERE id = $1", [off.id]);
    await source("workday", "https://x.wd1.myworkdayjobs.com/due");
    const calls: string[] = [];
    const f: ats.Fetch = async (url) => { calls.push(url); return new Response(JSON.stringify({ jobs: [] }), { status: 200 }); };
    expect(await crawlDue(pool, { fetch: f, pace })).toEqual([{ status: "ok", found: 0 }]);
    expect(calls).toEqual(["https://boards-api.greenhouse.io/v1/boards/due/jobs?content=true"]);
    expect(await crawlDue(pool, { fetch: f, pace })).toEqual([]);
    expect((await runs(due.id))).toHaveLength(1);
  });
});

describe.skipIf(!adminUrl)("worker", () => {
  test("starts pg-boss, schedules the 15-minute crawl tick once, and stops", async () => {
    const { startWorker, QUEUE } = await import("../src/worker.js");
    const db = await freshDatabase();
    await migrate(db.url, "up");
    const pool = new pg.Pool({ connectionString: db.url });
    try {
      await (await startWorker(db.url, pool))();
      await (await startWorker(db.url, pool))(); // a restart doesn't add a second schedule
      const s = await pool.query("SELECT name, cron FROM pgboss.schedule");
      expect(s.rows).toEqual([{ name: QUEUE, cron: "*/15 * * * *" }]);
      const q = await pool.query("SELECT policy, retry_limit, expire_seconds, heartbeat_seconds FROM pgboss.queue WHERE name = $1", [QUEUE]);
      expect(q.rows).toEqual([{ policy: "exclusive", retry_limit: 0, expire_seconds: 21600, heartbeat_seconds: 60 }]);
    } finally {
      await pool.end();
      await db.drop();
    }
  }, 30_000);
});
