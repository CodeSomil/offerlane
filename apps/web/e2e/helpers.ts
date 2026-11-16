import { expect, test, type Page } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { ANTHROPIC_BASE, OPENROUTER_BASE, OPENROUTER_PICKS } from "@offerlane/core";

// Every test fails on a console error, which includes a CSP violation (the deliberate 401/500 stubs, sync's "nothing stored yet" 404 and aborted requests are expected).
export function guards() {
  let errors: string[] = [];
  test.beforeEach(async ({ page }) => {
    errors = [];
    page.on("console", (m) => { if (m.type() === "error" && !/status of (401|404|500)|^Failed to load resource: net::ERR_FAILED$/.test(m.text())) errors.push(m.text()); });
    page.on("pageerror", (e) => errors.push(e.message));
    // Stub AI hosts: no test ever reaches a real provider. Anything a test doesn't stub itself is refused (later routes win).
    for (const host of [OPENROUTER_BASE, ANTHROPIC_BASE]) await page.route(`${new URL(host).origin}/**`, (r) => r.fulfill({ status: 500, json: {} }));
    await page.route(`${OPENROUTER_BASE}/models`, (r) => r.fulfill({ json: { data: [{ id: OPENROUTER_PICKS[0]!.id, pricing: { prompt: "0.000003", completion: "0.000015" } }] } }));
  });
  test.afterEach(() => expect(errors).toEqual([]));
}

export async function axe(page: Page) {
  const r = await new AxeBuilder({ page }).analyze();
  expect(r.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id}: ${v.nodes.map((n) => n.target).join(", ")}`)).toEqual([]);
}

/** A fake LLM on the OpenRouter host: `reply` gets the user prompt and returns the model's text. Returns the prompts seen. */
export async function fakeLLM(page: Page, reply: (prompt: string) => string) {
  const prompts: string[] = [];
  await page.route(`${OPENROUTER_BASE}/chat/completions`, (r) => {
    const p = r.request().postDataJSON().messages.at(-1).content as string;
    prompts.push(p);
    return r.fulfill({ json: { choices: [{ message: { content: p.startsWith('Reply with {"ok":true}') ? '{"ok":true}' : reply(p) } }] } });
  });
  return prompts;
}

/** Connect the AI for this visit (not remembered), then go to `view` without reloading. */
export async function connect(page: Page, view: string) {
  await page.goto("/#/connectAI");
  await page.getByLabel("OpenRouter key").fill("sk-or-test");
  await page.getByRole("button", { name: "Test and save" }).click();
  await expect(page.getByRole("status")).toHaveText(/Connected to OpenRouter/);
  await page.evaluate((v) => { location.hash = `#/${v}`; }, view);
}

/** Both themes through the Appearance picker, axe in each. */
export async function axeBoth(page: Page) {
  for (const t of ["dark", "light"]) { await page.getByLabel("Appearance").selectOption(t); await axe(page); }
}

/** Write records straight into the app's IndexedDB kv store (same db/store names as src/store.ts), then reload. */
export async function seed(page: Page, kv: Record<string, unknown>) {
  await page.goto("/");
  await page.evaluate((entries) => new Promise<void>((ok, fail) => {
    const r = indexedDB.open("offerlane", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("kv");
    r.onerror = () => fail(r.error);
    r.onsuccess = () => {
      const tx = r.result.transaction("kv", "readwrite");
      for (const [k, v] of Object.entries(entries)) tx.objectStore("kv").put(v, k);
      tx.oncomplete = () => { r.result.close(); ok(); }; tx.onerror = () => fail(tx.error);
    };
  }), kv);
}

/** The stub API on the dev origin the build points at (vite.config.ts default). */
export const API = "http://localhost:8787";
export const apiJob = (id: string, title: string, company: string, extra: Record<string, unknown> = {}) => ({
  id, ats: "greenhouse", title, company, location: "London, UK", remote: false, url: `https://boards.example/${id}`, applyUrl: `https://boards.example/${id}/apply`,
  description: "Python and SQL forecasting work.", postedAt: new Date().toISOString().slice(0, 10), ...extra });
