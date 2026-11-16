import { describe, expect, it } from "vitest";
import { isConfirmation, isWorkday, strongPassword } from "../src/apply.js";

describe("apply helpers", () => {
  it("strongPassword: 18 chars from the set, every class present", () => {
    for (let n = 0; n < 200; n++) {
      const p = strongPassword();
      expect(p).toMatch(/^[a-km-zA-HJ-NP-Z2-9!@#$%*?]{18}$/);
      for (const rx of [/[a-z]/, /[A-Z]/, /[2-9]/, /[!@#$%*?]/]) expect(p).toMatch(rx);
    }
    expect(new Set(Array.from({ length: 50 }, () => strongPassword())).size).toBe(50);
  });
  it("isConfirmation: thank-you text or URL", () => {
    expect(isConfirmation("Thank you for applying!", "https://x.com/a")).toBe(true);
    expect(isConfirmation("Review", "https://x.com/jobs/thank-you")).toBe(true);
    expect(isConfirmation("Review your application", "https://x.com/apply")).toBe(false);
  });
  it("isWorkday: Workday hosts only", () => {
    expect(isWorkday("https://acme.wd5.myworkdayjobs.com/en-US/x")).toBe(true);
    expect(isWorkday("https://boards.greenhouse.io/acme")).toBe(false);
  });
});

import { ApplyEngine, type ApplyPage } from "../src/apply.js";
import { MemoryVault } from "../src/applySelfTest.js";
import { job, newProfile } from "../src/models.js";

/** A page that answers autofill calls from a table and records every call that acts on the page. */
function fakePage(host: () => string, answers: Record<string, unknown | ((args: unknown[]) => unknown)>) {
  const acts: [string, unknown[]][] = [];
  const page: ApplyPage = {
    url: async () => `https://${host()}/apply`, host: async () => host(), load: async () => {}, waitForLoad: async () => {}, eval: async () => null,
    async call(fn, args = []) {
      if (/^(click|clickAid|clickButton|clickMatching|type|typeAid|typeSel|typeAllPasswords|select|upload|uploadAid|comboType|promptPick|chooseOption)$/.test(fn)) acts.push([fn, args]);
      const a = answers[`${fn} ${JSON.stringify(args)}`] ?? answers[fn];
      return typeof a === "function" ? a(args) : a ?? null;
    },
  };
  return { page, acts };
}
const profile = () => { const p = newProfile(); p.personal.email = "me@example.com"; return p; };
const engine = (page: ApplyPage, vault: MemoryVault) =>
  new ApplyEngine({ page, job: job({ company: "Acme", location: "London" }), profile: profile(), answers: [], pdf: null, vault, pace: 0 });

describe("ApplyEngine safety branches", () => {
  it("generic: a page that creates the account and sends the application in one step is left to the person", async () => {
    const vault = new MemoryVault(); vault.approve("jobs.acme.com", "Acme");
    const { page, acts } = fakePage(() => "jobs.acme.com", {
      hasFormInputs: true, count: 2, 'anyVisible ["input[type=password]"]': true,
      buttons: [{ k: 0, name: "Create account" }, { k: 1, name: "Submit application" }],
    });
    const out = await engine(page, vault).run(true);
    expect(out.kind).toBe("needsYou");
    expect(out.message).toMatch(/creates an account and sends the application in one step/);
    expect(acts.filter(([f]) => f !== "banner")).toEqual([]);
    expect(vault.accounts.size).toBe(0);
  });

  it("workday: stops when the next button says Submit and never clicks it", async () => {
    const { page, acts } = fakePage(() => "acme.wd5.myworkdayjobs.com", {
      count: 5, 'visible ["bottom-navigation-next-button"]': true, 'aidText ["bottom-navigation-next-button"]': "Submit",
    });
    const out = await engine(page, new MemoryVault()).run(true);
    expect(out.kind).toBe("prefilled");
    expect(acts.some(([f, a]) => f === "clickAid" && a[0] === "bottom-navigation-next-button")).toBe(false);
  });

  it("generic: a saved password is never typed on another host, and no account is made there without approval", async () => {
    const vault = new MemoryVault(); await vault.save("jobs.acme.com", "Acme", "me@example.com", "S3cret!pass");
    const { page, acts } = fakePage(() => "login.evil.example", { hasFormInputs: true, count: 1, 'anyVisible ["input[type=password]"]': true });
    const out = await engine(page, vault).run(true);
    expect(out.kind).toBe("account");
    expect(JSON.stringify(acts)).not.toContain("S3cret!pass");
  });

  it("generic: an unapproved required consent box is listed, not ticked", async () => {
    const field = { i: 1, type: "checkbox", name: "pp", flabel: "", label: "I agree to the privacy policy *", group: "", role: "", required: true, value: "", checked: false, options: null };
    const { page, acts } = fakePage(() => "boards.example.com", { hasFormInputs: true, count: 0, collect: [field], buttons: [{ k: 0, name: "Submit", submit: true }] });
    const out = await engine(page, new MemoryVault()).run(true);
    expect(out.kind).toBe("prefilled");
    expect(out.message).toContain("tick: I agree to the privacy policy");
    expect(acts.filter(([f]) => f === "click" || f === "clickButton")).toEqual([]);
  });
});
