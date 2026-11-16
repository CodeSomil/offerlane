import pg from "pg";
import { describe, expect, test } from "vitest";
import { dbReady, migrate } from "../src/db/migrate.js";
import { adminUrl, freshDatabase } from "./testdb.js";

const tables = ["crawl_runs", "devices", "idempotency_keys", "job_sources", "jobs", "rate_buckets", "sync_blobs", "users"];

async function userTables(url: string): Promise<string[]> {
  const c = new pg.Client({ connectionString: url });
  await c.connect();
  const r = await c.query<{ t: string }>(
    "SELECT tablename AS t FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'pgmigrations' ORDER BY 1");
  await c.end();
  return r.rows.map((x) => x.t);
}

describe.skipIf(!adminUrl)("migrations", () => {
  test("up, down, up on an empty database", async () => {
    const db = await freshDatabase();
    try {
      expect(await migrate(db.url, "up")).toEqual(["1731400000000_initial", "1731500000000_sync_kinds", "1731600000000_crawl_dedupe"]);
      expect(await userTables(db.url)).toEqual(tables);
      // The DB enforces the spec's kind list and opaque key ids too, not just the API.
      const c = new pg.Client({ connectionString: db.url });
      await c.connect();
      const u = (await c.query<{ id: string }>("INSERT INTO users (oidc_issuer, oidc_sub) VALUES ('i', 's') RETURNING id")).rows[0]!.id;
      const put = (kind: string, keyId: string) =>
        c.query("INSERT INTO sync_blobs (user_id, kind, version, key_id, ciphertext) VALUES ($1, $2, 1, $3, '\\x00')", [u, kind, keyId]);
      await expect(put("a1", "k1")).rejects.toThrow(/sync_blobs_kind_check/);
      await expect(put("profile", "me@x.com")).rejects.toThrow(/sync_blobs_key_id_check/);
      await put("profile", "k1");
      await c.end();
      await migrate(db.url, "down");
      expect(await userTables(db.url)).toEqual([]);
      await migrate(db.url, "up");
      expect(await userTables(db.url)).toEqual(tables);
      expect(await migrate(db.url, "up")).toEqual([]); // already current
    } finally {
      await db.drop();
    }
  });

  test("schema refuses oversized or malformed sync rows", async () => {
    const db = await freshDatabase();
    const c = new pg.Client({ connectionString: db.url });
    try {
      await migrate(db.url, "up");
      await c.connect();
      const { rows: [u] } = await c.query<{ id: string }>("INSERT INTO users (oidc_issuer, oidc_sub) VALUES ('i','s') RETURNING id");
      const put = (kind: string, size: number) => c.query(
        "INSERT INTO sync_blobs (user_id, kind, version, key_id, ciphertext) VALUES ($1, $2, 1, 'k1', $3)",
        [u!.id, kind, Buffer.alloc(size)]);
      await put("profile", 16);
      await expect(put("Bad Kind", 16)).rejects.toThrow(/check constraint/);
      await expect(put("big", 8 * 1024 * 1024 + 1)).rejects.toThrow(/check constraint/);
    } finally {
      await c.end().catch(() => {});
      await db.drop();
    }
  });
});

describe.skipIf(!adminUrl)("search_path", () => {
  test("migrations land in public even when a schema named after the migrating user exists", async () => {
    const db = await freshDatabase();
    try {
      const c = new pg.Client({ connectionString: db.url });
      await c.connect();
      await c.query("CREATE SCHEMA IF NOT EXISTS \"$user\"".replace("$user", new URL(db.url).username || "postgres"));
      await c.end();
      await migrate(db.url, "up");
      expect(await userTables(db.url)).toEqual(tables);
    } finally { await db.drop(); }
  });
});

describe.skipIf(!adminUrl)("readiness", () => {
  test("dbReady is true only when the newest migration is applied", async () => {
    const db = await freshDatabase();
    const pool = new pg.Pool({ connectionString: db.url });
    try {
      const ready = dbReady(pool);
      expect(await ready()).toBe(false); // no pgmigrations table yet
      await migrate(db.url, "up");
      expect(await ready()).toBe(true);
      await migrate(db.url, "down", 1);
      expect(await ready()).toBe(false);
    } finally { await pool.end(); await db.drop(); }
  });
});
