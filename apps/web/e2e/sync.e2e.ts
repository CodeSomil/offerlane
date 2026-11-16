import { createHash, randomBytes } from "node:crypto";
import { expect, test, type Page } from "@playwright/test";
import { API, axeBoth, guards, seed } from "./helpers.js";

// P3.7: sign-in (code + PKCE against a stub issuer) and end-to-end encrypted sync between two browsers (two contexts)
// through a stub API that keeps blobs in memory. The stub sees only ciphertext.
guards();

const ISS = "http://localhost:9000";  // vite.config.ts default VITE_OIDC_ISSUER
const WEB = "http://127.0.0.1:4173";
const b64u = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");

type Row = { version: number; keyId: string; ciphertext: string };
function server() {
  const rows = new Map<string, Row>(), bodies: string[] = [], auths = new Set<string>();
  const grants = new Map<string, { nonce: string; challenge: string; redirect: string }>();
  async function attach(page: Page, sub: string) {
    await page.route(`${ISS}/**`, async (r) => {
      const u = new URL(r.request().url()), cors = { "access-control-allow-origin": WEB };
      if (r.request().method() === "OPTIONS") return r.fulfill({ status: 204, headers: { ...cors, "access-control-allow-methods": "GET, POST", "access-control-allow-headers": "content-type, accept" } });
      if (u.pathname === "/.well-known/openid-configuration") return r.fulfill({ headers: cors, json: { issuer: `${ISS}/`, authorization_endpoint: `${ISS}/authorize`,
        token_endpoint: `${ISS}/oauth/token`, jwks_uri: `${ISS}/jwks`, id_token_signing_alg_values_supported: ["ES256"], code_challenge_methods_supported: ["S256"] } });
      if (u.pathname === "/authorize") {
        const p = u.searchParams, code = randomBytes(16).toString("hex");
        expect(p.get("code_challenge_method")).toBe("S256");
        grants.set(code, { nonce: p.get("nonce")!, challenge: p.get("code_challenge")!, redirect: p.get("redirect_uri")! });
        const to = new URL(p.get("redirect_uri")!);
        to.searchParams.set("code", code); to.searchParams.set("state", p.get("state")!);
        return r.fulfill({ status: 302, headers: { location: to.toString() } });
      }
      if (u.pathname === "/oauth/token") {
        const p = new URLSearchParams(r.request().postData() ?? ""), g = grants.get(p.get("code") ?? "");
        grants.delete(p.get("code") ?? "");
        if (!g || createHash("sha256").update(p.get("code_verifier") ?? "").digest("base64url") !== g.challenge || p.get("redirect_uri") !== g.redirect)
          return r.fulfill({ status: 400, headers: cors, json: { error: "invalid_grant" } });
        const now = Math.floor(Date.now() / 1000);
        const idToken = `${b64u({ alg: "ES256", typ: "JWT" })}.${b64u({ iss: `${ISS}/`, aud: "offerlane-api", sub, nonce: g.nonce, iat: now, exp: now + 3600 })}.c2ln`;
        return r.fulfill({ headers: cors, json: { access_token: "at", token_type: "Bearer", expires_in: 3600, id_token: idToken } });
      }
      return r.fulfill({ status: 404, headers: cors, json: {} });
    });
    await page.route(`${API}/v1/**`, async (r) => {
      const q = r.request(), u = new URL(q.url()), cors = { "access-control-allow-origin": WEB, "access-control-expose-headers": "etag" };
      if (q.method() === "OPTIONS") return r.fulfill({ status: 204, headers: { ...cors, "access-control-allow-methods": "GET, PUT",
        "access-control-allow-headers": "authorization, content-type, if-match, if-none-match, idempotency-key" } });
      const auth = (await q.allHeaders()).authorization ?? "";
      if (!auth.startsWith("Bearer ")) return r.fulfill({ status: 401, headers: cors, json: { error: "unauthorized" } });
      auths.add(auth);
      if (u.pathname === "/v1/me") return r.fulfill({ headers: cors, json: { id: "user-e2e" } });
      const kind = u.pathname.split("/").at(-1)!;
      if (q.method() === "GET") { const b = rows.get(kind); return b ? r.fulfill({ headers: cors, json: b }) : r.fulfill({ status: 404, headers: cors, json: { error: "not_found" } }); }
      const h = await q.allHeaders(), cur = rows.get(kind)?.version ?? null;
      expect(h["idempotency-key"]).toBeTruthy();
      const expected = h["if-none-match"] === "*" ? null : Number(/^"v(\d+)"$/.exec(h["if-match"] ?? "")?.[1]);
      if (expected !== cur) return r.fulfill({ status: 409, headers: cors, json: { error: "conflict", version: cur } });
      const body = q.postData() ?? "";
      bodies.push(body);
      const { keyId, ciphertext } = JSON.parse(body) as Row;
      rows.set(kind, { version: (cur ?? 0) + 1, keyId, ciphertext });
      return r.fulfill({ headers: cors, json: { version: (cur ?? 0) + 1 } });
    });
  }
  return { rows, bodies, auths, attach };
}

const CANARY = `Canary${randomBytes(4).toString("hex")} Example`;
const job = { id: "s1", company: "Initech", title: "Synced Analyst", location: "London, UK", url: "", apply_url: "", ats: "greenhouse", ats_slug: "", posted: null,
  description: "", visa: "ok", min_years: null, variant: "main", tailor_note: "" };
const now = new Date().toISOString();

test("Settings: sign in, turn on sync with a recovery key, a second browser restores with it; the API sees ciphertext only", async ({ page, browser }) => {
  const api = server();
  await api.attach(page, "alice");
  await seed(page, { profile: { personal: { name: CANARY } }, resume: { name: "main", source_text: `${CANARY} resume` },
    applications: { s1: { job, status: "applied", score: 70, created: now, updated: now } } });
  await page.goto("/#/settings");
  await expect(page.getByRole("heading", { name: "Settings", level: 1 })).toBeVisible();
  await axeBoth(page);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByRole("status")).toHaveText("Signed in.");
  expect(new URL(page.url()).search).toBe("");  // the code never stays in the address bar
  expect(new URL(page.url()).hash).toBe("#/settings");
  await page.getByRole("button", { name: "Turn on sync" }).click();

  await expect(page.getByRole("heading", { name: "Your recovery key" })).toBeFocused();
  await expect(page.locator("p.bad")).toContainText("If you lose every signed-in device and this key, your synced data is gone.");
  const rk = (await page.locator(".rk code").textContent())!;
  expect(rk).toMatch(/^([A-Z2-7]{4}-){6}[A-Z2-7]{2}$/);
  await axeBoth(page);
  const go = page.getByRole("button", { name: "Continue and sync" });
  await expect(go).toBeDisabled();
  await page.getByLabel("I've saved my recovery key somewhere safe").check();
  await go.click();
  await expect(page.getByRole("status")).toHaveText("Synced: 0 updated here, 3 sent.");
  await expect(page.getByText(/^Last synced /)).toBeVisible();
  await axeBoth(page);
  expect([...api.rows.keys()].sort()).toEqual(["applications", "keyring", "profile", "resumes"]);
  const sent = api.bodies.join("\n") + [...api.rows.values()].map((r) => Buffer.from(r.ciphertext, "base64").toString("latin1")).join("\n");
  for (const n of [CANARY, "Synced Analyst", "Initech", rk, rk.replaceAll("-", "")]) expect(sent.includes(n), n).toBe(false);

  // Device B: another browser profile, same account.
  const ctx = await browser.newContext({ baseURL: WEB });
  const b = await ctx.newPage();
  const errors: string[] = [];
  b.on("console", (m) => { if (m.type() === "error" && !/status of 404/.test(m.text())) errors.push(m.text()); });
  b.on("pageerror", (e) => errors.push(e.message));
  await api.attach(b, "alice");
  await b.goto("/#/settings");
  await b.getByRole("button", { name: "Sign in" }).click();
  await expect(b.getByText("This account already syncs from another device.")).toBeVisible();
  await b.getByLabel("Recovery key").fill("AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AA");
  await b.getByRole("button", { name: "Use recovery key" }).click();
  await expect(b.getByRole("alert")).toHaveText("That recovery key doesn't open this account's synced data.");
  await b.getByLabel("Recovery key").fill(rk.toLowerCase().replaceAll("-", " "));
  await b.getByRole("button", { name: "Use recovery key" }).click();
  await expect(b.getByRole("status")).toHaveText("Sync is on. 3 updated here, 0 sent.");
  await b.goto("/#/applications");
  await expect(b.getByText("Synced Analyst", { exact: true })).toBeVisible();
  expect(errors).toEqual([]);
  await ctx.close();
  expect([...api.auths].every((a) => a.split(".").length === 3)).toBe(true);  // the ID token is the bearer
});

test("Settings: signed out says what signing in adds; a cancelled sign-in says so", async ({ page }) => {
  await page.route(`${ISS}/**`, (r) => {
    const u = new URL(r.request().url()), cors = { "access-control-allow-origin": WEB };
    if (u.pathname === "/.well-known/openid-configuration") return r.fulfill({ headers: cors, json: { issuer: `${ISS}/`, authorization_endpoint: `${ISS}/authorize`, token_endpoint: `${ISS}/oauth/token` } });
    const to = new URL(u.searchParams.get("redirect_uri")!);
    to.searchParams.set("error", "access_denied"); to.searchParams.set("state", u.searchParams.get("state")!);
    return r.fulfill({ status: 302, headers: { location: to.toString() } });
  });
  await page.goto("/#/settings");
  await expect(page.getByText("Without it, everything stays on this device.")).toBeVisible();
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByRole("alert")).toHaveText("Sign-in was cancelled.");
  await expect(page.getByRole("button", { name: "Sign in" })).toBeVisible();
});
