// Onboarding on the web (P3.5a): paste or pick a resume, one AI parse (ResumeParser), check the profile, save on this device.
import { useEffect, useState } from "react";
import { isObject, len, newProfile, prefill, prefix, profileErrors, resumeFromParsed, RESUME_PARSE_PROMPT, type Profile, type ResumeVersion } from "@offerlane/core";
import { askJSON, readyAI } from "./ai.js";
import { loadProfile, loadResume, saveProfile, saveResume } from "./data.js";

const MIN = 200, MAX = 14_000;  // ResumeParser: too little text is a scan; the model reads the first 14000 characters
type Field = { id: string; label: string; get: (p: Profile) => string; set: (p: Profile, v: string) => void; type?: string };
const FIELDS: Field[] = [
  { id: "firstName", label: "First name", get: (p) => p.personal.first_name, set: (p, v) => { p.personal.first_name = v; } },
  { id: "lastName", label: "Last name", get: (p) => p.personal.last_name, set: (p, v) => { p.personal.last_name = v; } },
  { id: "email", label: "Email", type: "email", get: (p) => p.personal.email, set: (p, v) => { p.personal.email = v; } },
  { id: "phone", label: "Phone", type: "tel", get: (p) => p.personal.phone, set: (p, v) => { p.personal.phone = v; } },
  { id: "city", label: "City", get: (p) => p.personal.city, set: (p, v) => { p.personal.city = v; } },
  { id: "title", label: "Current title", get: (p) => p.work.current_title, set: (p, v) => { p.work.current_title = v; } },
  { id: "years", label: "Years of experience", get: (p) => p.work.years_experience, set: (p, v) => { p.work.years_experience = v; } },
  { id: "countries", label: "Countries where you can work without sponsorship (comma separated)", get: (p) => p.authorization.authorized_countries.join(", "),
    set: (p, v) => { p.authorization.authorized_countries = v.split(",").map((x) => x.trim()).filter((x) => x !== ""); } },
];

export function Onboarding() {
  const [text, setText] = useState("");
  const [file, setFile] = useState("pasted.txt");
  const [resume, setResume] = useState<ResumeVersion>();
  const [prof, setProf] = useState<Profile>();
  const [status, setStatus] = useState<{ ok: boolean; text: string }>();
  const [busy, setBusy] = useState(false);
  const [tried, setTried] = useState(false);
  useEffect(() => { Promise.all([loadResume(), loadProfile()]).then(([r, p]) => { if (r) { setResume(r); setProf(p); } }, () => { /* storage blocked: start fresh */ }); }, []);

  async function pick(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0]; if (!f) return;
    setText(await f.text()); setFile(f.name);
  }

  async function read(e: React.FormEvent) {
    e.preventDefault();
    const c = await readyAI();
    if (!c) { setStatus({ ok: false, text: "Connect an AI first (Profile → Connect AI)." }); return; }
    if (len(text.trim()) < MIN) { setStatus({ ok: false, text: "That's too little text to be a resume. Paste the whole thing, or pick a .txt or .md file." }); return; }
    setBusy(true); setStatus({ ok: true, text: "Reading your resume…" });
    try {
      const body = prefix(text, MAX);  // code points; Swift counts Characters (graphemes): SHORTCUT, see libs/core text.ts
      const content = resumeFromParsed(await askJSON(c, { system: "", prompt: RESUME_PARSE_PROMPT + body, smart: true, maxTokens: 6000 }, isObject), "main", "Main");
      if (content.experience.length === 0 && content.projects.length === 0) throw new Error("The AI couldn't find work experience in that resume. Check the text and try again.");
      const v: ResumeVersion = { name: "main", label: "Main", is_default: true, content, source_text: text, source_file: file, created: new Date().toISOString() };
      setResume(v); setProf(prefill(prof ?? await loadProfile().catch(newProfile), content)); setTried(false);
      const n = [...content.experience, ...content.projects].reduce((a, s) => a + s.bullets.length, 0);
      setStatus({ ok: true, text: `Read ${content.experience.length} roles and ${n} bullets. Check your details below, then save.` });
    } catch (err) {
      setStatus({ ok: false, text: err instanceof Error ? err.message : "Reading the resume failed." });
    }
    setBusy(false);
  }

  const errors = prof ? profileErrors(prof) : {};
  async function save(e: React.FormEvent) {
    e.preventDefault(); setTried(true);
    if (!resume || !prof || Object.keys(errors).length > 0) { setStatus({ ok: false, text: "Fix the fields marked below." }); return; }
    const p = { ...prof, personal: { ...prof.personal, full_name: `${prof.personal.first_name} ${prof.personal.last_name}`.trim() } };
    try { await saveResume(resume); await saveProfile(p); setProf(p); setStatus({ ok: true, text: "Saved on this device. Next: Discover." }); }
    catch { setStatus({ ok: false, text: "This browser wouldn't store it. Allow site storage and try again." }); }
  }

  const edit = (f: Field, v: string) => setProf((p) => { const q = structuredClone(p!); f.set(q, v); return q; });
  return (
    <div className="stack">
      <form className="stack" onSubmit={read} aria-labelledby="ob-resume">
        <h2 id="ob-resume">Your resume</h2>
        <p className="muted">Your resume stays in this browser. It goes only to the AI service you connected, to be read once.</p>
        <label>Paste your resume <textarea rows={10} value={text} onChange={(e) => setText(e.target.value)} spellCheck={false} /></label>
        {/* SHORTCUT: text files only; PDF/DOCX need pdfjs-dist or a DOCX unzip (a dependency decision for the human). */}
        <label>Or pick a text file (.txt, .md) <input type="file" accept=".txt,.md,text/plain,text/markdown" onChange={pick} /></label>
        <button type="submit" disabled={busy}>{busy ? "Reading…" : "Read my resume"}</button>
      </form>
      <p role={status && !status.ok ? "alert" : "status"} className={status ? (status.ok ? "ok" : "bad") : undefined}>{status?.text}</p>
      {resume && prof && (
        <form className="stack" onSubmit={save} aria-labelledby="ob-profile" noValidate>
          <h2 id="ob-profile">Your details</h2>
          <p className="muted">{resume.content.headline} · {resume.content.experience.map((s) => s.company).filter(Boolean).join(", ")}</p>
          {FIELDS.map((f) => {
            const err = tried ? errors[f.id] : undefined;
            return (
              <label key={f.id}>{f.label}
                <input type={f.type ?? "text"} value={f.get(prof)} onChange={(e) => edit(f, e.target.value)} aria-invalid={err ? true : undefined} aria-describedby={err ? `err-${f.id}` : undefined} />
                {err && <span id={`err-${f.id}`} className="bad">{err}</span>}
              </label>
            );
          })}
          <label className="radio"><input type="checkbox" checked={prof.authorization.needs_sponsorship} onChange={(e) => setProf({ ...prof, authorization: { ...prof.authorization, needs_sponsorship: e.target.checked } })} /> I need visa sponsorship</label>
          <button type="submit">Save profile</button>
        </form>
      )}
    </div>
  );
}
