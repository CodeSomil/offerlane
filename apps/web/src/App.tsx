import { useEffect, useRef, useState } from "react";
import { GROUPS, ITEMS, viewFromHash, type ViewId } from "./nav.js";
import { ConnectAI } from "./ConnectAI.js";
import { Discover } from "./Discover.js";
import { Onboarding } from "./Onboarding.js";
import { Pipeline } from "./Pipeline.js";
import { Review } from "./Review.js";
import { Settings } from "./Settings.js";
import { Today } from "./Today.js";
import { applyTheme, savedTheme, type Theme } from "./theme.js";

export function App() {
  const [view, setView] = useState<ViewId>(() => viewFromHash(location.hash));
  const [theme, setTheme] = useState<Theme>(savedTheme);
  useEffect(() => {
    const on = () => setView(viewFromHash(location.hash));
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  const item = ITEMS.find((i) => i.id === view)!;
  const h1 = useRef<HTMLHeadingElement>(null);
  const first = useRef(true);
  // Screen readers hear the new view: focus moves to its heading on every change after the first load.
  useEffect(() => { document.title = `${item.title} · Offerlane`; if (first.current) first.current = false; else h1.current?.focus(); }, [item]);

  return (
    <div className="shell">
      <a className="skip" href="#main" onClick={(e) => { e.preventDefault(); h1.current?.focus(); }}>Skip to content</a>
      <nav className="sidebar" aria-label="Offerlane">
        {GROUPS.map((g) => (
          <section key={g} aria-labelledby={`group-${g}`}>
            <h2 className="group" id={`group-${g}`}>{g}</h2>
            <ul>
              {ITEMS.filter((i) => i.group === g).map((i) => (
                <li key={i.id}><a className={i.id === view ? "nav on" : "nav"} href={`#/${i.id}`} aria-current={i.id === view ? "page" : undefined}>{i.title}</a></li>
              ))}
            </ul>
          </section>
        ))}
        <label className="theme">Appearance
          <select value={theme} onChange={(e) => { const t = e.target.value as Theme; setTheme(t); applyTheme(t); }}>
            <option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option>
          </select>
        </label>
      </nav>
      <main id="main">
        <h1 ref={h1} tabIndex={-1}>{item.title}</h1>
        {view === "home" ? <Today /> : view === "connectAI" ? <ConnectAI /> : view === "resumes" ? <Onboarding /> : view === "find" ? <Discover /> : view === "applications" ? <Pipeline /> : view === "review" ? <Review /> : view === "settings" ? <Settings />
          : <p className="muted">Coming soon on the web. Use the Mac app for {item.title} for now.</p>}
      </main>
    </div>
  );
}
