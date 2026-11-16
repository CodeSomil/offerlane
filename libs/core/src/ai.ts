// Browser-direct AI (P3.4, D3/D6): the rules of OpenAICompatibleClient.request and OpenRouterCatalog, ported for the web app.
import registry from "../../../Packages/OfferlaneCore/Sources/OfferlaneCore/Resources/providers.json" with { type: "json" };

export type AIProvider = "openrouter" | "anthropic";
export type Tier = "recommended" | "cheaper" | "advanced";
export interface Pick { id: string; fast: string; tier: Tier; use: string; privacy: string }
export interface AIConfig { provider: AIProvider; key: string; smart: string; fast: string }
export interface Ask { system: string; prompt: string; maxTokens: number; smart: boolean }

const openrouter = registry.providers.find((p) => p.id === "openrouter")!;
/** The Mac's curated picks (providers.json), so both apps offer the same three. */
export const OPENROUTER_PICKS: readonly Pick[] = (openrouter.picks ?? []).map((p) => ({ id: p.id, fast: p.fast, tier: p.tier as Tier, use: p.use, privacy: p.privacy }));
// SHORTCUT: providers.json has no Anthropic model ids, so the web keeps its own; move them into providers.json when the Mac's Anthropic step gets picks.
export const ANTHROPIC_PICKS: readonly Pick[] = [
  { id: "claude-sonnet-5-5", fast: "claude-haiku-5-5", tier: "recommended", use: "Sonnet-class tailoring and parsing, Haiku-class scoring.", privacy: "Sent to Anthropic under your API account's terms." },
  { id: "claude-haiku-5-5", fast: "claude-haiku-5-5", tier: "cheaper", use: "Haiku-class for everything.", privacy: "Sent to Anthropic under your API account's terms." },
  { id: "claude-opus-5-5", fast: "claude-haiku-5-5", tier: "advanced", use: "Opus-class tailoring and parsing, Haiku-class scoring.", privacy: "Sent to Anthropic under your API account's terms." },
];
export const OPENROUTER_BASE = "https://openrouter.ai/api/v1";
export const ANTHROPIC_BASE = "https://api.anthropic.com";
/** D6: only providers that keep nothing and don't collect data. */
export const OPENROUTER_PRIVACY = { data_collection: "deny", zdr: true, require_parameters: true } as const;
export const KEY_FORMAT: Record<AIProvider, RegExp> = { openrouter: /^sk-or-/u, anthropic: /^sk-ant-api/u };

/** LLMRequest.defaultSystem: what every client sends when a request has no system text. */
export const DEFAULT_SYSTEM = "You are a precise assistant. Reply with JSON only.";
export function chatRequest(c: AIConfig, r: Ask): { url: string; init: RequestInit } {
  const model = r.smart ? c.smart : c.fast, system = r.system === "" ? DEFAULT_SYSTEM : r.system;
  if (c.provider === "anthropic") {
    return { url: `${ANTHROPIC_BASE}/v1/messages`, init: { method: "POST",
      headers: { "content-type": "application/json", "x-api-key": c.key, "anthropic-version": "2023-06-01", "anthropic-dangerous-direct-browser-access": "true" },
      body: JSON.stringify({ model, max_tokens: r.maxTokens, temperature: 0.2, system, messages: [{ role: "user", content: r.prompt }] }) } };
  }
  if (model.endsWith(":free")) throw new Error("Free OpenRouter models may keep or train on your resume, so Offerlane doesn't use them. Choose a model in Connect AI.");
  return { url: `${OPENROUTER_BASE}/chat/completions`, init: { method: "POST",
    headers: { "content-type": "application/json", Authorization: `Bearer ${c.key}` },
    body: JSON.stringify({ model, max_tokens: r.maxTokens, temperature: 0.2, messages: [{ role: "system", content: system }, { role: "user", content: r.prompt }], provider: OPENROUTER_PRIVACY }) } };
}

export function replyText(p: AIProvider, j: unknown): string {
  const o = j as { choices?: { message?: { content?: unknown } }[]; content?: { type?: string; text?: unknown }[] };
  const t = p === "anthropic"
    ? o.content?.filter((b) => b.type === "text" && typeof b.text === "string").map((b) => b.text).join("")
    : o.choices?.[0]?.message?.content;
  if (typeof t !== "string" || !t) throw new Error("The AI reply had no text.");
  return t;
}

/** OpenRouterCatalog.Model: US dollars per million tokens, null when unreadable. */
export interface CatalogModel { id: string; inPerM: number | null; outPerM: number | null }
const perM = (s: unknown) => (typeof s === "string" && /^\d+(\.\d+)?([eE][-+]?\d+)?$/u.test(s) ? Number(s) * 1_000_000 : null);
export function parseCatalog(j: unknown): CatalogModel[] {
  const data = (j as { data?: unknown }).data;
  if (!Array.isArray(data)) return [];
  return data.filter((m): m is { id: string; pricing?: { prompt?: unknown; completion?: unknown } } => typeof m?.id === "string" && !m.id.endsWith(":free"))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
    .map((m) => ({ id: m.id, inPerM: perM(m.pricing?.prompt), outPerM: perM(m.pricing?.completion) }));
}
export const priceText = (m: CatalogModel) => (m.inPerM === null || m.outPerM === null ? "price unavailable" : `$${m.inPerM.toFixed(2)} in · $${m.outPerM.toFixed(2)} out per million tokens`);
