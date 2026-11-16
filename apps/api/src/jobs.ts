// GET /v1/jobs: the shared public job index. Filters are only the fields the client sends (P2 plan H5);
// the client ranks against its profile locally, so no profile text ever reaches this route.
import type { FastifyInstance } from "fastify";
import type pg from "pg";
import { jsonSchema, JobsQuery } from "@offerlane/contract";

export type JobQuery = { q?: string; location?: string; remote?: boolean; ats?: string; posted_since?: string; limit: number; cursor?: string };
export type Job = { id: string; ats: string; title: string; company: string; location: string; remote: boolean; url: string; applyUrl: string; description: string; postedAt: string | null };
export type JobPage = { items: Job[]; next: string | null };
/** null = the cursor isn't one we issued. */
export type JobSearch = (q: JobQuery) => Promise<JobPage | null>;

// Cursor = base64url JSON [posted_at as Postgres text (exact round trip) or null, id].
const PG_TS = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,6})?[+-]\d{2}(:\d{2})?$/;
const encode = (posted: string | null, id: string) => Buffer.from(JSON.stringify([posted, id])).toString("base64url");
function decode(c: string): [string | null, string] | null {
  try {
    const v = JSON.parse(Buffer.from(c, "base64url").toString("utf8")) as unknown;
    if (!Array.isArray(v) || v.length !== 2) return null;
    const [p, id] = v as unknown[];
    if (!(p === null || (typeof p === "string" && PG_TS.test(p) && realDay(p.slice(0, 10))))) return null;
    if (typeof id !== "string" || !/^[1-9]\d{0,18}$/.test(id) || BigInt(id) > 2n ** 63n - 1n) return null;
    return [p, id];
  } catch {
    return null;
  }
}
/** Date.parse rolls 2026-02-30 over; Postgres rejects it. */
const realDay = (d: string) => d >= "1900-01-01" && new Date(`${d}T00:00:00Z`).toISOString().slice(0, 10) === d;
const like = (x: string) => `%${x.replace(/[\\%_]/g, (m) => `\\${m}`)}%`;

export function dbJobs(pool: pg.Pool): JobSearch {
  return async (q) => {
    const where = ["j.duplicate_of IS NULL"], args: unknown[] = [];
    const add = (sql: string, ...v: unknown[]) => { args.push(...v); where.push(sql.replace(/\$(\d)/g, (_, i) => `$${args.length - v.length + Number(i)}`)); };
    if (q.q) add("j.search @@ websearch_to_tsquery('english', $1)", q.q);
    if (q.location) add("j.location ILIKE $1", like(q.location));
    if (q.remote !== undefined) add("j.remote = $1", q.remote);
    if (q.ats) add("s.ats = $1", q.ats);
    if (q.posted_since) add("j.posted_at >= $1::date", q.posted_since);
    if (q.cursor) {
      const c = decode(q.cursor);
      if (!c) return null;
      // Order is posted_at DESC NULLS LAST, id DESC; continue strictly after the cursor row.
      if (c[0] === null) add("(j.posted_at IS NULL AND j.id < $1)", c[1]);
      else add("(j.posted_at < $1::timestamptz OR (j.posted_at = $1::timestamptz AND j.id < $2) OR j.posted_at IS NULL)", c[0], c[1]);
    }
    args.push(q.limit + 1);
    const r = await pool.query<{ id: string; ats: string; title: string; company: string; location: string; remote: boolean; url: string; apply_url: string; description: string; posted: string | null; posted_day: string | null }>(
      `SELECT j.id, s.ats, j.title, j.company, j.location, j.remote, j.url, j.apply_url, j.description,
              j.posted_at::text AS posted, to_char(j.posted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD') AS posted_day
       FROM jobs j JOIN job_sources s ON s.id = j.source_id
       WHERE ${where.join(" AND ")}
       ORDER BY j.posted_at DESC NULLS LAST, j.id DESC LIMIT $${args.length}`, args);
    const page = r.rows.slice(0, q.limit);
    const last = page.at(-1);
    return {
      items: page.map((x) => ({ id: x.id, ats: x.ats, title: x.title, company: x.company, location: x.location, remote: x.remote, url: x.url, applyUrl: x.apply_url, description: x.description, postedAt: x.posted_day })),
      next: r.rows.length > q.limit && last ? encode(last.posted, last.id) : null,
    };
  };
}

const querystring = jsonSchema(JobsQuery);

// Registered inside the authenticated /v1 scope.
export function jobRoutes(v1: FastifyInstance, search: JobSearch) {
  v1.get<{ Querystring: JobQuery }>("/jobs", { schema: { querystring } }, async (req, reply) => {
    // The pattern lets 2026-02-31 through; Postgres would reject it with a 500.
    const d = req.query.posted_since;
    if (d && !realDay(d)) return reply.code(400).send({ error: "bad_request" });
    const page = await search(req.query);
    return page ?? reply.code(400).send({ error: "bad_cursor" });
  });
}
