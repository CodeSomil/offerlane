// Review on the web (P3.6): approved roles get a tailoring draft (the app's AI, the resume as-is, or Copy to Claude),
// then the Mac's Gate 2 review screen: every change shown against the original, the Guard on every text, approve or redo.
// Nothing is sent anywhere from here; downloads stay on this device.
import { useEffect, useState } from "react";
import { answersMarkdown, applyPlan, candidateBrief, guardCheck, planSource, handoffText, parseHandoff, personalDetails, planFromReview, rejections, review, searchConfig,
  tailorPlan, tailorRequest, UNREADABLE, type Profile, type ResumeContent, type ResumeVersion, type ReviewData, type TailorPlan } from "@offerlane/core";
import { askJSON, readyAI } from "./ai.js";
import { loadProfile, loadResume } from "./data.js";
import { download, guardAIPlan, resumeMarkdown } from "./draft.js";
import { loadSaved, MoveError, saveDraft, setStatus, type Saved } from "./jobs.js";

const isObject = (v: unknown) => v !== null && typeof v === "object" && !Array.isArray(v);
const storageError = (err: unknown) => (err instanceof MoveError ? err.message : "This browser wouldn't store it. Allow site storage and try again.");
type Msg = { ok: boolean; text: string };

export function Review() {
  const [saved, setSaved] = useState<Record<string, Saved>>();
  const [resume, setResume] = useState<ResumeVersion>();
  const [prof, setProf] = useState<Profile>();
  const [open, setOpen] = useState<string>();
  const [msg, setMsg] = useState<Msg>();
  const [busy, setBusy] = useState<string>();
  useEffect(() => {
    Promise.all([loadSaved(), loadResume(), loadProfile()]).then(([s, r, p]) => { setSaved(s); setResume(r); setProf(p); }, () => setSaved({}));
  }, []);

  if (!saved) return <p className="muted">Loading…</p>;
  const all = Object.values(saved).sort((a, b) => b.updated.localeCompare(a.updated));
  const todo = all.filter((s) => s.status === "tailoring"), drafts = all.filter((s) => s.status === "review");
  const current = open ? saved[open] : undefined;
  const status = <p role={msg && !msg.ok ? "alert" : "status"} className={msg ? (msg.ok ? "muted" : "bad") : undefined}>{msg?.text}</p>;
  if (!resume || !prof) return <p className="card">Add your resume first (<a href="#/resumes">Profile → Resumes</a>); tailoring uses only the facts in it.</p>;
  if (current?.status === "review" && current.plan)
    return <Draft s={current} v={resume} stored={setSaved} done={(next, m) => { setSaved(next); setOpen(undefined); setMsg(m); }} back={() => { setOpen(undefined); setMsg(undefined); }} />;

  const brief = () => candidateBrief(resume.content, [resume], prof, searchConfig({}), false);
  async function draft(s: Saved, how: () => Promise<{ plan: TailorPlan; notes?: string[] }>, note: (notes: string[]) => string, answers = (p: TailorPlan) => answersMarkdown(p, s.job.company)) {
    setBusy(s.job.id); setMsg({ ok: true, text: `Tailoring ${s.job.title} at ${s.job.company}…` });
    try {
      const r = await how(), p = { ...r.plan, variant: resume!.name };
      try { setSaved(await saveDraft(s.job.id, p, answers(p))); setMsg({ ok: true, text: note(r.notes ?? []) }); } catch (err) { setMsg({ ok: false, text: storageError(err) }); }
    } catch (err) { setMsg({ ok: false, text: err instanceof Error ? err.message : "Tailoring failed. Try again." }); }
    setBusy(undefined);
  }
  const tailor = (s: Saved) => draft(s, async () => {
    const c = await readyAI();
    if (!c) throw new Error("Connect an AI first (Profile → Connect AI), or use Copy to Claude.");
    const r = tailorRequest(s.job, resume, brief());
    return guardAIPlan(tailorPlan(await askJSON(c, { system: r.bank, prompt: r.prompt, smart: true, maxTokens: 3500 }, isObject) as Parameters<typeof tailorPlan>[0]), resume);
  }, (notes) => `Draft ready for ${s.job.company}. Open it below to check every change.` + (notes.length ? ` The Guard removed: ${notes.join("; ")}.` : ""));
  const asIs = (s: Saved) => draft(s, async () => ({ plan: { ...tailorPlan({}), changes_summary: "Your resume as-is." } }),
    () => `Using your resume as-is for ${s.job.company}.`, (p) => s.answers ?? answersMarkdown(p, s.job.company));

  return (
    <div className="stack">
      {status}
      <section className="card" aria-labelledby="r-drafts">
        <h2 id="r-drafts">Ready for your review <span className="muted">{drafts.length}</span></h2>
        {drafts.length === 0 ? <p className="muted">No drafts yet.</p> : (
          <ul className="list">{drafts.map((s) => (
            <li key={s.job.id} className="row"><span><strong>{s.job.title}</strong> <span className="muted">{s.job.company}</span></span>
              <button onClick={() => setOpen(s.job.id)} aria-label={`Review ${s.job.title} at ${s.job.company}`}>Review</button></li>
          ))}</ul>
        )}
      </section>
      <section className="card" aria-labelledby="r-todo">
        <h2 id="r-todo">Approved, waiting for tailoring <span className="muted">{todo.length}</span></h2>
        {todo.length === 0 ? <p className="muted">Approve roles in <a href="#/find">Discover</a> to tailor your resume for them.</p> : (
          <ul className="list">{todo.map((s) => (
            <li key={s.job.id} className="stack">
              <span><strong>{s.job.title}</strong> <span className="muted">{s.job.company}{s.job.tailor_note ? ` · note: ${s.job.tailor_note}` : ""}</span></span>
              <div className="row">
                <button disabled={busy !== undefined} onClick={() => void tailor(s)} aria-label={`Tailor for ${s.job.title} at ${s.job.company}`}>Tailor</button>
                <button className="secondary" disabled={busy !== undefined} onClick={() => void asIs(s)} aria-label={`Use my resume as-is for ${s.job.title} at ${s.job.company}`}>Use my resume as-is</button>
              </div>
              <Claude s={s} v={resume} text={() => handoffText(s.job, resume, brief(), personalDetails(prof, [resume]))} busy={busy !== undefined}
                save={(p) => draft(s, async () => ({ plan: { ...p, changes_summary: "Drafted with Claude. " + p.changes_summary } }), () => `Claude's draft for ${s.job.company} passed the Guard. Open it below.`)}
                fail={(text) => setMsg({ ok: false, text })} />
            </li>
          ))}</ul>
        )}
      </section>
    </div>
  );
}

/** Route B (D1): the user pastes the text into their own Claude chat and pastes the reply back. Refused whole if the Guard objects. */
function Claude({ s, v, text, busy, save, fail }: { s: Saved; v: ResumeVersion; text: () => string; busy: boolean; save: (p: TailorPlan) => Promise<void>; fail: (m: string) => void }) {
  const [shown, setShown] = useState<string>();
  const [reply, setReply] = useState("");
  const [copied, setCopied] = useState(false);
  const id = `claude-${s.job.id}`;
  if (shown === undefined) return <button className="secondary" onClick={() => setShown(text())} aria-label={`Copy to Claude for ${s.job.title} at ${s.job.company}`}>Copy to Claude…</button>;
  return (
    <div className="stack">
      <label htmlFor={`${id}-out`}>1. Paste this into your Claude chat (your email, phone and address are left out)</label>
      <textarea id={`${id}-out`} readOnly rows={4} value={shown} />
      <button className="secondary" onClick={() => navigator.clipboard.writeText(shown).then(() => setCopied(true), () => fail("The browser blocked copying. Select the text and copy it yourself."))}>{copied ? "Copied" : "Copy"}</button>
      <label htmlFor={`${id}-in`}>2. Paste Claude's whole reply here</label>
      <textarea id={`${id}-in`} rows={4} value={reply} onChange={(e) => setReply(e.target.value)} />
      <button disabled={busy || reply.trim() === ""} onClick={() => {
        const p = parseHandoff(reply);
        if (!p) { fail(UNREADABLE); return; }
        const bad = rejections(p, v);
        if (bad.length > 0) { fail("Nothing was saved. The Guard rejected: " + bad.join("; ") + ". Use only facts and numbers from the resume."); return; }
        void save(p);
      }}>Check and save draft</button>
    </div>
  );
}

/** Gate 2: headline, summary and bullets against the original, reorder/remove/add, the Guard's notes, answers.md, then approve. */
// What the reader sees of a review: a save whose result differs from this put back a change the Guard rejected.
const shown = (d: ReviewData) => JSON.stringify([d.headline.trim(), d.summary.trim(), d.groups.map((g) => g.bullets.map((b) => [b.id, b.text.trim()]))]);

function Draft({ s, v, stored, done, back }: { s: Saved; v: ResumeVersion; stored: (next: Record<string, Saved>) => void; done: (next: Record<string, Saved>, m: Msg) => void; back: () => void }) {
  const plan = s.plan!;
  const [data, setData] = useState<ReviewData>(() => review(plan, v));
  const [answers, setAnswers] = useState(s.answers ?? answersMarkdown(plan, s.job.company));
  const [note, setNote] = useState(s.job.tailor_note);
  const [msg, setMsg] = useState<Msg>();
  const [cur, setCur] = useState(plan);
  const [base, setBase] = useState(() => JSON.stringify([data, answers]));
  const dirty = JSON.stringify([data, answers]) !== base;
  const leave = (f: () => void) => { if (!dirty || confirm("Discard your unsaved edits?")) f(); };
  const content: ResumeContent = applyPlan(cur, v)[0];
  const who = `${s.job.title} at ${s.job.company}`;
  const edit = (f: (d: ReviewData) => void) => setData((d) => { const x = structuredClone(d); f(x); return x; });

  /** Saves and re-guards; `reverted` when the Guard put back the original of an edit, so Approve stops and shows why. */
  async function save(): Promise<{ reverted: boolean } | undefined> {
    const p = planFromReview(data, cur, v);
    try { stored(await saveDraft(s.job.id, p, answers)); } catch (err) { setMsg({ ok: false, text: storageError(err) }); return undefined; }
    const after = review(p, v), reverted = shown(after) !== shown(data);
    setCur(p); setData(after); setBase(JSON.stringify([after, answers]));
    // Human-typed answers.md is saved as typed (as on the Mac), but numbers the resume doesn't have are pointed out.
    const g = guardCheck(answers, planSource(v)), ans = g.ok ? "" : ` Check your cover letter and answers: ${g.warnings[0]}.`;
    setMsg(reverted ? { ok: false, text: "The Guard put back the original of a change it rejected; see Guard notes." + ans }
      : g.ok ? { ok: true, text: "Saved. The Guard checked every change again." } : { ok: false, text: "Saved." + ans });
    return { reverted };
  }
  async function move(to: string, job = s.job, m: string) {
    if (to === "ready") { const r = await save(); if (!r || r.reverted) return; }
    try { done(await setStatus(job, s.score, to), { ok: true, text: m }); } catch (err) { setMsg({ ok: false, text: storageError(err) }); }
  }

  return (
    <div className="stack">
      <button className="secondary" onClick={() => leave(back)}>← All drafts</button>
      <h2>{who}</h2>
      {cur.changes_summary && <p className="muted">{cur.changes_summary}</p>}
      <p role={msg && !msg.ok ? "alert" : "status"} className={msg ? (msg.ok ? "muted" : "bad") : undefined}>{msg?.text}</p>
      {data.warnings.length > 0 && (
        <section className="card" aria-labelledby="d-guard"><h3 id="d-guard">Guard notes</h3>
          <ul>{data.warnings.map((w) => <li key={w} className={w.includes("REJECTED") ? "bad" : undefined}>{w}</li>)}</ul></section>
      )}
      <section className="card stack" aria-labelledby="d-top"><h3 id="d-top">Headline and summary</h3>
        <label>Headline <input value={data.headline} onChange={(e) => edit((d) => { d.headline = e.target.value; })} /></label>
        {data.headline !== data.headline_original && <p className="muted">Was: {data.headline_original}</p>}
        <label>Summary <textarea rows={3} value={data.summary} onChange={(e) => edit((d) => { d.summary = e.target.value; })} /></label>
        {data.summary !== data.summary_original && <p className="muted">Was: {data.summary_original}</p>}
      </section>
      {data.groups.map((g, gi) => (
        <section key={g.g} className="card stack" aria-labelledby={`d-${g.g}`}><h3 id={`d-${g.g}`}>{g.title}</h3>
          <ol className="stack">{g.bullets.map((b, bi) => (
            <li key={b.id} className="stack">
              <label className="sr-only" htmlFor={`b-${b.id}`}>Bullet {bi + 1} in {g.title}</label>
              <textarea id={`b-${b.id}`} rows={2} value={b.text} onChange={(e) => edit((d) => { d.groups[gi]!.bullets[bi]!.text = e.target.value; })} />
              {b.text !== b.original && <p className="muted">Was: {b.original}</p>}
              <div className="row">
                <button className="secondary" disabled={bi === 0} onClick={() => edit((d) => { const l = d.groups[gi]!.bullets; [l[bi - 1], l[bi]] = [l[bi]!, l[bi - 1]!]; })} aria-label={`Move bullet ${bi + 1} in ${g.title} up`}>Up</button>
                <button className="secondary" disabled={bi === g.bullets.length - 1} onClick={() => edit((d) => { const l = d.groups[gi]!.bullets; [l[bi], l[bi + 1]] = [l[bi + 1]!, l[bi]!]; })} aria-label={`Move bullet ${bi + 1} in ${g.title} down`}>Down</button>
                {b.text !== b.original && <button className="secondary" onClick={() => edit((d) => { d.groups[gi]!.bullets[bi]!.text = b.original; })} aria-label={`Restore bullet ${bi + 1} in ${g.title}`}>Restore</button>}
                <button className="secondary" onClick={() => edit((d) => { d.groups[gi]!.bullets.splice(bi, 1); d.unused.push({ id: b.id, text: b.original, group: g.g }); })} aria-label={`Remove bullet ${bi + 1} in ${g.title}`}>Remove</button>
              </div>
            </li>
          ))}</ol>
          {data.unused.filter((u) => u.group === g.g).map((u) => (
            <div key={u.id} className="row"><span className="muted">Not used: {u.text}</span>
              <button className="secondary" onClick={() => edit((d) => { d.groups[gi]!.bullets.push({ id: u.id, text: u.text, original: u.text }); d.unused = d.unused.filter((x) => x.id !== u.id); })} aria-label={`Add back: ${u.text}`}>Add</button></div>
          ))}
        </section>
      ))}
      <section className="card stack" aria-labelledby="d-ans"><h3 id="d-ans">Cover letter and answers</h3>
        <label className="sr-only" htmlFor="d-answers">answers.md</label>
        <textarea id="d-answers" rows={10} value={answers} onChange={(e) => setAnswers(e.target.value)} />
      </section>
      <div className="row">
        <button onClick={() => void save()}>Save edits</button>
        <button className="secondary" onClick={() => download("resume.md", resumeMarkdown(content))}>Download resume.md</button>
        <button className="secondary" onClick={() => download("answers.md", answers)}>Download answers.md</button>
        <button className="secondary" onClick={() => window.print()}>Print / Save as PDF</button>
      </div>
      <p className="muted">The PDF here is your browser's print of the saved draft, not the Mac app's typeset PDF. Save edits first.</p>
      <div className="row">
        <button onClick={() => void move("ready", s.job, `Approved ${who}. It's ready to apply.`)}>Approve</button>
        <label>Note for a redo <input value={note} onChange={(e) => setNote(e.target.value)} /></label>
        <button className="secondary" onClick={() => leave(() => void move("tailoring", { ...s.job, tailor_note: note.trim() }, `${who} is back in tailoring${note.trim() ? " with your note" : ""}.`))}>Redo with note</button>
        <button className="secondary" onClick={() => { if (confirm(`Decline ${who}?` + (dirty ? " Your unsaved edits will be lost." : ""))) void move("declined", s.job, `Declined ${who}.`); }}>Decline this role</button>
      </div>
      <article className="print-only" aria-hidden="true">
        <h1>{content.name}</h1>
        <p>{[content.email, content.phone, content.location].filter((x) => x !== "").join(" · ")}</p>
        {content.headline && <p><strong>{content.headline}</strong></p>}
        {content.summary && <p>{content.summary}</p>}
        {[...content.experience, ...content.projects].map((x) => (
          <section key={x.id}><h2>{[x.title || x.name, x.company].filter((y) => y !== "").join(", ")}</h2>
            <p>{[x.location, x.dates].filter((y) => y !== "").join(" · ")}</p>
            <ul>{x.bullets.map((b) => <li key={b.id}>{b.text}</li>)}</ul></section>
        ))}
        {content.skills.length > 0 && <section><h2>Skills</h2><ul>{content.skills.map((k) => <li key={k.label}><strong>{k.label}:</strong> {k.items}</li>)}</ul></section>}
        {content.education.length > 0 && <section><h2>Education</h2><ul>{content.education.map((e, i) => <li key={i}>{[e.degree, e.school, e.dates].filter((y) => y !== "").join(", ")}</li>)}</ul></section>}
      </article>
    </div>
  );
}
