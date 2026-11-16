// Apply/AnswerRules.swift: which answer goes in which form field. The extension's assisted apply shows these as
// copy-ready answers; it never fills or submits (D4).
import type { Job, Profile } from "./models.js";
import type { Visa } from "./ranking.js";
import { findAll, first, has, len, search, sub, trimAll, trimChars, trimSpaces } from "./text.js";

export type FormField = { type: string; label: string; name?: string; group?: string };
export type Answer = [question: string, answer: string];

export const DONE_RX = "thank(s| you) for (applying|your application|submitting)|application (has been |was )?(submitted|received)|we('ve| have) received your application|your application is (in|complete)|successfully submitted";
export const CONSENT_RX = "consent|agree|privacy|terms|acknowledge|certify|i confirm|i have read";

/** answers.md → ordered (question, answer) pairs. */
export function parseAnswers(md: string): Answer[] {
  const out: Answer[] = [];
  let key: string | null = null, buf = "";
  const flush = () => { if (key !== null) { const a = trimAll(buf); if (a !== "") out.push([key, a]); } };
  for (const line of md.split("\n")) {
    if (line.startsWith("### ")) { flush(); key = trimSpaces(line.slice(4)); buf = ""; }
    else if (key !== null) buf += line + "\n";
  }
  flush();
  return out;
}

const STOP = new Set(["the", "and", "you", "your", "are", "for", "with", "this", "what", "why", "how", "have", "please", "our", "that", "would"]);
const words = (s: string) => new Set(findAll("[a-z]{3,}", s.toLowerCase()).filter((w) => !STOP.has(w)));

export function bestAnswer(label: string, answers: Answer[]): string | null {
  const lw = words(label);
  let best: string | null = null, sc = 0;
  for (const [q, a] of answers) {
    const qw = words(q);
    const inter = [...lw].filter((w) => qw.has(w)).length, uni = new Set([...lw, ...qw]).size;
    let s = inter / Math.max(1, uni);
    if (has(label.toLowerCase(), q.toLowerCase()) || has(q.toLowerCase(), trimChars(label.toLowerCase(), " *?"))) s = Math.max(s, 0.9);
    if (s > sc) { best = a; sc = s; }
  }
  if (sc >= 0.45) return best;
  if (search("\\bwhy\\b|interested in|motivat|excites? you|attract(s|ed)? you|want to (work|join)", label)) return answers.find(([q]) => search("^why\\b", q))?.[1] ?? null;
  return null;
}

export type Rule = [pattern: string, value: string | null | ((label: string) => string | null)];

export function rules(p: Profile, jobLocation: string, consent: boolean, visa: Visa): Rule[] {
  const ps = p.personal, w = p.work, a = p.authorization, e = p.eeo, ed = p.education, m = p.misc;
  const yn = (b: boolean) => (b ? "Yes" : "No");
  const opt = (s: string) => (s === "" ? null : s);
  const phone = ps.phone;
  const cc = first("^\\+\\d{1,3}", phone, false);
  const needs = a.needs_sponsorship;
  return [
    ["first name|given name|preferred first", ps.first_name], ["last name|surname|family name", ps.last_name],
    ["^(full )?name\\b|your name|legal name", ps.full_name], ["e-?mail", ps.email],
    ["country code|phone code", cc], ["phone device|device type", "Mobile"],
    ["phone number|local number", sub("^\\+\\d{1,3}[\\s-]*", "", phone)], ["phone|mobile", phone],
    ["linkedin", opt(ps.linkedin)], ["github", opt(ps.github)], ["website|portfolio|personal (site|url)", opt(ps.portfolio)],
    ["bound by|non-?compete|restrictive covenant", null],
    ["(ever|previously|currently).{0,40}(employed|worked) (by|for|at)|former employee|previously worked", "No"],
    ["whatsapp|sms|text message", null],
    ["sponsor|visa", (L) => yn(needs && !visa.authorizedFor(jobLocation, L))],
    ["(legally )?(authori[sz]ed|eligible|right) to work|work authori[sz]ation|work permit", (L) => yn(visa.authorizedFor(jobLocation, L))],
    ["relocat", yn(w.willing_to_relocate)], ["remote", yn(w.open_to_remote)],
    ["employer|current (company|organi[sz]ation)|most recent company|^company( name)?\\W*$", w.current_company],
    ["job title|current (title|role|position)|recent title", w.current_title],
    ["years? of (relevant |professional |total )?experience|how many years", opt(w.years_experience)],
    ["notice period", w.notice_period], ["start date|when can you start|earliest", m.start_date],
    ["current (ctc|salary|compensation|pay)", opt(w.current_salary)],
    ["expected (ctc|salary|compensation|pay)|salary expectation|desired (salary|compensation|pay)|compensation expectation", opt(w.expected_salary)],
    ["how did you (hear|find|learn)|^source", m.how_heard === "" ? "Company website" : m.how_heard],
    ["address line ?1|street", opt(ps.address)], ["\\bcity\\b", ps.city], ["state|province|region", opt(ps.state)],
    ["postal|zip", opt(ps.postal_code)],
    ["location|where are you (based|located)", [ps.city, ps.state, ps.country].filter((x) => x !== "").join(", ")],
    ["country", ps.country], ["school|university|college|institution", ed.school], ["degree", ed.degree],
    ["graduat", opt(ed.graduation_year)],
    ["gender", e.gender], ["veteran", e.veteran], ["disabilit", e.disability], ["race|ethnic|hispanic|latino", e.race],
    ["sexual orientation", e.sexual_orientation], ["pronoun", opt(m.pronouns)], ["citizenship|nationality", a.citizenship],
    [CONSENT_RX, consent ? "Yes" : null],
  ];
}

/** The value for a field (null = leave it) and the label it was matched on. */
export function want(f: FormField, R: Rule[], answers: Answer[]): [string | null, string] {
  const L = trimAll((f.group ?? "") === "" ? (f.label === "" ? f.name ?? "" : f.label) : f.group!);
  if (L === "") return [null, ""];
  if (f.type === "textarea" || len(L) > 70) {
    if (search("cover letter", L)) return [answers.find(([q]) => q === "Cover letter")?.[1] ?? bestAnswer("cover letter", answers), L];
    const ans = bestAnswer(L, answers);
    if (ans !== null || f.type === "textarea") return [ans, L];
  }
  for (const [r, v] of R) if (search(r, L)) return [typeof v === "function" ? v(L.toLowerCase()) : v, L];
  return [bestAnswer(L, answers), L];
}

/** The option matching a value: exact, prefix, contains, decline-style, yes/no, first comma part. */
export function pick(options: string[], value: string | null): string | null {
  const v = trimSpaces((value ?? "").toLowerCase());
  const O = options.filter((o) => trimSpaces(o) !== "" && !search("^(select|choose|--|please)", trimSpaces(o)));
  const part = v.split(",").filter((x) => x !== "")[0];
  const head = part === undefined ? v : trimSpaces(part);
  const tests: ((o: string) => boolean)[] = [
    (o) => o.toLowerCase() === v, (o) => o.toLowerCase().startsWith(v), (o) => o.toLowerCase().includes(v),
    (o) => v.startsWith("decline") && search("decline|prefer not|don.t wish|not to (say|disclose)|do not wish", o),
    (o) => v.startsWith("no") && search("^no\\b", o), (o) => v.startsWith("yes") && search("^(yes\\b|i agree|i consent)", o),
    (o) => len(v) > 3 && o.toLowerCase().includes(head),
  ];
  for (const t of tests) { const o = O.find(t); if (o !== undefined) return o; }
  return null;
}

/** Normalise a posting URL to the page with the form. */
export function formURL(j: Job): string {
  const u = j.apply_url === "" ? j.url : j.apply_url;
  const firstPart = u.split("?").filter((x) => x !== "")[0];
  const base = firstPart === undefined ? u : trimChars(firstPart, "/");
  if (j.ats === "lever" && !base.endsWith("/apply")) return base + "/apply";
  if (j.ats === "ashby" && !base.endsWith("/application")) return base + "/application";
  if (j.ats === "workable" && !base.endsWith("/apply")) return base + "/apply/";
  if (j.ats === "greenhouse") {
    const id = first("gh_jid=(\\d+)", u) ?? first("token=(\\d+)", u) ?? first("/jobs?[/.](\\d{5,})", u);
    const slug = j.ats_slug === "" ? first("greenhouse\\.io/(?!embed)([\\w-]+)/jobs", u) : j.ats_slug;
    if (id !== null && slug !== null) return `https://job-boards.greenhouse.io/embed/job_app?for=${slug}&token=${id}`;
  }
  return u;
}
