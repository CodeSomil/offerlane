import { describe, expect, it } from "vitest";
import { ANTHROPIC_PICKS, DEFAULT_SYSTEM, OPENROUTER_PICKS, OPENROUTER_PRIVACY, chatRequest, parseCatalog, priceText, replyText } from "../src/ai.js";

const ask = { system: "S", prompt: "P", maxTokens: 10, smart: true };

describe("ai (D6 rules shared with OpenAICompatibleClient)", () => {
  it("reads the three curated OpenRouter picks from the Mac's providers.json", () => {
    expect(OPENROUTER_PICKS.map((p) => p.tier)).toEqual(["recommended", "cheaper", "advanced"]);
    expect(ANTHROPIC_PICKS.map((p) => p.tier)).toEqual(["recommended", "cheaper", "advanced"]);
  });

  it("always sends the D6 provider block to OpenRouter", () => {
    const r = chatRequest({ provider: "openrouter", key: "k", smart: "a/b", fast: "a/c" }, ask);
    expect(r.url).toBe("https://openrouter.ai/api/v1/chat/completions");
    const body = JSON.parse(r.init.body as string);
    expect(body.provider).toEqual({ data_collection: "deny", zdr: true, require_parameters: true });
    expect(OPENROUTER_PRIVACY).toEqual(body.provider);
    expect(body.model).toBe("a/b");
    expect(body.messages[0]).toEqual({ role: "system", content: "S" });
    expect((r.init.headers as Record<string, string>).Authorization).toBe("Bearer k");
  });

  it("refuses :free models on OpenRouter", () => {
    expect(() => chatRequest({ provider: "openrouter", key: "k", smart: "x/y:free", fast: "a/c" }, ask)).toThrow(/Free OpenRouter models/);
    expect(() => chatRequest({ provider: "openrouter", key: "k", smart: "a/b", fast: "x/y:free" }, { ...ask, smart: false })).toThrow();
  });

  it("calls Anthropic directly with the browser-access header and no provider block", () => {
    const r = chatRequest({ provider: "anthropic", key: "sk-ant-api-1", smart: "claude-x", fast: "claude-y" }, { ...ask, smart: false });
    expect(r.url).toBe("https://api.anthropic.com/v1/messages");
    const h = r.init.headers as Record<string, string>;
    expect(h["x-api-key"]).toBe("sk-ant-api-1");
    expect(h["anthropic-dangerous-direct-browser-access"]).toBe("true");
    const body = JSON.parse(r.init.body as string);
    expect(body).toMatchObject({ model: "claude-y", system: "S", max_tokens: 10 });
    expect(body.provider).toBeUndefined();
  });

  it("an empty system text becomes LLMRequest.defaultSystem for both providers", () => {
    for (const provider of ["openrouter", "anthropic"] as const) {
      const body = JSON.parse(chatRequest({ provider, key: "k", smart: "m", fast: "m" }, { ...ask, system: "" }).init.body as string);
      expect(provider === "anthropic" ? body.system : body.messages[0].content).toBe(DEFAULT_SYSTEM);
    }
  });

  it("reads reply text from both providers", () => {
    expect(replyText("openrouter", { choices: [{ message: { content: "hi" } }] })).toBe("hi");
    expect(replyText("anthropic", { content: [{ type: "text", text: "a" }, { type: "text", text: "b" }] })).toBe("ab");
    expect(() => replyText("anthropic", {})).toThrow();
  });

  it("parses live prices like OpenRouterCatalog: per million, :free dropped, sorted, unreadable = unavailable", () => {
    const m = parseCatalog({ data: [
      { id: "z/m", pricing: { prompt: "0.000003", completion: "0.000015" } },
      { id: "a/free:free", pricing: { prompt: "0", completion: "0" } },
      { id: "a/m", pricing: { prompt: "nope" } },
    ] });
    expect(m.map((x) => x.id)).toEqual(["a/m", "z/m"]);
    expect(priceText(m[1]!)).toBe("$3.00 in · $15.00 out per million tokens");
    expect(priceText(m[0]!)).toBe("price unavailable");
    expect(parseCatalog({ nope: 1 })).toEqual([]);
  });
});
