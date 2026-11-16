import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type JWTPayload } from "jose";
import type { AppDeps } from "../src/app.js";
import type { SyncBlob, SyncStore } from "../src/sync.js";

export const issuer = "https://issuer.test/";
export const audience = "offerlane-api";

// A local OIDC issuer: signs tokens with a throwaway key and serves its JWKS in memory.
export async function fakeIssuer() {
  const { privateKey, publicKey } = await generateKeyPair("ES256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "k1", alg: "ES256" };
  const jwks = createLocalJWKSet({ keys: [jwk] });
  const sign = (claims: JWTPayload = {}, opts: { exp?: string | number; aud?: string; iss?: string } = {}) =>
    new SignJWT({ ...claims })
      .setProtectedHeader({ alg: "ES256", kid: "k1" })
      .setSubject((claims.sub as string | undefined) ?? "user-1")
      .setIssuer(opts.iss ?? issuer)
      .setAudience(opts.aud ?? audience)
      .setIssuedAt()
      .setExpirationTime(opts.exp ?? "5m")
      .sign(privateKey);
  return { jwks, sign, jwk };
}

// In-memory user table for tests that don't need Postgres.
export function memoryUsers(): AppDeps["users"] {
  const ids = new Map<string, string>();
  return async (iss, sub) => {
    const k = `${iss} ${sub}`;
    if (!ids.has(k)) ids.set(k, `u${ids.size + 1}`);
    return ids.get(k)!;
  };
}

// In-memory sync store with the same compare-and-set rules as dbSync.
export function memorySync(): SyncStore {
  const rows = new Map<string, SyncBlob>();
  return {
    async get(user, kind) { return rows.get(`${user} ${kind}`) ?? null; },
    async put(user, kind, expected, keyId, ciphertext) {
      const k = `${user} ${kind}`;
      const cur = rows.get(k)?.version ?? null;
      if (cur !== expected) return { ok: false, version: cur };
      const version = (cur ?? 0) + 1;
      rows.set(k, { version, keyId, ciphertext });
      return { ok: true, version };
    },
  };
}
