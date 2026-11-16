// v4 P3.8: the browser extension's "Save this job" (a page's JSON-LD JobPosting, else a known job-site URL) and the
// checks on every message between the web app and the extension (H5). Page text is untrusted: every field is capped
// and only http(s) links are kept.
import { job, profile, type Job, type Profile } from "./models.js";
import { collapse, prefix, stripHTML } from "./text.js";

/** What the extension's read-only page script returns (apps/extension/src/page.ts). */
export type PageInfo = { url: string; title: string; h1: string; ldjson: string[] };
export type AtsRef = { ats: string; slug: string; id: string };

type J = unknown;
const obj = (v: J): Record<string, J> | null => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, J>) : null);
const s = (v: J): string => (typeof v === "string" ? collapse(v) : typeof v === "number" ? String(v) : "");
const web = (u: string): URL | null => { try { const x = new URL(u); return x.protocol === "https:" || x.protocol === "http:" ? x : null; } catch { return null; } };
const noHash = (u: URL) => { const x = new URL(u); x.hash = ""; return x.href; };
// Tracking parameters never name a job; others (gh_jid, jobId, jk ...) can, so they stay in ids and matching.
const TRACKING = /^(utm_.*|ref|source|src|gh_src|lever-(source|origin)|trk.*|referrer|fbclid|gclid)$/i;
/** host + path (no trailing slash) + the sorted non-tracking query: one job, one address. */
const addr = (x: URL, path = x.pathname.replace(/\/+$/, "")) => {
  const q = [...x.searchParams].filter(([k]) => !TRACKING.test(k)).sort(([a], [b]) => a.localeCompare(b));
  return x.host + path + (q.length > 0 ? "?" + new URLSearchParams(q).toString() : "");
};

/** The job sites the Mac app and the API know (libs/contract ATS), by host; the path gives company slug and job id. */
const SITES: [ats: string, host: RegExp, path: RegExp][] = [
  ["greenhouse", /^(boards|job-boards)\.greenhouse\.io$/, /^\/([^/]+)\/jobs\/(\d+)/],
  ["lever", /^jobs\.lever\.co$/, /^\/([^/]+)\/([0-9a-f-]{20,})/i],
  ["ashby", /^jobs\.ashbyhq\.com$/, /^\/([^/]+)\/([0-9a-f-]{20,})/i],
  ["workable", /^apply\.workable\.com$/, /^\/([^/]+)\/j\/([A-Za-z0-9]+)/],
  ["smartrecruiters", /^jobs\.smartrecruiters\.com$/, /^\/([^/]+)\/(\d+)/],
];
export function atsFromURL(url: string): AtsRef | null {
  const u = web(url);
  if (!u) return null;
  const h = u.hostname.toLowerCase();
  if (/^(boards|job-boards)\.greenhouse\.io$/.test(h) && u.pathname.startsWith("/embed/job_app")) {
    const slug = u.searchParams.get("for"), id = u.searchParams.get("token");
    return slug && id && /^\d+$/.test(id) ? { ats: "greenhouse", slug, id } : null;
  }
  const wd = /^([a-z0-9-]+)\.wd\d+\.myworkdayjobs\.com$/.exec(h), wid = /\/job\/[^/]+\/[^/]*_([A-Za-z0-9-]+)(\/apply(\/[^/]*)?)?\/?$/.exec(u.pathname);
  if (wd && wid) return { ats: "workday", slug: wd[1]!, id: wid[1]! };
  for (const [ats, host, path] of SITES) {
    const m = host.test(h) ? path.exec(u.pathname) : null;
    if (m) return { ats, slug: decodeURIComponent(m[1]!), id: m[2]! };
  }
  return null;
}

const isPosting = (n: Record<string, J>) => { const t = n["@type"]; return t === "JobPosting" || (Array.isArray(t) && t.includes("JobPosting")); };
function postings(v: J, out: Record<string, J>[] = [], depth = 0): Record<string, J>[] {
  if (depth > 4) return out;
  if (Array.isArray(v)) v.forEach((x) => postings(x, out, depth + 1));
  const o = obj(v);
  if (o) { if (isPosting(o)) out.push(o); else if (o["@graph"] !== undefined) postings(o["@graph"], out, depth + 1); }
  return out;
}
const place = (v: J): string => {
  const a = obj(obj(v)?.address) ?? {}, country = obj(a.addressCountry)?.name ?? a.addressCountry;
  return [s(a.addressLocality), s(a.addressRegion), s(country)].filter((x) => x !== "").join(", ");
};
function day(v: J, now: Date): string | null {
  const t = typeof v === "string" ? Date.parse(v) : NaN;
  return Number.isNaN(t) || t > now.getTime() + 86_400_000 ? null : new Date(t).toISOString().slice(0, 10);
}

/** The job on this page, or null when it shows neither a JobPosting nor a known job-site URL. */
export function readPosting(p: PageInfo, now: Date = new Date()): Job | null {
  const page = web(p.url);
  if (!page) return null;
  let ld: Record<string, J> | undefined;
  for (const text of p.ldjson.slice(0, 20)) {
    try { ld = postings(JSON.parse(text))[0]; } catch { continue; }
    if (ld) break;
  }
  const ldURL = ld ? web(s(ld.url)) : null, url = noHash(ldURL ?? page);
  const ref = atsFromURL(p.url) ?? atsFromURL(url);
  if (!ld && !ref) return null;
  const org = ld ? (obj(ld.hiringOrganization)?.name ?? ld.hiringOrganization) : undefined;
  const locs = ld ? (Array.isArray(ld.jobLocation) ? ld.jobLocation : [ld.jobLocation]).map(place).filter((x) => x !== "") : [];
  const remote = ld && s(ld.jobLocationType).toUpperCase() === "TELECOMMUTE";
  const slugName = ref ? ref.slug.charAt(0).toUpperCase() + ref.slug.slice(1) : "";
  return { ...job({}), variant: "main",
    id: ref ? `${ref.ats}:${ref.slug}:${ref.id}` : `web:${addr(new URL(url))}`,
    company: prefix(s(org) || slugName, 200), title: prefix((ld ? s(ld.title) : "") || collapse(p.h1) || collapse(p.title), 200),
    location: prefix(locs.length > 0 ? locs.join("; ") : remote ? "Remote" : "", 200), url, apply_url: url,
    ats: ref?.ats ?? "", ats_slug: ref?.slug ?? "", posted: ld ? day(ld.datePosted, now) : null,
    description: ld ? prefix(stripHTML(typeof ld.description === "string" ? ld.description : ""), 20_000) : "" };
}

/** Is this tab the job's posting or its form? Same job-site job id, else the same address (tracking query, hash and /apply ignored). */
export function sameJob(j: Job, tabURL: string): boolean {
  const key = (u: string) => {
    const r = atsFromURL(u);
    if (r) return `${r.ats}:${r.slug.toLowerCase()}:${r.id}`;
    const x = web(u);
    return x ? addr(x, x.pathname.replace(/\/(apply|application)?\/*$/i, "")) : null;
  };
  const t = key(tabURL);
  return t !== null && [j.url, j.apply_url].some((u) => u !== "" && key(u) === t);
}

// ---- web <-> extension messages (externally_connectable; the extension also checks the sender's origin) ----
export type JobAnswers = { job: Job; answers: string };
export type ToExtension = { type: "ping" } | { type: "saved" } | { type: "clear"; ids: string[] } | { type: "answers"; profile: Profile; jobs: JobAnswers[] };
// MAX_MESSAGE keeps a whole answer set well under chrome.storage.local's 10 MB.
export const MAX_JOBS = 500, MAX_ANSWERS = 60_000, MAX_MESSAGE = 8_000_000;

/** A web request, or null for anything malformed or too big (the extension then ignores it). */
export function toExtension(v: J): ToExtension | null {
  const o = obj(v);
  if (!o) return null;
  if (o.type === "ping" || o.type === "saved") return { type: o.type };
  if (o.type === "clear") {
    const ids = o.ids;
    return Array.isArray(ids) && ids.length <= MAX_JOBS && ids.every((x) => typeof x === "string") ? { type: "clear", ids: ids as string[] } : null;
  }
  if (o.type !== "answers" || !obj(o.profile) || !Array.isArray(o.jobs) || o.jobs.length > MAX_JOBS) return null;
  try { if (JSON.stringify(o).length > MAX_MESSAGE) return null; } catch { return null; }
  const jobs: JobAnswers[] = [];
  for (const x of o.jobs) {
    const e = obj(x);
    if (!e || !obj(e.job) || typeof e.answers !== "string" || e.answers.length > MAX_ANSWERS) return null;
    jobs.push({ job: job(e.job), answers: e.answers });
  }
  return { type: "answers", profile: profile(o.profile), jobs };
}

/** The extension's answer to "saved": the jobs it holds, read leniently; links that aren't http(s) are blanked. */
export function savedReply(v: J): Job[] | null {
  const list = obj(v)?.jobs;
  if (!Array.isArray(list)) return null;
  return list.slice(0, MAX_JOBS).filter((x) => obj(x) && typeof obj(x)!.id === "string" && obj(x)!.id !== "").map((x) => {
    const j = job(x);
    return { ...j, url: web(j.url) ? j.url : "", apply_url: web(j.apply_url) ? j.apply_url : "" };
  });
}
