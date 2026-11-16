// Approved roles on their way out (v4 P4.3d): open the posting, and once you've sent it yourself, put it on the board.
// Inside the Windows app, "Fill in application" opens the apply window and fills the form; it never submits (the human does).
import { useState } from "react";
import { canMove, parseAnswers, STATUS_TITLE, type JobStatus, type OutcomeKind, type Profile } from "@offerlane/core";
import { MoveError, setStatus, type Saved } from "./jobs.js";
import { notify } from "./notify.js";
import { platform } from "./platform.js";

export const OUTGOING: readonly string[] = ["ready", "applying", "account", "needs_you", "prefilled"];
// "applied" means the page text looked like a confirmation; only the human's "I've submitted it" records an application.
const AFTER: Record<OutcomeKind, JobStatus> = { applied: "prefilled", prefilled: "prefilled", account: "account", needsYou: "needs_you" };
let filling = false;  // one fill at a time, even if Review is left and opened again while the apply window works
type Msg = { ok: boolean; text: string };

/** Moves a role along `path`, skipping steps it's already at; returns the stored set after the last move. */
async function advance(s: Saved, path: string[]) {
  let all: Record<string, Saved> | undefined, cur = s;
  for (const to of path) if (cur.status !== to) { all = await setStatus(cur.job, cur.score, to); cur = all[cur.job.id]!; }
  return all;
}

export function Ready({ roles, profile, stored, say }: { roles: Saved[]; profile: Profile; stored: (all: Record<string, Saved>) => void; say: (m: Msg) => void }) {
  const [busyHere, setBusy] = useState(false);
  const busy = busyHere || filling;
  const fill = platform.fill;
  const fail = (err: unknown) => say({ ok: false, text: err instanceof MoveError ? err.message : err instanceof Error ? err.message : "That didn't work. Try again." });

  async function submitted(s: Saved) {
    const who = `${s.job.title} at ${s.job.company}`;
    setBusy(true);
    try { const all = await advance(s, canMove(s.status, "applied") ? ["applied"] : ["applying", "applied"]); if (all) stored(all); say({ ok: true, text: `Moved ${who} to Applied.` }); }
    catch (err) { fail(err); }
    setBusy(false);
  }
  async function fillIn(s: Saved, approve: boolean) {
    if (!fill || filling) return;
    filling = true; setBusy(true); say({ ok: true, text: `Filling in ${s.job.title} at ${s.job.company}. Watch the apply window.` });
    try {
      const applying = await advance(s, ["applying"]);
      if (applying) stored(applying);
      const r = await fill(s.job, profile, parseAnswers(s.answers ?? ""), approve);
      stored((await advance({ ...s, status: "applying" }, [AFTER[r.kind]]))!);
      say({ ok: r.kind !== "needsYou", text: r.message });
      notify(`${s.job.company}: ${r.kind === "prefilled" ? "ready for you to submit" : "needs you"}`, r.message);
    } catch (err) { fail(err); }
    filling = false; setBusy(false);
  }

  return (
    <section className="card" aria-labelledby="r-ready">
      <h2 id="r-ready">Ready to apply <span className="muted">{roles.length}</span></h2>
      {roles.length === 0 ? <p className="muted">Approve a draft below and it comes here.</p> : (
        <ul className="list">{roles.map((s) => {
          const who = `${s.job.title} at ${s.job.company}`, url = s.job.apply_url || s.job.url;
          return (
            <li key={s.job.id} className="stack">
              <span><strong>{s.job.title}</strong> <span className="muted">{s.job.company} · {STATUS_TITLE[s.status as JobStatus] ?? s.status}</span></span>
              <div className="row">
                {fill && url && <button disabled={busy} onClick={() => void fillIn(s, false)} aria-label={`Fill in application for ${who}`}>Fill in application</button>}
                {fill && url && s.status === "account" && <button className="secondary" disabled={busy} onClick={() => void fillIn(s, true)} aria-label={`Allow an account for ${s.job.company} and continue`}>Allow an account for {s.job.company}</button>}
                {url && <a href={url} target="_blank" rel="noreferrer noopener" aria-label={`Open the posting for ${who}`}>Open the posting</a>}
                <button className="secondary" disabled={busy} onClick={() => void submitted(s)} aria-label={`I've submitted it: ${who}`}>I've submitted it</button>
              </div>
            </li>
          );
        })}</ul>
      )}
      <p className="muted">{fill
        ? "Offerlane fills the form in its apply window and stops before Submit. Check every page, attach your resume PDF, then submit it yourself."
        : "Apply on the employer's site. The browser extension shows your answers beside the form to copy."}</p>
    </section>
  );
}
