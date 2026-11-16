import { expect, test } from "@playwright/test";
import { axe, axeBoth, guards } from "./helpers.js";
import { ITEMS } from "../src/nav.js";
import { ANTHROPIC_BASE, OPENROUTER_BASE, OPENROUTER_PICKS } from "@offerlane/core";

guards();

test("shell: Mac sidebar groups, hash views, strict CSP", async ({ page }) => {
  const res = await page.goto("/");
  const csp = res!.headers()["content-security-policy"]!;
  for (const d of ["script-src 'self'", "style-src 'self'", "object-src 'none'", "frame-ancestors 'none'",
    `connect-src 'self' http://localhost:8787 http://localhost:9000 ${new URL(OPENROUTER_BASE).origin} ${new URL(ANTHROPIC_BASE).origin}`]) expect(csp).toContain(d);
  await expect(page.locator('meta[http-equiv="Content-Security-Policy"]')).toHaveAttribute("content", /script-src 'self'/);
  const nav = page.getByRole("navigation", { name: "Offerlane" });
  await expect(nav.getByRole("heading")).toHaveText(["Today", "Find", "Pipeline", "Grow", "Profile"]);
  await expect(nav.getByRole("link")).toHaveText(["Today", "Discover", "Review", "Pipeline", "Interview Prep", "Goals", "Skills", "Resumes", "Connect AI", "Settings"]);
  await expect(nav.getByRole("link", { name: "Today" })).toHaveAttribute("aria-current", "page");
  await nav.getByRole("link", { name: "Discover" }).click();
  await expect(page).toHaveURL(/#\/find$/);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Discover");
  await expect(page.getByRole("heading", { level: 1 })).toBeFocused();  // the view change is announced
});

test("static host headers (dist/_headers) match the served ones", async ({ page, request }) => {
  const served = (await page.goto("/"))!.headers();
  const file = await (await request.get("/_headers")).text();
  for (const h of ["content-security-policy", "x-content-type-options", "referrer-policy"]) expect(file).toContain(served[h]!);
  expect(file).toContain("frame-ancestors 'none'");
});

test("theme: an explicit choice stops following the system", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" });
  await page.goto("/");
  await page.emulateMedia({ colorScheme: "dark" });
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");  // System follows live
  await page.getByLabel("Appearance").selectOption("light");
  await page.emulateMedia({ colorScheme: "light" });
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));  // let the change event fire
  await page.emulateMedia({ colorScheme: "dark" });
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
});

test("theme: system default, dark and light stick across reloads, axe clean in both", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.goto("/");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.getByLabel("Appearance").selectOption("light");
  await page.reload();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await axe(page);
  await page.getByLabel("Appearance").selectOption("dark");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await axe(page);
});

test("Connect AI (OpenRouter): live price, D6 body, remembered key, :free refused", async ({ page }) => {
  const bodies: any[] = [];
  await page.route(`${OPENROUTER_BASE}/chat/completions`, (r) => { bodies.push(r.request().postDataJSON()); return r.fulfill({ json: { choices: [{ message: { content: '{"ok":true}' } }] } }); });
  await page.goto("/#/connectAI");
  await expect(page.getByText("$3.00 in · $15.00 out per million tokens")).toBeVisible();
  await expect(page.getByText("price unavailable")).toHaveCount(2);  // the stub lists only the first pick
  for (const t of ["dark", "light"]) { await page.getByLabel("Appearance").selectOption(t); await axe(page); }

  const key = page.getByLabel("OpenRouter key");
  await key.fill("not-a-key");
  await page.getByRole("button", { name: "Test and save" }).click();
  await expect(page.getByRole("alert")).toHaveText(/doesn't look like an OpenRouter key/);

  await page.getByText("Other model (developer)").click();
  await page.getByLabel("Model id").fill("some/model:free");
  await key.fill("sk-or-test");
  await page.getByRole("button", { name: "Test and save" }).click();
  await expect(page.getByRole("alert")).toHaveText(/Free OpenRouter models/);
  expect(bodies).toEqual([]);

  await page.getByLabel("Model id").fill("");
  await page.getByLabel(/Remember on this device/).check();
  await page.getByRole("button", { name: "Test and save" }).click();
  await expect(page.getByRole("status")).toHaveText(/Connected to OpenRouter .*Remembered on this device/);
  expect(bodies).toHaveLength(1);
  expect(bodies[0].provider).toEqual({ data_collection: "deny", zdr: true, require_parameters: true });
  expect(bodies[0].model).toBe(OPENROUTER_PICKS[0]!.id);
  await expect(key).toHaveValue("");

  await page.reload();
  await expect(page.getByText(`Connected: OpenRouter · ${OPENROUTER_PICKS[0]!.id}`)).toBeVisible();
  await page.getByRole("button", { name: "Forget key" }).click();
  await expect(page.getByRole("status")).toHaveText("Key forgotten.");
  await page.reload();
  await expect(page.getByText(/^Connected:/)).toHaveCount(0);
});

test("Connect AI (Anthropic): browser-direct header, session-only key, refused key reported", async ({ page }) => {
  let ok = false;
  const seen: Record<string, string>[] = [];
  await page.route(`${ANTHROPIC_BASE}/v1/messages`, (r) => { seen.push(r.request().headers()); return ok ? r.fulfill({ json: { content: [{ type: "text", text: "{}" }] } }) : r.fulfill({ status: 401, json: {} }); });
  await page.goto("/#/connectAI");
  await page.getByLabel("Anthropic API").check();
  await page.getByLabel("Anthropic API key").fill("sk-ant-api03-test");
  await page.getByRole("button", { name: "Test and save" }).click();
  await expect(page.getByRole("alert")).toHaveText("The key was refused. Check it and try again.");
  ok = true;
  await page.getByRole("button", { name: "Test and save" }).click();
  await expect(page.getByRole("status")).toHaveText(/Connected to Anthropic API .*Kept for this visit only/);
  expect(seen.at(-1)!["anthropic-dangerous-direct-browser-access"]).toBe("true");
  expect(seen.at(-1)!["x-api-key"]).toBe("sk-ant-api03-test");
  await page.reload();
  await expect(page.getByText(/^Connected:/)).toHaveCount(0);  // not remembered
});

test("Connect AI works for the visit when IndexedDB is blocked, and a failed price read shows unavailable", async ({ page }) => {
  await page.addInitScript(() => { IDBFactory.prototype.open = () => { throw new DOMException("blocked", "SecurityError"); }; });
  await page.route(`${OPENROUTER_BASE}/models`, (r) => r.fulfill({ status: 500, json: {} }));
  await page.route(`${OPENROUTER_BASE}/chat/completions`, (r) => r.fulfill({ json: { choices: [{ message: { content: "{}" } }] } }));
  await page.goto("/#/connectAI");
  await expect(page.getByText("price unavailable")).toHaveCount(3);
  await page.getByLabel("OpenRouter key").fill("sk-or-test");
  await page.getByLabel(/Remember on this device/).check();
  await page.getByRole("button", { name: "Test and save" }).click();
  await expect(page.getByRole("status")).toHaveText(/Connected to OpenRouter .*wouldn't store it, so it's kept for this visit only/);
  await page.getByRole("button", { name: "Forget key" }).click();
  await expect(page.getByRole("alert")).toHaveText(/Forgotten for this visit/);
});

// P3.9 gate: every sidebar view (new ones are picked up from nav.ts), fresh store, both themes. Seeded states are axe-checked in flows/sync.
test("axe: every view on a fresh store, light and dark", async ({ page }) => {
  await page.goto("/");
  for (const i of ITEMS) {
    await page.evaluate((v) => { location.hash = `#/${v}`; }, i.id);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(i.title);
    await axeBoth(page);
  }
});
