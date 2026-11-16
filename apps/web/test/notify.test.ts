import { describe, expect, it, vi } from "vitest";

const shown = vi.hoisted(() => [] as [string, string][]);
vi.mock("../src/platform.js", () => ({ platform: { name: "windows", notify: async (t: string, b: string) => { shown.push([t, b]); } } }));
const { notify } = await import("../src/notify.js");

describe("notify", () => {
  it("shows a toast only while the app is in the background, and never throws", async () => {
    const focus = vi.fn(() => true);
    vi.stubGlobal("document", { hasFocus: focus });
    notify("Seen", "already on screen");
    focus.mockReturnValue(false);
    notify("Filled", "check and submit");
    await Promise.resolve();
    expect(shown).toEqual([["Filled", "check and submit"]]);
    vi.unstubAllGlobals();
  });
});
