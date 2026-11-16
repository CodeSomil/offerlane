// Parity gate (v4 P3.2): the TS port must give exactly what the Swift core gives for the shared fixtures.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import * as C from "../src/index.js";

const FX = new URL("../../../Packages/OfferlaneCore/Tests/OfferlaneCoreTests/Fixtures/", import.meta.url);
const fx = (name: string) => JSON.parse(readFileSync(new URL(name, FX), "utf8"));

describe("core golden (core_expected.json)", () => {
  const d = fx("core/core_expected.json");
  const v = C.resumeVersion(d.inputs.version), versions = d.inputs.versions.map(C.resumeVersion);
  const p = C.profile(d.inputs.profile), s = C.searchConfig(d.inputs.search), j = C.job(d.inputs.job), plan = C.tailorPlan(d.inputs.plan);
  const edits = d.inputs.edits as C.ReviewData;

  it("decodes the Swift shapes without loss", () => {
    expect(v).toEqual(d.inputs.version); expect(p).toEqual(d.inputs.profile); expect(plan).toEqual(d.inputs.plan);
  });
  it("Brief", () => {
    expect(C.candidateBrief(v.content, versions, p, s)).toBe(d.brief.private);
    expect(C.candidateBrief(v.content, versions, p, s, false)).toBe(d.brief.public);
    expect(C.candidateBrief(v.content, [v], C.profile({}), C.searchConfig({}))).toBe(d.brief.single);
  });
  it("Copy to Claude: scrub, parse, Guard on every text, answers.md", () => {
    const h = d.handoff;
    for (const c of h.clean) expect(C.scrub(c.text, c.known)).toBe(c.out);
    for (const c of h.parse) expect(C.parseHandoff(c.reply)).toEqual(c.plan === null ? null : C.tailorPlan(c.plan));
    expect(C.rejections(plan, v)).toEqual(h.rejections.plan);
    expect(C.rejections(C.tailorPlan(h.rejections.loudPlan), v)).toEqual(h.rejections.loud);
    expect(C.answersMarkdown(C.tailorPlan(h.answersMarkdown.plan), "Globex")).toBe(h.answersMarkdown.out);
    // The handoff text the web copies is the golden text, scrubbed: no email or phone survives.
    const text = C.handoffText(j, v, d.brief.public, ["020 7946 0000"]);
    expect(text).toBe(C.scrub(d.prompts.handoff, ["020 7946 0000"]));
    expect(C.handoffText({ ...j, tailor_note: "call me on 020 7946 0000 or me@x.io" }, v, "", ["020 7946 0000"])).not.toMatch(/0000|me@x/);
  });
  it("PlanApplier", () => {
    expect(C.compact(v.content)).toBe(d.compact);
    expect(C.planSource(v)).toBe(d.source);
    const [content, warnings] = C.applyPlan(plan, v);
    expect(warnings).toEqual(d.apply.warnings); expect(content).toEqual(d.apply.content);
    expect(C.review(plan, v)).toEqual(d.review);
    expect(C.planFromReview(edits, plan, v)).toEqual(d.planFromReview);
  });
  it("prompts", () => {
    const P = d.prompts, brief = d.brief.public;
    expect(C.rankHead(["main"])).toBe(P.rank);
    expect(C.rankHead(["main", "lead"])).toBe(P.rankMulti);
    expect(C.rankLine(j)).toBe(P.rankLine);
    expect(C.RESUME_PARSE_PROMPT).toBe(P.resumeParse);
    expect(C.SEARCH_SETUP_PROMPT).toBe(P.searchSetup);
    expect(C.searchBrief(s, v.content, versions, p)).toBe(P.searchBrief);
    expect(C.tailorRequest(j, v, brief)).toEqual(P.tailor);
    expect(C.handoffTextUnscrubbed(j, v, brief)).toBe(P.handoff);
    expect(C.companyBriefPrompt(C.companySource(j))).toBe(P.companyBrief);
    const parsed = C.resumeFromParsed(C.parseJSON(d.parse.reply, C.isObject), "main", "");
    expect(parsed).toEqual(d.parse.content);
    const typed = C.newProfile(); typed.personal.phone = "typed by the user";
    expect(C.prefill(typed, parsed)).toEqual(d.parse.profile);
    for (const c of d.companySupported) expect(C.companySupported(c.line, C.companySource(j)), c.line).toBe(c.ok);
  });
});

it("Guard cases", () => {
  for (const c of fx("core/guard_cases.json")) expect(C.guardCheck(c.new, c.source), c.why).toEqual({ ok: c.ok, warnings: c.warnings });
});

it("pay cases", () => {
  for (const c of fx("core/pay_cases.json")) expect(C.parsePay(c.text), c.text).toEqual(c.expect);
});

it("Adzuna countries and attribution (adzuna_cases.json)", () => {
  const c = fx("core/adzuna_cases.json");
  expect(C.ADZUNA_ATTRIBUTION).toBe(c.fallback);
  for (const a of c.attribution) expect(C.adzunaAttribution(a.url), a.url).toBe(a.expect);
  for (const r of c.defaultCountry) expect(C.adzunaDefaultCountry(r.region), String(r.region)).toBe(r.expect);
  expect(C.ADZUNA_COUNTRIES).toHaveLength(19);
  expect(C.adzunaCountry("de", "GB")).toBe("de");
  expect(C.adzunaCountry("", "GB")).toBe("gb");
});

it("ranking matches rank_expected.json (same inputs as RankingTests.swift)", () => {
  const expected = fx("rank_expected.json");
  // The parsed postings come from the ATS golden (AdapterGoldenTests.swift), so no ATS parser is needed here.
  const postings: { title: string; location: string; description: string; posted: string | null }[] = fx("ats_expected.json").greenhouse_scaleai;
  const r = C.resumeContent({ top_skills: ["python", "sql", "llm", "machine learning"] });
  const s = C.searchConfig({ target_titles: ["Data Scientist", "AI Product Manager"], penalty_keywords: ["computer vision"], locations: ["san francisco"] });
  const p = C.profile({ work: { years_experience: "5" }, authorization: { authorized_countries: ["India"], needs_sponsorship: true } });
  const ctx = C.rankContext(r, p, s), visa = new C.Visa(p), now = new Date("2026-10-31T00:00:00Z");
  expect(postings.length).toBe(Object.keys(expected).length);
  for (const post of postings) {
    const e = expected[post.title];
    const j = C.job({ company: "Scale AI", title: post.title, location: post.location, description: post.description, posted: post.posted });
    expect(C.localScore(j, ctx, visa, now), post.title).toBe(e.score);
    expect(j.min_years, post.title).toBe(e.min_years ?? null);
    expect(j.visa, post.title).toBe(e.visa);
    expect(C.condense(post.description), post.title).toBe(e.condense);
  }
  const w = { ...ctx, watch: ["scale ai"] };
  const a = C.job({ company: "Scale AI", title: "Data Scientist", location: "Remote" }), b = C.job({ company: "Unlisted Co", title: "Data Scientist", location: "Remote" });
  expect(C.localScore(a, w, visa) - C.localScore(b, w, visa)).toBe(10);
});

it("answers match answers_expected.json (same cases as AnswerRulesTests.swift)", () => {
  const f = fx("answers_expected.json");
  const p = C.profile(f.profile), answers = C.parseAnswers(f.answers_md);
  expect(answers.map((a) => a[0])).toEqual(["Cover letter", "Why Globex?", "Why do you want to work here?", "What is your biggest strength?"]);
  const visa = new C.Visa(p);
  let checked = 0;
  for (const c of f.want) {
    const R = C.rules(p, "London, UK", c.consent === true, visa);
    expect(C.want({ type: c.type, label: c.label }, R, answers)[0], `${c.label} consent=${c.consent}`).toBe(c.value ?? null);
    checked++;
  }
  expect(checked).toBe(60);
  for (const c of f.pick) expect(C.pick(c.options.filter((o: unknown) => typeof o === "string"), c.v)).toBe(c.pick ?? null);
});

it("formURL (same cases as AnswerRulesTests.testFormURL)", () => {
  const j = (url: string, ats: string, ats_slug = "") => C.job({ url, ats, ats_slug });
  expect(C.formURL(j("https://jobs.lever.co/spotify/abc", "lever"))).toBe("https://jobs.lever.co/spotify/abc/apply");
  expect(C.formURL(j("https://job-boards.greenhouse.io/scaleai/jobs/4567890?gh_src=x", "greenhouse", "scaleai"))).toBe("https://job-boards.greenhouse.io/embed/job_app?for=scaleai&token=4567890");
  expect(C.formURL(j("https://jobs.ashbyhq.com/perplexity/123", "ashby"))).toBe("https://jobs.ashbyhq.com/perplexity/123/application");
});

// Review fixes (P3.2): places where JS and Foundation/ICU differ and no shared fixture reaches.
it("a hyphenated country still matches (escapeRe is valid under the u flag)", () => {
  const p = C.profile({ authorization: { authorized_countries: ["Timor-Leste"], needs_sponsorship: true } });
  expect(new C.Visa(p).authorizedFor("Dili, Timor-Leste")).toBe(true);
  expect(new C.Visa(p).tag("Acme", "Dili, Timor-Leste", "")).toBe("ok");
});

it("an empty needle never matches, as in Foundation", () => {
  const answers: C.Answer[] = [["", "secret text"], ["Cover letter", "Dear team"]];
  expect(C.want({ type: "text", label: "*" }, [], answers)[0]).toBeNull();
  expect(C.bestAnswer("What is your notice period?", answers)).toBeNull();
  const r = C.resumeContent({}), p = C.profile({}), visa = new C.Visa(p), now = new Date("2026-10-31T00:00:00Z");
  const score = (s: C.SearchConfig) => C.localScore(C.job({ title: "x", location: "Paris" }), C.rankContext(r, p, s), visa, now);
  expect(score(C.searchConfig({ penalty_keywords: [""], locations: [""] }))).toBe(score(C.searchConfig({})));
});

it("prototype keys are ordinary ids", () => {
  const v = C.resumeVersion({ name: "m", content: { experience: [{ id: "constructor", bullets: [{ id: "toString", text: "Ran reviews." }] }] } });
  const [content] = C.applyPlan(C.tailorPlan({}), v);
  expect(content.experience[0]!.bullets.map((b) => b.text)).toEqual(["Ran reviews."]);
  expect(C.Visa.canon("constructor")).toBe("constructor");
});

it("the sponsor register path (Visa.inRegister)", () => {
  const p = C.profile({ authorization: { authorized_countries: ["India"], needs_sponsorship: true } });
  const visa = new C.Visa(p, { uk: ["acme analytics", "globex"].sort() });
  expect(visa.tag("Globex Ltd", "London, UK", "")).toBe("sponsor-register");
  expect(visa.tag("Acme", "London, UK", "")).toBe("sponsor-register"); // "acme analytics" starts with "acme "
  expect(visa.tag("Initech", "London, UK", "")).toBe("unknown");
  expect(new C.Visa(C.profile({ authorization: { needs_sponsorship: false } }), { uk: ["globex"] }).tag("Globex", "London, UK", "")).toBe("ok");
});

describe("profileErrors (Profile.validationErrors)", () => {
  it("flags the same fields as Swift", () => {
    const p = C.newProfile();
    expect(Object.keys(C.profileErrors(p)).sort()).toEqual(["countries", "email", "firstName", "lastName"]);
    p.personal.first_name = "Test"; p.personal.last_name = "Person"; p.personal.email = "test@example.com";
    p.authorization.authorized_countries = ["United Kingdom"];
    expect(C.profileErrors(p)).toEqual({});
    p.personal.phone = "12 34"; p.work.years_experience = "five"; p.personal.email = "a@b";
    expect(Object.keys(C.profileErrors(p)).sort()).toEqual(["email", "phone", "years"]);
  });
});

describe("JobStatus + PipelineHints (core_expected.json status, pipeline_cases.json)", () => {
  it("the status table matches Swift", () => {
    const d = fx("core/core_expected.json").status;
    expect([...C.STATUSES]).toEqual(d.order); expect([...C.TRACKED]).toEqual(d.tracked); expect(C.STATUS_TITLE).toEqual(d.titles);
    expect(Object.fromEntries(C.STATUSES.map((f) => [f, C.STATUSES.filter((t) => C.canMove(f, t))]))).toEqual(d.allowed);
    expect(C.canMove("nope", "applied")).toBe(false);
  });
  it("hints match the shared cases", () => {
    const f = fx("core/pipeline_cases.json"), now = new Date(f.now);
    for (const c of f.cases) {
      expect(C.pipelineAge(c.updated, now), c.why).toBe(c.age);
      expect(C.isStale(c.status, c.updated, now), c.why).toBe(c.stale);
      expect(C.nextStep(c.status, c.updated, now), c.why).toBe(c.next);
    }
  });
});

describe("profileErrors Unicode email (ICU \\w)", () => {
  it("accepts accented local parts like the Mac", () => {
    const p = C.newProfile(); p.personal.first_name = "Zoë"; p.personal.last_name = "José"; p.authorization.authorized_countries = ["Spain"];
    for (const e of ["zoë@example.com", "josé@correo.es", "a_b@x-y.example"]) { p.personal.email = e; expect(C.profileErrors(p), e).toEqual({}); }
    for (const e of ["a@b", "a b@x.com", "@x.com"]) { p.personal.email = e; expect(Object.keys(C.profileErrors(p)), e).toEqual(["email"]); }
  });
});
