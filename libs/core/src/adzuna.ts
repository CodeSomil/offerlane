// Discovery/Adzuna.swift countries, attribution(for:) and defaultCountry, ported; the table is the Swift bundle's own file.
import table from "../../../Packages/OfferlaneCore/Sources/OfferlaneCore/Resources/adzuna_countries.json" with { type: "json" };

export const ADZUNA_COUNTRIES: readonly string[] = table.map((r) => r.code);
export const ADZUNA_ATTRIBUTION = "https://www.adzuna.co.uk";
const SITES = new Set(table.map((r) => r.site));

/** The Adzuna country site the advert's own link is on (https, `[www.]` + a known site), else ADZUNA_ATTRIBUTION. */
export function adzunaAttribution(jobURL: string): string {
  // Literal "https://", then printable ASCII without a backslash (no whitespace, BOM or IDN), so WHATWG and Foundation URL parsing (Adzuna.swift) agree.
  if (!/^https:\/\/[\x21-\x5B\x5D-\x7E]+$/u.test(jobURL)) return ADZUNA_ATTRIBUTION;
  let u: URL;
  try { u = new URL(jobURL); } catch { return ADZUNA_ATTRIBUTION; }
  const host = u.hostname.toLowerCase();
  return u.protocol === "https:" && SITES.has(host.startsWith("www.") ? host.slice(4) : host) ? "https://" + host : ADZUNA_ATTRIBUTION;
}

export function adzunaDefaultCountry(region: string | null | undefined): string {
  const l = (region ?? "").toLowerCase(), r = l === "uk" ? "gb" : l;
  return ADZUNA_COUNTRIES.includes(r) ? r : "us";
}

/** The saved country, else one from the device region, else the US. */
export const adzunaCountry = (saved: string, region: string | null | undefined) => (ADZUNA_COUNTRIES.includes(saved) ? saved : adzunaDefaultCountry(region));
