// The stored JSON shapes (snake_case, as JSONCoding writes them) of the Swift models the ports use, with the same
// lenient decoding: Lenient strings accept numbers/booleans, LenientBool accepts "yes"/1, LenientArray drops bad items.
// SHORTCUT: plain Swift fields with defaults (e.g. ResumeContent.format) are lenient here too; Swift would reject a missing key.

import { toDouble } from "./text.js";

type J = unknown;
const obj = (v: J): Record<string, J> => (v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, J>) : {});
/** @Lenient */
export const str = (v: J): string =>
  typeof v === "string" ? v : typeof v === "number" ? String(v) : typeof v === "boolean" ? (v ? "Yes" : "No") : "";
/** @LenientBool */
export const bool = (v: J, def: boolean): boolean =>
  typeof v === "boolean" ? v : typeof v === "number" && Number.isInteger(v) ? v !== 0
    : typeof v === "string" ? ["yes", "true", "1", "y"].includes(v.toLowerCase()) : def;
/** @LenientArray of strings (non-strings are dropped, as LossyItem<String> does). */
export const strs = (v: J): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
const lossy = <T>(v: J, f: (x: J) => T | null): T[] => (Array.isArray(v) ? v.map(f).filter((x): x is T => x !== null) : []);
const strMap = (v: J): Record<string, string> => Object.fromEntries(Object.entries(obj(v)).filter((e): e is [string, string] => typeof e[1] === "string"));
const reqStr = (v: J): string | null => (typeof v === "string" ? v : null);
const int = (v: J): number | null => (typeof v === "number" && Number.isInteger(v) ? v : null);

export type Bullet = { id: string; text: string; original?: string };
export type Section = { id: string; title: string; company: string; name: string; location: string; dates: string; bullets: Bullet[] };
export type Skill = { label: string; items: string };
export type EducationItem = { school: string; degree: string; dates: string; details: string };
export type ResumeContent = {
  variant: string; label: string; format: string; name: string; email: string; phone: string; location: string;
  links: Record<string, string>; headline: string; summary: string; experience: Section[]; projects: Section[];
  education: EducationItem[]; skills: Skill[]; certifications: string[]; extras: string[]; years_experience: string;
  seniority: string; field: string; suggested_titles: string[]; top_skills: string[];
};
export type ResumeVersion = { name: string; label: string; is_default: boolean; content: ResumeContent; source_text: string; source_file: string; created: string };

export const bullet = (v: J): Bullet | null => {
  const o = obj(v), id = reqStr(o.id), text = reqStr(o.text);
  if (id === null || text === null) return null;
  const original = reqStr(o.original);
  return original === null ? { id, text } : { id, text, original };
};
export const section = (v: J): Section | null => {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return null;
  const o = obj(v);
  return { id: reqStr(o.id) ?? "", title: str(o.title), company: str(o.company), name: str(o.name), location: str(o.location), dates: str(o.dates), bullets: lossy(o.bullets, bullet) };
};
export const resumeContent = (v: J): ResumeContent => {
  const o = obj(v);
  return {
    variant: reqStr(o.variant) ?? "", label: reqStr(o.label) ?? "", format: reqStr(o.format) ?? "html",
    name: str(o.name), email: str(o.email), phone: str(o.phone), location: str(o.location), links: strMap(o.links),
    headline: str(o.headline), summary: str(o.summary), experience: lossy(o.experience, section), projects: lossy(o.projects, section),
    education: lossy(o.education, (x) => { const e = obj(x); return Array.isArray(x) || typeof x !== "object" || x === null ? null : { school: str(e.school), degree: str(e.degree), dates: str(e.dates), details: str(e.details) }; }),
    skills: lossy(o.skills, (x) => { const k = obj(x), label = reqStr(k.label); return label === null ? null : { label, items: str(k.items) }; }),
    certifications: strs(o.certifications), extras: strs(o.extras), years_experience: str(o.years_experience),
    seniority: str(o.seniority), field: str(o.field), suggested_titles: strs(o.suggested_titles), top_skills: strs(o.top_skills),
  };
};
export const resumeVersion = (v: J): ResumeVersion => {
  const o = obj(v);
  return { name: str(o.name), label: str(o.label), is_default: o.is_default === true, content: resumeContent(o.content),
           source_text: str(o.source_text), source_file: str(o.source_file), created: str(o.created) };
};
export const sections = (r: ResumeContent) => [...r.experience, ...r.projects];
/** Section.heading: "Title @ Company". */
export const heading = (s: Section) => { const t = s.title === "" ? s.name : s.title; return s.company === "" ? t : `${t} @ ${s.company}`; };
/** ResumeContent.yearsValue */
export const yearsValue = (r: ResumeContent) => { const m = /[\d.]+/.exec(r.years_experience)?.[0]; return (m === undefined ? null : toDouble(m)) ?? 0; };

export type Profile = {
  personal: { first_name: string; last_name: string; full_name: string; email: string; phone: string; address: string; city: string; state: string; country: string; postal_code: string; linkedin: string; github: string; portfolio: string };
  work: { current_company: string; current_title: string; years_experience: string; notice_period: string; current_salary: string; expected_salary: string; willing_to_relocate: boolean; open_to_remote: boolean };
  education: { degree: string; school: string; graduation_year: string };
  authorization: { citizenship: string; authorized_countries: string[]; needs_sponsorship: boolean };
  eeo: { gender: string; race: string; veteran: string; disability: string; sexual_orientation: string };
  misc: { how_heard: string; start_date: string; pronouns: string };
  prefs: { paper: string; dealbreakers: string; notes: string };
};
const strs0 = <K extends string>(o: Record<string, J>, keys: readonly K[]) => Object.fromEntries(keys.map((k) => [k, str(o[k])])) as Record<K, string>;
export const profile = (v: J): Profile => {
  const o = obj(v), w = obj(o.work), a = obj(o.authorization);
  return {
    personal: strs0(obj(o.personal), ["first_name", "last_name", "full_name", "email", "phone", "address", "city", "state", "country", "postal_code", "linkedin", "github", "portfolio"] as const),
    work: { ...strs0(w, ["current_company", "current_title", "years_experience", "notice_period", "current_salary", "expected_salary"] as const),
            willing_to_relocate: bool(w.willing_to_relocate, false), open_to_remote: bool(w.open_to_remote, true) },
    education: strs0(obj(o.education), ["degree", "school", "graduation_year"] as const),
    authorization: { citizenship: str(a.citizenship), authorized_countries: strs(a.authorized_countries), needs_sponsorship: bool(a.needs_sponsorship, false) },
    eeo: strs0(obj(o.eeo), ["gender", "race", "veteran", "disability", "sexual_orientation"] as const),
    misc: strs0(obj(o.misc), ["how_heard", "start_date", "pronouns"] as const),
    prefs: strs0(obj(o.prefs), ["paper", "dealbreakers", "notes"] as const),
  };
};

/** Profile(): the Swift defaults for a new profile (decoding "{}" gives blanks instead). */
export const newProfile = (): Profile => {
  const p = profile({}), d = "Decline to self-identify";
  p.eeo = { gender: d, race: d, veteran: d, disability: d, sexual_orientation: d };
  p.misc.how_heard = "Company website"; p.prefs.paper = "A4";
  return p;
};

export type Company = { name: string; slug?: string; workday?: string; ats?: string };
export type SearchConfig = {
  target_titles: string[]; title_include: string[]; title_exclude: string[]; boost_keywords: string[]; penalty_keywords: string[];
  exclude_companies: string[]; locations: string[]; remote_ok: boolean; companies: Company[]; queries: string[]; aspirations: string[];
};
export const searchConfig = (v: J): SearchConfig => {
  const o = obj(v);
  return {
    target_titles: strs(o.target_titles), title_include: strs(o.title_include), title_exclude: strs(o.title_exclude),
    boost_keywords: strs(o.boost_keywords), penalty_keywords: strs(o.penalty_keywords), exclude_companies: strs(o.exclude_companies),
    locations: strs(o.locations), remote_ok: bool(o.remote_ok, true), queries: strs(o.queries), aspirations: strs(o.aspirations),
    companies: lossy(o.companies, (x) => { const c = obj(x), name = reqStr(c.name); if (name === null) return null;
      const out: Company = { name }; for (const k of ["slug", "workday", "ats"] as const) { const s = reqStr(c[k]); if (s !== null) out[k] = s; } return out; }),
  };
};

/** The Job fields the ports read or set. */
export type Job = {
  id: string; company: string; title: string; location: string; url: string; apply_url: string; ats: string; ats_slug: string;
  posted: string | null; description: string; visa: string; min_years: number | null; variant: string; tailor_note: string;
};
export const job = (v: J): Job => {
  const o = obj(v);
  return { id: str(o.id), company: str(o.company), title: str(o.title), location: str(o.location), url: str(o.url), apply_url: str(o.apply_url),
           ats: str(o.ats), ats_slug: str(o.ats_slug), posted: reqStr(o.posted), description: str(o.description), visa: str(o.visa),
           min_years: int(o.min_years), variant: str(o.variant), tailor_note: str(o.tailor_note) };
};

export type QA = { q: string; a: string };
export type TailorPlan = {
  keywords: string[]; headline: string; summary: string; order: Record<string, string[]>; rewrites: Record<string, string>;
  skills_order: string[]; cover_letter: string; why_company: string; answers: QA[]; changes_summary: string; variant?: string;
};
export const tailorPlan = (v: J): TailorPlan => {
  const o = obj(v);
  const order = Object.fromEntries(Object.entries(obj(o.order)).filter((e) => Array.isArray(e[1]) && e[1].every((x) => typeof x === "string"))) as Record<string, string[]>;
  const p: TailorPlan = {
    keywords: strs(o.keywords), headline: str(o.headline), summary: str(o.summary),
    // Swift decodes order/rewrites as a whole: one bad entry drops the map.
    order: Object.keys(order).length === Object.keys(obj(o.order)).length ? order : {},
    rewrites: Object.values(obj(o.rewrites)).every((x) => typeof x === "string") ? strMap(o.rewrites) : {},
    skills_order: strs(o.skills_order), cover_letter: str(o.cover_letter), why_company: str(o.why_company),
    answers: lossy(o.answers, (x) => (x !== null && typeof x === "object" && !Array.isArray(x) ? { q: str(obj(x).q), a: str(obj(x).a) } : null)),
    changes_summary: str(o.changes_summary),
  };
  if (typeof o.variant === "string") p.variant = o.variant;
  return p;
};

export type ReviewBullet = { id: string; text: string; original: string };
export type ReviewGroup = { g: string; title: string; moved: string[]; bullets: ReviewBullet[] };
export type ReviewData = {
  variant: string; headline: string; summary: string; headline_original: string; summary_original: string;
  groups: ReviewGroup[]; unused: { id: string; text: string; group: string }[]; warnings: string[];
};
