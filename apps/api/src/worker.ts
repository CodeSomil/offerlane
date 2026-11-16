// The crawl worker: a pg-boss tick every 15 minutes crawls the sources that are due (crawl.ts decides which).
// Lives in apps/api to share ats.ts/crawl.ts; the Dockerfile's `worker` target runs it (P2.9 decision: no apps/worker split).
import "./otel.js"; // first: tracing must start before pg and http load (off unless OTEL_EXPORTER_OTLP_ENDPOINT)
import { fileURLToPath } from "node:url";
import pg from "pg";
import { PgBoss } from "pg-boss";
import { crawlDue } from "./crawl.js";
import { pruneIdempotency } from "./idempotency.js";
import { initSentry, reportError } from "./sentry.js";

export const QUEUE = "crawl";

/** Starts the scheduler + worker on an existing pool's database. Returns a stop function. */
export async function startWorker(databaseUrl: string, pool: pg.Pool): Promise<() => Promise<void>> {
  const boss = new PgBoss(databaseUrl);
  // The code only: a Postgres message can quote a row.
  boss.on("error", (e: Error) => {
    const code = (e as { code?: string }).code ?? "error";
    console.error(JSON.stringify({ msg: "pg-boss error", code }));
    reportError(e, code);
  });
  await boss.start();
  // exclusive: at most one tick queued or running, so a slow crawl never overlaps the next one.
  // No retry (the next tick is the retry) and a 6 h expiry, so a long tick isn't failed and re-run beside itself.
  // The 60 s heartbeat frees the queue soon after a worker dies mid-tick (otherwise exclusive blocks ticks until expiry).
  await boss.createQueue(QUEUE, { policy: "exclusive", retryLimit: 0, expireInSeconds: 6 * 3600, heartbeatSeconds: 60 });
  await boss.schedule(QUEUE, "*/15 * * * *");
  await boss.work(QUEUE, async ([job]) => {
    const pruned = await pruneIdempotency(pool);
    const r = await crawlDue(pool, job ? { signal: job.signal } : {});
    console.log(JSON.stringify({ msg: "crawl tick", sources: r.length, failed: r.filter((x) => x.status === "failed").length, idempotencyPruned: pruned }));
  });
  return () => boss.stop({ graceful: true });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  initSentry(process.env.SENTRY_DSN);
  const pool = new pg.Pool({ connectionString: url });
  const stop = await startWorker(url, pool);
  for (const sig of ["SIGINT", "SIGTERM"] as const) process.on(sig, () => void stop().then(() => pool.end()));
}
