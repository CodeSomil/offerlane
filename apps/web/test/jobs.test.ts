import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { job, tailorPlan } from "@offerlane/core";
import { addFound, loadSaved, MoveError, saveDraft, setStatus } from "../src/jobs.js";
import { setItem } from "../src/store.js";

const j = job({ id: "d1", company: "Globex", title: "Data Scientist" });
const plan = { ...tailorPlan({}), headline: "Forecasting lead", cover_letter: "Hi" };

describe("drafts (saveDraft, P3.6)", () => {
  it("moves tailoring to review with the plan and answers, and approving keeps them", async () => {
    await setStatus(j, 80, "tailoring");
    await saveDraft("d1", plan, "### Cover letter\nHi\n");
    let s = (await loadSaved()).d1!;
    expect(s.status).toBe("review"); expect(s.plan).toEqual(plan); expect(s.answers).toBe("### Cover letter\nHi\n"); expect(s.score).toBe(80);
    await saveDraft("d1", { ...plan, headline: "Edited" }, "edited");   // edits in review stay in review
    await setStatus(s.job, 80, "ready");
    s = (await loadSaved()).d1!;
    expect(s.status).toBe("ready"); expect(s.plan?.headline).toBe("Edited"); expect(s.answers).toBe("edited");
  });
  it("refuses a role that moved on or is gone, and writes nothing", async () => {
    await expect(saveDraft("d1", plan, "")).rejects.toBeInstanceOf(MoveError);        // d1 is ready now
    await expect(saveDraft("nope", plan, "")).rejects.toBeInstanceOf(MoveError);
    expect((await loadSaved()).d1!.plan?.headline).toBe("Edited");
  });
  it("reads a broken saved plan leniently", async () => {
    await setItem("applications", { x: { job: { id: "x" }, status: "review", plan: "junk", answers: 5 } });
    const s = (await loadSaved()).x!;
    expect(s.plan).toBeUndefined(); expect(s.answers).toBeUndefined();
  });
});

describe("addFound (jobs saved with the extension, P3.8)", () => {
  it("adds new jobs as found; skips ones already saved by id or address, and repeats in one batch", async () => {
    await setItem("applications", {});
    await setStatus(job({ id: "k1", title: "Kept", url: "https://jobs.lever.co/acme/aaaaaaaa-1111-2222-3333-444444444444" }), 50, "tailoring");
    const n = await addFound([
      job({ id: "k1", title: "Same id" }),
      job({ id: "lever:acme:aaaaaaaa-1111-2222-3333-444444444444", title: "Same posting", url: "https://jobs.lever.co/acme/aaaaaaaa-1111-2222-3333-444444444444/apply" }),
      job({ id: "n1", title: "New", url: "https://careers.beta.test/jobs?gh_jid=1" }),
      job({ id: "n1", title: "New again", url: "https://careers.beta.test/jobs?gh_jid=1" }),
      job({ id: "n2", title: "Other", url: "https://careers.beta.test/jobs?gh_jid=2" }),
      job({ id: "", title: "No id" }),
    ]);
    const s = await loadSaved();
    expect(n).toBe(2);
    expect(Object.fromEntries(Object.entries(s).map(([k, v]) => [k, [v.status, v.job.title]]))).toEqual({
      k1: ["tailoring", "Kept"], n1: ["found", "New"], n2: ["found", "Other"] });
  });
});
