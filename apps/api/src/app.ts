import Fastify, { type FastifyInstance } from "fastify";
import { verifyBearer, type AuthConfig, type UserLookup } from "./auth.js";
import { idempotencyHooks, type IdempotencyStore } from "./idempotency.js";
import { jobRoutes, type JobSearch } from "./jobs.js";
import { bucketFor, type RateLimiter } from "./ratelimit.js";
import { reportError } from "./sentry.js";
import { syncRoutes, type SyncStore } from "./sync.js";

declare module "fastify" {
  interface FastifyRequest { userId: string }
}

// logStream: request logs (method, url, status; never headers or bodies). Omitted = no logging.
// jobs omitted = no /v1/jobs route (tests that only exercise auth or sync).
// ready omitted = /readyz always ready (tests; server.ts always sets it).
// idempotency / limits omitted = Idempotency-Key ignored / no rate limits (server.ts always sets both).
// webOrigins: the exact origins (scheme://host[:port]) of the Offerlane web app allowed to call the API from a browser.
//   Omitted or empty = no CORS headers at all (browsers then refuse every cross-origin call).
export type AppDeps = {
  webOrigins?: readonly string[]; auth: AuthConfig; users: UserLookup; sync: SyncStore; jobs?: JobSearch; idempotency?: IdempotencyStore; limits?: RateLimiter; ready?: () => Promise<boolean>; logStream?: NodeJS.WritableStream;
};

// Fastify's request logs carry no headers or bodies; this is the backstop for anything a handler logs by mistake.
const secret = ["authorization", "cookie", "set-cookie", "idempotency-key", "body", "payload", "ciphertext"];
export const REDACT = { paths: secret.flatMap((k) => [`["${k}"]`, `*["${k}"]`, `*.*["${k}"]`]), censor: "[redacted]" };

// Request log line: method and path only. The query can hold profile words (/v1/jobs?q=); IPs identify people.
// Also applied to any `req` key a handler logs, so it must cope with objects that aren't requests.
const logReq = (r: { method?: string; url?: string }) => ({ method: String(r.method ?? ""), url: String(r.url ?? "").replace(/\?.*$/s, "") });

// Builds the API without listening, so tests can drive it with inject().
export function buildApp(deps: AppDeps): FastifyInstance {
  // removeAdditional off: unknown body fields are rejected, not silently dropped.
  const app = Fastify({ logger: deps.logStream ? { level: "info", stream: deps.logStream, redact: REDACT, serializers: { req: logReq } } : false, ajv: { customOptions: { removeAdditional: false } } });
  app.decorateRequest("userId", "");
  // Never send internal error text (DB hosts, stack details) to callers.
  app.setErrorHandler((e, req, reply) => {
    const err = e as { statusCode?: number; code?: string };
    const code = err.statusCode && err.statusCode < 500 ? err.statusCode : 500;
    // Log the code only: a Postgres error message can quote the failing row (here, ciphertext).
    if (code === 500) { req.log.error({ code: err.code }, "request failed"); reportError(e, err.code); }
    // Public codes only (libs/contract lists them per response); Fastify's internal FST_* codes are not part of the API.
    const error = code === 500 ? "internal" : code === 413 ? "too_large" : code === 415 ? "unsupported_media_type" : "bad_request";
    reply.code(code).send({ error });
  });
  // CORS by hand (no dependency): only the listed origins, never "*"; no credentials (the bearer is a header, not a cookie).
  const origins = new Set(deps.webOrigins ?? []);
  app.addHook("onRequest", async (req, reply) => {
    const o = req.headers.origin;
    if (typeof o !== "string" || !origins.has(o)) return;
    reply.header("access-control-allow-origin", o).header("vary", "Origin")
      .header("access-control-expose-headers", "etag, retry-after, idempotent-replayed, www-authenticate");
    // A preflight is answered here, before the /v1 auth hook (browsers send it without the bearer).
    if (req.method === "OPTIONS" && req.headers["access-control-request-method"]) {
      return reply.code(204).header("access-control-allow-methods", "GET, PUT")
        .header("access-control-allow-headers", "authorization, content-type, idempotency-key, if-match, if-none-match")
        .header("access-control-max-age", "600").send();
    }
  });
  app.get("/healthz", async () => ({ ok: true }));
  app.get("/readyz", async (_req, reply) => {
    const ok = deps.ready ? await deps.ready().catch(() => false) : true;
    return ok ? { ok: true } : reply.code(503).send({ error: "not_ready" });
  });

  // Everything under /v1 needs a valid token from the configured OIDC issuer.
  app.register(async (v1) => {
    v1.addHook("onRequest", async (req, reply) => {
      let who;
      try {
        who = await verifyBearer(req.headers.authorization, deps.auth);
      } catch {
        return reply.code(401).header("www-authenticate", 'Bearer error="invalid_token"').send({ error: "unauthorized" });
      }
      req.userId = await deps.users(who.issuer, who.subject);
      // After auth, so the bucket is the user's (unauthenticated floods are for the edge/proxy; see RUNBOOK).
      const wait = deps.limits ? await deps.limits(req.userId, bucketFor(req.routeOptions.url)) : 0;
      if (wait) return reply.code(429).header("retry-after", String(wait)).send({ error: "rate_limited" });
    });
    if (deps.idempotency) idempotencyHooks(v1, deps.idempotency);
    v1.get("/me", async (req) => ({ id: req.userId }));
    syncRoutes(v1, deps.sync);
    if (deps.jobs) jobRoutes(v1, deps.jobs);
  }, { prefix: "/v1" });
  return app;
}
