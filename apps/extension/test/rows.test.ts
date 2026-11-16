// v4 P3.8: which answer the side panel offers for each question (AnswerRules port), and which job a tab belongs to.
import { describe, expect, it } from "vitest";
import type { PageField } from "../src/page.js";
import { matchJob, rows } from "../src/rows.js";
import { ANSWERS, FORM_URL, person, role } from "./fixture.js";

const f = (type: string, label: string, extra: Partial<PageField> = {}): PageField => ({ type, label, name: "", key: "", group: "", options: null, ...extra });
const form: PageField[] = [
  f("text", "First name *"), f("text", "Last name *"), f("email", "Email"), f("tel", "Phone"),
  f("file", "Resume/CV"),
  f("textarea", "Why do you want to work at Acme?"),
  f("select", "Are you legally authorized to work in the United Kingdom?", { options: ["Select...", "Yes", "No"] }),
  f("radio", "Yes", { key: "sp", group: "Will you now or in the future require visa sponsorship?" }), f("radio", "No", { key: "sp", group: "Will you now or in the future require visa sponsorship?" }),
  f("select", "Gender", { options: ["Male", "Female", "I don't wish to answer"] }),
  f("text", "What is your favourite colour?"),
  f("checkbox", "I agree to the privacy policy and terms"),
  f("text", "Email"),
];

describe("rows", () => {
  it("offers the profile, the role's answers and the matching option; consent and unknowns are left to the person", () => {
    expect(rows(form, person(), { job: role(), answers: ANSWERS }).map((r) => [r.label, r.answer])).toEqual([
      ["First name *", "Ada"], ["Last name *", "Lovelace"], ["Email", "ada@example.com"], ["Phone", "+44 20 7946 0000"],
      ["Why do you want to work at Acme?", "Because Acme builds the engines I care about."],
      ["Are you legally authorized to work in the United Kingdom?", "Yes"],
      ["Will you now or in the future require visa sponsorship?", "No"],
      ["Gender", "I don't wish to answer"],
      ["What is your favourite colour?", null],
      ["I agree to the privacy policy and terms", null],
    ]);
  });
  it("without a matching role, only the profile answers", () => {
    expect(rows(form, person(), null).find((r) => r.label.startsWith("Why"))?.answer).toBeNull();
  });

  it("a lone checkbox that picked up a stray group label is its own question", () => {
    expect(rows([f("text", "Email"), f("checkbox", "I agree to the privacy policy and terms", { key: "ok", group: "Email" }), f("radio", "Yes", { key: "x", group: "Email" })], person(), null).map((r) => [r.label, r.answer]))
      .toEqual([["Email", "ada@example.com"], ["I agree to the privacy policy and terms", null], ["Yes", null]]);
  });
});

describe("matchJob", () => {
  const jobs = [{ job: role(), answers: ANSWERS }];
  it("finds the role on its posting and its form, not elsewhere", () => {
    expect(matchJob(jobs, FORM_URL + "?src=x")?.job.title).toBe("Platform Engineer");
    expect(matchJob(jobs, "http://127.0.0.1:4199/acme/jobs/101")?.job.title).toBe("Platform Engineer");
    expect(matchJob(jobs, "http://127.0.0.1:4199/acme/jobs/102/apply")).toBeNull();
  });
});
