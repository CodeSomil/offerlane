// Tailoring drafts on the web (P3.6): the Guard pass on the app's own AI reply and the Markdown download.
import { guardCheck, planSource, type ResumeContent, type ResumeVersion, type TailorPlan } from "@offerlane/core";

/** The app's own tailoring: bullets, headline and summary are already guarded by applyPlan (rejected → original kept).
 *  The other texts are guarded here; a rejected one is blanked (an answer is dropped) and named in the notes.
 *  Stricter than the Mac's own tailoring, which doesn't check them. A pasted Claude reply is refused whole instead (rejections). */
export function guardAIPlan(plan: TailorPlan, v: ResumeVersion): { plan: TailorPlan; notes: string[] } {
  const src = planSource(v), notes: string[] = [], ok = (k: string, t: string) => {
    if (t === "") return true;
    const g = guardCheck(t, src);
    if (!g.ok) notes.push(`${k} removed: ${g.warnings[0]}`);
    return g.ok;
  };
  return { plan: { ...plan, cover_letter: ok("cover letter", plan.cover_letter) ? plan.cover_letter : "", why_company: ok("why us", plan.why_company) ? plan.why_company : "",
    changes_summary: ok("change note", plan.changes_summary) ? plan.changes_summary : "", answers: plan.answers.filter((qa) => ok("question", qa.q) && ok("answer", qa.a)) }, notes };
}

/** resume.md: the tailored resume as plain Markdown (no Swift twin; the Mac renders a PDF). */
export function resumeMarkdown(c: ResumeContent): string {
  const out: string[] = [`# ${c.name}`, [c.email, c.phone, c.location, ...Object.values(c.links)].filter((x) => x !== "").join(" · ")];
  if (c.headline !== "") out.push(`**${c.headline}**`);
  if (c.summary !== "") out.push(c.summary);
  const secs = (title: string, ss: ResumeContent["experience"]) => {
    if (ss.length === 0) return;
    out.push(`## ${title}`);
    for (const s of ss) {
      const head = [s.title || s.name, s.company].filter((x) => x !== "").join(", ");
      out.push(`### ${head}` + ([s.location, s.dates].some((x) => x !== "") ? `\n${[s.location, s.dates].filter((x) => x !== "").join(" · ")}` : ""));
      if (s.bullets.length > 0) out.push(s.bullets.map((b) => `- ${b.text}`).join("\n"));
    }
  };
  secs("Experience", c.experience); secs("Projects", c.projects);
  if (c.skills.length > 0) out.push("## Skills", c.skills.map((s) => `- **${s.label}:** ${s.items}`).join("\n"));
  if (c.education.length > 0) out.push("## Education", c.education.map((e) => `- ${[e.degree, e.school, e.dates].filter((x) => x !== "").join(", ")}${e.details === "" ? "" : ` (${e.details})`}`).join("\n"));
  if (c.certifications.length > 0) out.push("## Certifications", c.certifications.map((x) => `- ${x}`).join("\n"));
  if (c.extras.length > 0) out.push("## Extras", c.extras.map((x) => `- ${x}`).join("\n"));
  return out.filter((x) => x !== "").join("\n\n") + "\n";
}

/** Saves text as a file through a temporary blob link (no server round trip). */
export function download(name: string, text: string) {
  const u = URL.createObjectURL(new Blob([text], { type: "text/markdown;charset=utf-8" })), a = document.createElement("a");
  a.href = u; a.download = name; document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(u), 1000);  // some browsers start the download after click() returns
}
