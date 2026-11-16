import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { forgetAI, getItem, loadAI, rememberAI, setItem, delItem, updateItem } from "../src/store.js";

const cfg = { provider: "openrouter" as const, key: "sk-or-secret", smart: "a/b", fast: "a/c" };

describe("store (IndexedDB, H3)", () => {
  it("round-trips and deletes plain values", async () => {
    await setItem("view", { v: 1 });
    expect(await getItem("view")).toEqual({ v: 1 });
    await delItem("view");
    expect(await getItem("view")).toBeUndefined();
  });

  it("remembers the AI key only encrypted, under a non-extractable key", async () => {
    expect(await loadAI()).toBeUndefined();
    await rememberAI(cfg);
    const raw = await getItem("ai");
    expect(JSON.stringify(raw)).not.toContain("sk-or-secret");
    const wrap = (await getItem("ai-wrap")) as CryptoKey;
    expect(wrap.extractable).toBe(false);
    expect(await loadAI()).toEqual(cfg);
    await forgetAI();
    expect(await loadAI()).toBeUndefined();
    expect(await getItem("ai-wrap")).toBeUndefined();
  });

  it("drops an unreadable remembered key instead of failing", async () => {
    await rememberAI(cfg);
    await setItem("ai", { iv: new Uint8Array(12), ct: new Uint8Array(32) });
    expect(await loadAI()).toBeUndefined();
    expect(await getItem("ai")).toBeUndefined();
  });
});

describe("updateItem (one transaction per read-modify-write)", () => {
  it("overlapping updates all land", async () => {
    await setItem("n", []);
    await Promise.all([1, 2, 3, 4, 5].map((i) => updateItem("n", (v) => [...(v as number[]), i])));
    expect(((await getItem("n")) as number[]).sort()).toEqual([1, 2, 3, 4, 5]);
  });
  it("a throwing change writes nothing and rejects with its error", async () => {
    await setItem("m", { a: 1 });
    await expect(updateItem("m", () => { throw new Error("no"); })).rejects.toThrow("no");
    expect(await getItem("m")).toEqual({ a: 1 });
  });
});
