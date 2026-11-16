// v4 P3.8: the extension's "Save this job" reader and the web <-> extension message checks.
import { describe, expect, it } from "vitest";
import * as C from "../src/index.js";

const page = (url: string, ld: unknown[] = [], extra: Partial<C.PageInfo> = {}): C.PageInfo =>
  ({ url, title: "", h1: "", ldjson: ld.map((x) => (typeof x === "string" ? x : JSON.stringify(x))), ...extra });

const posting = {
  "@context": "https://schema.org", "@type": "JobPosting", title: " Senior Engineer ", datePosted: "2026-11-02T09:00:00Z",
  description: "<p>Build &amp; ship <b>things</b>.</p><ul><li>Go</li></ul>",
  hiringOrganization: { "@type": "Organization", name: "Acme Ltd" },
  jobLocation: [{ "@type": "Place", address: { addressLocality: "London", addressRegion: "", addressCountry: { name: "United Kingdom" } } },
                { "@type": "Place", address: { addressLocality: "Leeds", addressCountry: "GB" } }],
  identifier: { "@type": "PropertyValue", value: 4567890 },
};

describe("atsFromURL", () => {
  it.each([
    ["https://boards.greenhouse.io/scaleai/jobs/4567890?gh_src=x", ["greenhouse", "scaleai", "4567890"]],
    ["https://job-boards.greenhouse.io/scaleai/jobs/4567890", ["greenhouse", "scaleai", "4567890"]],
    ["https://job-boards.greenhouse.io/embed/job_app?for=scaleai&token=4567890", ["greenhouse", "scaleai", "4567890"]],
    ["https://boards.greenhouse.io/embed/job_app?for=scaleai&token=4567890", ["greenhouse", "scaleai", "4567890"]],
    ["https://nvidia.wd5.myworkdayjobs.com/en-US/Site/job/US-CA/Senior-Engineer_JR-1990001/apply/applyManually", ["workday", "nvidia", "JR-1990001"]],
    ["https://jobs.lever.co/spotify/5e1c2b7a-1111-2222-3333-444455556666/apply", ["lever", "spotify", "5e1c2b7a-1111-2222-3333-444455556666"]],
    ["https://jobs.ashbyhq.com/openai/0a1b2c3d-aaaa-bbbb-cccc-ddddeeeeffff/application", ["ashby", "openai", "0a1b2c3d-aaaa-bbbb-cccc-ddddeeeeffff"]],
    ["https://apply.workable.com/acme/j/ABC123DEF/", ["workable", "acme", "ABC123DEF"]],
    ["https://jobs.smartrecruiters.com/Visa/744000012345678-senior-engineer", ["smartrecruiters", "Visa", "744000012345678"]],
    ["https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite/job/US-CA-Santa-Clara/Senior-Engineer_JR1990001", ["workday", "nvidia", "JR1990001"]],
  ])("%s", (url, [ats, slug, id]) => expect(C.atsFromURL(url)).toEqual({ ats, slug, id }));
  it("ignores other sites and look-alike hosts", () => {
    expect(C.atsFromURL("https://example.com/jobs/1")).toBeNull();
    expect(C.atsFromURL("https://jobs.lever.co.evil.test/spotify/abc")).toBeNull();
    expect(C.atsFromURL("https://boards.greenhouse.io/scaleai")).toBeNull();
    expect(C.atsFromURL("not a url")).toBeNull();
  });
});

describe("readPosting", () => {
  const now = new Date("2026-11-16T12:00:00Z");
  it("reads a JSON-LD JobPosting on a job-site page", () => {
    const j = C.readPosting(page("https://boards.greenhouse.io/acme/jobs/4567890#app", [posting]), now)!;
    expect(j).toEqual({ ...C.job({}), id: "greenhouse:acme:4567890", company: "Acme Ltd", title: "Senior Engineer",
      location: "London, United Kingdom; Leeds, GB", url: "https://boards.greenhouse.io/acme/jobs/4567890", apply_url: "https://boards.greenhouse.io/acme/jobs/4567890",
      ats: "greenhouse", ats_slug: "acme", posted: "2026-11-02", description: "Build & ship things . Go", variant: "main" });
  });
  it("finds the posting inside @graph and arrays, and skips broken blocks", () => {
    const j = C.readPosting(page("https://careers.acme.test/jobs/eng?ref=li", ["{not json", [{ "@type": "WebSite" }],
      { "@graph": [{ ...posting, "@type": ["Thing", "JobPosting"], jobLocation: undefined, jobLocationType: "TELECOMMUTE", url: "https://careers.acme.test/jobs/eng" }] }]), now)!;
    expect(j.id).toBe("web:careers.acme.test/jobs/eng");
    expect(j.location).toBe("Remote");
    expect(j.ats).toBe("");
  });
  it("falls back to the job-site URL and the page heading", () => {
    const j = C.readPosting(page("https://jobs.lever.co/spotify/5e1c2b7a-1111-2222-3333-444455556666", [], { title: "Spotify - Data Engineer", h1: " Data Engineer " }), now)!;
    expect([j.id, j.company, j.title, j.ats]).toEqual(["lever:spotify:5e1c2b7a-1111-2222-3333-444455556666", "Spotify", "Data Engineer", "lever"]);
  });
  it("gives up on a page that is neither", () => {
    expect(C.readPosting(page("https://news.test/a", [{ "@type": "Article", headline: "x" }], { h1: "Hello" }), now)).toBeNull();
  });
  it("keeps only http(s) links, caps the text and drops a future or bad date", () => {
    const j = C.readPosting(page("https://careers.acme.test/j/1", [{ ...posting, url: "javascript:alert(1)", datePosted: "2099-01-01",
      title: "x".repeat(500), description: "y".repeat(40_000) }]), now)!;
    expect(j.url).toBe("https://careers.acme.test/j/1");
    expect(j.posted).toBeNull();
    expect(j.title.length).toBe(200);
    expect(j.description.length).toBe(20_000);
    expect(C.readPosting(page("file:///etc/passwd", [posting]), now)).toBeNull();
  });
});

describe("job ids keep the query that names the job", () => {
  const now = new Date("2026-11-16T12:00:00Z");
  const at = (u: string) => C.readPosting(page(u, [{ "@type": "JobPosting", title: "T" }]), now)!.id;
  it("different gh_jid = different jobs; tracking parameters don't count", () => {
    expect(at("https://careers.acme.test/jobs?gh_jid=1")).not.toBe(at("https://careers.acme.test/jobs?gh_jid=2"));
    expect(at("https://careers.acme.test/jobs?gh_jid=1&utm_source=li&ref=x")).toBe(at("https://careers.acme.test/jobs?gh_jid=1"));
    const j = { ...C.job({}), url: "https://careers.acme.test/jobs?gh_jid=1" };
    expect(C.sameJob(j, "https://careers.acme.test/jobs?gh_jid=2")).toBe(false);
    expect(C.sameJob(j, "https://careers.acme.test/jobs/?utm_medium=x&gh_jid=1")).toBe(true);
  });
});

describe("sameJob", () => {
  const j = { ...C.job({}), url: "https://jobs.lever.co/spotify/abc", apply_url: "", ats: "lever" };
  it("matches the posting, its form and other query strings, not other jobs", () => {
    expect(C.sameJob(j, "https://jobs.lever.co/spotify/abc/apply?lever-source=x")).toBe(true);
    expect(C.sameJob(j, "https://jobs.lever.co/spotify/abc/")).toBe(true);
    expect(C.sameJob(j, "https://jobs.lever.co/spotify/abd")).toBe(false);
    expect(C.sameJob({ ...j, url: "" }, "https://example.com/")).toBe(false);
  });
});

describe("bridge messages", () => {
  const p = C.newProfile(), jb = { ...C.job({ id: "a", url: "https://x.test/a" }) };
  it("accepts the three web requests", () => {
    expect(C.toExtension({ type: "answers", profile: p, jobs: [{ job: jb, answers: "### Why\nBecause" }] }))
      .toEqual({ type: "answers", profile: p, jobs: [{ job: jb, answers: "### Why\nBecause" }] });
    expect(C.toExtension({ type: "saved" })).toEqual({ type: "saved" });
    expect(C.toExtension({ type: "clear", ids: ["a", "b"] })).toEqual({ type: "clear", ids: ["a", "b"] });
    expect(C.toExtension({ type: "ping" })).toEqual({ type: "ping" });
  });
  it("refuses anything else", () => {
    for (const m of [null, "answers", {}, { type: "fill" }, { type: "answers", profile: p, jobs: "x" }, { type: "clear", ids: [1] },
      { type: "answers", profile: p, jobs: Array(501).fill({ job: jb, answers: "" }) }, { type: "answers", profile: p, jobs: [{ job: jb, answers: "x".repeat(60_001) }] },
      { type: "answers", profile: null, jobs: [] },
      { type: "answers", profile: { ...p, prefs: { ...p.prefs, notes: "x".repeat(8_000_001) } }, jobs: [] }])
      expect(C.toExtension(m)).toBeNull();
  });
  it("the web reads saved jobs back leniently and only with http(s) links", () => {
    expect(C.savedReply({ ok: true, jobs: [{ id: "a", title: "T", url: "javascript:x" }, "junk", { title: "no id" }] }))
      .toEqual([{ ...C.job({ id: "a", title: "T" }), url: "" }]);
    expect(C.savedReply(undefined)).toBeNull();
  });
});
