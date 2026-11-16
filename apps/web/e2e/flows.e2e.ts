// The core Mac flows on the web (P3.5), against a fake LLM and a stub API.
import { expect, test } from "@playwright/test";
import { newProfile, prefill, RESUME_PARSE_PROMPT, resumeFromParsed } from "@offerlane/core";
import { API, apiJob, axeBoth, connect, fakeLLM, guards, seed } from "./helpers.js";

guards();

const RESUME = "Test Person\ntest@example.com\nLondon, UK\nSenior Data Scientist, Acme (2022 - now)\n" +
  "- Built demand forecasting for 1,200 products, cutting error by 30%.\n- Led 4 analysts on pricing experiments in Python and SQL.\n" +
  "Data Analyst, Initrode (2019 - 2022)\n- Automated 12 weekly reports with dbt and Airflow.\nSkills: Python, SQL, dbt, Airflow, forecasting\n";
const PARSED = {
  name: "Test Person", email: "test@example.com", phone: "", location: "London, UK", links: { linkedin: "", github: "", portfolio: "" },
  headline: "Data Scientist", summary: "",
  experience: [{ company: "Acme", title: "Senior Data Scientist", location: "London", dates: "2022 - now",
                 bullets: ["Built demand forecasting for 1,200 products, cutting error by 30%.", "Led 4 analysts on pricing experiments in Python and SQL."] },
               { company: "Initrode", title: "Data Analyst", location: "", dates: "2019 - 2022", bullets: ["Automated 12 weekly reports with dbt and Airflow."] }],
  projects: [], education: [], skills: [{ label: "Skills", items: "Python, SQL, dbt, Airflow, forecasting" }], certifications: [], extras: [],
  years_experience: 5, seniority: "senior", field: "data science", suggested_titles: ["Data Scientist", "ML Engineer"], top_skills: ["python", "sql", "forecasting"],
};

test("onboarding: paste a resume, one AI parse, check details, saved on this device", async ({ page }) => {
  let n = 0;
  const prompts = await fakeLLM(page, () => (++n === 1 ? "Sure! Here it is: {not json" : "```json\n" + JSON.stringify(PARSED) + "\n```"));
  await page.goto("/#/resumes");
  await page.getByLabel("Paste your resume").fill(RESUME);
  await page.getByRole("button", { name: "Read my resume" }).click();
  await expect(page.getByRole("alert")).toHaveText(/Connect an AI first/);

  await connect(page, "resumes");
  await page.getByLabel("Paste your resume").fill("too short");
  await page.getByRole("button", { name: "Read my resume" }).click();
  await expect(page.getByRole("alert")).toHaveText(/too little text/);
  await page.getByLabel("Paste your resume").fill(RESUME.repeat(2));
  await page.getByRole("button", { name: "Read my resume" }).click();
  await expect(page.getByRole("status")).toHaveText("Read 2 roles and 3 bullets. Check your details below, then save.");
  // The first reply was broken: one repair call on the fast model with only that reply.
  expect(prompts.slice(1)).toEqual([RESUME_PARSE_PROMPT + RESUME.repeat(2),
    "Fix this into valid JSON. Keep every value; drop any prose or code fences. Reply with the JSON only.\n\nSure! Here it is: {not json"]);

  await expect(page.getByLabel("First name")).toHaveValue("Test");
  await expect(page.getByLabel("Last name")).toHaveValue("Person");
  await expect(page.getByLabel("Current title")).toHaveValue("Senior Data Scientist");
  await expect(page.getByLabel(/Countries where you can work/)).toHaveValue("United Kingdom");
  await page.getByLabel("Email").fill("not an email");
  await page.getByRole("button", { name: "Save profile" }).click();
  await expect(page.getByText("Enter a valid email address.")).toBeVisible();
  await expect(page.getByLabel("Email")).toHaveAttribute("aria-invalid", "true");
  await axeBoth(page);
  await page.getByLabel("Email").fill("test@example.com");
  await page.getByRole("button", { name: "Save profile" }).click();
  await expect(page.getByRole("status")).toHaveText(/Saved on this device/);

  await page.reload();
  await expect(page.getByLabel("First name")).toHaveValue("Test");
  await expect(page.getByText("Data Scientist · Acme, Initrode")).toBeVisible();
});

const content = resumeFromParsed(PARSED, "main", "Main");
const me = { resume: { name: "main", label: "Main", is_default: true, content, source_text: RESUME, source_file: "cv.txt", created: "2026-11-01T00:00:00Z" },
             profile: { ...prefill(newProfile(), content), authorization: { citizenship: "", authorized_countries: ["United Kingdom"], needs_sponsorship: true } } };

test("Discover: index search sends only the title, local ranking, keyboard triage, saved decisions", async ({ page }) => {
  const urls: URL[] = [];
  await page.route(`${API}/v1/jobs*`, (r) => {
    urls.push(new URL(r.request().url()));
    expect(r.request().headers().authorization).toBeUndefined();  // no sign-in yet (P3.7)
    return r.fulfill({ headers: { "access-control-allow-origin": "*" }, json: { next: null, items: [
      apiJob("j1", "Warehouse Assistant", "Boxco", { description: "Lifting boxes." }),
      apiJob("j2", "Senior Data Scientist", "Globex", { location: "New York, US", description: "Python, SQL and forecasting. £70,000 - £85,000 per year. We cannot sponsor visas." }),
      apiJob("j3", "Data Scientist", "Initech", { description: "Python and SQL forecasting. Visa sponsorship available." }),
    ] } });
  });
  await seed(page, me);
  await page.goto("/#/find");
  const cards = page.getByRole("list", { name: "Matches" }).getByRole("article");
  await expect(cards).toHaveCount(3);
  expect(Object.fromEntries(urls[0]!.searchParams)).toEqual({ q: "Data Scientist", limit: "50" });
  await expect(cards.getByRole("heading")).toHaveText(["Data Scientist", "Senior Data Scientist", "Warehouse Assistant"]);
  await expect(cards.nth(1)).toContainText("£70–85k");
  await expect(cards.nth(1)).toContainText("No sponsorship");
  await expect(cards.nth(0)).toContainText("Can work here");  // London, and the profile can work in the UK
  await expect(cards.nth(0)).toContainText("Why it fits: python, sql, forecasting");
  await axeBoth(page);

  await cards.nth(0).focus();
  await page.keyboard.press("j");
  await expect(cards.nth(1)).toBeFocused();
  await page.keyboard.press("d");
  await expect(page.getByRole("status")).toHaveText(/Declined Senior Data Scientist at Globex/);
  await expect(cards).toHaveCount(2);
  await expect(cards.nth(1)).toBeFocused();  // the next card
  await page.keyboard.press("k");
  await page.keyboard.press("a");
  await expect(page.getByRole("status")).toHaveText(/Approved Data Scientist at Initech/);
  await expect(cards.first()).toBeFocused();  // focus has moved to the next card (one frame later)
  await page.getByLabel("Job title").press("a");  // typing in the search box never triages
  await expect(cards).toHaveCount(1);

  await page.reload();
  await expect(cards).toHaveCount(1);  // decisions are remembered; declined jobs don't come back
  await expect(cards.getByRole("heading")).toHaveText(["Warehouse Assistant"]);
  await cards.first().focus();
  await page.keyboard.press("d");
  await expect(cards).toHaveCount(0);
  await expect(page.getByLabel("Job title")).toBeFocused();  // after the last card, focus goes to the search field
});

test("Discover: signed out (401), unreachable index, and no resume yet", async ({ page }) => {
  let mode: "401" | "down" = "401";  // "down" aborts the request: helpers.ts guards() allows that one console error
  await page.route(`${API}/v1/jobs*`, (r) => (mode === "401" ? r.fulfill({ status: 401, headers: { "access-control-allow-origin": "*" }, json: { error: "unauthorized" } }) : r.abort()));
  await page.goto("/#/find");
  await expect(page.getByRole("link", { name: "Profile → Resumes" })).toBeVisible();
  await seed(page, me);
  await page.goto("/#/find");
  await expect(page.getByRole("alert")).toHaveText(/Sign in \(Settings\) to search Offerlane's job index/);
  await axeBoth(page);
  mode = "down";
  await page.getByRole("button", { name: "Search" }).click();
  await expect(page.getByRole("alert")).toHaveText(/Couldn't reach Offerlane's job index/);
});

const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString();
const app = (id: string, title: string, status: string, age: number) => {
  const job = { id, company: `Co ${id}`, title, location: "London, UK", url: "", apply_url: "", ats: "greenhouse", ats_slug: "", posted: null,
                description: "", visa: "ok", min_years: null, variant: "main", tailor_note: "" };
  return [id, { job, status, score: 60, created: daysAgo(age), updated: daysAgo(age) }] as const;
};

test("Pipeline: stages, stale hint, next steps, move by menu and by drag, remembered", async ({ page }) => {
  await seed(page, { ...me, applications: Object.fromEntries([app("a1", "Analyst", "applied", 20), app("a2", "Data Scientist", "interview", 1),
    app("a3", "ML Engineer", "applied", 2), app("a4", "Approved Role", "tailoring", 0), app("a5", "Declined Role", "declined", 0),
    ["broken", { status: "applied" }]]) });  // an unreadable stored entry is skipped, not a blank view
  await page.goto("/#/applications");
  await expect(page.getByText("3 applications · 1 needs a follow-up · 1 approved role not sent yet, see Review")).toBeVisible();
  const col = (name: string) => page.getByRole("region", { name: new RegExp(`^${name} \\d`) });
  await expect(col("Applied").getByRole("listitem")).toHaveCount(2);
  const analyst = col("Applied").getByRole("listitem").filter({ hasText: "Analyst" });
  await expect(analyst).toContainText("Quiet for 20 days");
  await expect(analyst).toContainText("Send a short follow-up");
  await expect(col("Interview")).toContainText("Prepare your STAR stories");
  await expect(page.getByText("Approved Role", { exact: true })).toHaveCount(0);  // not submitted: not on the board
  await axeBoth(page);

  await page.getByLabel("Move ML Engineer to").selectOption("screen");
  await expect(page.getByRole("status")).toHaveText("Moved ML Engineer at Co a3 to Screen.");
  await expect(col("Screen")).toContainText("ML Engineer");
  await expect(page.getByLabel("Move ML Engineer to").locator("option")).toHaveText(["Choose a stage…", "Applied", "Acknowledged", "Assessment", "Interview", "Offer", "Rejected", "Withdrawn"]);

  await col("Interview").getByRole("listitem").dragTo(col("Offer"));
  await expect(col("Offer")).toContainText("Data Scientist");
  await expect(col("Offer").getByRole("listitem")).toHaveClass(/offer/);
  await page.getByLabel("Move Analyst to").selectOption("rejected");
  await expect(page.getByText("2 applications")).toBeVisible();

  await page.reload();
  await expect(col("Offer")).toContainText("Data Scientist");
  await expect(col("Screen")).toContainText("ML Engineer");
  await expect(page.getByText("Analyst", { exact: true })).toHaveCount(0);
});

test("Review: ready roles; a browser offers no filling, and \"I've submitted it\" puts a role on the board", async ({ page }) => {
  const r1 = app("r1", "Ready Role", "ready", 1);
  r1[1].job.url = "https://jobs.example.com/r1";
  await seed(page, { ...me, applications: Object.fromEntries([r1, app("r2", "Half Done", "prefilled", 0), app("r3", "Still Tailoring", "tailoring", 0)]) });
  await page.goto("/#/review");
  const ready = page.getByRole("region", { name: /^Ready to apply/ });
  await expect(ready.getByRole("listitem")).toHaveCount(2);
  await expect(ready.getByRole("listitem").filter({ hasText: "Half Done" })).toContainText("Ready to submit");
  await expect(page.getByRole("button", { name: /^Fill in/ })).toHaveCount(0);  // only the Windows app fills forms
  await expect(ready).toContainText("browser extension");
  await expect(ready.getByRole("link", { name: "Open the posting for Ready Role at Co r1" })).toHaveAttribute("target", "_blank");
  await axeBoth(page);

  await ready.getByRole("button", { name: "I've submitted it: Ready Role at Co r1" }).click();
  await expect(page.getByRole("status")).toHaveText("Moved Ready Role at Co r1 to Applied.");
  await expect(ready.getByRole("listitem")).toHaveCount(1);
  await page.goto("/#/applications");
  await expect(page.getByRole("region", { name: /^Applied \d/ })).toContainText("Ready Role");
});

test("Pipeline: empty state points to Discover", async ({ page }) => {
  await page.goto("/#/applications");
  await expect(page.getByRole("link", { name: "Discover" }).last()).toHaveAttribute("href", "#/find");
  await expect(page.getByText("No applications yet.")).toBeVisible();
  await axeBoth(page);
});

test("Today: next action follows setup, then a follow-up; checklist, funnel, interviews", async ({ page }) => {
  await page.goto("/");
  const next = page.getByRole("region", { name: "Next" });
  await expect(next.getByRole("link")).toHaveText("Connect an AI");
  await expect(page.getByText("0 of 3 done")).toBeVisible();
  await expect(page.getByText("No interviews in progress.")).toBeVisible();
  await axeBoth(page);

  await seed(page, { ...me, applications: Object.fromEntries([app("a1", "Analyst", "applied", 20), app("a2", "Data Scientist", "interview", 1),
    app("a3", "ML Engineer", "applied", 2), app("a4", "Approved Role", "tailoring", 0)]) });
  await fakeLLM(page, () => "{}");
  await connect(page, "home");
  await expect(next.getByRole("link")).toHaveText("Follow up with Co a1");
  await expect(next.getByRole("link")).toHaveAttribute("href", "#/applications");
  await expect(page.getByText("3 of 3 done")).toBeVisible();
  const week = page.getByRole("region", { name: "This week" });
  await expect(week.locator("dd")).toHaveText(["3", "2", "1", "0"]);  // a1 changed 20 days ago: not this week
  await expect(week).toContainText("1 approved role not sent yet. See Review.");
  await expect(page.getByRole("region", { name: "Interviews" })).toContainText("Data Scientist at Co a2 · Interview");
  await axeBoth(page);
});

const approved = (id: string, title: string, note = "") => [id, { job: { id, company: "Globex", title, location: "London, UK", url: "", apply_url: "", ats: "greenhouse",
  ats_slug: "", posted: null, description: "Forecasting and pricing in Python.", visa: "ok", min_years: null, variant: "main", tailor_note: note },
  status: "tailoring", score: 70, created: daysAgo(0), updated: daysAgo(0) }] as const;
const PLAN = { keywords: ["pricing"], headline: "Data Scientist, pricing", summary: "", order: { e1: ["e1.2", "e1.1"] },
  rewrites: { "e1.1": "Built demand forecasting for 1,200 products, cutting forecast error by 30%." }, skills_order: [],
  cover_letter: "Dear Globex team, I led 4 analysts on pricing.", why_company: "I grew revenue 80%.", answers: [{ q: "Why this role?", a: "Pricing is my work." }],
  changes_summary: "Led with pricing." };

test("Review: AI tailoring, every change against the original, Guard on edits, downloads, approve", async ({ page }) => {
  const prompts = await fakeLLM(page, () => JSON.stringify(PLAN));
  await seed(page, { ...me, applications: Object.fromEntries([approved("r1", "Pricing Scientist")]) });
  await connect(page, "review");
  await page.getByRole("button", { name: "Tailor for Pricing Scientist at Globex" }).click();
  await expect(page.getByRole("status")).toHaveText('Draft ready for Globex. Open it below to check every change. The Guard removed: why us removed: numbers not in your resume: ["80"].');
  expect(prompts.at(-1)).toMatch(/^JOB: Pricing Scientist at Globex/);
  await page.getByRole("button", { name: "Review Pricing Scientist at Globex" }).click();
  const b1 = page.getByLabel("Bullet 1 in Senior Data Scientist @ Acme", { exact: true }), b2 = page.getByLabel("Bullet 2 in Senior Data Scientist @ Acme", { exact: true });
  await expect(b1).toHaveValue("Led 4 analysts on pricing experiments in Python and SQL.");   // the AI's order
  await expect(b2).toHaveValue(PLAN.rewrites["e1.1"]);
  await expect(page.getByText("Was: Built demand forecasting for 1,200 products, cutting error by 30%.")).toBeVisible();
  await expect(page.getByLabel("answers.md")).toHaveValue(/### Why Globex\?\n\n/);              // the rejected why-us is blank
  await axeBoth(page);
  // An edit with a number the resume doesn't have: the Guard rejects it and the original stays.
  await b1.fill("Led 9 analysts on pricing experiments in Python and SQL.");
  await page.getByRole("button", { name: "Save edits" }).click();
  await expect(page.getByRole("region", { name: "Guard notes" })).toContainText('e1.2 REJECTED, kept original: numbers not in your resume: ["9"]');
  await expect(b1).toHaveValue("Led 4 analysts on pricing experiments in Python and SQL.");
  await page.getByRole("button", { name: "Move bullet 1 in Senior Data Scientist @ Acme down" }).click();
  await page.getByRole("button", { name: "Save edits" }).click();
  await expect(page.getByRole("status")).toHaveText("Saved. The Guard checked every change again.");
  // Saved edits are what a reopened draft shows.
  await page.getByRole("button", { name: "← All drafts" }).click();
  await page.getByRole("button", { name: "Review Pricing Scientist at Globex" }).click();
  await expect(b1).toHaveValue(PLAN.rewrites["e1.1"]);
  const md = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download resume.md" }).click();
  const file = await md;
  expect(file.suggestedFilename()).toBe("resume.md");
  const text = await (await import("node:fs/promises")).readFile((await file.path())!, "utf8");
  expect(text).toContain(`### Senior Data Scientist, Acme\nLondon · 2022 - now\n\n- ${PLAN.rewrites["e1.1"]}\n- Led 4 analysts`);
  // Approve with an edit the Guard rejects: nothing is approved, the original is back and the reason is shown.
  await b2.fill("Led 9 analysts on pricing experiments in Python and SQL.");
  await page.getByRole("button", { name: "Approve" }).click();
  await expect(page.getByRole("alert")).toHaveText("The Guard put back the original of a change it rejected; see Guard notes.");
  await expect(b2).toHaveValue("Led 4 analysts on pricing experiments in Python and SQL.");
  await page.getByRole("button", { name: "Approve" }).click();
  await expect(page.getByRole("status")).toHaveText("Approved Pricing Scientist at Globex. It's ready to apply.");
  await expect(page.getByRole("region", { name: /^Ready for your review/ })).toContainText("No drafts yet.");
  await page.reload();
  await expect(page.getByRole("region", { name: /^Approved, waiting/ })).toContainText("Approve roles in");   // remembered
});

test("Review: Copy to Claude leaves out contact details, refuses invented numbers and unreadable replies; as-is draft", async ({ page }) => {
  await seed(page, { ...me, profile: { ...me.profile, personal: { ...me.profile.personal, phone: "07700 900123" } },
    applications: Object.fromEntries([approved("r1", "Pricing Scientist", "call 07700 900123 or test@example.com"), approved("r2", "Analyst")]) });
  await page.goto("/#/review");
  await page.getByRole("button", { name: "Copy to Claude for Pricing Scientist at Globex" }).click();
  const out = page.getByLabel(/1\. Paste this into your Claude chat/);
  await expect(out).toHaveValue(/BULLET BANK:/);
  await expect(out).toHaveValue(/CANDIDATE'S NOTE: call <personal> or <email>/);
  expect(await out.inputValue()).not.toMatch(/07700|test@example\.com/);
  const reply = page.getByLabel("2. Paste Claude's whole reply here"), check = page.getByRole("button", { name: "Check and save draft" });
  await reply.fill("Sorry, I can't do that.");
  await check.click();
  await expect(page.getByRole("alert")).toHaveText(/^Offerlane couldn't read that reply/);
  await reply.fill("Here you go:\n```json\n" + JSON.stringify({ ...PLAN, why_company: "" , cover_letter: "I grew revenue 80%." }) + "\n```");
  await check.click();
  await expect(page.getByRole("alert")).toHaveText('Nothing was saved. The Guard rejected: cover letter REJECTED: numbers not in your resume: ["80"]. Use only facts and numbers from the resume.');
  await expect(page.getByRole("region", { name: /^Ready for your review/ })).toContainText("No drafts yet.");
  await reply.fill(JSON.stringify({ ...PLAN, why_company: "Pricing at scale." }));
  await check.click();
  await expect(page.getByRole("status")).toHaveText("Claude's draft for Globex passed the Guard. Open it below.");
  await page.getByRole("button", { name: "Use my resume as-is for Analyst at Globex" }).click();
  await expect(page.getByRole("status")).toHaveText("Using your resume as-is for Globex.");
  await page.getByRole("button", { name: "Review Pricing Scientist at Globex" }).click();
  await expect(page.getByText("Drafted with Claude. Led with pricing.")).toBeVisible();
  await axeBoth(page);
});
