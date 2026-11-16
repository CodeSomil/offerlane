import { describe, expect, it } from "vitest";
import { job, newProfile } from "@offerlane/core";
import { shellFill } from "../src/apply.js";
import { memoryApprovals, type Invoke } from "../src/bridge.js";

describe("shellFill", () => {
  it("refuses a role without a web link before opening any window", async () => {
    const calls: string[] = [];
    const invoke: Invoke = async (cmd) => { calls.push(cmd); return null; };
    const f = shellFill(invoke, async () => () => {}, memoryApprovals(), "");
    for (const url of ["", "file:///C:/x.html", "javascript:alert(1)"]) {
      await expect(f.fill(job({ company: "Acme", title: "T", location: "", url }), newProfile(), [], false)).rejects.toThrow("no web link");
    }
    expect(calls).toEqual([]);
  });
});
