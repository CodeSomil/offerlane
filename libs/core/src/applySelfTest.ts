// App/Sources/Apply/SelfTest.swift ApplySelfTest: the 14 apply checks on the mock sites in App/Resources/SelfTest (v4 P4.1).
// One list for every port: Playwright runs it against Chromium, the Windows shell's --selftest against WebView2.
import { ApplyEngine, isConfirmation, type ApplyPage, type ApplyVault, type Outcome } from "./apply.js";
import { parseAnswers } from "./answers.js";
import { job, newProfile, tailorPlan } from "./models.js";
import { answersMarkdown } from "./tailor.js";

export type Check = { ok: boolean; what: string };

/** Self-tests only (looser than Vault.swift: exact-case company, approval not implied by save). Per-host password + email, per-(host, company) approval. */
export class MemoryVault implements ApplyVault {
  readonly accounts = new Map<string, { email: string; password: string }>();
  readonly approvals = new Set<string>();
  async password(host: string) { return this.accounts.get(host)?.password ?? null; }
  async accountEmail(host: string) { return this.accounts.get(host)?.email ?? null; }
  async save(host: string, _company: string, email: string, password: string) { this.accounts.set(host, { email, password }); }
  async isApproved(host: string, company: string) { return this.approvals.has(`${host}\n${company}`); }
  approve(host: string, company: string) { this.approvals.add(`${host}\n${company}`); }
}

// A minimal PDF: the mock sites only check that a file named like a resume arrived.
const PDF = { b64: btoa("%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"), name: "Test_Person_Resume.pdf" };
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * `base` serves the three SelfTest pages; `newPage` gives a fresh, non-persistent apply page each call; `vault` starts empty
 * (MemoryVault, or Credential Manager on Windows; the caller cleans it up). `log` gets each PASS/FAIL line as it happens.
 */
export async function applySelfTest(env: { base: string; newPage: () => Promise<ApplyPage>; vault: ApplyVault & { approve(host: string, company: string): void | Promise<void> }; log?: (line: string) => void }): Promise<Check[]> {
  const results: Check[] = [];
  const check = (ok: boolean, what: string) => { env.log?.((ok ? "PASS " : "FAIL ") + what); results.push({ ok, what }); };
  const { base, vault } = env;

  const p = newProfile();
  Object.assign(p.personal, { first_name: "Test", last_name: "Person", full_name: "Test Person", email: "test@example.com", phone: "+44 7700 900000", city: "London", country: "United Kingdom" });
  Object.assign(p.work, { current_company: "Acme", current_title: "Senior Data Scientist", years_experience: "5" });
  p.authorization.authorized_countries = ["United Kingdom"]; p.authorization.needs_sponsorship = true;
  p.misc.how_heard = "Company Website"; p.eeo.gender = "Male";
  const answers = parseAnswers(answersMarkdown(tailorPlan({ cover_letter: "Hello from the cover letter", why_company: "Because",
    answers: [{ q: "Why do you want to work here?", a: "Because the mission fits." }] }), "Globex"));
  const engine = (pg: ApplyPage, j: ReturnType<typeof job>) => new ApplyEngine({ page: pg, job: j, profile: p, answers, pdf: PDF, vault, pace: 0.08 });
  const js = async (pg: ApplyPage, s: string): Promise<Record<string, unknown>> => {
    const v = await pg.eval(`JSON.stringify(${s})`);
    try { return typeof v === "string" ? ((JSON.parse(v) as Record<string, unknown> | null) ?? {}) : {}; } catch { return {}; }
  };
  const is = (o: Outcome, kind: Outcome["kind"]) => o.kind === kind;

  // ---- Workday-style site: account gate, approval, account creation, six pages, stop at Review ----
  const wd = job({ company: "Acme", title: "Senior Data Scientist", location: "London, UK", url: `${base}/workday.html` });
  const pg = await env.newPage();
  await pg.load(wd.url);
  const o1 = await engine(pg, wd).run(true);
  check(is(o1, "account") && o1.message === "Create a Workday account at Acme with test@example.com?", `Workday-style site: asks before creating an account (${o1.message})`);
  const host = await pg.host();
  await vault.approve(host, "Acme");
  check(await vault.isApproved(host, "Acme"), "your approval recorded for this company");
  const o2 = await engine(pg, wd).run(false);
  const created = await js(pg, "window.CREATED"), saved = await vault.password(await pg.host());
  check(saved !== null && created.p === saved && created.e === "test@example.com", "account created with a strong password stored in the vault");
  const body = String((await pg.eval("document.body.innerText")) ?? "");
  check(is(o2, "prefilled") && body.includes("Submit"), `filled every page and stopped on Review before Submit (${o2.message})`);
  check((await pg.eval("window.SUBMITTED ?? null")) === null, "agent did NOT submit");
  const d = await js(pg, "S.data");
  env.log?.("   workday answers: " + ["source", "country", "phoneType", "phone-number", "prev", "sponsor", "auth", "agr"].map((k) => `${k}=${typeof d[k] === "string" ? d[k] : d[k] === true ? "true" : "-"}`).join(" "));
  check(new Set([d.sponsor, d.auth]).size === 2 && [d.sponsor, d.auth].includes("Yes") && [d.sponsor, d.auth].includes("No") && d.prev === "No" && d.country === "United Kingdom"
        && d.phoneType === "Mobile", "Workday dropdowns/radios answered from your profile");
  check(d.source === "Company Website", "multi-select prompt answered (How did you hear)");
  await pg.eval(`document.querySelector('[data-automation-id="bottom-navigation-next-button"]').click()`);
  await sleep(800);
  const after = String((await pg.eval("document.body.innerText")) ?? "");
  check(isConfirmation(after, await pg.url()), "after YOUR click, the confirmation page is detected");

  // ---- second visit to the same site signs in with the saved password ----
  const pg2 = await env.newPage();
  await pg2.load(wd.url);
  await pg2.eval(`S.account = ${JSON.stringify(created)}; true`);
  const o3 = await engine(pg2, wd).run(true);
  check(is(o3, "prefilled"), `next application at that company signs in with the saved password (${o3.message})`);

  // ---- simple single-page form (Greenhouse-like) ----
  const simple = job({ company: "Globex", title: "Data Scientist", location: "New York, NY", url: `${base}/simple.html` });
  const pg3 = await env.newPage();
  await pg3.load(simple.url);
  const o4 = await engine(pg3, simple).run(true);
  const v = await js(pg3, "({fn:fn.value,em:em.value,ph:ph.value,sp:sp.value,why:why.value,cl:cl.value,cv:cv.files.length,pp:pp.checked})");
  env.log?.("   simple form: " + JSON.stringify(v));
  check(is(o4, "prefilled") && v.fn === "Test" && v.sp === "Yes" && v.cv === 1 && v.pp === false, `single-page form filled, resume uploaded, consent box left for you (${o4.message})`);
  check(o4.message.includes("tick: I agree to the privacy policy"), "the unticked consent box is listed for you");
  check(typeof v.why === "string" && v.why.startsWith("Because"), "custom question answered from the drafted answers");
  check(v.cl === "Hello from the cover letter", "cover letter pasted");

  // ---- honeypots and hidden fields are never filled ----
  const pg4 = await env.newPage();
  await pg4.load(`${base}/honeypot.html`);
  await engine(pg4, simple).run(true);
  const h = await js(pg4, "({fn:fn.value, trap:trap.value, hid:hid.value, em:em.value})");
  check(h.fn === "Test" && h.trap === "" && h.hid === "" && h.em === "test@example.com", "honeypot and aria-hidden fields skipped");

  const failed = results.filter((r) => !r.ok).length;
  env.log?.(failed === 0 ? `ALL ${results.length} APPLY CHECKS PASSED` : `${failed} OF ${results.length} APPLY CHECKS FAILED`);
  return results;
}
