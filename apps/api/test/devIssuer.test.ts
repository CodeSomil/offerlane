import { createHash } from "node:crypto";
import { createServer, type Server } from "node:http";
import { createLocalJWKSet, jwtVerify } from "jose";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { devIssuerHandler } from "./devIssuerApp.js";
import { audience, fakeIssuer } from "./fakeIssuer.js";

// The DEV-ONLY issuer's browser flow (P3.7 H4): OIDC code + PKCE (S256), auto-consent, localhost redirects only.
const web = "http://127.0.0.1:4173";
let server: Server, iss = "";
beforeAll(async () => {
  server = createServer();
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  iss = `http://127.0.0.1:${(server.address() as { port: number }).port}/`;
  const f = await fakeIssuer();
  server.on("request", devIssuerHandler({ iss, sign: f.sign, jwk: f.jwk, webOrigins: [web] }));
});
afterAll(() => new Promise<void>((ok) => server.close(() => ok())));

const verifier = "v".repeat(43);
const challenge = createHash("sha256").update(verifier).digest("base64url");
const authorize = (p: Record<string, string>) => fetch(`${iss}authorize?${new URLSearchParams({ response_type: "code", client_id: audience,
  redirect_uri: `${web}/`, state: "st", nonce: "nn", code_challenge: challenge, code_challenge_method: "S256", scope: "openid", ...p })}`, { redirect: "manual" });
const token = (p: Record<string, string>) => fetch(`${iss}oauth/token`, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", origin: web },
  body: new URLSearchParams({ grant_type: "authorization_code", client_id: audience, redirect_uri: `${web}/`, code_verifier: verifier, ...p }) });
const codeFrom = async (r: Response) => new URL(r.headers.get("location")!).searchParams.get("code")!;

describe("dev issuer: browser code + PKCE flow", () => {
  test("discovery lists the endpoints, S256 and ES256", async () => {
    const d = await (await fetch(`${iss}.well-known/openid-configuration`)).json();
    expect(d).toMatchObject({ issuer: iss, authorization_endpoint: `${iss}authorize`, token_endpoint: `${iss}oauth/token`,
      code_challenge_methods_supported: ["S256"], id_token_signing_alg_values_supported: ["ES256"], response_types_supported: ["code"] });
  });

  test("a good request redirects with code, state and iss; the code buys a verifiable id_token once", async () => {
    const r = await authorize({ login_hint: "alice" });
    expect(r.status).toBe(302);
    const loc = new URL(r.headers.get("location")!);
    expect(loc.origin + loc.pathname).toBe(`${web}/`);
    expect(loc.searchParams.get("state")).toBe("st");
    expect(loc.searchParams.get("iss")).toBe(iss);
    const code = loc.searchParams.get("code")!;
    const t = await token({ code });
    expect(t.status).toBe(200);
    expect(t.headers.get("access-control-allow-origin")).toBe(web);
    const body = await t.json();
    expect(body).toMatchObject({ token_type: "Bearer", expires_in: 7200 });
    const jwks = createLocalJWKSet({ keys: [(await (await fetch(`${iss}jwks`)).json()).keys[0]] });
    const { payload } = await jwtVerify(body.id_token, jwks, { issuer: iss, audience });
    expect(payload).toMatchObject({ sub: "alice", nonce: "nn" });
    await jwtVerify(body.access_token, jwks, { issuer: iss, audience });
    expect((await token({ code })).status).toBe(400); // single use
  });

  test("refuses a wrong verifier, a non-local or mismatched redirect, plain PKCE and another client", async () => {
    expect((await token({ code: await codeFrom(await authorize({})), code_verifier: "w".repeat(43) })).status).toBe(400);
    expect((await token({ code: await codeFrom(await authorize({})), redirect_uri: "http://127.0.0.1:4173/other" })).status).toBe(400);
    expect((await authorize({ redirect_uri: "https://evil.example/" })).status).toBe(400);
    expect((await authorize({ code_challenge_method: "plain" })).status).toBe(400);
    expect((await authorize({ client_id: "someone-else" })).status).toBe(400);
    expect((await authorize({ code_challenge: "" })).status).toBe(400);
  });

  test("CORS only for the configured web origins; preflight answered", async () => {
    const pre = await fetch(`${iss}oauth/token`, { method: "OPTIONS", headers: { origin: web, "access-control-request-method": "POST" } });
    expect(pre.status).toBe(204);
    expect(pre.headers.get("access-control-allow-origin")).toBe(web);
    const other = await fetch(`${iss}.well-known/openid-configuration`, { headers: { origin: "https://evil.example" } });
    expect(other.headers.get("access-control-allow-origin")).toBeNull();
  });

  test("the load test's GET /token?sub= still works", async () => {
    const body = await (await fetch(`${iss}token?sub=bob`)).json();
    expect(typeof body.token).toBe("string");
  });
});
