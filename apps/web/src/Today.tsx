// Today (P3.5d): one next action, setup readiness, this week's funnel and the interviews in progress. No AI call.
import { useEffect, useState } from "react";
import { IN_FLIGHT, isStale, STATUS_TITLE, TRACKED, type JobStatus } from "@offerlane/core";
import { readyAI } from "./ai.js";
import { loadResume } from "./data.js";
import { loadSaved, type Saved } from "./jobs.js";

type State = { ai: boolean; resume: boolean; saved: Saved[] };
const WEEK = 7 * 86_400_000;
export function Today() {
  const [s, setS] = useState<State>();
  useEffect(() => {
    Promise.all([readyAI(), loadResume().catch(() => undefined), loadSaved().catch(() => ({}))])
      .then(([ai, r, saved]) => setS({ ai: !!ai, resume: !!r, saved: Object.values(saved) }));
  }, []);
  if (!s) return <p className="muted">Loading…</p>;

  const approved = s.saved.filter((x) => x.status !== "declined" && x.status !== "found"),  // "found" = saved with the extension, not approved yet
    tracked = s.saved.filter((x) => (TRACKED as readonly string[]).includes(x.status));
  const stale = tracked.filter((x) => isStale(x.status, x.updated)).sort((a, b) => a.updated.localeCompare(b.updated));
  const steps = [
    { done: s.ai, text: "Connect an AI", href: "#/connectAI" },
    { done: s.resume, text: "Add your resume", href: "#/resumes" },
    { done: approved.length > 0, text: "Approve your first role", href: "#/find" },
  ];
  const todo = steps.find((x) => !x.done);
  const hero = todo ? { text: todo.text, href: todo.href, why: "Finish setting up so Offerlane can rank roles for you." }
    : stale[0] ? { text: `Follow up with ${stale[0].job.company}`, href: "#/applications", why: `${stale[0].job.title}: no reply for 14 days or more.` }
    : { text: "Find more roles", href: "#/find", why: "Your pipeline is up to date." };
  // SHORTCUT: the web keeps no event log yet, so "this week" counts records changed in the last 7 days by their current
  // stage (the Mac counts Analytics events); add an event log when sync (P3.7) brings the Mac's history over.
  const recent = s.saved.filter((x) => Date.now() - Date.parse(x.updated) < WEEK);
  const funnel = [
    { label: "Approved", n: recent.filter((x) => x.status !== "declined").length },
    { label: "Applied", n: recent.filter((x) => (TRACKED as readonly string[]).includes(x.status)).length },
    { label: "Interviews", n: recent.filter((x) => ["screen", "interview"].includes(x.status)).length },
    { label: "Offers", n: recent.filter((x) => x.status === "offer").length },
  ];
  const max = Math.max(1, ...funnel.map((f) => f.n));
  const interviews = tracked.filter((x) => x.status === "screen" || x.status === "interview");
  const waiting = s.saved.filter((x) => IN_FLIGHT.includes(x.status as JobStatus)).length;
  const done = steps.filter((x) => x.done).length;

  return (
    <div className="stack">
      <section className="card hero" aria-labelledby="t-next">
        <h2 id="t-next">Next</h2>
        <a className="button" href={hero.href}>{hero.text}</a>
        <p className="muted">{hero.why}</p>
      </section>
      <section className="card" aria-labelledby="t-setup">
        <h2 id="t-setup">Setup</h2>
        <p><meter min={0} max={steps.length} value={done} aria-label="Setup progress" /> {done} of {steps.length} done</p>
        <ul className="checklist">
          {steps.map((x) => <li key={x.text}>{x.done ? <span className="ok">✓ {x.text}<span className="sr"> (done)</span></span> : <a href={x.href}>{x.text}</a>}</li>)}
        </ul>
      </section>
      <section className="card" aria-labelledby="t-week">
        <h2 id="t-week">This week</h2>
        <dl className="funnel">
          {funnel.map((f) => (
            <div key={f.label}><dt>{f.label}</dt><dd><span className="bar" style={{ ["--w" as string]: `${(f.n / max) * 100}%` }} aria-hidden="true" />{f.n}</dd></div>
          ))}
        </dl>
        {waiting > 0 && <p className="muted">{waiting} approved role{waiting === 1 ? "" : "s"} not sent yet. See <a href="#/review">Review</a>.</p>}
      </section>
      <section className="card" aria-labelledby="t-int">
        <h2 id="t-int">Interviews</h2>
        {interviews.length === 0 ? <p className="muted">No interviews in progress.</p>
          : <ul>{interviews.map((x) => <li key={x.job.id}>{x.job.title} at {x.job.company} · {STATUS_TITLE[x.status as JobStatus]}</li>)}</ul>}
      </section>
    </div>
  );
}
