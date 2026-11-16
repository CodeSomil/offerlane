// v4 P3.8: the unpacked extension in Chromium, with the built web app and fixture job pages on 127.0.0.1:4199 (routed, no server).
// The web sends the answer set; the extension saves a job from its JSON-LD and shows copy-ready answers beside a form;
// the web brings the saved job into Discover. The form page records every event and change: nothing may ever happen to it.
import { chromium, expect, test, type BrowserContext, type Page, type Worker } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { fileURLToPath } from "node:url";
import { resumeVersion } from "@offerlane/core";
import { ANSWERS, FORM_URL, person, role } from "../test/fixture.js";

const EXT = fileURLToPath(new URL("../dist-test", import.meta.url)), ID = "ifhcpkmhnnlojhhddfdklkcffjjihfed";
const WEB = "http://127.0.0.1:4173", POSTING = "http://127.0.0.1:4199/beta/jobs/7";

const postingHTML = `<!doctype html><html lang="en"><head><title>Data Engineer - Beta</title>
<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", "@type": "JobPosting", title: "Data Engineer", datePosted: "2026-11-10",
  hiringOrganization: { name: "Beta" }, jobLocation: { address: { addressLocality: "London", addressCountry: "UK" } }, description: "<p>Python and SQL pipelines.</p>" })}</script>
</head><body><h1>Data Engineer</h1><p>Python and SQL pipelines.</p></body></html>`;
// A Greenhouse-style form. Every event, attribute or value change is recorded in window.__events.
const formHTML = `<!doctype html><html lang="en"><head><title>Apply: Platform Engineer at Acme</title></head><body>
<h1>Platform Engineer</h1>
<form id="f" action="/never" method="post">
  <label for="fn">First name *</label><input id="fn" name="first_name" required>
  <label for="ln">Last name *</label><input id="ln" name="last_name">
  <label for="em">Email</label><input id="em" type="email" name="email">
  <label for="cv">Resume/CV</label><input id="cv" type="file">
  <label for="why">Why do you want to work at Acme?</label><textarea id="why"></textarea>
  <label for="au">Are you legally authorized to work in the United Kingdom?</label><select id="au"><option>Select...</option><option>Yes</option><option>No</option></select>
  <fieldset><legend>Will you now or in the future require visa sponsorship?</legend>
    <label><input type="radio" name="sp" value="y"> Yes</label><label><input type="radio" name="sp" value="n"> No</label></fieldset>
  <label><input type="checkbox" id="ok"> I agree to the privacy policy and terms</label>
  <input type="hidden" name="honeypot_trap">
  <button type="submit">Submit application</button>
</form>
<script>
  window.__events = [];
  for (const t of ["submit", "click", "input", "change", "focusin", "keydown", "mousedown", "pointerdown"]) document.addEventListener(t, (e) => { __events.push(t); if (t === "submit") e.preventDefault(); }, true);
  new MutationObserver((m) => __events.push(...m.map((x) => "mutation:" + x.type))).observe(document.documentElement, { subtree: true, attributes: true, childList: true, characterData: true });
  window.__values = () => [...document.querySelectorAll("input,textarea,select")].map((e) => e.type === "checkbox" || e.type === "radio" ? e.checked : e.value);
</script></body></html>`;

let ctx: BrowserContext, sw: Worker;
const errors: string[] = [];
const watch = (p: Page) => { p.on("console", (m) => { if (m.type() === "error") errors.push(`${p.url()}: ${m.text()}`); }); p.on("pageerror", (e) => errors.push(e.message)); return p; };

test.beforeAll(async () => {
  ctx = await chromium.launchPersistentContext("", { channel: "chromium", args: [`--disable-extensions-except=${EXT}`, `--load-extension=${EXT}`] });
  await ctx.route("http://127.0.0.1:4199/**", (r) => r.fulfill({ contentType: "text/html", body: new URL(r.request().url()).pathname.endsWith("/apply") ? formHTML : postingHTML }));
  // The web app's auto-search in Discover: an empty index, and never a real host.
  await ctx.route("http://localhost:8787/**", (r) => r.fulfill({ headers: { "access-control-allow-origin": "*" }, json: { next: null, items: [] } }));
  sw = ctx.serviceWorkers()[0] ?? await ctx.waitForEvent("serviceworker");
});
test.afterAll(async () => { await ctx.close(); expect(errors).toEqual([]); });

/** What a toolbar click does (Playwright can't click the toolbar): read the tab showing `url`. */
const read = (url: string) => sw.evaluate(async (u) => {
  const [t] = await chrome.tabs.query({ url: u });
  await (globalThis as unknown as { readTab: (id: number) => Promise<void> }).readTab(t!.id!);
}, url);

test("answers from the web, save a job, copy-ready answers on the form, saved job lands in Discover, nothing touches the form", async () => {
  expect(new URL(sw.url()).host).toBe(ID);  // the pinned dev id the web build expects

  // Web: a profile, a resume, and one role in Ready with its answers.
  const web = watch(await ctx.newPage());
  await web.goto(WEB + "/");
  const t = "2026-11-15T10:00:00Z";
  await web.evaluate((kv) => new Promise<void>((ok, fail) => {
    const r = indexedDB.open("offerlane", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("kv");
    r.onsuccess = () => { const tx = r.result.transaction("kv", "readwrite"); for (const [k, v] of Object.entries(kv)) tx.objectStore("kv").put(v, k);
      tx.oncomplete = () => { r.result.close(); ok(); }; tx.onerror = () => fail(tx.error); };
  }), { profile: person(), resume: resumeVersion({ name: "main", label: "Main", is_default: true, created: t, content: { name: "Ada Lovelace", suggested_titles: ["Data Engineer"], top_skills: ["Python", "SQL"] } }),
        applications: { [role().id]: { job: role(), status: "ready", score: 80, created: t, updated: t, answers: ANSWERS } } });
  await web.goto(WEB + "/#/settings");
  await web.getByRole("button", { name: "Send my answers" }).click();
  await expect(web.getByRole("status").last()).toHaveText("Sent your profile and the answers for 1 role in Review or Ready.");

  // A job page: Save this job (from its JSON-LD).
  const job = watch(await ctx.newPage());
  await job.goto(POSTING);
  await read(POSTING);
  const panel = watch(await ctx.newPage());
  await panel.goto(`chrome-extension://${ID}/panel.html`);
  await expect(panel.getByText("Data Engineer - Beta")).toBeVisible();
  await panel.getByRole("button", { name: "Save this job" }).click();
  await expect(panel.getByRole("status")).toHaveText(/Saved “Data Engineer”/);
  await expect(panel.getByText("1 job saved here", { exact: false })).toBeVisible();
  await panel.getByRole("button", { name: "Save this job" }).click();  // saving twice keeps one
  await expect(panel.getByRole("status")).toHaveText("\u201cData Engineer\u201d is already saved here.");
  await expect(panel.getByText("1 job saved here", { exact: false })).toBeVisible();

  // The application form: answers for this role, consent and unknowns left to the person.
  const form = watch(await ctx.newPage());
  await form.goto(FORM_URL);
  const before = await form.evaluate(() => (window as unknown as { __values: () => unknown[] }).__values());
  await read(FORM_URL);
  await panel.bringToFront();
  await expect(panel.getByText("For Platform Engineer at Acme.")).toBeVisible();
  const answers = panel.getByRole("list").getByRole("listitem");
  await expect(answers).toHaveText([
    /^First name \*Ada/, /^Last name \*Lovelace/, /^Emailada@example\.com/, /^Why do you want to work at Acme\?Because Acme builds the engines I care about\./,
    /^Are you legally authorized to work in the United Kingdom\?Yes/, /^Will you now or in the future require visa sponsorship\?No/,
    /^I agree to the privacy policy and termsYou answer this/,
  ]);
  await expect(panel.getByRole("button", { name: "Copy answer for Email" })).toBeVisible();
  for (const scheme of ["light", "dark"] as const) {
    await panel.emulateMedia({ colorScheme: scheme });
    const r = await new AxeBuilder({ page: panel }).analyze();
    expect(r.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => v.id)).toEqual([]);
  }
  // Read it twice more for good measure; the form must be exactly as it was, with no event, change or submit.
  await read(FORM_URL); await read(FORM_URL);
  await form.waitForTimeout(300);
  expect(await form.evaluate(() => (window as unknown as { __events: string[] }).__events)).toEqual([]);
  expect(await form.evaluate(() => (window as unknown as { __values: () => unknown[] }).__values())).toEqual(before);
  expect(form.url()).toBe(FORM_URL);

  // The read tab navigates: the panel drops that page's answers instead of showing them for the wrong page.
  await job.goto(POSTING + "?next=1");
  await read(FORM_URL);
  await form.goto(POSTING);
  await expect(panel.getByText("Click the Offerlane button in the toolbar", { exact: false })).toBeVisible();

  // Web: bring the saved job in; it joins Discover, and the extension forgets it.
  await web.bringToFront();
  await web.getByRole("button", { name: "Bring in saved jobs" }).click();
  await expect(web.getByRole("status").last()).toHaveText("Added 1 saved job to Discover.");
  expect(await sw.evaluate(async () => (await chrome.storage.local.get("saved")).saved)).toEqual([]);
  await web.getByRole("button", { name: "Bring in saved jobs" }).click();
  await expect(web.getByRole("status").last()).toHaveText("No new saved jobs.");
  await web.goto(WEB + "/#/find");
  await expect(web.getByRole("list", { name: "Matches" }).getByRole("article")).toHaveCount(1);
  await expect(web.getByRole("heading", { name: "Data Engineer" })).toBeVisible();
  await web.getByRole("button", { name: "Approve Data Engineer at Beta" }).click();
  await expect(web.getByText(/Approved Data Engineer at Beta/)).toBeVisible();

  // Forget removes the answer set from the browser.
  await panel.bringToFront();
  await panel.getByRole("button", { name: "Forget my answers on this browser" }).click();
  await expect(panel.getByRole("status")).toHaveText("Your answers are removed from this browser.");
  await expect(panel.getByRole("button", { name: "Forget my answers on this browser" })).toHaveCount(0);
  expect(await sw.evaluate(async () => (await chrome.storage.local.get("answers")).answers)).toBeUndefined();
});

test("a page from another origin can't talk to the extension, and a bad message is refused", async () => {
  const p = watch(await ctx.newPage());
  await p.goto(POSTING);  // 127.0.0.1:4199 isn't the web origin (and the port check refuses it even though the host matches)
  const r = await p.evaluate((id) => new Promise((ok) => {
    const rt = (globalThis as { chrome?: { runtime?: { sendMessage?: (id: string, m: unknown, cb: (x: unknown) => void) => void; lastError?: unknown } } }).chrome?.runtime;
    if (!rt?.sendMessage) return ok("no runtime");
    rt.sendMessage(id, { type: "saved" }, (x) => { void rt.lastError; ok(x === undefined ? "no reply" : x); });
  }), ID);
  expect(["no runtime", "no reply"]).toContain(r);
  const web = watch(await ctx.newPage());
  await web.goto(WEB + "/");
  expect(await web.evaluate((id) => new Promise((ok) => {
    (globalThis as unknown as { chrome: { runtime: { sendMessage: (id: string, m: unknown, cb: (x: unknown) => void) => void } } }).chrome.runtime.sendMessage(id, { type: "fill", selector: "#fn" }, ok);
  }), ID)).toEqual({ ok: false });
});
