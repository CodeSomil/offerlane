// DEV ONLY (devIssuer.ts): the local OIDC issuer's request handler. Never run it next to real data.
// - discovery + JWKS
// - GET /token?sub=… hands out a token for any sub (load test, image smoke check)
// - the browser flow for the web app (P3.7 H4): /authorize auto-consents (login_hint = sub, default "dev-user") and
//   redirects to a localhost-only redirect_uri; POST /oauth/token checks the single-use code against the S256 PKCE challenge.
import { createHash, randomBytes } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { audience, type fakeIssuer } from "./fakeIssuer.js";

type Issuer = Awaited<ReturnType<typeof fakeIssuer>>;
type Grant = { sub: string; nonce: string; challenge: string; redirect: string; expires: number };

const localRedirect = (u: string) => {
  try { const x = new URL(u); return x.protocol === "http:" && (x.hostname === "localhost" || x.hostname === "127.0.0.1") && x.username === "" && x.password === ""; }
  catch { return false; }
};

export function devIssuerHandler(o: { iss: string; sign: Issuer["sign"]; jwk: Issuer["jwk"]; webOrigins: string[] }) {
  const grants = new Map<string, Grant>();
  const readBody = (req: IncomingMessage) => new Promise<string>((ok, fail) => {
    let s = "";
    req.on("data", (c) => { s += c; if (s.length > 8192) { req.destroy(); fail(new Error("body too large")); } }).on("end", () => ok(s)).on("error", fail);
  });
  return async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", o.iss);
    const origin = req.headers.origin;
    const cors: Record<string, string> = origin && o.webOrigins.includes(origin) ? { "access-control-allow-origin": origin, vary: "origin" } : {};
    const send = (body: unknown, status = 200) => { res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store", ...cors }); res.end(JSON.stringify(body)); };
    const bad = (error: string) => send({ error }, 400);
    if (req.method === "OPTIONS") {
      res.writeHead(204, { ...cors, ...(cors["access-control-allow-origin"] ? { "access-control-allow-methods": "GET, POST", "access-control-allow-headers": "content-type, accept, dpop" } : {}) });
      return res.end();
    }
    if (url.pathname === "/.well-known/openid-configuration") return send({
      issuer: o.iss, jwks_uri: `${o.iss}jwks`, authorization_endpoint: `${o.iss}authorize`, token_endpoint: `${o.iss}oauth/token`,
      response_types_supported: ["code"], code_challenge_methods_supported: ["S256"], id_token_signing_alg_values_supported: ["ES256"],
      grant_types_supported: ["authorization_code"], token_endpoint_auth_methods_supported: ["none"], subject_types_supported: ["public"] });
    if (url.pathname === "/jwks") return send({ keys: [o.jwk] });
    if (url.pathname === "/authorize" && req.method === "GET") {
      const p = url.searchParams, redirect = p.get("redirect_uri") ?? "";
      if (p.get("response_type") !== "code" || p.get("client_id") !== audience) return bad("invalid_request");
      if (!localRedirect(redirect)) return bad("invalid_redirect_uri");
      if (p.get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43}$/.test(p.get("code_challenge") ?? "")) return bad("invalid_request");
      for (const [c, g] of grants) if (g.expires < Date.now()) grants.delete(c);
      const code = randomBytes(24).toString("base64url");
      grants.set(code, { sub: p.get("login_hint") || "dev-user", nonce: p.get("nonce") ?? "", challenge: p.get("code_challenge")!, redirect, expires: Date.now() + 60_000 });
      const to = new URL(redirect);
      to.searchParams.set("code", code); to.searchParams.set("iss", o.iss);
      if (p.has("state")) to.searchParams.set("state", p.get("state")!);
      res.writeHead(302, { location: to.toString(), "cache-control": "no-store" });
      return res.end();
    }
    if (url.pathname === "/oauth/token" && req.method === "POST") {
      const p = new URLSearchParams(await readBody(req)), code = p.get("code") ?? "", g = grants.get(code);
      grants.delete(code);
      if (p.get("grant_type") !== "authorization_code" || p.get("client_id") !== audience || !g || g.expires < Date.now()) return bad("invalid_grant");
      if (p.get("redirect_uri") !== g.redirect) return bad("invalid_grant");
      if (createHash("sha256").update(p.get("code_verifier") ?? "").digest("base64url") !== g.challenge) return bad("invalid_grant");
      const opts = { iss: o.iss, aud: audience, exp: "2h" };
      return send({ token_type: "Bearer", expires_in: 7200, access_token: await o.sign({ sub: g.sub }, opts),
        id_token: await o.sign({ sub: g.sub, ...(g.nonce ? { nonce: g.nonce } : {}) }, opts) });
    }
    const sub = url.searchParams.get("sub");
    if (url.pathname === "/token" && sub) return send({ token: await o.sign({ sub }, { iss: o.iss, aud: audience, exp: "2h" }) });
    send({ error: "not_found" }, 404);
  };
}
