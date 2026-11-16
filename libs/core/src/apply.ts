// App/Sources/Apply/ApplyEngine.swift, line for line: fills an application at a human pace and stops before Submit (v4 P4.1).
// The page is driven through `ApplyPage` (autofill.js in an isolated world), so the same decisions run on the Mac port's
// self-test pages in Chromium (cdp.ts over Playwright) and in WebView2 on Windows (cdp.ts over the Tauri shell).
import { rules as answerRules, want, pick, CONSENT_RX, DONE_RX, type Answer, type Rule } from "./answers.js";
import { Visa } from "./ranking.js";
import type { Job, Profile } from "./models.js";
import { escapeRe, prefix, search } from "./text.js";

export const HUMAN_RX = "captcha|are you a robot|verify you are human|press and hold|unusual traffic";
export const VERIFY_RX = "verify your (email|account)|verification (email|link|code)|check your (email|inbox)|activate your account";

/** WebPage.swift: the apply browser as the engine sees it. `call` runs window.__ja.<fn>(...args) in the isolated world (null on any error). */
export interface ApplyPage {
  url(): Promise<string>;
  /** host[:port] of the current page, "" when there is none. Passwords are keyed by it. */
  host(): Promise<string>;
  load(url: string): Promise<void>;
  waitForLoad(timeoutMs?: number): Promise<void>;
  call(fn: string, args?: unknown[]): Promise<unknown>;
  /** Main-world JavaScript (self-tests read mock-site state with this). */
  eval(js: string): Promise<unknown>;
}

/** Vault.swift: per-site passwords (Keychain / Credential Manager) and the per-company approval to create accounts. */
export interface ApplyVault {
  password(host: string): Promise<string | null>;
  accountEmail(host: string): Promise<string | null>;
  /** Throws when the secret store refuses; the engine then hands over instead of creating an account it can't sign back into. */
  save(host: string, company: string, email: string, password: string): Promise<void>;
  isApproved(host: string, company: string): Promise<boolean>;
}

export type OutcomeKind = "applied" | "prefilled" | "account" | "needsYou";
export type Outcome = { kind: OutcomeKind; message: string };
const out = (kind: OutcomeKind, message: string): Outcome => ({ kind, message });

/** One field from autofill.js collect(). */
export type ApplyField = {
  i: number; type: string; name: string; flabel: string; label: string; group: string; role: string;
  required: boolean; value: string; checked: boolean; options: string[] | null;
};

export type ApplyOptions = {
  page: ApplyPage; job: Job; profile: Profile; answers: Answer[]; pdf: { b64: string; name: string } | null; vault: ApplyVault;
  pace?: number;
};

/** Keychain.strongPassword: 18 characters with lower, upper, digit and symbol (no look-alikes). */
export function strongPassword(length = 18): string {
  const lower = "abcdefghijkmnopqrstuvwxyz", upper = "ABCDEFGHJKLMNPQRSTUVWXYZ", digits = "23456789", sym = "!@#$%*?";
  const all = lower + upper + digits + sym;
  const pickOne = (set: string) => set[crypto.getRandomValues(new Uint32Array(1))[0]! % set.length]!;
  for (;;) {
    const p = Array.from({ length }, () => pickOne(all)).join("");
    if ([lower, upper, digits, sym].every((s) => [...p].some((c) => s.includes(c)))) return p;
  }
}

/** ApplyController.isConfirmation. */
export const isConfirmation = (body: string, url: string) => search(DONE_RX, body.slice(0, 20000)) || search("/(thanks|thank-you|confirmation|submitted)", url);

export const isWorkday = (url: string) => search("myworkdayjobs\\.com|myworkday(site)?\\.com|wd\\d+\\.myworkday", url);

const NEXT_RX = "^(next|continue|save and continue|save & continue|proceed|next step)$";
const SUBMIT_RX = "^(submit( application)?|send application|apply now|finish)$";
/** Account-creation buttons only (never "submit" or "apply"). */
const CREATE_RX = "^(create( an| my| your)? account|sign up|register|create)$";
const SIGN_IN_RX = "^(sign in|log ?in|continue)$";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
type Rec = Record<string, unknown>;
const arr = (v: unknown): Rec[] => (Array.isArray(v) ? v.filter((x): x is Rec => typeof x === "object" && x !== null) : []);
const strs = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
const sv = (v: unknown) => (typeof v === "string" ? v : "");
const errText = (e: unknown) => (e instanceof Error ? e.message : String(e));

export class ApplyEngine {
  approved = false;
  filledCount = 0;
  readonly pace: number;
  constructor(private readonly o: ApplyOptions) { this.pace = o.pace ?? 1; }

  private get page() { return this.o.page; }
  private get email() { return this.o.profile.personal.email; }
  private async bool(fn: string, args: unknown[] = []) { return (await this.page.call(fn, args)) === true; }
  private async str(fn: string, args: unknown[] = []) { return sv(await this.page.call(fn, args)); }
  private pause(a = 0.35, b = 0.9) { return sleep((a + Math.random() * (b - a)) * this.pace * 1000); }
  private async settle(s: number) { await sleep(s * Math.max(this.pace, 0.15) * 1000); await this.page.waitForLoad(); }
  private rules(consent: boolean): Rule[] {
    return answerRules(this.o.profile, this.o.job.location, consent, new Visa(this.o.profile));
  }

  // ---- fill one page ----

  async fill(consent: boolean, withPDF = true): Promise<{ filled: [string, string][]; need: string[] }> {
    const R = this.rules(consent), { answers, pdf } = this.o;
    const filled: [string, string][] = [], need: string[] = [], done = new Set<string>();
    const fields = arr(await this.page.call("collect")) as ApplyField[];
    const files = fields.filter((f) => f.type === "file");
    const blob = (f: ApplyField) => `${f.label} ${f.name} ${f.flabel}`;
    const named = files.filter((f) => search("resume|cv\\b", blob(f)) && !blob(f).toLowerCase().includes("cover"));
    for (const f of fields) {
      if (f.type === "file") {
        const target = named.length > 0 ? named.includes(f) : f === files[0] && !blob(f).toLowerCase().includes("cover");
        if (withPDF && pdf && target && f.value === "") {
          if (await this.bool("upload", [f.i, pdf.b64, pdf.name, "application/pdf"])) filled.push(["Resume upload", pdf.name]);
          else if (f.required) need.push("resume upload");
        } else if (f.required && f.value === "") need.push(f.flabel === "" ? (f.label === "" ? "file upload" : f.label) : f.flabel);
        continue;
      }
      const [v, L] = want(f, R, answers);
      if (f.type === "radio" || f.type === "checkbox") {
        const key = L === "" ? f.name : L;
        if (done.has(key) || f.checked) { done.add(key); continue; }
        if (f.type === "checkbox" && search(CONSENT_RX, L + " " + f.label)) {
          if (consent) { await this.bool("click", [f.i]); done.add(key); filled.push([prefix(L, 60), "ticked (approved)"]); }
          else if (f.required) need.push("tick: " + prefix(f.label === "" ? L : f.label, 70));
          continue;
        }
        if (v !== null && pick([f.label], v) !== null) { await this.bool("click", [f.i]); done.add(key); filled.push([L, f.label]); }
        continue;
      }
      if (f.value !== "" || v === null) { if (f.value === "" && f.required) need.push(L); continue; }
      if (f.type === "select") {
        const o = pick(f.options ?? [], v);
        if (o !== null) { if (await this.bool("select", [f.i, o])) filled.push([L, o]); }
        else if (f.required) need.push(L);
      } else if (f.role === "combobox") {
        const firstPart = prefix(v.split(",").filter((x) => x !== "")[0] ?? v, 60);
        await this.bool("comboType", [f.i, firstPart]); filled.push([L, firstPart]);
      } else {
        await this.bool("type", [f.i, v]); filled.push([L, prefix(v, 60)]);
      }
    }
    need.push(...strs(await this.page.call("requiredRadioNames")).map((n) => `choose an option: ${n}`));
    const seen = new Set<string>();
    return { filled, need: need.filter((n) => n !== "" && !seen.has(n) && seen.add(n)) };
  }

  /** Workday's custom list boxes and multi-select prompts. Re-query after every pick: Workday re-renders. */
  async workdayControls(consent: boolean): Promise<{ filled: number; need: string[] }> {
    const R = this.rules(consent), { answers } = this.o;
    let filled = 0; const need: string[] = [], done = new Set<string>();
    for (let n = 0; n < 30; n++) {
      const boxes = await this.page.call("listboxes");
      if (!Array.isArray(boxes)) break;
      const b = arr(boxes).find((b) => { const L = sv(b.label), cur = sv(b.current); return !done.has(L) && (cur === "" || search("^select", cur)); });
      if (!b || typeof b.k !== "number") break;
      const L = sv(b.label), req = b.required === true;
      done.add(L);
      const [v] = want({ type: "select", label: L }, R, answers);
      if (v === null) { if (req) need.push(L); continue; }
      const opts = strs(await this.page.call("openListbox", [b.k]));
      const o = pick(opts, v);
      if (o !== null && (await this.bool("chooseOption", [o]))) filled++;
      else { await this.page.call("escape"); if (req) need.push(L); }
    }
    for (const b of arr(await this.page.call("searchBoxes"))) {
      if (b.selected === true || typeof b.k !== "number") continue;
      const [v] = want({ type: "select", label: typeof b.label === "string" ? b.label : "source" }, R, answers);
      if (v !== null && (await this.bool("promptPick", [b.k, prefix(v, 30)]))) filled++;
    }
    return { filled, need };
  }

  // ---- Workday (multi-page, per-company account) ----

  async workday(): Promise<Outcome> {
    const { job, vault, pdf } = this.o;
    let last: string | null = null, stuck = 0, uploaded = false, stuckSince: number | null = null;
    const start = Date.now();
    for (let n = 0; n < 60; n++) {
      await this.page.waitForLoad(); await this.pause(1.2, 2.2);
      const body = await this.str("text");
      if (search(HUMAN_RX, body)) return out("needsYou", "The site is asking to verify you're human. Complete it here, then press Continue.");
      if (search(DONE_RX, body)) return out("applied", "Application submitted");
      if (await this.bool("visible", ["applyFlowLoadingPage"])) continue;
      // Workday is a single-page app: right after "load" nothing is rendered yet. Give it time before judging the page.
      const rendered = await this.page.call("count", ["[data-automation-id]"]);
      if ((typeof rendered === "number" ? rendered : 0) === 0 && Date.now() - start < 15000) { await sleep(700); continue; }
      let dialog = false;
      for (const id of ["autofillWithResume", "applyManually"]) {
        if (await this.bool("visible", [id])) { await this.bool("clickAid", [id]); await this.settle(3); dialog = true; break; }
      }
      if (dialog) continue;
      if ((await this.bool("visible", ["adventureButton"])) && !(await this.bool("exists", ["applyFlowPage"]))) {
        await this.bool("clickAid", ["adventureButton"]); await this.settle(2); continue;
      }
      const pwVisible = await this.bool("anyVisible", ["input[type=password]"]);
      const signIn = await this.bool("visible", ["signInContent"]), createLink = await this.bool("visible", ["createAccountLink"]);
      if (pwVisible || signIn || createLink) {
        const creating = await this.bool("visible", ["verifyPassword"]);
        // Passwords belong to one website: look up and save under the page's CURRENT host, so a flow that has
        // moved elsewhere (SSO, another ATS, a hostile redirect) is never handed this site's password.
        const host = await this.page.host();
        const saved = await vault.password(host);
        if (saved === null && !this.approved) return out("account", `Create a Workday account at ${job.company} with ${this.email}?`);
        if ((await this.bool("visible", ["SignInWithEmailButton"])) && !(await this.bool("visible", ["email"]))) {
          await this.bool("clickAid", ["SignInWithEmailButton"]); continue;
        }
        if (saved !== null && !creating) {
          const acct = (await vault.accountEmail(host)) ?? this.email;
          await this.bool("typeAid", ["email", acct === "" ? this.email : acct]); await this.bool("typeAid", ["password", saved]);
          const via = (await this.bool("visible", ["click_filter"])) ? "click_filter" : "signInSubmitButton";
          await this.bool("clickAid", [via]); await this.settle(3.5);
          if ((await this.bool("visible", ["password"])) && search("invalid|incorrect|wrong|locked", await this.str("text"))) {
            return out("needsYou", "Sign-in failed with the saved password. Sign in (or reset it) here, then press Continue.");
          }
          continue;
        }
        if (!this.approved) return out("account", `Create a Workday account at ${job.company} with ${this.email}?`);
        if (!creating) {
          if (await this.bool("visible", ["createAccountLink"])) { await this.bool("clickAid", ["createAccountLink"]); continue; }
          return out("needsYou", "Couldn't find Workday's “Create Account” option. Create an account or sign in here, then press Continue.");
        }
        const pw = strongPassword();
        try { await vault.save(host, job.company, this.email, pw); }   // saved BEFORE clicking Create
        catch (e) { return out("needsYou", `Couldn't save the new password (${errText(e)}). Create the account yourself, then press Continue.`); }
        await this.bool("typeAid", ["email", this.email]); await this.bool("typeAid", ["password", pw]); await this.bool("typeAid", ["verifyPassword", pw]);
        if ((await this.bool("visible", ["createAccountCheckbox"])) && !(await this.bool("checked", ["createAccountCheckbox"]))) await this.bool("clickAid", ["createAccountCheckbox"]);
        const via = (await this.bool("visible", ["click_filter"])) ? "click_filter" : "createAccountSubmitButton";
        await this.bool("clickAid", [via]); await this.settle(4);
        // SHORTCUT: no emailed verification link is followed (the IMAP side and Tracking.trustedLink aren't ported); the person clicks it.
        if (search(VERIFY_RX, await this.str("text"))) return out("needsYou", `Workday sent a verification email to ${this.email}. Click the link in it, then press Continue.`);
        continue;
      }
      if (pdf && !uploaded && (await this.bool("exists", ["file-upload-input-ref"]))) {
        if (!(await this.bool("anyVisible", ['[data-automation-id="file-upload-successful"],[data-automation-id="file-upload-item"]']))) {
          await this.bool("uploadAid", ["file-upload-input-ref", pdf.b64, pdf.name, "application/pdf"]); await this.settle(2);
        }
        uploaded = true;
      }
      const f1 = await this.fill(this.approved);
      const f2 = await this.workdayControls(this.approved);
      this.filledCount += f1.filled.length + f2.filled;
      const need = [...f1.need, ...f2.need];
      let nextID: string | null = null;
      for (const id of ["bottom-navigation-next-button", "pageFooterNextButton"]) if (await this.bool("visible", [id])) { nextID = id; break; }
      const step = (await this.bool("exists", ["progressBarActiveStep"])) ? await this.str("aidText", ["progressBarActiveStep"]) : await this.page.url();
      if (nextID === null) {
        stuck++; stuckSince ??= Date.now();
        if (stuck > 3 && Date.now() - stuckSince > 10000) return out("needsYou", "Offerlane isn't sure what to do on this page. Take a look, then press Continue.");
        await sleep(800);
        continue;
      }
      stuck = 0; stuckSince = null;
      if (search("submit", await this.str("aidText", [nextID]))) {
        return out("prefilled", `Filled ${this.filledCount} fields across all pages. Check the Review page, then click Submit.`);
      }
      const errs = strs(await this.page.call("errors"));
      if (step === last && (errs.length > 0 || need.length > 0)) return out("needsYou", "Please complete: " + [...errs, ...need].slice(0, 6).join("; ") + ", then press Continue.");
      last = step;
      await this.bool("clickAid", [nextID]); await this.settle(1);
    }
    return out("needsYou", "This application has more pages than expected. Please finish it here.");
  }

  // ---- everything else (Greenhouse, Lever, Ashby, SmartRecruiters, company sites) ----

  async generic(first: boolean): Promise<Outcome> {
    const { job, vault } = this.o;
    let total = 0, lastURL: string | null = null;
    for (let loop = 0; loop < 14; loop++) {
      await this.page.waitForLoad(); await this.pause(1.0, 1.8);
      const body = await this.str("text");
      if (search(HUMAN_RX, body)) return out("needsYou", "The site is asking to verify you're human. Complete it here, then press Continue.");
      if (loop > 0 && search(DONE_RX, body)) return out("applied", "Application submitted");
      const hasInputs = await this.bool("hasFormInputs");
      if (first && loop === 0 && !hasInputs) {
        for (const name of ["Apply for this job", "Apply now", "Apply", "I'm interested", "Apply for this position"]) {
          if (await this.bool("clickMatching", [`^${escapeRe(name)}$`, true])) { await this.settle(2.5); break; }
        }
        continue;
      }
      const pwRaw = await this.page.call("count", ["input[type=password]"]), pwCount = typeof pwRaw === "number" ? pwRaw : 0;
      if ((await this.bool("anyVisible", ["input[type=password]"])) && !(await this.bool("anyVisible", ["input[type=file]"]))) {
        const host = await this.page.host();   // passwords are only ever typed into the site they were saved for
        const saved = await vault.password(host);
        if (saved !== null) {
          const acct = (await vault.accountEmail(host)) ?? this.email;
          await this.bool("typeSel", ["input[type=email],input[name*=mail i],input[id*=mail i],input[name*=user i]", acct]);
          await this.bool("typeAllPasswords", [saved, 1]);
          await this.bool("clickMatching", [SIGN_IN_RX, false]); await this.settle(3.5);
          if (await this.bool("anyVisible", ["input[type=password]"])) return out("needsYou", "Sign-in didn't go through. Please sign in here, then press Continue.");
          continue;
        }
        if (!this.approved) return out("account", `${job.company}'s career site needs an account. Create one with ${this.email}?`);
        if (pwCount === 1 && (await this.bool("hasMatching", ["create (an )?account|sign up|register|new user", true]))) {
          await this.bool("clickMatching", ["create (an )?account|sign up|register|new user", true]); await this.settle(2.5); continue;
        }
        if (pwCount >= 2) {
          // Some sites combine "create account" with the application itself. Offerlane never presses a
          // button that would send the application: if one is on this page, the user takes over.
          const names = arr(await this.page.call("buttons")).map((b) => sv(b.name));
          const create = names.find((n) => search(CREATE_RX, n));
          if (create === undefined || names.some((n) => search(SUBMIT_RX, n) || search("submit|apply", n))) {
            return out("needsYou", "This page creates an account and sends the application in one step. Fill in a password and check everything here, then click the button yourself.");
          }
          const p = strongPassword();
          try { await vault.save(host, job.company, this.email, p); } catch { return out("needsYou", "Couldn't save the password."); }
          await this.bool("typeSel", ["input[type=email],input[name*=mail i],input[id*=mail i]", this.email]);
          await this.bool("typeAllPasswords", [p, 2]);
          await this.fill(this.approved, false);
          await this.bool("clickMatching", [`^${escapeRe(create)}$`, false]); await this.settle(4);
          if (search(VERIFY_RX, await this.str("text"))) return out("needsYou", `${job.company} sent a verification email to ${this.email}. Open it, then press Continue.`);
          continue;
        }
        return out("needsYou", "This site needs you to sign in or register. Do it here, then press Continue.");
      }
      const { filled, need } = await this.fill(this.approved); total += filled.length; this.filledCount += filled.length;
      const buttons = arr(await this.page.call("buttons"));
      const names = buttons.map((b) => sv(b.name));
      const next = buttons.find((b) => search(NEXT_RX, sv(b.name)));
      const hasSubmit = names.some((n) => search(SUBMIT_RX, n)) || buttons.some((b) => b.submit === true);
      if (next && !hasSubmit && typeof next.k === "number") {
        const u = await this.page.url();
        if (need.length > 0 && u === lastURL) return out("needsYou", "Please complete: " + need.slice(0, 6).join("; ") + ", then press Continue.");
        lastURL = u; await this.bool("clickButton", [next.k]); await this.settle(2.5); continue;
      }
      return out("prefilled", `Filled ${total} fields.` + (need.length === 0 ? "" : ` Still needed: ${need.slice(0, 6).join("; ")}.`) + " Check the form, then click Submit.");
    }
    return out("needsYou", "This application has more steps than expected. Please finish it here.");
  }

  async run(first: boolean): Promise<Outcome> {
    const { job, vault } = this.o;
    this.approved = await vault.isApproved(await this.page.host(), job.company);
    if (this.pace < 1) await this.page.call("setPace", [this.pace]);
    const wdHooks = await this.bool("anyVisible", ['[data-automation-id="adventureButton"],[data-automation-id="signInContent"],[data-automation-id="progressBarActiveStep"]']);
    const r = isWorkday(await this.page.url()) || wdHooks ? await this.workday() : await this.generic(first);
    // Unlike the Swift banner, the company name and message are escaped: on the web they can come from page text.
    const c = esc(job.company);
    const banner = r.kind === "prefilled"
      ? `<b>Offerlane</b> filled this application for <b>${c}</b>. Review everything, then click <b>Submit</b> yourself.`
      : `<b>Offerlane</b> is working on this application for <b>${c}</b>. ${esc(r.message)}`;
    await this.page.call("banner", [banner]);
    return r;
  }
}
