// Assisted apply (H5): the answer for each question on the form, via the ported AnswerRules (want, pick). The panel shows
// these with a Copy button; nothing is ever put into the page.
import { parseAnswers, pick, rules, sameJob, Visa, want, type FormField, type JobAnswers, type Profile } from "@offerlane/core";
import type { PageField } from "./page.js";

export type Row = { label: string; answer: string | null; options: string[] | null };

/** The job the web app sent that this tab shows (posting or form), if any. */
export const matchJob = (jobs: JobAnswers[], tabURL: string): JobAnswers | null => jobs.find((j) => sameJob(j.job, tabURL)) ?? null;

export function rows(fields: PageField[], p: Profile, ja: JobAnswers | null): Row[] {
  // Consent is false: the person reads and ticks every consent or terms box themselves.
  const R = rules(p, ja?.job.location ?? "", false, new Visa(p)), answers = parseAnswers(ja?.answers ?? "");
  // A radio/checkbox group (same legend and same HTML name) is one question; its inputs' labels are the options.
  // A "group" of one input is a stray legend from grp()'s parent walk (e.g. a lone consent box): it's its own question.
  const choice_ = (f: PageField) => (f.type === "radio" || f.type === "checkbox") && f.group !== "";
  const gkey = (f: PageField) => `g:${f.group}|${f.key}`;
  const size = new Map<string, number>();
  for (const f of fields) if (choice_(f)) size.set(gkey(f), (size.get(gkey(f)) ?? 0) + 1);
  const groups = new Map<string, { f: PageField; options: string[] }>();
  for (const f0 of fields) {
    if (f0.type === "file") continue;
    const f = choice_(f0) && size.get(gkey(f0)) === 1 ? { ...f0, group: "" } : f0;
    const multi = choice_(f);
    const key = multi ? gkey(f) : `f:${f.label}:${f.name}`;
    const g = groups.get(key);
    if (g) { if (multi) g.options.push(f.label); continue; }
    groups.set(key, { f, options: multi ? [f.label] : f.options ?? [] });
  }
  const out: Row[] = [], seen = new Set<string>();
  for (const { f, options } of groups.values()) {
    const ff: FormField = { type: f.type, label: f.label, name: f.name, group: f.group };
    const [v, L] = want(ff, R, answers);
    if (L === "" || seen.has(L)) continue;
    seen.add(L);
    const choice = options.length > 0 ? pick(options, v) : v;
    out.push({ label: L, answer: choice === null || choice === "" ? null : choice, options: options.length > 0 ? options : null });
  }
  return out;
}
