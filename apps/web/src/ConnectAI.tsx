import { useEffect, useState } from "react";
import { ANTHROPIC_PICKS, KEY_FORMAT, OPENROUTER_BASE, OPENROUTER_PICKS, parseCatalog, priceText, type AIProvider, type CatalogModel, type Pick } from "@offerlane/core";
import { ask, currentAI, readyAI, setCurrentAI } from "./ai.js";
import { forgetAI, rememberAI } from "./store.js";

const TIER = { recommended: "Recommended", cheaper: "Cheaper", advanced: "Advanced" } as const;
const NAME: Record<AIProvider, string> = { openrouter: "OpenRouter", anthropic: "Anthropic API" };
const KEY_PAGE: Record<AIProvider, string> = { openrouter: "https://openrouter.ai/keys", anthropic: "https://platform.claude.com/settings/keys" };

/** Live OpenRouter prices, read once per visit (D6: never bundled). */
let catalog: Promise<CatalogModel[]> | undefined;
const prices = () => (catalog ??= fetch(`${OPENROUTER_BASE}/models`, { credentials: "omit", referrerPolicy: "no-referrer", signal: AbortSignal.timeout(10_000) })
  .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status))))).then(parseCatalog)
  .catch(() => { catalog = undefined; return []; }));  // a failed read is retried on the next visit to this view

export function ConnectAI() {
  const [provider, setProvider] = useState<AIProvider>("openrouter");
  const [pick, setPick] = useState(0);
  const [custom, setCustom] = useState("");
  const [key, setKey] = useState("");
  const [remember, setRemember] = useState(false);
  const [models, setModels] = useState<CatalogModel[] | undefined>();
  const [status, setStatus] = useState<{ ok: boolean; text: string } | undefined>();
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(currentAI);

  useEffect(() => { void readyAI().then((c) => { if (c) setSaved(c); }); }, []);
  useEffect(() => { if (provider === "openrouter") void prices().then(setModels); }, [provider]);

  const picks: readonly Pick[] = provider === "openrouter" ? OPENROUTER_PICKS : ANTHROPIC_PICKS;
  const price = (id: string) => (provider === "anthropic" ? "See Anthropic's pricing page" : !models ? "Reading live price…" : priceText(models.find((m) => m.id === id) ?? { id, inPerM: null, outPerM: null }));

  async function save(e: React.FormEvent) {
    e.preventDefault();
    const k = key.trim();
    if (!KEY_FORMAT[provider].test(k)) { setStatus({ ok: false, text: `That doesn't look like an ${NAME[provider]} key.` }); return; }
    const p = picks[pick]!, smart = custom.trim() || p.id;
    const c = { provider, key: k, smart, fast: custom.trim() || p.fast };
    setBusy(true); setStatus(undefined);
    try {
      await ask(c, { system: "Reply with JSON only.", prompt: 'Reply with {"ok":true}', maxTokens: 20, smart: true });
    } catch (err) {
      setStatus({ ok: false, text: err instanceof Error ? err.message : "The test call failed." });
      setBusy(false); return;
    }
    setCurrentAI(c); setSaved(c); setKey("");
    // Storage is separate from the test call: the key works for this visit even when this browser blocks IndexedDB.
    let note = " Kept for this visit only.";
    try { if (remember) { await rememberAI(c); note = " Remembered on this device."; } else await forgetAI(); }
    catch { note = remember ? " This browser wouldn't store it, so it's kept for this visit only." : " Kept for this visit, but a key remembered earlier couldn't be cleared from this browser."; }
    setStatus({ ok: true, text: `Connected to ${NAME[provider]} (${smart}).${note}` });
    setBusy(false);
  }

  async function forget() {
    setCurrentAI(undefined); setSaved(undefined);
    try { await forgetAI(); setStatus({ ok: true, text: "Key forgotten." }); }
    catch { setStatus({ ok: false, text: "Forgotten for this visit, but this browser's storage couldn't be cleared." }); }
  }

  return (
    <form className="stack" onSubmit={save}>
      <p className="muted">Your key stays in this browser. Offerlane calls the AI service directly; our servers never see your key or your resume.</p>
      {saved && <p className="card">Connected: {NAME[saved.provider]} · {saved.smart} <button type="button" onClick={forget}>Forget key</button></p>}
      <fieldset>
        <legend>Service</legend>
        {(["openrouter", "anthropic"] as const).map((p) => (
          <label key={p} className="radio"><input type="radio" name="provider" checked={provider === p} onChange={() => { setProvider(p); setPick(0); setCustom(""); }} /> {NAME[p]}</label>
        ))}
      </fieldset>
      <fieldset className="cards">
        <legend>Model</legend>
        {picks.map((p, i) => (
          <label key={p.tier} className={i === pick ? "card pick on" : "card pick"}>
            <input type="radio" name="pick" checked={i === pick} onChange={() => setPick(i)} />
            <strong>{TIER[p.tier]}</strong> <code>{p.id}</code>
            <span className="muted">{p.use}</span>
            <span className="muted">{price(p.id)}</span>
            <span className="muted">{p.privacy}</span>
          </label>
        ))}
      </fieldset>
      <details>
        <summary>Other model (developer)</summary>
        <label>Model id <input value={custom} onChange={(e) => setCustom(e.target.value)} placeholder={picks[pick]!.id} spellCheck={false} /></label>
      </details>
      <label>{NAME[provider]} key <input type="password" autoComplete="off" spellCheck={false} value={key} onChange={(e) => setKey(e.target.value)} required /></label>
      <p className="muted"><a href={KEY_PAGE[provider]} target="_blank" rel="noreferrer noopener">Get a key (opens in a new tab)</a></p>
      <label className="radio"><input type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} /> Remember on this device (stored encrypted in this browser)</label>
      <button type="submit" disabled={busy}>{busy ? "Testing…" : "Test and save"}</button>
      <p role={status && !status.ok ? "alert" : "status"} className={status ? (status.ok ? "ok" : "bad") : undefined}>{status?.text}</p>
    </form>
  );
}
