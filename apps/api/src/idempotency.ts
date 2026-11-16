import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type pg from "pg";

// Idempotency-Key on POST/PUT (P2.7): a retried request gets the first response back instead of running twice.
export type Stored = { status: number; etag?: string; body: string };
// token: the claim's created_at (ISO 8601 via to_json, exact whatever the session DateStyle/TimeZone), so a request that lost its claim (stale takeover) can't overwrite or delete the new one.
export type Claim = { state: "new"; token: string } | { state: "replay"; stored: Stored } | { state: "mismatch" } | { state: "busy" };
export type IdempotencyStore = {
  claim(userId: string, key: string, hash: string): Promise<Claim>;
  save(userId: string, key: string, token: string, stored: Stored): Promise<void>;
  release(userId: string, key: string, token: string): Promise<void>;
};

const KEY = /^[\x21-\x7e]{1,255}$/; // visible ASCII, like the DB's length CHECK
const TTL = "24 hours";
const STALE = "5 minutes"; // an unfinished claim this old belongs to a crashed request

export function dbIdempotency(pool: pg.Pool): IdempotencyStore {
  return {
    async claim(userId, key, hash) {
      // One statement: insert, or take over an expired key / a stale unfinished claim.
      const won = await pool.query<{ token: string }>(
        `INSERT INTO idempotency_keys (user_id, key, request_hash) VALUES ($1, $2, $3)
         ON CONFLICT (user_id, key) DO UPDATE SET request_hash = EXCLUDED.request_hash, status_code = NULL, response = NULL, created_at = now()
         WHERE idempotency_keys.created_at < now() - interval '${TTL}'
            OR (idempotency_keys.status_code IS NULL AND idempotency_keys.created_at < now() - interval '${STALE}')
         RETURNING to_json(created_at)#>>'{}' AS token`, [userId, key, hash]);
      if (won.rows[0]) return { state: "new", token: won.rows[0].token };
      const r = (await pool.query<{ request_hash: string; status_code: number | null; response: Buffer | null }>(
        "SELECT request_hash, status_code, response FROM idempotency_keys WHERE user_id = $1 AND key = $2", [userId, key])).rows[0];
      if (!r) return this.claim(userId, key, hash); // pruned in between: try again
      if (r.status_code === null || !r.response) return { state: "busy" }; // still running: nothing to compare against yet
      if (r.request_hash !== hash) return { state: "mismatch" };
      return { state: "replay", stored: JSON.parse(r.response.toString()) as Stored };
    },
    async save(userId, key, token, stored) {
      await pool.query("UPDATE idempotency_keys SET status_code = $4, response = $5 WHERE user_id = $1 AND key = $2 AND created_at = $3::timestamptz",
        [userId, key, token, stored.status, Buffer.from(JSON.stringify(stored))]);
    },
    async release(userId, key, token) {
      await pool.query("DELETE FROM idempotency_keys WHERE user_id = $1 AND key = $2 AND created_at = $3::timestamptz AND status_code IS NULL", [userId, key, token]);
    },
  };
}

/** Deletes keys past the 24 h window (the worker runs it each tick). Returns how many went. */
export async function pruneIdempotency(pool: pg.Pool): Promise<number> {
  return (await pool.query(`DELETE FROM idempotency_keys WHERE created_at < now() - interval '${TTL}'`)).rowCount ?? 0;
}

declare module "fastify" {
  interface FastifyRequest { idem?: { key: string; token: string } | undefined }
}

// Registered inside the authenticated /v1 scope (req.userId is set). preHandler runs after body validation,
// so a malformed request is rejected before it can claim a key.
export function idempotencyHooks(v1: FastifyInstance, store: IdempotencyStore) {
  v1.addHook("preHandler", async (req: FastifyRequest, reply: FastifyReply) => {
    if (req.method !== "POST" && req.method !== "PUT") return;
    const key = req.headers["idempotency-key"];
    if (key === undefined) return;
    if (typeof key !== "string" || !KEY.test(key)) return reply.code(400).send({ error: "bad_idempotency_key" });
    // The hash covers everything that decides the outcome; it is a digest, so it never holds the body itself.
    const h = createHash("sha256").update(`${req.method} ${req.url}\n${req.headers["if-match"] ?? ""}\n${req.headers["if-none-match"] ?? ""}\n`)
      .update(JSON.stringify(req.body ?? null)).digest("hex");
    const c = await store.claim(req.userId, key, h);
    if (c.state === "mismatch") return reply.code(422).send({ error: "idempotency_key_reused" });
    if (c.state === "busy") return reply.code(409).send({ error: "idempotency_key_in_flight" });
    if (c.state === "replay") {
      if (c.stored.etag) reply.header("etag", c.stored.etag);
      return reply.code(c.stored.status).header("idempotent-replayed", "true").type("application/json; charset=utf-8").send(c.stored.body);
    }
    req.idem = { key, token: c.token };
  });
  // Store what we answered. A 5xx releases the claim so the client's retry can run for real.
  // A failed save must not turn a committed write into a 500: the client gets the real answer, and a retry sees
  // "in flight" until the claim goes stale (then re-runs, which If-Match / If-None-Match keep safe).
  v1.addHook("onSend", async (req, reply, payload) => {
    const idem = req.idem;
    if (!idem) return payload;
    req.idem = undefined;
    try {
      if (reply.statusCode >= 500) await store.release(req.userId, idem.key, idem.token);
      else {
        const etag = reply.getHeader("etag");
        await store.save(req.userId, idem.key, idem.token, { status: reply.statusCode, ...(typeof etag === "string" ? { etag } : {}), body: String(payload) });
      }
    } catch (e) {
      req.log.error({ code: (e as { code?: string }).code }, "idempotency save failed"); // the code only (see app.ts)
    }
    return payload;
  });
}
