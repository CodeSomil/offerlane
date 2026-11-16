// tokens.css has [data-theme="light"|"dark"]; "system" follows prefers-color-scheme live.
export type Theme = "system" | "light" | "dark";
const media = window.matchMedia("(prefers-color-scheme: dark)");  // one list, so a later choice can remove the "system" listener
export function savedTheme(): Theme {
  try { const t = localStorage.getItem("theme"); return t === "light" || t === "dark" ? t : "system"; } catch { return "system"; }
}
export function applyTheme(t: Theme) {
  try { if (t === "system") localStorage.removeItem("theme"); else localStorage.setItem("theme", t); } catch { /* private window: per-visit only */ }
  const set = () => { document.documentElement.dataset.theme = t === "system" ? (media.matches ? "dark" : "light") : t; };
  media.onchange = t === "system" ? set : null;
  set();
}
