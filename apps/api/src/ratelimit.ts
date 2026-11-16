import type pg from "pg";

// Per-user token buckets (P2.7). Returns 0 when the request may go ahead, else the seconds to wait.
export type RateLimiter = (userId: string, bucket: Bucket) => Promise<number>;
export type Bucket = "sync" | "jobs" | "api";
export type Rule = { capacity: number; perSecond: number };

// Defaults: a burst of 60 sync calls and 120 others, refilled at 1 and 2 per second.
export const DEFAULT_RULES: Record<Bucket, Rule> = {
  sync: { capacity: 60, perSecond: 1 },
  jobs: { capacity: 120, perSecond: 2 },
  api: { capacity: 120, perSecond: 2 },
};

export function bucketFor(route: string | undefined): Bucket {
  if (route?.startsWith("/v1/sync")) return "sync";
  if (route?.startsWith("/v1/jobs")) return "jobs";
  return "api";
}

export function dbLimits(pool: pg.Pool, rules: Record<Bucket, Rule> = DEFAULT_RULES): RateLimiter {
  return async (userId, bucket) => {
    const { capacity, perSecond } = rules[bucket];
    // One atomic statement, safe across instances: refill by elapsed time (capped), then spend one token.
    // A request is allowed when the result is >= 0. A denied one still spends, floored at -1, so hammering
    // only stretches the wait to at most 2 tokens' worth.
    const r = await pool.query<{ tokens: number }>(
      `INSERT INTO rate_buckets (user_id, bucket, tokens, updated_at) VALUES ($1, $2, $3::float8 - 1, now())
       ON CONFLICT (user_id, bucket) DO UPDATE SET
         tokens = GREATEST(LEAST($3::float8, rate_buckets.tokens + EXTRACT(EPOCH FROM now() - rate_buckets.updated_at)::float8 * $4::float8) - 1, -1),
         updated_at = now()
       RETURNING tokens`, [userId, bucket, capacity, perSecond]);
    const t = r.rows[0]!.tokens;
    return t >= 0 ? 0 : Math.ceil((1 - t) / perSecond);
  };
}
