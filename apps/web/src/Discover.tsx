// Discover (P3.5b): search the shared index, rank on this device, triage with J/K (move), A (approve), D (decline).
import { useEffect, useRef, useState } from "react";
import { parsePay, type Profile, type ResumeVersion } from "@offerlane/core";
import { loadProfile, loadResume } from "./data.js";
import { notify } from "./notify.js";
import { JobsError, loadSaved, MoveError, payLabel, rank, searchJobs, setStatus, toJob, VISA_LABEL, type Match, type Saved } from "./jobs.js";

export function Discover() {
  const [me, setMe] = useState<{ r: ResumeVersion; p: Profile } | null>();
  const [q, setQ] = useState("");
  const [matches, setMatches] = useState<Match[]>();
  const [saved, setSaved] = useState<Record<string, Saved>>({});
  const [status, setStatus_] = useState<{ ok: boolean; text: string }>();
  const [busy, setBusy] = useState(false);
  const cards = useRef<(HTMLElement | null)[]>([]);
  const search_ = useRef<HTMLInputElement>(null);
  useEffect(() => {
    Promise.all([loadResume(), loadProfile(), loadSaved()]).then(([r, p, s]) => {
      setSaved(s); setMe(r ? { r, p } : null); if (r) setQ(r.content.suggested_titles[0] ?? p.work.current_title);
    }, () => setMe(null));
  }, []);

  async function search(e?: React.FormEvent) {
    e?.preventDefault();
    if (!me || q.trim() === "") return;
    setBusy(true); setStatus_(undefined);
    try {
      const m = rank((await searchJobs(q.trim())).map(toJob), me.r.content, me.p);
      setMatches(m); setStatus_({ ok: true, text: m.length === 0 ? "No jobs found. Try a broader title." : `${m.length} jobs, best match first.` });
      if (m.length > 0) notify("New matches", `${m.length} ${q.trim()} jobs, best match first.`);
    } catch (err) { setMatches(undefined); setStatus_({ ok: false, text: err instanceof JobsError ? err.message : "The search failed." }); }
    setBusy(false);
  }
  useEffect(() => { if (me && q !== "" && matches === undefined) void search(); }, [me]);  // eslint-disable-line react-hooks/exhaustive-deps

  // Jobs saved with the browser extension ("found") come first, ranked the same way.
  const browser = me ? rank(Object.values(saved).filter((s) => s.status === "found").map((s) => s.job), me.r.content, me.p) : [];
  const open = [...browser, ...(matches ?? []).filter((m) => !saved[m.job.id])];
  async function act(m: Match, s: "tailoring" | "declined") {
    const i = open.indexOf(m);
    try { setSaved(await setStatus(m.job, m.score, s)); }
    catch (err) { setStatus_({ ok: false, text: err instanceof MoveError ? err.message : "This browser wouldn't store it. Allow site storage and try again." }); return; }
    setStatus_({ ok: true, text: s === "declined" ? `Declined ${m.job.title} at ${m.job.company}. It won't come back in later searches.` : `Approved ${m.job.title} at ${m.job.company}. It's in Pipeline.` });
    // Keep the keyboard on the next card; after the last one, on the search field.
    requestAnimationFrame(() => (open.length > 1 ? cards.current[Math.min(i, open.length - 2)] : search_.current)?.focus());
  }
  function keys(e: React.KeyboardEvent, i: number) {
    if (e.target !== e.currentTarget || e.metaKey || e.ctrlKey || e.altKey) return;  // plain keys on the card itself only
    const k = e.key.toLowerCase();
    if (k === "j" || k === "k") { e.preventDefault(); cards.current[Math.max(0, Math.min(open.length - 1, i + (k === "j" ? 1 : -1)))]?.focus(); }
    else if (k === "a" || k === "d") { e.preventDefault(); void act(open[i]!, k === "a" ? "tailoring" : "declined"); }
  }

  if (me === undefined) return <p className="muted">Loading…</p>;
  if (me === null) return <p>Add your resume first: <a href="#/resumes">Profile → Resumes</a>. Discover ranks jobs against it.</p>;
  return (
    <div className="stack">
      <form className="row" onSubmit={search} role="search">
        <label>Job title <input ref={search_} value={q} onChange={(e) => setQ(e.target.value)} /></label>
        <button type="submit" disabled={busy}>{busy ? "Searching…" : "Search"}</button>
      </form>
      <p className="muted">Ranked on this device from your resume; nothing about you is sent with the search except the title. Keys: J/K to move, A approve, D decline.</p>
      <p role={status && !status.ok ? "alert" : "status"} className={status ? (status.ok ? "muted" : "bad") : undefined}>{status?.text}</p>
      <ul className="matches" aria-label="Matches">
        {open.map((m, i) => {
          const pay = parsePay(m.job.description)[0];
          return (
            <li key={m.job.id}>
              <article className="card match" tabIndex={0} ref={(el) => { cards.current[i] = el; }} onKeyDown={(e) => keys(e, i)} aria-labelledby={`m-${m.job.id}`}>
                <span className="monogram" aria-hidden="true">{m.job.company.slice(0, 1).toUpperCase()}</span>
                <div className="grow">
                  <h2 id={`m-${m.job.id}`}><a href={m.job.url} target="_blank" rel="noreferrer noopener">{m.job.title}</a></h2>
                  <p className="muted">{m.job.company} · {m.job.location}{m.job.posted ? ` · posted ${m.job.posted}` : ""}</p>
                  {m.why.length > 0 && <p>Why it fits: {m.why.join(", ")}</p>}
                  <p className="chips">
                    {pay && <span className="chip">{payLabel(pay)}</span>}
                    <span className={m.job.visa === "no-sponsorship" ? "chip bad" : "chip"}>{VISA_LABEL[m.job.visa] ?? m.job.visa}</span>
                  </p>
                </div>
                <span className="score" aria-label={`Match ${Math.round(m.score)} of 100`}>{Math.round(m.score)}</span>
                <div className="actions">
                  <button type="button" onClick={() => act(m, "tailoring")} aria-label={`Approve ${m.job.title} at ${m.job.company}`}>Approve</button>
                  <button type="button" className="secondary" onClick={() => act(m, "declined")} aria-label={`Decline ${m.job.title} at ${m.job.company}`}>Decline</button>
                </div>
              </article>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
