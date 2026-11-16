import { describe, expect, it } from "vitest";
import { resumeContent, resumeVersion, tailorPlan } from "@offerlane/core";
import { guardAIPlan, resumeMarkdown } from "../src/draft.js";

const content = resumeContent({ name: "Test Person", email: "t@example.com", headline: "Data Scientist",
  experience: [{ id: "e1", title: "Analyst", company: "Acme", dates: "2020 - 2023", bullets: [{ id: "b1", text: "Cut costs by 30%." }] }],
  skills: [{ label: "Languages", items: "Python" }] });
const v = resumeVersion({ name: "main", content });

describe("guardAIPlan", () => {
  it("blanks texts and drops answers with numbers the resume doesn't have", () => {
    const plan = { ...tailorPlan({}), cover_letter: "I cut costs by 30%.", why_company: "I grew sales 50%.",
      answers: [{ q: "Why?", a: "I cut costs 30%." }, { q: "Size?", a: "I led 9 people." }] };
    const r = guardAIPlan(plan, v);
    expect(r.plan.cover_letter).toBe("I cut costs by 30%."); expect(r.plan.why_company).toBe("");
    expect(r.plan.answers).toEqual([{ q: "Why?", a: "I cut costs 30%." }]);
    expect(r.notes).toEqual(['why us removed: numbers not in your resume: ["50"]', 'answer removed: numbers not in your resume: ["9"]']);
  });
});
describe("resumeMarkdown", () => {
  it("writes the sections that have content", () => {
    expect(resumeMarkdown(content)).toBe("# Test Person\n\nt@example.com\n\n**Data Scientist**\n\n## Experience\n\n### Analyst, Acme\n2020 - 2023\n\n- Cut costs by 30%.\n\n## Skills\n\n- **Languages:** Python\n");
  });
});
