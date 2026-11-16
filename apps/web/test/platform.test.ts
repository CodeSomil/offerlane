// In the Windows shell, "remember this key" goes to the platform's secret store (Credential Manager), never IndexedDB.
import "fake-indexeddb/auto";
import { describe, expect, it, vi } from "vitest";
import type { AIConfig } from "@offerlane/core";

const kept = vi.hoisted(() => ({ value: undefined as unknown }));
vi.mock("../src/platform.js", () => ({
  platform: { name: "windows", secrets: {
    save: async (c: unknown) => { kept.value = c; },
    load: async () => kept.value,
    forget: async () => { kept.value = undefined; },
  } },
}));
const { forgetAI, getItem, loadAI, rememberAI } = await import("../src/store.js");

describe("AI key with a platform secret store", () => {
  it("saves, loads and forgets there, and writes nothing to IndexedDB", async () => {
    const cfg: AIConfig = { provider: "anthropic", key: "sk-ant-api-secret", smart: "s", fast: "f" };
    await rememberAI(cfg);
    expect(kept.value).toEqual(cfg);
    expect(await loadAI()).toEqual(cfg);
    expect(await getItem("ai")).toBeUndefined();
    expect(await getItem("ai-wrap")).toBeUndefined();
    await forgetAI();
    expect(await loadAI()).toBeUndefined();
  });
});
