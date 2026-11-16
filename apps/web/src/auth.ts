// Sign-in (P3.7, H4): OIDC authorization code + PKCE (S256) in the browser, through oauth4webapi. The web app works fully
// signed out; signing in only adds the job index and sync. The provider is config (VITE_OIDC_ISSUER / VITE_OIDC_CLIENT_ID);
// locally it is the dev issuer (apps/api/test/devIssuerApp.ts). The bearer is the ID token: the API's OIDC_AUDIENCE is our client id.
import * as o from "oauth4webapi";

declare const __OIDC_ISSUER__: string, __OIDC_CLIENT_ID__: string;
const ISSUER = new URL(__OIDC_ISSUER__);
const client: o.Client = { client_id: __OIDC_CLIENT_ID__ };
// Plain http only for a localhost issuer (dev), as the API's auth.ts allows.
const http = ISSUER.protocol === "http:" && (ISSUER.hostname === "localhost" || ISSUER.hostname === "127.0.0.1");
const opts = () => ({ [o.allowInsecureRequests]: http, signal: AbortSignal.timeout(15_000) });
const PENDING = "offerlane-signin", SESSION = "offerlane-session";
const redirectUri = () => location.origin + location.pathname;

export type Session = { token: string; sub: string; expires: number };
export class AuthError extends Error {}

const server = async () => o.processDiscoveryResponse(ISSUER, await o.discoveryRequest(ISSUER, opts()));

/** Leaves the page for the provider; the PKCE verifier, state and nonce wait in this tab's sessionStorage. */
export async function signIn(): Promise<void> {
  let as;
  try { as = await server(); } catch { throw new AuthError("Couldn't reach the sign-in service. Check your connection and try again."); }
  if (!as.authorization_endpoint) throw new AuthError("The sign-in service isn't set up for browser sign-in.");
  const verifier = o.generateRandomCodeVerifier(), state = o.generateRandomState(), nonce = o.generateRandomNonce();
  sessionStorage.setItem(PENDING, JSON.stringify({ verifier, state, nonce, back: location.hash }));
  const u = new URL(as.authorization_endpoint);
  u.search = new URLSearchParams({ client_id: client.client_id, redirect_uri: redirectUri(), response_type: "code", scope: "openid", state, nonce,
    code_challenge: await o.calculatePKCECodeChallenge(verifier), code_challenge_method: "S256" }).toString();
  location.assign(u);
}

/** On load: when the provider sent us back (?code= or ?error=), clean the URL first, then trade the code for tokens. */
export async function finishSignIn(): Promise<Session | undefined> {
  const params = new URLSearchParams(location.search);
  if (!params.has("code") && !params.has("error")) return undefined;
  const raw = sessionStorage.getItem(PENDING);
  sessionStorage.removeItem(PENDING);
  let p: { verifier: string; state: string; nonce: string; back: string } | undefined;
  try { p = raw ? JSON.parse(raw) : undefined; } catch { p = undefined; }
  history.replaceState(null, "", location.pathname + (p?.back ?? ""));
  if (!p) throw new AuthError("That sign-in didn't start in this tab, or it expired. Sign in again.");
  try {
    const as = await server();
    const cb = o.validateAuthResponse(as, client, params, p.state);
    const res = await o.authorizationCodeGrantRequest(as, client, o.None(), cb, redirectUri(), p.verifier, opts());
    const r = await o.processAuthorizationCodeResponse(as, client, res, { expectedNonce: p.nonce, requireIdToken: true });
    const claims = o.getValidatedIdTokenClaims(r)!;
    const s: Session = { token: r.id_token!, sub: claims.sub, expires: claims.exp * 1000 };
    sessionStorage.setItem(SESSION, JSON.stringify(s));
    return s;
  } catch (e) {
    if (e instanceof o.AuthorizationResponseError && e.error === "access_denied") throw new AuthError("Sign-in was cancelled.");
    throw new AuthError("Sign-in didn't complete. Try again.");
  }
}

let returned: Promise<Session | undefined> | undefined;
/** Called once in main.tsx before the first render (the URL is cleaned synchronously, before App reads the hash). */
export const signedIn = () => (returned ??= finishSignIn());

/** SHORTCUT: no refresh token; within a minute of expiry the session ends and the user signs in again. */
export function session(now = Date.now()): Session | undefined {
  try {
    const s = JSON.parse(sessionStorage.getItem(SESSION) ?? "null") as Session | null;
    if (s && typeof s.token === "string" && typeof s.expires === "number" && s.expires - 60_000 > now) return s;
    sessionStorage.removeItem(SESSION);
  } catch { /* storage blocked: signed out */ }
  return undefined;
}
export function signOut() { try { sessionStorage.removeItem(SESSION); } catch { /* nothing to clear */ } }
export const bearer = (): string | undefined => session()?.token;
