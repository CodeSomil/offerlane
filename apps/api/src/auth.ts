import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import type pg from "pg";

// Hosted OIDC only (H2): we verify the provider's tokens and never see a password.
export type AuthConfig = { issuer: string; audience: string; jwks: JWTVerifyGetKey };
// Maps a verified (issuer, subject) to our user id, creating the user on first sight.
export type UserLookup = (issuer: string, subject: string) => Promise<string>;

const algorithms = ["RS256", "ES256", "EdDSA"]; // asymmetric only: no "none", no shared-secret HS*

export async function verifyBearer(header: string | undefined, cfg: AuthConfig): Promise<{ issuer: string; subject: string }> {
  const m = /^Bearer ([A-Za-z0-9._~+/=-]+)$/i.exec(header ?? "");
  if (!m) throw new Error("missing bearer token");
  const { payload } = await jwtVerify(m[1]!, cfg.jwks, {
    issuer: cfg.issuer, audience: cfg.audience, algorithms, requiredClaims: ["sub", "exp"], clockTolerance: 30,
  });
  return { issuer: cfg.issuer, subject: payload.sub! };
}

export function dbUsers(pool: pg.Pool): UserLookup {
  return async (issuer, subject) => {
    // Read first so a known user costs no write; insert on a miss (DO NOTHING + re-read covers a race).
    const find = () => pool.query<{ id: string }>("SELECT id FROM users WHERE oidc_issuer = $1 AND oidc_sub = $2", [issuer, subject]);
    const hit = await find();
    if (hit.rows[0]) return hit.rows[0].id;
    await pool.query("INSERT INTO users (oidc_issuer, oidc_sub) VALUES ($1, $2) ON CONFLICT DO NOTHING", [issuer, subject]);
    return (await find()).rows[0]!.id;
  };
}

// Reads the provider's discovery document so the JWKS URL never has to be configured by hand.
// allowLocalHttp: plain http to localhost only, for the dev issuer (server.ts sets it from OIDC_ALLOW_LOCAL_HTTP=1,
// which only compose.dev.yml sets). Off by default, so a deploy can't trust an http issuer by mistake.
export async function discover(issuer: string, audience: string, allowLocalHttp = false): Promise<AuthConfig> {
  const secure = (u: URL) => u.protocol === "https:" || (allowLocalHttp && u.protocol === "http:" && (u.hostname === "localhost" || u.hostname === "127.0.0.1"));
  const base = new URL(issuer);
  if (!secure(base)) throw new Error("OIDC issuer must use https");
  // No redirects: the document must come from the issuer itself.
  const res = await fetch(new URL(".well-known/openid-configuration", issuer.endsWith("/") ? issuer : issuer + "/"), { redirect: "error" });
  if (!res.ok) throw new Error(`OIDC discovery failed: ${res.status}`);
  const doc = (await res.json()) as { issuer?: string; jwks_uri?: string };
  if (doc.issuer !== issuer || !doc.jwks_uri) throw new Error("OIDC discovery document does not match the issuer");
  // The signing keys must also arrive over https, or anyone on the path could swap in their own keys.
  const jwksUrl = new URL(doc.jwks_uri);
  if (!secure(jwksUrl)) throw new Error("OIDC jwks_uri must use https");
  return { issuer, audience, jwks: createRemoteJWKSet(jwksUrl) };
}
