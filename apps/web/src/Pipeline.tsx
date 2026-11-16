// Pipeline (P3.5c): the Mac board on the web. Submitted applications by stage, age and stale hints, a template next step,
// drag and drop between stages plus a "Move to" menu (keyboard and screen readers). Every move goes through the ported StateMachine.
import { useEffect, useState } from "react";
import { canMove, IN_FLIGHT, isStale, nextStep, pipelineAge, STATUS_TITLE, TRACKED, type JobStatus } from "@offerlane/core";
import { loadSaved, MoveError, setStatus, type Saved } from "./jobs.js";

const OUT: JobStatus[] = ["rejected", "withdrawn"];
export function Pipeline() {
  const [saved, setSaved] = useState<Record<string, Saved>>();
  const [status, setMsg] = useState<{ ok: boolean; text: string }>();
  const [over, setOver] = useState<string>();
  useEffect(() => { loadSaved().then(setSaved, () => setSaved({})); }, []);

  async function move(s: Saved, to: string) {
    if (!canMove(s.status, to)) { setMsg({ ok: false, text: `A role can't move from ${STATUS_TITLE[s.status as JobStatus] ?? s.status} to ${STATUS_TITLE[to as JobStatus] ?? to}.` }); return; }
    try { setSaved(await setStatus(s.job, s.score, to)); setMsg({ ok: true, text: `Moved ${s.job.title} at ${s.job.company} to ${STATUS_TITLE[to as JobStatus]}.` }); }
    catch (err) { setMsg({ ok: false, text: err instanceof MoveError ? err.message : "This browser wouldn't store it. Allow site storage and try again." }); }
  }

  if (!saved) return <p className="muted">Loading…</p>;
  const all = Object.values(saved), tracked = all.filter((s) => (TRACKED as readonly string[]).includes(s.status));
  const waiting = all.filter((s) => IN_FLIGHT.includes(s.status as JobStatus)).length, quiet = tracked.filter((s) => isStale(s.status, s.updated)).length;
  return (
    <div className="stack">
      <p className="muted">
        {tracked.length} application{tracked.length === 1 ? "" : "s"}{quiet > 0 ? ` · ${quiet} need${quiet === 1 ? "s" : ""} a follow-up` : ""}
        {waiting > 0 && <> · {waiting} approved role{waiting === 1 ? "" : "s"} not sent yet, see <a href="#/review">Review</a></>}
      </p>
      <p role={status && !status.ok ? "alert" : "status"} className={status ? (status.ok ? "muted" : "bad") : undefined}>{status?.text}</p>
      {tracked.length === 0 ? <p className="card">No applications yet. Approve roles in <a href="#/find">Discover</a>; they arrive here once you've applied.</p> : (
        <div className="board">
          {TRACKED.map((col) => {
            const cards = tracked.filter((s) => s.status === col).sort((a, b) => b.updated.localeCompare(a.updated));
            return (
              <section key={col} aria-labelledby={`col-${col}`} className={`column${cards.length === 0 ? " empty" : ""}${over === col ? " over" : ""}`}
                onDragOver={(e) => { e.preventDefault(); setOver(col); }} onDragLeave={() => setOver(undefined)}
                onDrop={(e) => { e.preventDefault(); setOver(undefined); const s = saved[e.dataTransfer.getData("text/plain")]; if (s && s.status !== col) void move(s, col); }}>
                <h2 id={`col-${col}`}>{STATUS_TITLE[col]} <span className="muted">{cards.length}</span></h2>
                <ul>
                  {cards.map((s) => {
                    const age = pipelineAge(s.updated), stale = isStale(s.status, s.updated);
                    return (
                      <li key={s.job.id} className={`card pcard${col === "offer" ? " offer" : ""}`} draggable onDragStart={(e) => e.dataTransfer.setData("text/plain", s.job.id)}>
                        <strong>{s.job.title}</strong>
                        <span className="muted">{s.job.company} · {age === 0 ? "today" : `${age} day${age === 1 ? "" : "s"}`}</span>
                        {stale && <span className="bad">Quiet for {age} days</span>}
                        <span>{nextStep(s.status, s.updated)}</span>
                        <label className="move">Move {s.job.title} to
                          <select value="" onChange={(e) => { if (e.target.value) void move(s, e.target.value); }}>
                            <option value="">Choose a stage…</option>
                            {[...TRACKED, ...OUT].filter((t) => t !== s.status && canMove(s.status, t)).map((t) => <option key={t} value={t}>{STATUS_TITLE[t]}</option>)}
                          </select>
                        </label>
                      </li>
                    );
                  })}
                </ul>
              </section>
            );
          })}
        </div>
      )}
    </div>
  );
}
