// Discover on the web (P3.5b): the shared job index (GET /v1/jobs through the generated client), mapped into the core Job
// and ranked on this device with the ported localScore. Saved jobs (approved, declined, applied ...) live in IndexedDB.
import { apiClient, type ApiJob } from "@offerlane/contract/client";
import { canMove, isStatus, sameJob, job as decodeJob, STATUS_TITLE, tailorPlan, type TailorPlan, localScore, per, rankContext, searchConfig, Visa, type Job, type PayRange, type Profile, type ResumeContent } from "@offerlane/core";
import { bearer } from "./auth.js";
import { getItem, updateItem } from "./store.js";

declare const __API_ORIGIN__: string;
const api = apiClient(__API_ORIGIN__, { credentials: "omit", referrerPolicy: "no-referrer" });

export class JobsError extends Error {}
export async function searchJobs(q: string): Promise<ApiJob[]> {
  const t = bearer();
  let r;
  try {
    r = await api.GET("/v1/jobs", { params: { query: { q, limit: 50 } }, headers: t ? { authorization: `Bearer ${t}` } : {}, signal: AbortSignal.timeout(15_000) });
  } catch { throw new JobsError("Couldn't reach Offerlane's job index. Check your connection and try again."); }
  if (r.response.status === 401) throw new JobsError("Sign in (Settings) to search Offerlane's job index. Your data stays on this device unless you turn on sync.");
  if (r.response.status === 429) throw new JobsError("Too many searches in a short time. Try again in a minute.");
  if (!r.data) throw new JobsError(`The job index answered ${r.response.status}. Try again later.`);
  return r.data.items;
}

// The index is shared data: only http(s) links become hrefs.
const web = (u: string) => (/^https?:\/\//i.test(u) ? u : "");
export const toJob = (a: ApiJob): Job => ({ id: a.id, company: a.company, title: a.title, location: a.location, url: web(a.url), apply_url: web(a.applyUrl),
  ats: a.ats, ats_slug: "", posted: a.postedAt, description: a.description, visa: "", min_years: null, variant: "main", tailor_note: "" });

export type Match = { job: Job; score: number; why: string[] };
/** Local ranking only (no AI call): the Mac's localScore with the resume's titles/skills and the profile's city. */
export function rank(items: Job[], r: ResumeContent, p: Profile, now = new Date()): Match[] {
  const ctx = rankContext(r, p, searchConfig({ locations: p.personal.city === "" ? [] : [p.personal.city] })), visa = new Visa(p);
  return items.map((job) => {
    const score = localScore(job, ctx, visa, now), d = job.description.toLowerCase();
    return { job, score, why: ctx.skills.filter((s) => s !== "" && d.includes(s)).slice(0, 4) };
  }).sort((a, b) => b.score - a.score);
}

/** FindView.pay: "£45–55k", "$30–45 an hour"; one "k" only when both ends are thousands. */
export function payLabel(p: PayRange): string {
  const f0 = new Intl.NumberFormat("en", { maximumFractionDigits: 0 }), f1 = new Intl.NumberFormat("en", { maximumFractionDigits: 1 });
  const both = p.low >= 1000 && p.high >= 1000, n = (v: number) => (v >= 1000 ? f1.format(v / 1000) : f0.format(v));
  return `${p.currency}${both ? n(p.low) : f0.format(p.low)}–${both ? n(p.high) + "k" : f0.format(p.high)}` + (p.period === "year" ? "" : per(p.period));
}
export const VISA_LABEL: Record<string, string> = { ok: "Can work here", remote: "Remote", "no-sponsorship": "No sponsorship", sponsors: "Sponsors visas",
  "sponsor-register": "Licensed sponsor", "h1b-lottery": "H-1B lottery", likely: "Visa likely", unknown: "Visa unknown" };

/** A job the user acted on. `status` is a JobStatus raw value (Swift JobStatus.swift). */
/** `plan` + `answers` are the tailoring draft (answers.md text) once the role reached Review (P3.6). */
export type Saved = { job: Job; status: string; score: number; created: string; updated: string; plan?: TailorPlan; answers?: string };
export class MoveError extends Error {}
/** Read back leniently: an entry without a readable job or status is dropped, never a crash in Pipeline or Today. */
const decodeSaved = (v: unknown): Record<string, Saved> => {
  const o = v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {}, out: Record<string, Saved> = {};
  for (const [id, x] of Object.entries(o)) {
    const e = (x ?? {}) as Record<string, unknown>;
    if (typeof e.status !== "string" || e.job === null || typeof e.job !== "object") continue;
    const j = decodeJob(e.job), t = typeof e.updated === "string" ? e.updated : "";
    if (j.id !== id) continue;
    out[id] = { job: j, status: e.status, score: typeof e.score === "number" ? e.score : 0, created: typeof e.created === "string" ? e.created : t, updated: t };
    if (e.plan !== null && typeof e.plan === "object" && !Array.isArray(e.plan)) out[id].plan = tailorPlan(e.plan as Parameters<typeof tailorPlan>[0]);
    if (typeof e.answers === "string") out[id].answers = e.answers;
  }
  return out;
};
export const loadSaved = async (): Promise<Record<string, Saved>> => decodeSaved(await getItem("applications"));
/** Every status change goes through here and the ported StateMachine (a new job starts as "found"), in one transaction. */
export function setStatus(job: Job, score: number, status: string, now = new Date()): Promise<Record<string, Saved>> {
  const t = now.toISOString();
  return updateItem("applications", (v) => {
    const all = decodeSaved(v), old = all[job.id];
    if (!canMove(old?.status ?? "found", status)) throw new MoveError(`This role is already ${old?.status ?? "found"}; it can't move to ${status}.`);
    all[job.id] = { ...old, job, score, status, created: old?.created ?? t, updated: t };
    return all;
  });
}
/** Tailor.finish: a draft is only accepted for a role approved and not yet sent (tailoring or review); it lands in review.
 *  The status check and the write are one transaction, so a role another tab moved on is never overwritten. */
export function saveDraft(id: string, plan: TailorPlan, answers: string, now = new Date()): Promise<Record<string, Saved>> {
  return updateItem("applications", (v) => {
    const all = decodeSaved(v), old = all[id];
    if (!old) throw new MoveError("That role is no longer saved on this device.");
    if (old.status !== "tailoring" && old.status !== "review")
      throw new MoveError(`That role is at \u201c${isStatus(old.status) ? STATUS_TITLE[old.status] : old.status}\u201d. Drafts are only accepted for roles you approved and haven't sent yet.`);
    all[id] = { ...old, status: "review", plan, answers, updated: now.toISOString() };
    return all;
  });
}

/** Jobs saved with the browser extension join Discover as "found" (one transaction); a job already saved here, by id or
 *  by its posting/form address, is left as it is. Returns how many were added. */
export async function addFound(jobs: Job[], now = new Date()): Promise<number> {
  let added = 0;
  const t = now.toISOString();
  await updateItem("applications", (v) => {
    const all = decodeSaved(v);
    added = 0;
    for (const j of jobs) {
      if (j.id === "" || all[j.id] || Object.values(all).some((s) => [j.url, j.apply_url].some((u) => u !== "" && sameJob(s.job, u)))) continue;
      all[j.id] = { job: j, status: "found", score: 0, created: t, updated: t };
      added++;
    }
    return all;
  });
  return added;
}
