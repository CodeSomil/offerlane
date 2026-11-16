// The AI config for this visit. It lives in memory unless the user chose "Remember on this device" (store.ts encrypts it).
import { chatRequest, parseJSON, replyText, type AIConfig, type Ask } from "@offerlane/core";
import { loadAI } from "./store.js";

let current: AIConfig | undefined;
export const currentAI = () => current;
export const setCurrentAI = (c: AIConfig | undefined) => { current = c; };
/** The remembered config, read once; storage failures just mean nothing is remembered. */
let loaded: Promise<void> | undefined;
export const readyAI = async () => { await (loaded ??= loadAI().catch(() => undefined).then((c) => { if (c && !current) current = c; })); return current; };

export async function ask(c: AIConfig, a: Ask): Promise<string> {
  const { url, init } = chatRequest(c, a);  // throws for :free OpenRouter models (D6)
  const r = await fetch(url, { ...init, credentials: "omit", referrerPolicy: "no-referrer" });
  if (!r.ok) throw new Error(r.status === 401 || r.status === 403 ? "The key was refused. Check it and try again." : `The AI service answered ${r.status}.`);
  return replyText(c.provider, await r.json());
}

/** AI.json: on a reply that isn't the JSON asked for, ask once more on the fast model with only the broken reply. */
export const REPAIR_PROMPT = "Fix this into valid JSON. Keep every value; drop any prose or code fences. Reply with the JSON only.\n\n";
export async function askJSON(c: AIConfig, a: Ask, accept: (v: unknown) => boolean): Promise<unknown> {
  const first = await ask(c, a);
  try { return parseJSON(first, accept); } catch { /* one repair retry */ }
  const second = await ask(c, { system: a.system, prompt: REPAIR_PROMPT + first.slice(0, 24_000), smart: false,
    maxTokens: Math.min(a.maxTokens, Math.max(400, Math.floor(first.length / 3) + 200)) });
  return parseJSON(second, accept);
}
