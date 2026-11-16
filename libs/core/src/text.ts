// Util/Text.swift and Util/Regex.swift, the parts the ports need.
// SHORTCUT: JS \w and \b are ASCII while ICU's are Unicode, and lengths count code points where Swift counts graphemes.
// Same results for ASCII text; only flagging and length cut-offs differ. Number matching (the Guard) uses \p{Nd} like ICU's \d.
// SHORTCUT: unescapeHTML/stripTags/collapse are also in apps/api/src/ats.ts (pinned by ats_expected.json); point the api at
// @offerlane/core when it next changes.

const cache = new Map<string, RegExp | null>();
/** Re.compile: nil (here null) for an invalid pattern, so callers fail closed like the Swift side. */
export function rx(pattern: string, flags = ""): RegExp | null {
  const key = flags + "|" + pattern;
  if (!cache.has(key)) {
    let r: RegExp | null = null;
    try { r = new RegExp(pattern, flags + "u"); } catch { r = null; }
    cache.set(key, r);
  }
  return cache.get(key) ?? null;
}
const g = (r: RegExp) => new RegExp(r.source, r.flags + "g");

/** Re.search: case-insensitive unless `ci` is false. */
export const search = (pattern: string, s: string, ci = true): boolean => rx(pattern, ci ? "i" : "")?.test(s) ?? false;

/** Re.findAll: the first group of every match if the pattern has groups, else the whole match. */
export function findAll(pattern: string, s: string, ci = false): string[] {
  const r = rx(pattern, ci ? "i" : "");
  if (!r) return [];
  const out: string[] = [];
  for (const m of s.matchAll(g(r))) { const v = m.length > 1 ? m[1] : m[0]; if (v !== undefined) out.push(v); }
  return out;
}

/** Re.first: the first group of the first match (or the whole match when there are no groups). Case-insensitive. */
export function first(pattern: string, s: string, ci = true): string | null {
  const m = rx(pattern, ci ? "i" : "")?.exec(s);
  if (!m) return null;
  return (m.length > 1 ? m[1] : m[0]) ?? null;
}

/** Re.sub with a `$1` template; case-sensitive like the Swift default. */
export const sub = (pattern: string, template: string, s: string): string => { const r = rx(pattern); return r ? s.replace(g(r), template) : s; };

/** Re.split (patterns without capture groups: JS would splice groups into the result). */
export const split = (pattern: string, s: string): string[] => { const r = rx(pattern); return r ? s.split(g(r)) : [s]; };

/** NSRegularExpression.escapedPattern. No "-": under the u flag "\-" outside a class is a syntax error. */
export const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&");
/** Foundation's `contains`: an empty needle is never found (JS `includes("")` is true). */
export const has = (hay: string, needle: string) => needle !== "" && hay.includes(needle);

/** Swift `trimmingCharacters(in: .whitespaces)`: spaces and tabs only, newlines stay. */
export const trimSpaces = (x: string) => x.replace(/^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu, "");
/** `.whitespacesAndNewlines` (Unicode White_Space). */
export const trimAll = (x: string) => x.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, "");
/** Trim a set of characters from both ends. */
export const trimChars = (x: string, chars: string) => { const c = `[${chars.replace(/[\]\\^-]/g, "\\$&")}]+`; return x.replace(new RegExp(`^${c}|${c}$`, "gu"), ""); };

/** String.count and String.prefix(n), in code points. */
export const len = (x: string) => [...x].length;
export const prefix = (x: string, n: number) => { const a = [...x]; return a.length <= n ? x : a.slice(0, n).join(""); };

// ICU's \s and Foundation's .whitespacesAndNewlines are both Unicode White_Space (JS \s adds U+FEFF and misses U+0085).
export const collapse = (x: string) => x.replace(/\p{White_Space}+/gu, " ").replace(/^ | $/g, "");
/** Text.norm: lowercase, non-alphanumerics to one space. */
export const norm = (x: string | null | undefined) => trimSpaces((x ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " "));

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
export const stripHTML = (x: string): string => collapse(stripTags(unescapeHTML(unescapeHTML(x))));

/** Swift `Double(String)`: a plain decimal number, else null. */
export const toDouble = (x: string): number | null => (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(x) ? Number(x) : null);

/** Swift's `"\(["a", "b"])"`: how a [String] prints inside a message. */
export const swiftList = (xs: string[]) => "[" + xs.map((x) => JSON.stringify(x)).join(", ") + "]";

/** Dates.ageDays: whole days from an ISO date to `now`'s day; unknown dates count as 0. Days are UTC here. */
export function ageDays(iso: string | null | undefined, now: Date = new Date()): number {
  if (!iso || len(iso) < 10) return 0;
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(prefix(iso, 10));
  if (!m) return 0;
  const d = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  const t = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  return Math.round((t - d) / 86_400_000);
}
