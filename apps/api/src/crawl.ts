// P2.6 crawl: one public ATS board → the shared job index, with exact and near-duplicate marking.
import { createHash } from "node:crypto";
import type pg from "pg";
import { board, CRAWL_ENABLED, type Ats, type Fetch, type Pacer } from "./ats.js";

export type Source = { id: number; ats: Ats; company_slug: string; company_name: string | null; etag: string | null; last_modified: string | null };
export type CrawlOpts = { fetch?: Fetch; pace?: Pacer };
export type CrawlResult = { status: "ok" | "failed" | "refused"; found: number | null };

/** Lowercase, no accents, words only: "Sr. Engineer – Zürich" → "sr engineer zurich". */
export const normalize = (x: string) =>
  x.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();

export const dedupeHash = (title: string, company: string, location: string) =>
  createHash("sha256").update([title, company, location].map(normalize).join("|")).digest("hex");

export const DIMS = 256;
/** Near-duplicate threshold on cosine distance (0 = same words): one extra word among about 8 features is near;
 *  a changed level ("II") among 4 is not. */
export const NEAR = 0.1;

/** Feature-hashed bag of title words, title bigrams and location words, L2-normalised. Only public job text goes in (H5).
 *  SHORTCUT: a hashed vector, not a learned embedding; it catches reworded/reordered copies, not synonyms. Swap in a real
 *  embedding model (same column, new dimension migration) once the human picks one. */
export function embed(title: string, location: string): number[] {
  const v = new Array<number>(DIMS).fill(0);
  const t = normalize(title).split(" ").filter(Boolean);
  const feats = [...t, ...t.slice(1).map((w, i) => `${t[i]} ${w}`), ...normalize(location).split(" ").filter(Boolean).map((w) => `@${w}`)];
  for (const f of feats) {
    const h = createHash("sha256").update(f).digest();
    v[h.readUInt16BE(0) % DIMS]! += h[2]! & 1 ? 1 : -1;
  }
  const n = Math.hypot(...v);
  return n === 0 ? v : v.map((x) => x / n);
}

const isRemote = (location: string) => /\bremote\b/i.test(location);
/** toDate keeps any 10 characters a board sends; one bad date must not fail the whole board's insert. */
export const validDay = (d: string | null): string | null =>
  d && /^\d{4}-\d{2}-\d{2}$/.test(d) && d >= "1970-01-01" && new Date(`${d}T00:00:00Z`).toISOString().startsWith(d) ? d : null;
/** Clients render these as links: http(s) only, never javascript: or data:. */
export const webURL = (u: string): string | null => { try { return /^https?:$/.test(new URL(u).protocol) ? u : null; } catch { return null; } };

async function finish(pool: pg.Pool, run: number, r: CrawlResult, error: string | null = null): Promise<CrawlResult> {
  await pool.query("UPDATE crawl_runs SET finished_at = now(), status = $2, found = $3, error = $4 WHERE id = $1", [run, r.status, r.found, error]);
  return r;
}

/** Crawls one source. Never throws for board problems; they are recorded in crawl_runs. */
export async function crawlSource(pool: pg.Pool, src: Source, opts: CrawlOpts = {}): Promise<CrawlResult> {
  if (!CRAWL_ENABLED.includes(src.ats)) {
    await pool.query("INSERT INTO crawl_runs (source_id, finished_at, status, error) VALUES ($1, now(), 'refused', 'ats not enabled')", [src.id]);
    return { status: "refused", found: null };
  }
  const run = (await pool.query<{ id: string }>("INSERT INTO crawl_runs (source_id) VALUES ($1) RETURNING id", [src.id])).rows[0]!.id;
  const markCrawled = (etag: string | null, lastModified: string | null) =>
    pool.query("UPDATE job_sources SET last_crawled_at = now(), etag = $2, last_modified = $3 WHERE id = $1", [src.id, etag, lastModified]);
  let b;
  try {
    b = await board(src.ats, src.company_slug, { ...opts, validators: { etag: src.etag, lastModified: src.last_modified } });
  } catch {
    b = null;
  }
  if (b === null) {
    // Keep the old jobs and validators: a board that's briefly down shouldn't empty the index. Next try after the usual interval.
    await pool.query("UPDATE job_sources SET last_crawled_at = now() WHERE id = $1", [src.id]);
    return finish(pool, Number(run), { status: "failed", found: null }, "unavailable");
  }
  if (b === "not_modified") {
    await pool.query("UPDATE jobs SET last_seen_at = now() WHERE source_id = $1", [src.id]);
    await markCrawled(src.etag, src.last_modified);
    return finish(pool, Number(run), { status: "ok", found: null });
  }
  const company = src.company_name ?? src.company_slug;
  const rows = [...new Map(b.postings.filter((p) => webURL(p.url) && p.title).map((p) => [p.url, p])).values()].map((p) => ({
    url: p.url, apply_url: webURL(p.applyUrl) ?? "", title: p.title, location: p.location, remote: isRemote(p.location),
    description: p.description, posted: validDay(p.posted), hash: dedupeHash(p.title, company, p.location),
    embedding: `[${embed(p.title, p.location).join(",")}]`,
  }));
  const c = await pool.connect();
  try {
    await c.query("BEGIN");
    await c.query(
      `INSERT INTO jobs (source_id, external_id, url, apply_url, title, company, location, remote, description, posted_at, dedupe_hash, embedding)
       SELECT $1, r.url, r.url, r.apply_url, r.title, $2, r.location, r.remote, r.description, r.posted::timestamptz, r.hash, r.embedding::vector
       FROM jsonb_to_recordset($3::jsonb) AS r(url text, apply_url text, title text, location text, remote boolean, description text, posted text, hash text, embedding text)
       ON CONFLICT (source_id, external_id) DO UPDATE SET
         url = excluded.url, apply_url = excluded.apply_url, title = excluded.title, company = excluded.company, location = excluded.location,
         remote = excluded.remote, description = excluded.description, posted_at = excluded.posted_at, dedupe_hash = excluded.dedupe_hash,
         embedding = excluded.embedding, last_seen_at = now(),
         duplicate_of = CASE WHEN jobs.dedupe_hash = excluded.dedupe_hash THEN jobs.duplicate_of END`,
      [src.id, company, JSON.stringify(rows)]);
    // The board is the source of truth: postings it no longer lists are closed (only when we saw all of it).
    if (b.complete) await c.query("DELETE FROM jobs WHERE source_id = $1 AND NOT (external_id = ANY($2::text[]))", [src.id, rows.map((r) => r.url)]);
    // SHORTCUT: scans the company's visible rows (index jobs_company_live), no ANN index; fine while a company has thousands of
    // jobs, not millions. Upgrade to an HNSW ORDER BY embedding <=> ... LIMIT k lookup if companies get that big.
    // Each of this source's rows becomes a duplicate of the oldest-id visible job at the same company with the same hash or a near-identical vector.
    await c.query(
      `UPDATE jobs j SET duplicate_of = (
         SELECT o.id FROM jobs o
         WHERE o.id < j.id AND o.duplicate_of IS NULL AND o.company = j.company
           AND (o.dedupe_hash = j.dedupe_hash OR o.embedding <=> j.embedding < $2)
         ORDER BY o.id LIMIT 1)
       WHERE j.source_id = $1 AND j.duplicate_of IS NULL`, [src.id, NEAR]);
    await c.query("COMMIT");
  } catch (e) {
    let broken: Error | undefined;
    try { await c.query("ROLLBACK"); } catch (r) { broken = r as Error; }
    c.release(broken); // a client whose rollback failed is destroyed, not pooled
    // The code only: a Postgres message can quote the row. Still counts as crawled, so a bad board waits the usual interval.
    await pool.query("UPDATE job_sources SET last_crawled_at = now() WHERE id = $1", [src.id]).catch(() => {});
    await finish(pool, Number(run), { status: "failed", found: null }, `db ${(e as { code?: string }).code ?? "error"}`).catch(() => {});
    throw e;
  }
  c.release();
  await markCrawled(b.etag, b.lastModified);
  return finish(pool, Number(run), { status: "ok", found: rows.length });
}

/** Crawls every enabled source that is due (never crawled, or not for everyHours), one after another.
 *  Each source is claimed (last_crawled_at = now()) with SKIP LOCKED before it is fetched, so two workers never crawl the
 *  same source at once. Stops between sources once signal aborts (pg-boss expiry or shutdown). */
export async function crawlDue(pool: pg.Pool, opts: CrawlOpts & { everyHours?: number; signal?: AbortSignal } = {}): Promise<CrawlResult[]> {
  const out: CrawlResult[] = [];
  while (!opts.signal?.aborted) {
    const s = (await pool.query<Source>(
      `UPDATE job_sources SET last_crawled_at = now() WHERE id = (
         SELECT id FROM job_sources
         WHERE enabled AND ats = ANY($1::text[]) AND (last_crawled_at IS NULL OR last_crawled_at < now() - make_interval(hours => $2))
         ORDER BY last_crawled_at NULLS FIRST, id LIMIT 1 FOR UPDATE SKIP LOCKED)
       RETURNING id, ats, company_slug, company_name, etag, last_modified`, [CRAWL_ENABLED, opts.everyHours ?? 6])).rows[0];
    if (!s) break;
    try { out.push(await crawlSource(pool, s, opts)); } catch { out.push({ status: "failed", found: null }); }
  }
  return out;
}
