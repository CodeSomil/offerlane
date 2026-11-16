import { execFile, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { migrate } from "../src/db/migrate.js";
import { adminUrl, freshDatabase } from "./testdb.js";

const run = promisify(execFile);
const drill = fileURLToPath(new URL("../../../scripts/db_restore_drill.sh", import.meta.url));

// The P2 restore gate: scripts/db_restore_drill.sh against a seeded database, with the tools inside the Postgres
// container (same major version as the server; local compose and the CI service both run pgvector/pgvector:pg17).
describe.skipIf(!adminUrl)("restore drill", () => {
  let src: Awaited<ReturnType<typeof freshDatabase>>;
  const targets: Awaited<ReturnType<typeof freshDatabase>>[] = [];
  let tools: string;
  // URLs as the container sees its own server.
  const inside = (url: string) => `postgres://postgres@localhost:5432${new URL(url).pathname}`;
  const restoreInto = async (env: Record<string, string> = {}) => {
    const dst = await freshDatabase();
    targets.push(dst);
    return run("bash", [drill, inside(src.url), inside(dst.url)], { env: { ...process.env, PG_TOOLS: tools, ...env } });
  };

  beforeAll(async () => {
    const id = execFileSync("docker", ["ps", "-q", "--filter", "ancestor=pgvector/pgvector:pg17"], { encoding: "utf8" }).trim().split("\n")[0];
    if (!id) throw new Error("no running pgvector/pgvector:pg17 container to run the drill's tools in");
    tools = `docker exec -i ${id}`;
    src = await freshDatabase();
    await migrate(src.url, "up");
    const c = new pg.Client({ connectionString: src.url });
    await c.connect();
    // One row per kind of data the drill must carry: uuids, bytea ciphertext, vectors, nulls, timestamps.
    const u = (await c.query("INSERT INTO users (oidc_issuer, oidc_sub) VALUES ('https://i/', 's1') RETURNING id")).rows[0].id;
    await c.query("INSERT INTO sync_blobs (user_id, kind, version, key_id, ciphertext) VALUES ($1, 'profile', 3, 'k1', $2)", [u, Buffer.from([1, 0, 255, 7])]);
    const s = (await c.query("INSERT INTO job_sources (ats, company_slug, company_name) VALUES ('greenhouse', 'acme', 'Acme') RETURNING id")).rows[0].id;
    await c.query(`INSERT INTO jobs (source_id, external_id, url, apply_url, title, company, location, remote, description, posted_at, dedupe_hash, embedding)
      VALUES ($1, '1', 'https://b/1', 'https://b/1', 'Engineer', 'Acme', 'Remote', true, 'Build things', '2026-11-01', 'h1', $2)`, [s, `[${Array(256).fill(0.5).join(",")}]`]);
    // The worker's queue schema (pg-boss creates the real one at start); the drill must carry it too.
    await c.query("CREATE SCHEMA pgboss; CREATE TABLE pgboss.job (id bigserial PRIMARY KEY, name text); INSERT INTO pgboss.job (name) VALUES ('crawl')");
    await c.end();
  });
  afterAll(async () => {
    for (const t of targets) await t.drop();
    await src?.drop();
  });

  test("a restore into an empty database matches the source table by table", async () => {
    const { stdout } = await restoreInto();
    expect(stdout).toMatch(/^restore drill OK: \d+ tables, [1-9]\d* sequences, [1-9]\d* rows match/);
  });

  test("a restore that lost or changed rows fails", async () => {
    for (const sql of ["DELETE FROM jobs", "UPDATE sync_blobs SET ciphertext = '\\x00'", "DELETE FROM pgboss.job", "SELECT setval('job_sources_id_seq', 1000)"]) {
      const err = await restoreInto({ DRILL_AFTER_RESTORE: sql }).catch((e: { code: number; stderr: string }) => e);
      expect(err).toMatchObject({ code: 1 });
      expect((err as { stderr: string }).stderr).toMatch(/restore drill FAILED/);
    }
  }, 60_000);

  test("fails when a fingerprint query fails, even if it fails the same way on both sides", async () => {
    // A tools wrapper whose per-table count query always fails: without the checks, both sides would print the same blank.
    const dir = mkdtempSync(join(tmpdir(), "drill-"));
    const wrap = join(dir, "tools.sh");
    writeFileSync(wrap, `#!/bin/bash\ncase "$*" in *"count(*)"*) exit 3;; esac\nexec ${tools} "$@"\n`, { mode: 0o755 });
    try {
      const err = await restoreInto({ PG_TOOLS: wrap }).catch((e: { code: number; stdout: string }) => e);
      expect(err).toMatchObject({ code: 1 });
      expect((err as { stdout: string }).stdout).not.toMatch(/OK/);
    } finally { rmSync(dir, { recursive: true }); }
  }, 30_000);

  test("refuses a target that already has tables", async () => {
    const dst = await freshDatabase();
    targets.push(dst);
    await migrate(dst.url, "up");
    const err = await run("bash", [drill, inside(src.url), inside(dst.url)], { env: { ...process.env, PG_TOOLS: tools } }).catch((e: { stderr: string }) => e);
    expect((err as { stderr: string }).stderr).toMatch(/target database is not empty/);
  });
});
