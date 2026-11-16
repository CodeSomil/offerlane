// Injected into the open tab by chrome.scripting.executeScript (activeTab), so it must be self-contained: no imports and
// no outer variables. It ONLY READS the page: the labels and field list come from App/Resources/autofill.js
// (lab, grp, collect) with every write removed (no data-ja marks, no values, no clicks). test/source.test.ts enforces that.
import type { PageInfo } from "@offerlane/core";

/** `key` is the HTML name (else id): radios in one group share it. */
export type PageField = { type: string; label: string; name: string; key: string; group: string; options: string[] | null };
export type Page = PageInfo & { fields: PageField[] };

export function readPage(): Page {
  const docs = (): Document[] => {
    const out = [document];
    document.querySelectorAll("iframe").forEach((f) => { try { if (f.contentDocument?.body) out.push(f.contentDocument); } catch { /* another site's frame */ } });
    return out;
  };
  const txt = (n: Element | null | undefined) => ((n as HTMLElement | null)?.innerText || n?.textContent || "").trim();
  const vis = (e: HTMLInputElement) => { const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    return e.type === "file" || (r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none"); };
  const lab = (e: HTMLInputElement) => {
    const d = e.ownerDocument; let t = "";
    if (e.id) { const l = d.querySelector(`label[for="${CSS.escape(e.id)}"]`); if (l) t = txt(l); }
    if (!t && e.getAttribute("aria-labelledby")) t = e.getAttribute("aria-labelledby")!.split(" ").map((x) => txt(d.getElementById(x))).join(" ");
    if (!t) t = e.getAttribute("aria-label") || "";
    if (!t) { const l = e.closest("label"); if (l) t = txt(l); }
    if (!t) { let p = e.parentElement; for (let k = 0; k < 5 && p && !t; k++, p = p.parentElement) {
      const l = p.querySelector("label,legend,[class*=label]"); if (l && !l.contains(e) && !l.querySelector("input,textarea,select")) t = txt(l); } }
    return (t || e.placeholder || e.name || "").replace(/\s+/g, " ").slice(0, 300);
  };
  const grp = (e: HTMLInputElement) => {
    const f = e.closest("fieldset"); if (f?.querySelector("legend")) return txt(f.querySelector("legend"));
    let p = e.parentElement;
    for (let k = 0; k < 6 && p; k++, p = p.parentElement) {
      const q = p;
      const c = [...q.querySelectorAll("label,legend,[class*=label],[class*=question],p,span")].find((n) => !n.contains(e) && !n.querySelector("input") && !n.closest("label")
        && txt(n).length > 3 && q.querySelectorAll("input[type=radio],input[type=checkbox]").length > 1);
      if (c) return txt(c).slice(0, 300);
    }
    return "";
  };
  const fields: PageField[] = [];
  for (const d of docs()) d.querySelectorAll<HTMLInputElement>("input,textarea,select").forEach((e) => {
    const ty = (e.tagName === "INPUT" ? (e.type || "text") : e.tagName).toLowerCase();
    if (["hidden", "submit", "button", "search", "image", "reset", "password"].includes(ty) || !vis(e) || e.disabled || (e.readOnly && ty !== "file")
        || (ty !== "file" && e.tabIndex < 0 && e.getAttribute("role") !== "combobox")) return;
    if (/beecatcher|honeypot|hp_|trap/i.test((e.getAttribute("data-automation-id") || "") + " " + (e.name || "") + " " + (e.id || "")) || e.closest("[aria-hidden=true]")) return;
    if (fields.length >= 300) return;
    fields.push({ type: ty, label: lab(e), name: ((e.name || "") + " " + (e.id || "")).trim().slice(0, 200), key: (e.name || e.id || "").slice(0, 200), group: ["radio", "checkbox"].includes(ty) ? grp(e) : "",
      options: e.tagName === "SELECT" ? [...(e as unknown as HTMLSelectElement).options].slice(0, 300).map((o) => o.text.trim().slice(0, 200)) : null });
  });
  const ldjson = [...document.querySelectorAll('script[type="application/ld+json"]')].slice(0, 20).map((s) => (s.textContent || "").slice(0, 200_000));
  return { url: location.href, title: document.title.slice(0, 300), h1: txt(document.querySelector("h1")).slice(0, 300), ldjson, fields };
}
