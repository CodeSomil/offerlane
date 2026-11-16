import "./otel.js"; // first: tracing must start before pg and http load (off unless OTEL_EXPORTER_OTLP_ENDPOINT)
import pg from "pg";
import { buildApp } from "./app.js";
import { dbUsers, discover } from "./auth.js";
import { dbIdempotency } from "./idempotency.js";
import { dbJobs } from "./jobs.js";
import { dbLimits } from "./ratelimit.js";
import { dbReady } from "./db/migrate.js";
import { initSentry } from "./sentry.js";
import { dbSync } from "./sync.js";

function need(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

initSentry(process.env.SENTRY_DSN);
const pool = new pg.Pool({ connectionString: need("DATABASE_URL") });
// /readyz has its own connection, so a pool busy with requests doesn't make a healthy instance look not-ready.
const probePool = new pg.Pool({ connectionString: need("DATABASE_URL"), max: 1, connectionTimeoutMillis: 2000, statement_timeout: 2000 });
// An idle client dies when the DB restarts; without a listener that 'error' event would crash the process.
for (const p of [pool, probePool]) p.on("error", (e: Error & { code?: string }) => console.error(JSON.stringify({ msg: "pg pool error", code: e.code ?? "error" })));
const auth = await discover(need("OIDC_ISSUER"), need("OIDC_AUDIENCE"), process.env.OIDC_ALLOW_LOCAL_HTTP === "1");
const port = Number(process.env.PORT ?? 8787);
// Localhost unless the deploy sets HOST (containers set 0.0.0.0).
const host = process.env.HOST ?? "127.0.0.1";
// WEB_ORIGINS: comma-separated origins of the web app (CORS); unset = browsers can't call the API.
const webOrigins = (process.env.WEB_ORIGINS ?? "").split(",").map((o) => o.trim()).filter((o) => o !== "");
await buildApp({ webOrigins, auth, users: dbUsers(pool), sync: dbSync(pool), jobs: dbJobs(pool), idempotency: dbIdempotency(pool), limits: dbLimits(pool), ready: dbReady(probePool), logStream: process.stdout }).listen({ port, host });
