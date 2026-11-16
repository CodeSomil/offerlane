// ResumeParser.content and AI.decode (Swift): the resume-parse reply as ResumeContent. Pinned by core_expected.json "parse".
import { resumeContent, strs, type Profile, type ResumeContent, type Section } from "./models.js";
import { toDouble, trimAll, trimSpaces } from "./text.js";

/** AI.decode: strip fences, then try the whole text, the outermost {...}, each later "{" (max 20), the outermost [...]. */
export function parseJSON(text: string, accept: (v: unknown) => boolean = () => true): unknown {
  const t = text.trim().replace(/^```(?:json)?|```$/gmu, "").trim();
  const cands = [t], b = t.lastIndexOf("}"), a = t.indexOf("{");
  if (a >= 0 && a < b) cands.push(t.slice(a, b + 1));
  if (b >= 0) for (let i = a + 1, n = 0; i >= 1 && i < b && n < 20; i++) if (t[i] === "{") { cands.push(t.slice(i, b + 1)); n++; }
  const la = t.indexOf("["), lb = t.lastIndexOf("]");
  if (la >= 0 && la < lb) cands.push(t.slice(la, lb + 1));
  for (const c of cands) { try { const v: unknown = JSON.parse(c); if (accept(v)) return v; } catch { /* next candidate */ } }
  throw new Error("The AI's reply wasn't valid JSON.");
}
export const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);

/** ResumeParser.content: bullets are trimmed, blanks dropped, ids e1, e1.1, p1.1 ... */
// SHORTCUT: a non-string value in "links" is dropped here; Swift rejects the whole reply (then the repair retry runs).
export function resumeFromParsed(v: unknown, name: string, label: string): ResumeContent {
  const o = isObject(v) ? v : {}, base = resumeContent({ ...o, experience: [], projects: [] });
  const secs = (xs: unknown, prefix: string): Section[] => (Array.isArray(xs) ? xs.filter(isObject) : []).map((s, i) => {
    const id = `${prefix}${i + 1}`, d = resumeContent({ experience: [{ ...s, id, bullets: [] }] }).experience[0]!;
    const bullets = strs(s.bullets).map(trimAll).filter((x) => x !== "");
    return { ...d, bullets: bullets.map((text, k) => ({ id: `${id}.${k + 1}`, text })) };
  });
  return {
    ...base, variant: name, label: label === "" ? name : label, format: "html",
    links: Object.fromEntries(Object.entries(base.links).filter(([, x]) => x !== "")),
    skills: base.skills.filter((s) => s.label !== ""), certifications: base.certifications.filter((x) => x !== ""), extras: base.extras.filter((x) => x !== ""),
    experience: secs(o.experience, "e"), projects: secs(o.projects, "p"),
  };
}

/** Profile.prefill(from:): fill empty fields from a parsed resume, never overwriting what the user typed. Returns a copy. */
export function prefill(p0: Profile, r: ResumeContent): Profile {
  const p: Profile = structuredClone(p0);
  const set = <G extends keyof Profile>(g: G, k: keyof Profile[G], v: string) => {
    const o = p[g] as Record<string, unknown>; if (o[k as string] === "" && v !== "") o[k as string] = v;
  };
  const parts = r.name.split(" ").filter((x) => x !== "");
  set("personal", "full_name", r.name); set("personal", "first_name", parts[0] ?? "");
  set("personal", "last_name", parts.length > 1 ? parts.slice(1).join(" ") : "");
  set("personal", "email", r.email); set("personal", "phone", r.phone);
  const loc = r.location.split(",").filter((x) => x !== "").map(trimSpaces), last = loc.at(-1);
  set("personal", "city", loc[0] ?? "");
  if (loc.length > 1) set("personal", "country", last === "UK" ? "United Kingdom" : last === "US" || last === "USA" ? "United States" : last!);
  for (const k of ["linkedin", "github", "portfolio"] as const) set("personal", k, r.links[k] ?? "");
  const job = r.experience.find((s) => s.company !== "");
  if (job) { set("work", "current_company", job.company); set("work", "current_title", job.title); }
  set("work", "years_experience", r.years_experience);
  const e = r.education[0];
  if (e) { set("education", "school", e.school); set("education", "degree", e.degree); set("education", "graduation_year", e.dates.match(/(?:19|20)\d{2}/g)?.at(-1) ?? ""); }
  if (p.authorization.authorized_countries.length === 0 && p.personal.country !== "") p.authorization.authorized_countries = [p.personal.country];
  return p;
}

/** Profile.validationErrors: problems that block saving the profile, keyed by field. `\w` spelled out as ICU's (Unicode). */
export function profileErrors(p: Profile): Record<string, string> {
  const e: Record<string, string> = {};
  if (trimSpaces(p.personal.first_name) === "") e.firstName = "Enter your first name.";
  if (trimSpaces(p.personal.last_name) === "") e.lastName = "Enter your last name.";
  if (!/^[\p{L}\p{M}\p{N}\p{Pc}.+-]+@[\p{L}\p{M}\p{N}\p{Pc}-]+(\.[\p{L}\p{M}\p{N}\p{Pc}-]+)+$/u.test(trimSpaces(p.personal.email))) e.email = "Enter a valid email address.";
  if (p.personal.phone !== "" && (p.personal.phone.match(/\p{N}/gu)?.length ?? 0) < 7) e.phone = "That phone number looks too short.";
  if (p.work.years_experience !== "" && toDouble(p.work.years_experience) === null) e.years = "Use a number, e.g. 5.";
  if (p.authorization.authorized_countries.length === 0) e.countries = "Add at least one country where you can work without sponsorship.";
  return e;
}
