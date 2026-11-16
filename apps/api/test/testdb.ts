import { randomBytes } from "node:crypto";
import pg from "pg";

// Admin URL for a throwaway Postgres (scripts/test.sh starts docker-compose's db and sets it).
export const adminUrl = process.env.OFFERLANE_TEST_DATABASE_URL;
if (!adminUrl) {
  if (process.env.OFFERLANE_REQUIRE_DB) throw new Error("OFFERLANE_TEST_DATABASE_URL is required (OFFERLANE_REQUIRE_DB is set)");
  console.warn("\n*** SKIPPING database tests: OFFERLANE_TEST_DATABASE_URL is not set (is Docker running?) ***\n");
}

// Creates an empty database and returns its URL plus a drop function.
export async function freshDatabase(): Promise<{ url: string; drop: () => Promise<void> }> {
  const name = `offerlane_t_${randomBytes(6).toString("hex")}`;
  const admin = new pg.Client({ connectionString: adminUrl });
  await admin.connect();
  await admin.query(`CREATE DATABASE ${name}`);
  await admin.end();
  const url = new URL(adminUrl!);
  url.pathname = `/${name}`;
  return {
    url: url.toString(),
    drop: async () => {
      const c = new pg.Client({ connectionString: adminUrl });
      await c.connect();
      await c.query(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`);
      await c.end();
    },
  };
}
