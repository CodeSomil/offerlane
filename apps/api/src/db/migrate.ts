import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { runner } from "node-pg-migrate";
import type pg from "pg";

const dir = fileURLToPath(new URL("../../migrations", import.meta.url));

// Runs migrations against databaseUrl. down with no count rolls back every migration.
export async function migrate(databaseUrl: string, direction: "up" | "down", count = Infinity): Promise<string[]> {
  const ran = await runner({
    databaseUrl, dir, direction, count,
    migrationsTable: "pgmigrations",
    // search_path = public only: the app role may create schemas (pg-boss), and a schema named after the migrating
    // user would otherwise come first ("$user", public) and capture unqualified names in a superuser migration.
    schema: "public",
    singleTransaction: true,
    checkOrder: true,
    log: () => {},
  });
  return ran.map((m) => m.name);
}

// Readiness: the DB answers within 2 s and the newest migration file is applied (a deploy that skipped `migrate up` is not ready).
export function dbReady(pool: pg.Pool): () => Promise<boolean> {
  const newest = readdirSync(dir).filter((f) => f.endsWith(".sql")).sort().at(-1)!.replace(/\.sql$/, "");
  return async () => {
    const check = pool.query("SELECT 1 FROM pgmigrations WHERE name = $1", [newest]).then((r) => r.rowCount === 1, () => false);
    const timeout = new Promise<boolean>((res) => setTimeout(res, 2000, false).unref());
    return Promise.race([check, timeout]);
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const url = process.env.DATABASE_URL;
  const direction = process.argv[2];
  if (!url || (direction !== "up" && direction !== "down")) {
    console.error("usage: DATABASE_URL=... tsx src/db/migrate.ts up|down [count]");
    process.exit(2);
  }
  const count = process.argv[3] ? Number(process.argv[3]) : direction === "down" ? 1 : Infinity;
  console.log((await migrate(url, direction, count)).join("\n") || "nothing to run");
}
