// The side panel: "Save this job" and copy-ready answers for the form in the open tab. It never fills or submits (D4).
import { useEffect, useState } from "react";
import { readPosting, type Job } from "@offerlane/core";
import type { Page } from "./page.js";
import { matchJob, rows } from "./rows.js";
import { getLocal, type AnswerSet } from "./store.js";

type State = { page: Page | null; error: boolean; answers: AnswerSet | null; saved: Job[] };

async function load(): Promise<State> {
  const s = await chrome.storage.session.get(["page", "pageError"]);
  return { page: (s.page as Page | null) ?? null, error: s.pageError === "unreadable", answers: await getLocal<AnswerSet | null>("answers", null), saved: await getLocal<Job[]>("saved", []) };
}

export function Panel() {
  const [st, setSt] = useState<State | null>(null);
  const [note, setNote] = useState("");
  const [copied, setCopied] = useState<string | null>(null);
  useEffect(() => {
    const refresh = () => void load().then(setSt);
    refresh();
    chrome.storage.onChanged.addListener(refresh);
    return () => chrome.storage.onChanged.removeListener(refresh);
  }, []);
  useEffect(() => { setNote(""); setCopied(null); }, [st?.page?.url]);
  if (!st) return null;
  const { page, answers, saved } = st;

  const save = async () => {
    const j = page ? readPosting(page) : null;
    if (!j) { setNote("Offerlane can't find a job on this page. Open the job's own page and try again."); return; }
    // The background does the write, in one queue with the web's "clear", so neither overwrites the other.
    const r = (await chrome.runtime.sendMessage({ type: "save", job: j }).catch(() => undefined)) as { ok?: boolean; added?: boolean } | undefined;
    if (r?.ok !== true) { setNote("Couldn't save it. Try again."); return; }
    setNote(r.added ? `Saved “${j.title}”. In Offerlane on the web, open Settings and choose Bring in saved jobs.` : `“${j.title}” is already saved here.`);
  };
  const again = () => void chrome.runtime.sendMessage({ type: "read" }).catch(() => {});
  const copy = async (label: string, text: string) => {
    try { await navigator.clipboard.writeText(text); setCopied(label); } catch { setCopied(null); setNote("Couldn't copy. Select the answer and copy it yourself."); }
  };
  const forget = async () => { await chrome.storage.local.remove("answers"); setNote("Your answers are removed from this browser."); };

  const ja = page && answers ? matchJob(answers.jobs, page.url) : null;
  const list = page && answers ? rows(page.fields, answers.profile, ja) : [];
  return (
    <main className="stack">
      <h1>Offerlane</h1>
      <p className="muted">Offerlane never fills in or sends this form. Copy each answer and paste it yourself.</p>
      {!page ? (
        <p>{st.error ? "Offerlane can't read this page (browser pages and the Web Store are off limits)." : "Click the Offerlane button in the toolbar on a job or application page."}</p>
      ) : (
        <>
          <section className="card stack" aria-labelledby="page-h">
            <h2 id="page-h">This page</h2>
            <p className="muted">{page.title || page.url}</p>
            <div className="row">
              <button type="button" onClick={() => void save()}>Save this job</button>
              <button type="button" className="secondary" onClick={again}>Read this page again</button>
            </div>
            <p className="muted">{saved.length === 1 ? "1 job saved here" : `${saved.length} jobs saved here`}, waiting for Offerlane on the web.</p>
          </section>
          <section className="card stack" aria-labelledby="ans-h">
            <h2 id="ans-h">Answers for this form</h2>
            {!answers ? (
              <p>No answers here yet. In Offerlane on the web, open Settings and choose Send my answers.</p>
            ) : list.length === 0 ? (
              <p>No form fields on this page. If the form opens on another page, go there and click the Offerlane button again.</p>
            ) : (
              <>
                <p className="muted">{ja ? `For ${ja.job.title} at ${ja.job.company}.` : "No role you approved matches this page, so these come from your profile only."}</p>
                <ul className="answers">
                  {list.map((r) => (
                    <li key={r.label} className="stack">
                      <span className="q">{r.label}</span>
                      {r.answer === null ? <span className="muted">You answer this</span> : (
                        <span className="row"><span className="a">{r.answer}</span>
                          <button type="button" className="secondary" aria-label={`Copy answer for ${r.label}`} onClick={() => void copy(r.label, r.answer!)}>
                            {copied === r.label ? "Copied" : "Copy"}</button></span>)}
                    </li>
                  ))}
                </ul>
              </>
            )}
          </section>
        </>
      )}
      <p role="status" aria-live="polite">{note}</p>
      {answers && <button type="button" className="secondary" onClick={() => void forget()}>Forget my answers on this browser</button>}
    </main>
  );
}
