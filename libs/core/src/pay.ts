// Offer/Offers.swift PayRange.parse, ported line for line.
import { prefix, rx, search } from "./text.js";

export type Period = "year" | "month" | "day" | "hour";
export type PayRange = { currency: string; low: number; high: number; period: Period };
/** Period.per: " a year", " an hour", … */
export const per = (p: Period) => (p === "hour" ? " an hour" : ` a ${p}`);

const CURRENCY = "(CA\\$|AU\\$|US\\$|C\\$|A\\$|USD|GBP|EUR|INR|CAD|AUD|[$£€₹])";
const SYMBOL: Record<string, string> = { "CA$": "C$", "AU$": "A$", "US$": "$", USD: "$", GBP: "£", EUR: "€", INR: "₹", CAD: "C$", AUD: "A$" };
const AMOUNT = "([0-9]{1,3}(?:,[0-9]{2})*(?:,[0-9]{3})+|[0-9]{1,3}(?:\\.[0-9]{3})+(?![0-9])|[0-9]+(?:\\.[0-9]+)?)(?:\\s?([kK]|[lL]akhs?|LPA|lpa|L|[cC]r(?:ores?)?)(?:pa|[A-Z]{3})?(?![A-Za-z0-9]))?";
const PATTERN = `${CURRENCY}\\s?${AMOUNT}\\s*(?:-|–|—|to)\\s*(?:[A-Z]{3}\\s?)?(?:CA\\$|AU\\$|US\\$|C\\$|A\\$|[$£€₹])?\\s?${AMOUNT}`;

const num = (s: string | undefined) => {
  if (s === undefined) return null;
  const t = (search("^[0-9]{1,3}(\\.[0-9]{3})+$", s) ? s.replaceAll(".", "") : s).replaceAll(",", "");
  const n = Number(t);
  return t !== "" && Number.isFinite(n) ? n : null;
};
/** Lakh and crore are rupee units only. */
const unit = (s: string, cur: string) => { const c = s.toLowerCase()[0]; return c === "k" ? 1e3 : cur !== "₹" ? 1 : c === "c" ? 1e7 : 1e5; };
function bounds(p: Period, cur: string): [number, number] {
  const [lo, hi]: [number, number] = p === "year" ? [10_000, 2_000_000] : p === "month" ? [500, 30_000] : p === "day" ? [50, 5_000] : [7, 500];
  return cur === "₹" ? [lo * 10, hi * 50] : [lo, hi];
}

/** Every range in `text` that passes the sanity bounds; funding, bonuses and single figures are ignored. */
// SHORTCUT: a symbol after the number ("45.000 €") and space thousands ("45 000") aren't read; add them if European postings miss pay.
export function parsePay(text: string): PayRange[] {
  const r = rx(PATTERN);
  if (!r) return [];
  const out: PayRange[] = [];
  for (const m of text.matchAll(new RegExp(r.source, r.flags + "g"))) {
    const cur = m[1], a = num(m[2]), b = num(m[4]);
    if (cur === undefined || a === null || b === null) continue;
    const sym = SYMBOL[cur] ?? cur;
    const ua = m[3] === undefined ? null : unit(m[3], sym), ub = m[5] === undefined ? null : unit(m[5], sym);
    const low = a * (ua ?? (a < 1000 ? ub ?? 1 : 1)), high = b * (ub ?? 1); // "$120-150k", "₹12 - 18 LPA"
    const end = m.index + m[0].length, after = prefix(text.slice(end, end + 50), 25); // slice first: prefix copies its input
    // The period word must be on the same line; a figure only a year fits stays a year ("$120k - $150k a day-one start").
    const said: Period = search("^[ \\t]*(/\\s?h(ou)?r|per hour|an hour|hourly)", after) ? "hour"
      : search("^[ \\t]*(/\\s?day|per day|a day|daily)", after) ? "day"
      : search("^[ \\t]*(/\\s?mo(nth)?|per month|a month|monthly|p\\.?m\\.?(?![a-z]))", after) ? "month" : "year";
    const fits = (p: Period) => { const [lo, hi] = bounds(p, sym); return low >= lo && low <= hi; };
    const period: Period = said !== "year" && !fits(said) && fits("year") ? "year" : said;
    const ok = low <= high && high <= low * 3 && fits(period);
    if (ok) out.push({ currency: sym, low, high, period });
  }
  return out;
}
