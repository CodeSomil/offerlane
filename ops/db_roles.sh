#!/usr/bin/env bash
# Least privilege for the cloud DB (P2.9). Idempotent: safe to rerun, and it MUST be rerun after a restore (RUNBOOK §2),
# because pg_restore --no-owner hands every object to the restoring user.
#   - the schema owner (POSTGRES_USER, default postgres) runs migrations (the `migrate` target) and nothing else;
#   - offerlane_app (api + worker) can only read and write rows in public, and owns the pgboss schema (the worker's queue).
# compose.preview.yml mounts this into docker-entrypoint-initdb.d, so it runs once on a new volume.
# Elsewhere: APP_DB_PASSWORD=… PGHOST=… PGUSER=<owner> PGDATABASE=offerlane ops/db_roles.sh
set -euo pipefail
: "${APP_DB_PASSWORD:?set APP_DB_PASSWORD}"
owner="${POSTGRES_USER:-${PGUSER:-postgres}}"
psql -X -q -v ON_ERROR_STOP=1 -v pw="$APP_DB_PASSWORD" -v owner="$owner" -U "$owner" -d "${POSTGRES_DB:-${PGDATABASE:-offerlane}}" <<'SQL'
SELECT 'CREATE ROLE offerlane_app LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'offerlane_app')\gexec
ALTER ROLE offerlane_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pw';
-- CREATE on the database: pg-boss runs CREATE SCHEMA IF NOT EXISTS at start, which checks it even when pgboss exists.
-- SHORTCUT: lets the app role create (and own) new schemas; it still has no DDL in public. Upgrade: install pg-boss's
-- schema from the migrate step and start the worker with pg-boss `migrate: false`, then drop this CREATE.
SELECT format('GRANT CONNECT, CREATE ON DATABASE %I TO offerlane_app', current_database())\gexec
-- The owner resolves names in public only, so a schema the app role creates can't capture a migration's names (migrate.ts pins it too).
ALTER ROLE :"owner" SET search_path = public;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO offerlane_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO offerlane_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO offerlane_app;
-- Tables the owner's later migrations create get the same grants.
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO offerlane_app;
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO offerlane_app;
-- pg-boss creates and upgrades its own tables at worker start, so the app role owns that schema (and only that one).
CREATE SCHEMA IF NOT EXISTS pgboss AUTHORIZATION offerlane_app;
ALTER SCHEMA pgboss OWNER TO offerlane_app;
SELECT format('ALTER TABLE pgboss.%I OWNER TO offerlane_app', tablename) FROM pg_tables WHERE schemaname = 'pgboss'\gexec
SELECT format('ALTER SEQUENCE pgboss.%I OWNER TO offerlane_app', sequencename) FROM pg_sequences WHERE schemaname = 'pgboss'\gexec
SELECT format('ALTER FUNCTION %s OWNER TO offerlane_app', p.oid::regprocedure) FROM pg_proc p WHERE p.pronamespace = 'pgboss'::regnamespace\gexec
SELECT format('ALTER TYPE pgboss.%I OWNER TO offerlane_app', t.typname) FROM pg_type t
  WHERE t.typnamespace = 'pgboss'::regnamespace AND t.typtype IN ('e', 'd', 'c') AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid)\gexec
SQL
echo "db roles: offerlane_app ready (owner $owner)"
