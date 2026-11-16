// Discovery/Ranking.swift (condense, Context, localScore, the scoring prompt) and Search/Visa.swift, ported line for line.
import { yearsValue, type Job, type Profile, type ResumeContent, type SearchConfig } from "./models.js";
import { RANK_PROMPT } from "./prompts.js";
import { ageDays, collapse, escapeRe, findAll, has, len, norm, prefix, search, split, sub, toDouble, trimSpaces } from "./text.js";

const YEARS = "(\\d{1,2})\\s*\\+?\\s*(?:-\\s*\\d+\\s*)?(?:years|yrs)";

/** The requirement-bearing sentences of a JD, up to `n` characters. */
export function condense(d: string | null | undefined, n = 700): string {
  const text = d ?? "";
  const s = split("(?<=[.!?•;])\\s+", text).map(trimSpaces).filter((x) => len(x) > 25 && len(x) < 350);
  const cue = "you (will|'ll)|responsib|require|qualif|experience (with|in)|must|should have|looking for|what you|skills";
  const keep = s.filter((x) => search(cue, x));
  let out = "", count = 0;
  for (const x of keep.length === 0 ? s : keep) { const c = len(x); if (count + c > n) break; out += x + " "; count += c + 1; }
  const r = trimSpaces(out);
  return r === "" ? prefix(text, n) : r;
}

export type RankContext = { titles: string[]; skills: string[]; penalty: string[]; locs: string[]; years: number; watch: string[] };
export function rankContext(r: ResumeContent, p: Profile, s: SearchConfig): RankContext {
  return {
    titles: s.target_titles.length === 0 ? r.suggested_titles : s.target_titles,
    skills: (s.boost_keywords.length === 0 ? r.top_skills : s.boost_keywords).map((x) => x.toLowerCase()).slice(0, 40),
    penalty: s.penalty_keywords.map((x) => x.toLowerCase()),
    locs: s.locations.map((x) => x.toLowerCase()),
    years: toDouble(p.work.years_experience) ?? yearsValue(r),
    watch: s.companies.map((c) => c.name),
  };
}

const words = (x: string) => new Set(norm(x).split(" ").filter((w) => w !== ""));

/** Title (40) + skills (30) − penalties + location (10) + recency (10) + years fit + watchlist (10) − no-sponsorship.
 *  Sets `j.min_years` and `j.visa`, like the Swift inout. */
export function localScore(j: Job, ctx: RankContext, visa: Visa, now: Date = new Date()): number {
  const t = words(j.title), d = j.description.toLowerCase(), l = j.location.toLowerCase();
  const ratios = ctx.titles.map((x) => { const w = words(x); return [...t].filter((y) => w.has(y)).length / Math.max(1, w.size); });
  const title = (ratios.length === 0 ? 0 : Math.max(...ratios)) * 40;
  const kw = Math.min(30, 3 * ctx.skills.filter((x) => x !== "" && d.includes(x)).length) - Math.min(20, 8 * ctx.penalty.filter((x) => has(d, x)).length);
  const first = ctx.locs[0];
  const loc = first !== undefined && has(l, first) ? 10 : l.includes("remote") ? 6 : 3;
  const age = ageDays(j.posted, now);
  const rec = age <= 7 ? 10 : age <= 14 ? 5 : 0;
  const yrs = findAll(YEARS, prefix(d, 6000), true).map(Number).filter((y) => y > 0 && y < 25);
  j.min_years = yrs.length === 0 ? null : Math.min(...yrs);
  const exp = j.min_years === null ? 0 : j.min_years <= ctx.years + 1 ? 5 : j.min_years > ctx.years + 3 ? -20 : -5;
  j.visa = visa.tag(j.company, j.location, j.description);
  const spons = j.visa === "no-sponsorship" ? -30 : 0;
  const watched = ctx.watch.some((x) => norm(x) === norm(j.company)) ? 10 : 0;
  return Math.round(Math.max(0, title + kw + loc + rec + exp + watched + spons) * 10) / 10;
}

/** Ranking.head: the scoring instructions; with several resume versions the AI also picks one. */
export function rankHead(names: string[]): string {
  const key = names.length > 1 ? ", v=best resume version (" + names.join("|") + ")" : "";
  return RANK_PROMPT[0] + key + RANK_PROMPT[1] + (names.length > 1 ? ',"v":""' : "") + RANK_PROMPT[2];
}
/** Ranking.line: what one job contributes to the prompt. */
export const rankLine = (j: Job) => `${j.company} | ${j.title} | ${j.location} | ${j.visa} | ${j.min_years ?? "?"} | ${condense(j.description)}`;

const COUNTRIES: [string, string][] = [
  ["india", "india|bengaluru|bangalore|mumbai|pune|hyderabad|delhi|gurgaon|gurugram|noida|chennai|kolkata|ahmedabad"],
  ["united states", "united states|\\busa?\\b|america|new york|san francisco|seattle|austin|boston|chicago|los angeles|menlo park|palo alto|mountain view|sunnyvale|bellevue|, (ca|ny|wa|tx|ma|il|co|ga|nc|va)\\b"],
  ["united kingdom", "united kingdom|\\buk\\b|england|london|manchester|edinburgh|cambridge|scotland"],
  ["netherlands", "netherlands|amsterdam|rotterdam|utrecht|eindhoven"], ["germany", "germany|berlin|munich|hamburg|frankfurt"],
  ["ireland", "ireland|dublin"], ["canada", "canada|toronto|vancouver|montreal"], ["singapore", "singapore"],
  ["united arab emirates", "\\buae\\b|dubai|abu dhabi|united arab emirates"], ["australia", "australia|sydney|melbourne"],
  ["france", "france|paris"], ["spain", "spain|madrid|barcelona"], ["switzerland", "switzerland|zurich|geneva"],
];
const COUNTRY_RX = new Map(COUNTRIES);
const EASY = new Set(["germany", "ireland", "singapore", "united arab emirates", "canada", "netherlands"]);
const NEG = "(unable|not able|cannot|can't|do not|does not|won't|will not)\\s+(to\\s+)?(provide\\s+)?sponsor|no (visa )?sponsorship|without (the need for )?(visa )?sponsorship|must (already )?have (the )?(full )?right to work";
const POS = "visa sponsorship (is )?(available|provided|offered)|(we|will|can) (offer|provide)?\\s*(visa )?sponsor|sponsorship (is )?available|relocation (support|assistance|package)";
const SUFFIX = "\\b(ltd|limited|inc|llc|plc|b ?v|n ?v|gmbh|ag|sa|corp(oration)?|co|company|holdings?|group|technolog(y|ies)|services|solutions|software|india|uk|europe|international|the|pvt|private)\\b";
const ALIAS: Record<string, string> = {
  "uk": "united kingdom", "u.k.": "united kingdom", "england": "united kingdom", "britain": "united kingdom", "great britain": "united kingdom",
  "scotland": "united kingdom", "wales": "united kingdom", "us": "united states", "u.s.": "united states", "usa": "united states",
  "america": "united states", "united states of america": "united states", "uae": "united arab emirates", "emirates": "united arab emirates",
  "holland": "netherlands", "the netherlands": "netherlands",
};

/** Work-authorization realism per posting (no AI). `registers` are the sorted UK/NL sponsor register names (nname'd). */
export class Visa {
  readonly authorized: string[];
  readonly needsSponsorship: boolean;
  constructor(p: Profile, private readonly registers: { uk?: string[]; nl?: string[] } = {}) {
    this.authorized = p.authorization.authorized_countries.map(Visa.canon);
    this.needsSponsorship = p.authorization.needs_sponsorship;
  }
  static canon(c: string): string { const x = trimSpaces(c).toLowerCase(); return Object.hasOwn(ALIAS, x) ? ALIAS[x]! : x; }
  static countriesIn(loc: string): string[] { const l = loc.toLowerCase(); return COUNTRIES.filter(([, r]) => search(r, l, false)).map(([c]) => c); }
  authorizedFor(loc: string, label = ""): boolean {
    const hay = (loc + " " + label).toLowerCase();
    return this.authorized.some((c) => search(COUNTRY_RX.get(c) ?? escapeRe(c), hay, false));
  }
  static nname(s: string): string { return collapse(sub(SUFFIX, " ", sub("[^a-z0-9 ]", " ", s.toLowerCase()))); }
  inRegister(company: string, k: "uk" | "nl"): boolean {
    const n = Visa.nname(company), reg = this.needsSponsorship ? this.registers[k] ?? [] : [];
    if (n === "" || reg.length === 0) return false;
    let lo = 0, hi = reg.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (reg[mid]! < n) lo = mid + 1; else hi = mid; }
    if (lo < reg.length && (reg[lo] === n || reg[lo]!.startsWith(n + " "))) return true;
    return lo + 1 < reg.length && reg[lo + 1]!.startsWith(n + " ");
  }
  /** ok | remote | no-sponsorship | sponsors | sponsor-register | h1b-lottery | likely | unknown */
  tag(company: string, location: string, description: string): string {
    const cs = Visa.countriesIn(location);
    if (this.authorizedFor(location)) return "ok";
    if (cs.length === 0 && search("remote|anywhere", location)) return "remote";
    if (!this.needsSponsorship) return "ok";
    if (search(NEG, description)) return "no-sponsorship";
    if (search(POS, description)) return "sponsors";
    if ((cs.includes("united kingdom") && this.inRegister(company, "uk")) || (cs.includes("netherlands") && this.inRegister(company, "nl"))) return "sponsor-register";
    if (cs.includes("united states")) return "h1b-lottery";
    if (cs.some((c) => EASY.has(c))) return "likely";
    return "unknown";
  }
}
