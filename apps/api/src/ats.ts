// The six public ATS job-board APIs, ported line for line from OfferlaneCore Discovery/Adapters.swift.
// Both ports must give the same output for the recorded fixtures; the test checks this against
// Packages/OfferlaneCore/Tests/OfferlaneCoreTests/Fixtures/ats_expected.json.
// SHORTCUT: this lives in apps/api; move it to libs/ when the P2.6 worker becomes its own package.
import { ATS } from "@offerlane/contract";
export { ATS };

export type Posting = {
  title: string;
  location: string;
  url: string;
  applyUrl: string;
  posted: string | null;
  description: string;
  /** A follow-up URL with the full description (SmartRecruiters, Workday). */
  detail: string | null;
};

export type Ats = (typeof ATS)[number];
/** Workable's and Workday's terms are still unclear (P0 note 5), so the crawl leaves them out until the human decides. */
export const CRAWL_ENABLED: readonly Ats[] = ["greenhouse", "lever", "ashby", "smartrecruiters"];

type J = unknown;
const get = (v: J, k: string): J => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, J>)[k] : undefined);
const arr = (v: J): J[] => (Array.isArray(v) ? v : []);
/** Swift `JSONValue.string`: numbers become strings too (non-integers and |n| > 2^53 can print differently from Swift's `String(Double)`). */
const s = (v: J): string => (typeof v === "string" ? v : typeof v === "number" ? String(v) : "");
/** Swift `JSONValue.double`: numbers, or strings that parse as a decimal number. */
const num = (v: J): number | null =>
  typeof v === "number" ? v : typeof v === "string" && /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(v) ? Number(v) : null;

// MARK: text and dates (Util/Text.swift)

const scalar = (n: number, orig: string) => (n <= 0x10ffff && (n < 0xd800 || n > 0xdfff) ? String.fromCodePoint(n) : orig);
const NAMED: Record<string, string> = { "&lt;": "<", "&gt;": ">", "&quot;": '"', "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " " };

export function unescapeHTML(x: string): string {
  if (!x.includes("&")) return x;
  let out = x;
  for (const [k, v] of Object.entries(NAMED)) out = out.replaceAll(k, v);
  out = out.replace(/&#(\d+);/g, (m, d: string) => scalar(Number(d), m));
  out = out.replace(/&#x([0-9a-fA-F]+);/g, (m, h: string) => scalar(parseInt(h, 16), m));
  return out.replaceAll("&amp;", "&");
}
// ICU's \s and Foundation's .whitespacesAndNewlines are both Unicode White_Space (JS \s adds U+FEFF and misses U+0085).
const collapse = (x: string) => x.replace(/\p{White_Space}+/gu, " ").replace(/^ | $/g, "");
/** Same output as replacing `<[^>]+>` with " ", in linear time (that regex is quadratic on "<<<<…" with no ">"). Mirrors Text.stripTags. */
export function stripTags(x: string): string {
  let out = "", i = 0;
  while (i < x.length) {
    const lt = x.indexOf("<", i);
    if (lt < 0) return out + x.slice(i);
    const gt = x.indexOf(">", lt + 1);
    if (gt < 0) return out + x.slice(i); // no ">" later: nothing after can match
    if (gt === lt + 1) { out += x.slice(i, lt + 1); i = lt + 1; continue; } // "<>" isn't a tag
    out += x.slice(i, lt) + " ";
    i = gt + 1;
  }
  return out;
}
export const stripHTML = (x: J): string => collapse(stripTags(unescapeHTML(unescapeHTML(s(x)))));
/** Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs only, newlines stay. */
const trimSpaces = (x: string) => x.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, "");

const day = (d: Date): string | null => (Number.isNaN(d.getTime()) ? null : d.toISOString().slice(0, 10));
/** Epoch seconds or milliseconds, or any string starting with an ISO date. Days are UTC. */
export function toDate(v: J): string | null {
  if (typeof v === "number") return Number.isFinite(v) ? day(new Date((v > 1e11 ? v / 1000 : v) * 1000)) : null;
  return typeof v === "string" && v !== "" ? [...v].slice(0, 10).join("") : null;
}
export const daysAgo = (n: number, now: Date) => day(new Date(now.getTime() - n * 86_400_000));

// MARK: parsers (pure)

const remote = (v: J) => (v === true ? " / Remote" : "");
const cityCountry = (v: J) => [s(get(v, "city")), s(get(v, "country"))].filter((x) => x !== "").join(", ");

export const greenhouse = (j: J): Posting[] =>
  arr(get(j, "jobs")).map((x) => ({
    title: s(get(x, "title")), location: s(get(get(x, "location"), "name")), url: s(get(x, "absolute_url")), applyUrl: s(get(x, "absolute_url")),
    posted: toDate(s(get(x, "updated_at"))), description: stripHTML(get(x, "content")), detail: null,
  }));

export const lever = (j: J): Posting[] =>
  arr(j).map((x) => {
    const lists = arr(get(x, "lists")).map((l) => stripHTML(get(l, "content"))).join(" ");
    const created = num(get(x, "createdAt"));
    return {
      title: s(get(x, "text")), location: s(get(get(x, "categories"), "location")), url: s(get(x, "hostedUrl")), applyUrl: s(get(x, "applyUrl")),
      posted: created === null ? null : toDate(created), description: trimSpaces(s(get(x, "descriptionPlain")) + " " + lists), detail: null,
    };
  });

export const ashby = (j: J): Posting[] =>
  arr(get(j, "jobs")).filter((x) => get(x, "isListed") !== false).map((x) => ({
    title: s(get(x, "title")), location: s(get(x, "location")) + remote(get(x, "isRemote")), url: s(get(x, "jobUrl")), applyUrl: s(get(x, "applyUrl")),
    posted: toDate(s(get(x, "publishedAt"))),
    description: s(get(x, "descriptionPlain")) === "" ? stripHTML(get(x, "descriptionHtml")) : s(get(x, "descriptionPlain")), detail: null,
  }));

export const workable = (j: J): Posting[] =>
  arr(get(j, "jobs")).map((x) => {
    const url = s(get(x, "url")) === "" ? s(get(x, "shortlink")) : s(get(x, "url"));
    return {
      title: s(get(x, "title")), location: cityCountry(x) + remote(get(x, "telecommuting")), url,
      applyUrl: s(get(x, "application_url")) === "" ? url : s(get(x, "application_url")),
      posted: toDate(s(get(x, "published_on"))), description: stripHTML(get(x, "description")), detail: null,
    };
  });

export const smartrecruiters = (j: J, slug: string): Posting[] =>
  arr(get(j, "content")).map((x) => {
    const l = get(x, "location"), id = s(get(x, "id")), u = `https://jobs.smartrecruiters.com/${slug}/${id}`;
    return {
      title: s(get(x, "name")), location: cityCountry(l) + remote(get(l, "remote")), url: u, applyUrl: u,
      posted: toDate(s(get(x, "releasedDate"))), description: "", detail: `https://api.smartrecruiters.com/v1/companies/${slug}/postings/${id}`,
    };
  });

function workdaySite(siteURL: string): { host: string; site: string } | null {
  let u: URL;
  try { u = new URL(siteURL); } catch { return null; }
  const site = u.pathname.split("/").filter((x) => x !== "").find((x) => !/^[a-z]{2}-[A-Z]{2}$/.test(x));
  return u.hostname && site ? { host: u.hostname, site } : null;
}
/** https://<tenant>.wdN.myworkdayjobs.com/<site> → https://<tenant>.wdN.myworkdayjobs.com/wday/cxs/<tenant>/<site> */
export function workdayAPI(siteURL: string): string | null {
  const w = workdaySite(siteURL);
  return w ? `https://${w.host}/wday/cxs/${w.host.split(".")[0]}/${w.site}` : null;
}
export function workday(j: J, siteURL: string, api: string, now = new Date()): Posting[] {
  const w = workdaySite(siteURL);
  if (!w) return [];
  return arr(get(j, "jobPostings")).flatMap((p) => {
    const path = s(get(p, "externalPath"));
    if (path === "") return [];
    const on = s(get(p, "postedOn")).toLowerCase();
    const d = /(\d+)\+? days/i.exec(on);
    const n = Number(d?.[1]); // Swift: Int(d) ?? 0
    const posted = d ? daysAgo(Number.isSafeInteger(n) ? n : 0, now) : on.includes("yesterday") ? daysAgo(1, now) : on.includes("today") ? daysAgo(0, now) : null;
    const url = `https://${w.host}/${w.site}${path}`;
    return [{ title: s(get(p, "title")), location: s(get(p, "locationsText")), url, applyUrl: url, posted, description: "", detail: api + path }];
  });
}

/** Full description from a detail response (SmartRecruiters `jobAd.sections`, Workday `jobPostingInfo`). */
export function detailText(j: J): string {
  const wd = get(get(j, "jobPostingInfo"), "jobDescription");
  if (typeof wd === "string") return stripHTML(wd);
  const sec = get(get(j, "jobAd"), "sections");
  return ["jobDescription", "qualifications"].map((k) => stripHTML(get(get(sec, k), "text"))).filter((x) => x !== "").join(" ");
}

// MARK: fetching

export type Fetch = (url: string, init: RequestInit) => Promise<Response>;
/** Server-side only (the Mac app takes any host): a crawl must not POST to internal hosts. */
const WORKDAY_HOST = /^[a-z0-9-]+\.wd\d+\.myworkdayjobs\.com$/;
const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

/** Per-host pacing, mirroring HTTP.swift: one request per host every minMs; back-off pushes the host's next slot.
 *  backoffScale scales the retry waits (tests pass 0). */
export function pacer(minMs = 350, backoffScale = 1) {
  const next = new Map<string, number>();
  const sleep = (ms: number) => (ms > 0 ? new Promise((r) => setTimeout(r, ms)) : Promise.resolve());
  return {
    async wait(host: string) {
      const now = Date.now(), slot = Math.max(now, next.get(host) ?? now);
      next.set(host, slot + minMs);
      await sleep(slot - now);
    },
    push(host: string, ms: number) { next.set(host, Date.now() + ms * backoffScale); },
    retryPause: () => sleep((1000 + Math.random() * 1000) * backoffScale),
  };
}
export type Pacer = ReturnType<typeof pacer>;
const shared = pacer();
/** A board bigger than this is refused rather than buffered (the largest real boards are a few MB). */
export const MAX_BODY = 20 * 1024 * 1024;

export type Validators = { etag?: string | null; lastModified?: string | null };
type Got = { j: J; etag: string | null; lastModified: string | null } | "not_modified" | null;
type Opts = { fetch?: Fetch; queries?: string[]; pace?: Pacer; validators?: Validators };

async function readCapped(r: Response): Promise<string | null> {
  if (Number(r.headers.get("content-length") ?? 0) > MAX_BODY) { await r.body?.cancel(); return null; }
  if (!r.body) return "";
  const reader = r.body.getReader(), parts: Uint8Array[] = [];
  let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.byteLength;
    if (n > MAX_BODY) { await reader.cancel(); return null; }
    parts.push(value);
  }
  return Buffer.concat(parts).toString("utf8");
}

// Like HTTP.swift: a 429 waits for Retry-After (else 5 s, 10 s; capped at 30 s) up to twice; a network error retries once.
async function json(o: Opts, url: string, body?: unknown, v?: Validators): Promise<Got> {
  const f = o.fetch ?? fetch, pace = o.pace ?? shared, host = new URL(url).host;
  const headers: Record<string, string> = { "User-Agent": USER_AGENT, Accept: "application/json, text/html;q=0.9" };
  if (v?.etag) headers["If-None-Match"] = v.etag;
  if (v?.lastModified) headers["If-Modified-Since"] = v.lastModified;
  const init: RequestInit = { headers, redirect: "error" };
  if (body !== undefined) { init.method = "POST"; init.body = JSON.stringify(body); headers["Content-Type"] = "application/json"; }
  for (let rateTries = 0, netTries = 0; ;) {
    await pace.wait(host);
    let r: Response;
    try {
      r = await f(url, { ...init, signal: AbortSignal.timeout(25_000) });
    } catch {
      if (netTries++ >= 1) return null;
      await pace.retryPause();
      continue;
    }
    if (r.status === 429 && rateTries < 2) {
      await r.body?.cancel();
      const after = Number(r.headers.get("retry-after") ?? NaN);
      pace.push(host, Math.min(Number.isFinite(after) && after >= 0 ? after : 5 * (rateTries + 1), 30) * 1000);
      rateTries++;
      continue;
    }
    if (r.status === 304 && v) { await r.body?.cancel(); return "not_modified"; }
    if (r.status !== 200) { await r.body?.cancel(); return null; }
    try {
      const text = await readCapped(r);
      return text === null ? null : { j: JSON.parse(text) as J, etag: r.headers.get("etag"), lastModified: r.headers.get("last-modified") };
    } catch {
      return null;
    }
  }
}

/** complete = every posting the board has is in postings (the crawl closes the rest only then). */
export type Board = { postings: Posting[]; etag: string | null; lastModified: string | null; complete: boolean };
export const SR_MAX = 2000;

/** One company's board, with its cache validators. "not_modified" when the validators matched (304);
 *  null when the board isn't there (non-200, bad JSON, too big, network error). Workday (POST) ignores validators.
 *  It doesn't check CRAWL_ENABLED; the crawl must. */
export async function board(ats: Ats, slug: string, opts: Opts = {}): Promise<Board | "not_modified" | null> {
  const e = encodeURIComponent(slug), v = opts.validators;
  const one = async (url: string, parse: (j: J) => Posting[] | null): Promise<Board | "not_modified" | null> => {
    const g = await json(opts, url, undefined, v);
    if (g === null || g === "not_modified") return g;
    const postings = parse(g.j);
    return postings === null ? null : { postings, etag: g.etag, lastModified: g.lastModified, complete: true };
  };
  switch (ats) {
    case "greenhouse": return one(`https://boards-api.greenhouse.io/v1/boards/${e}/jobs?content=true`, greenhouse);
    case "lever": return one(`https://api.lever.co/v0/postings/${e}?mode=json`, (j) => (Array.isArray(j) ? lever(j) : null));
    case "ashby": return one(`https://api.ashbyhq.com/posting-api/job-board/${e}?includeCompensation=true`, ashby);
    case "workable": return one(`https://apply.workable.com/api/v1/widget/accounts/${e}?details=true`, workable);
    case "smartrecruiters": {
      // Paged 100 at a time (no validators: a 304 on page one says nothing about the rest). Past SR_MAX the board is
      // marked incomplete, so the crawl keeps postings it didn't see instead of closing them.
      const out: Posting[] = [];
      for (let off = 0; ; off += 100) {
        if (off >= SR_MAX) return { postings: out, etag: null, lastModified: null, complete: false };
        const g = await json(opts, `https://api.smartrecruiters.com/v1/companies/${e}/postings?limit=100&offset=${off}`);
        if (g === null || g === "not_modified") return null; // a missing page: don't trust a partial board
        const page = arr(get(g.j, "content"));
        if (off === 0 && page.length === 0) return null;
        out.push(...smartrecruiters(g.j, e));
        if (page.length < 100 || off + 100 >= (num(get(g.j, "totalFound")) ?? Infinity)) return { postings: out, etag: null, lastModified: null, complete: true };
      }
    }
    case "workday": {
      const api = workdayAPI(slug);
      if (!api || !WORKDAY_HOST.test(new URL(api).hostname)) return null;
      const out = new Map<string, Posting>();
      for (const q of opts.queries ?? [""]) {
        const g = await json(opts, `${api}/jobs`, { appliedFacets: {}, limit: 20, offset: 0, searchText: q });
        if (g === null || g === "not_modified") return null;
        for (const p of workday(g.j, slug, api)) out.set(p.url, p);
      }
      // A search page of 20 per query is never the whole site.
      return { postings: [...out.values()], etag: null, lastModified: null, complete: false };
    }
  }
}

/** One company's postings, or null when the board isn't there. */
export async function list(ats: Ats, slug: string, opts: Omit<Opts, "validators"> = {}): Promise<Posting[] | null> {
  const b = await board(ats, slug, opts);
  return b === null || b === "not_modified" ? null : b.postings;
}
