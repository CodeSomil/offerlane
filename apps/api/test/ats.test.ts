import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import * as ats from "../src/ats.js";

// The Swift fixtures are the shared fixtures; the golden file is written by AdapterGoldenTests.swift.
const dir = new URL("../../../Packages/OfferlaneCore/Tests/OfferlaneCoreTests/Fixtures/", import.meta.url);
const read = (p: string): unknown => JSON.parse(readFileSync(new URL(p, dir), "utf8"));
const fx = (name: string) => read(`ats/${name}.json`);

test("every parser matches the Swift golden output", () => {
  const site = "https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite";
  const api = ats.workdayAPI(site)!;
  const got = {
    greenhouse_scaleai: ats.greenhouse(fx("greenhouse_scaleai")),
    lever_spotify: ats.lever(fx("lever_spotify")),
    ashby_perplexity: ats.ashby(fx("ashby_perplexity")),
    workable_huggingface: ats.workable(fx("workable_huggingface")),
    smartrecruiters_bosch: ats.smartrecruiters(fx("smartrecruiters_bosch"), "BoschGroup"),
    workday_nvidia: ats.workday(fx("workday_nvidia"), site, api, new Date("2026-10-31T00:00:00Z")),
    workdayAPI: api,
    synthetic_edge: (() => {
      const e = fx("synthetic_edge") as Record<string, unknown>;
      return {
        greenhouse: ats.greenhouse(e.greenhouse), lever: ats.lever(e.lever), ashby: ats.ashby(e.ashby),
        smartrecruiters: ats.smartrecruiters(e.smartrecruiters, "Edge"),
        workday: ats.workday(e.workday, site, api, new Date("2026-10-31T00:00:00Z")),
        strip: (e.strip as string[]).map(ats.stripHTML),
      };
    })(),
    detailText: {
      smartrecruiters_bosch_detail: ats.detailText(fx("smartrecruiters_bosch_detail")),
      workday_nvidia_detail: ats.detailText(fx("workday_nvidia_detail")),
    },
  };
  expect(got).toEqual(read("ats_expected.json"));
});

test("stripHTML is linear on unclosed tags and equals the regex it replaced", () => {
  const t = performance.now();
  expect(ats.stripHTML("<".repeat(200_000) + "a")).toHaveLength(200_001);
  expect(performance.now() - t).toBeLessThan(500);
  const regex = (x: string) => x.replace(/<[^>]+>/g, " ");
  for (const x of ["<<<a>", "<>x<", "a < b > c", "<<>>", "<a><b", "><>a<b>c<", "", "plain", "<\u0301x>y"]) expect(ats.stripTags(x), x).toBe(regex(x));
});

test("toDate and Workday's relative dates", () => {
  expect(ats.toDate(1792792277)).toBe("2026-10-23");
  expect(ats.toDate(1792792277203)).toBe("2026-10-23");
  expect(ats.toDate(1e300)).toBeNull();
  expect(ats.toDate("")).toBeNull();
  const now = new Date("2026-10-31T00:00:00Z"), api = "https://x.wd1.myworkdayjobs.com/wday/cxs/x/S";
  const posted = ["Posted 30+ Days Ago", "Posted Today", "Posted 3 days ago", "soon"].map((postedOn, i) =>
    ats.workday({ jobPostings: [{ externalPath: `/job/${i}`, postedOn }] }, "https://x.wd1.myworkdayjobs.com/S", api, now)[0]!.posted);
  expect(posted).toEqual(["2026-10-01", "2026-10-31", "2026-10-28", null]);
  expect(ats.workdayAPI("not a url")).toBeNull();
  expect(ats.workdayAPI("https://x.wd1.myworkdayjobs.com/en-US")).toBeNull();
});

type Call = { url: string; init: RequestInit };
const stub = (routes: Record<string, unknown>, calls: Call[] = []): ats.Fetch => async (url, init) => {
  calls.push({ url, init });
  const hit = Object.entries(routes).find(([k]) => url.includes(k));
  return hit ? new Response(JSON.stringify(hit[1]), { status: 200 }) : new Response("nope", { status: 404 });
};

test("list() calls each board's endpoint and returns null when it isn't there", async () => {
  const calls: Call[] = [];
  const f = stub({
    "boards-api.greenhouse.io/v1/boards/scaleai/jobs?content=true": fx("greenhouse_scaleai"),
    "api.lever.co/v0/postings/spotify?mode=json": fx("lever_spotify"),
    "api.ashbyhq.com/posting-api/job-board/perplexity?includeCompensation=true": fx("ashby_perplexity"),
    "apply.workable.com/api/v1/widget/accounts/huggingface?details=true": fx("workable_huggingface"),
    "api.smartrecruiters.com/v1/companies/BoschGroup/postings?limit=100": fx("smartrecruiters_bosch"),
    "api.smartrecruiters.com/v1/companies/empty/postings": { content: [] },
    "api.lever.co/v0/postings/object": { not: "an array" },
  }, calls);
  for (const [a, slug] of [["greenhouse", "scaleai"], ["lever", "spotify"], ["ashby", "perplexity"], ["workable", "huggingface"], ["smartrecruiters", "BoschGroup"]] as const)
    expect((await ats.list(a, slug, { fetch: f }))?.length, a).toBe(3);
  expect(await ats.list("greenhouse", "missing", { fetch: f })).toBeNull();
  expect(await ats.list("smartrecruiters", "empty", { fetch: f })).toBeNull();
  expect(await ats.list("lever", "object", { fetch: f })).toBeNull();
  expect(await ats.list("ashby", "x", { fetch: async () => { throw new Error("offline"); } })).toBeNull();
  expect(await ats.list("ashby", "x", { fetch: async () => new Response("<html>", { status: 200 }) })).toBeNull();
  expect(await ats.list("greenhouse", "../admin", { fetch: f })).toBeNull();
  expect(calls.at(-1)!.url).toContain("/boards/..%2Fadmin/jobs");
  expect((calls[0]!.init.headers as Record<string, string>)["User-Agent"]).toMatch(/^Mozilla/);
});

test("list() posts each Workday query and dedupes by URL", async () => {
  const calls: Call[] = [];
  const site = "https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite";
  const f = stub({ "/wday/cxs/nvidia/NVIDIAExternalCareerSite/jobs": fx("workday_nvidia") }, calls);
  expect(await ats.list("workday", site, { fetch: f, queries: ["data", "ml"] })).toHaveLength(3);
  expect(calls.map((c) => [c.init.method, JSON.parse(c.init.body as string).searchText])).toEqual([["POST", "data"], ["POST", "ml"]]);
  expect(await ats.list("workday", "https://nvidia.wd5.myworkdayjobs.com/Other", { fetch: f })).toBeNull();
  expect(await ats.list("workday", "nope", { fetch: f })).toBeNull();
  // Server-side host allowlist: no POSTs to internal hosts, and redirects are refused.
  const n = calls.length;
  expect(await ats.list("workday", "https://internal.svc.cluster.local/x", { fetch: f })).toBeNull();
  expect(await ats.list("workday", "http://169.254.169.254/latest", { fetch: f })).toBeNull();
  expect(calls).toHaveLength(n);
  expect(calls.every((c) => c.init.redirect === "error")).toBe(true);
});

test("Workable and Workday are off in the crawl until the human decides", () => {
  expect(ats.CRAWL_ENABLED).not.toContain("workable");
  expect(ats.CRAWL_ENABLED).not.toContain("workday");
  expect(ats.CRAWL_ENABLED).toHaveLength(4);
});

test("fetching paces each host and backs off on 429 like HTTP.swift", async () => {
  const at: number[] = [];
  const f: ats.Fetch = async () => { at.push(Date.now()); return new Response("[]", { status: 200 }); };
  const pace = ats.pacer(60, 0);
  await Promise.all([ats.list("lever", "a", { fetch: f, pace }), ats.list("lever", "b", { fetch: f, pace }), ats.list("lever", "c", { fetch: f, pace })]);
  at.sort((a, b) => a - b);
  expect(at[1]! - at[0]!).toBeGreaterThanOrEqual(55);
  expect(at[2]! - at[1]!).toBeGreaterThanOrEqual(55);

  // 429 twice (Retry-After honoured), then 200; a third 429 in a row gives up.
  let n = 0;
  const limited: ats.Fetch = async () => (++n <= 2 ? new Response("", { status: 429, headers: { "Retry-After": "1" } }) : new Response("[]", { status: 200 }));
  expect(await ats.list("lever", "x", { fetch: limited, pace: ats.pacer(0, 0) })).toEqual([]);
  expect(n).toBe(3);
  n = 0;
  const always429: ats.Fetch = async () => { n++; return new Response("", { status: 429 }); };
  expect(await ats.list("lever", "x", { fetch: always429, pace: ats.pacer(0, 0) })).toBeNull();
  expect(n).toBe(3);

  // One retry on a network error.
  n = 0;
  const flaky: ats.Fetch = async () => { if (++n === 1) throw new Error("reset"); return new Response("[]", { status: 200 }); };
  expect(await ats.list("lever", "x", { fetch: flaky, pace: ats.pacer(0, 0) })).toEqual([]);
  n = 0;
  const down: ats.Fetch = async () => { n++; throw new Error("down"); };
  expect(await ats.list("lever", "x", { fetch: down, pace: ats.pacer(0, 0) })).toBeNull();
  expect(n).toBe(2);
});

test("a board over MAX_BODY is refused, whether or not it declares its length", async () => {
  const pace = ats.pacer(0, 0);
  const big = "[" + " ".repeat(ats.MAX_BODY) + "]";
  expect(await ats.list("lever", "x", { fetch: async () => new Response(big, { status: 200 }), pace })).toBeNull();
  const stream = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(big)); c.close(); } });
  expect(await ats.list("lever", "x", { fetch: async () => new Response(stream, { status: 200 }), pace })).toBeNull();
  expect(await ats.list("lever", "x", { fetch: async () => new Response("[]", { status: 200, headers: { "Content-Length": String(ats.MAX_BODY + 1) } }), pace })).toBeNull();
});

test("board() sends cache validators and reports 304 as not_modified", async () => {
  const calls: Call[] = [];
  const pace = ats.pacer(0, 0);
  const f: ats.Fetch = async (url, init) => {
    calls.push({ url, init });
    const h = init.headers as Record<string, string>;
    return h["If-None-Match"] === '"v1"' ? new Response(null, { status: 304 }) : new Response("[]", { status: 200, headers: { ETag: '"v1"', "Last-Modified": "Wed, 11 Nov 2026 10:00:00 GMT" } });
  };
  const first = await ats.board("lever", "x", { fetch: f, pace });
  expect(first).toEqual({ postings: [], etag: '"v1"', lastModified: "Wed, 11 Nov 2026 10:00:00 GMT", complete: true });
  expect(await ats.board("lever", "x", { fetch: f, pace, validators: { etag: '"v1"', lastModified: "Wed, 11 Nov 2026 10:00:00 GMT" } })).toBe("not_modified");
  expect((calls[1]!.init.headers as Record<string, string>)["If-Modified-Since"]).toBe("Wed, 11 Nov 2026 10:00:00 GMT");
  // A 304 we didn't ask for is not a board.
  expect(await ats.board("lever", "x", { fetch: async () => new Response(null, { status: 304 }), pace })).toBeNull();
});

test("SmartRecruiters pages to the end, caps at SR_MAX, and a missing page fails the board", async () => {
  const pace = ats.pacer(0, 0);
  const page = (off: number, n: number, total: number) => ({ offset: off, limit: 100, totalFound: total,
    content: Array.from({ length: n }, (_, i) => ({ id: String(off + i), name: `Role ${off + i}`, releasedDate: "2026-11-01T00:00:00Z", location: {} })) });
  const sr = (total: number, missing = -1, calls: string[] = []): ats.Fetch => async (url) => {
    calls.push(url);
    const off = Number(new URL(url).searchParams.get("offset"));
    if (off === missing) return new Response("", { status: 500 });
    return new Response(JSON.stringify(page(off, Math.max(0, Math.min(100, total - off)), total)), { status: 200 });
  };
  const calls: string[] = [];
  const b = await ats.board("smartrecruiters", "Co", { fetch: sr(250, -1, calls), pace });
  expect(b !== null && b !== "not_modified" && [b.postings.length, b.complete]).toEqual([250, true]);
  expect(calls.map((u) => new URL(u).searchParams.get("offset"))).toEqual(["0", "100", "200"]);
  const exact = await ats.board("smartrecruiters", "Co", { fetch: sr(200), pace });
  expect(exact !== null && exact !== "not_modified" && [exact.postings.length, exact.complete]).toEqual([200, true]);
  const big = await ats.board("smartrecruiters", "Co", { fetch: sr(5018), pace });
  expect(big !== null && big !== "not_modified" && [big.postings.length, big.complete]).toEqual([ats.SR_MAX, false]);
  expect(await ats.board("smartrecruiters", "Co", { fetch: sr(250, 100), pace })).toBeNull();
  // No totalFound: keep paging until a short page.
  const noTotal: ats.Fetch = async (url) => { const off = Number(new URL(url).searchParams.get("offset")); const p = page(off, off < 200 ? 100 : 5, 0) as Record<string, unknown>; delete p.totalFound; return new Response(JSON.stringify(p), { status: 200 }); };
  const nt = await ats.board("smartrecruiters", "Co", { fetch: noTotal, pace });
  expect(nt !== null && nt !== "not_modified" && [nt.postings.length, nt.complete]).toEqual([205, true]);
});
