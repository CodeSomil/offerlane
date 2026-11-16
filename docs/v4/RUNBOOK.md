# Offerlane cloud runbook (P2.9)

For the API (`apps/api`, Dockerfile target `api`), the crawl worker (target `worker`) and their Postgres.
Written before hosting exists (H3). Steps that depend on the host say **[host]**: fill them in once it's chosen.

**First, always:** open an incident note (time, who, what you see) and keep adding to it. Never paste tokens,
ciphertext, request bodies or user ids into chat or tickets. The server holds no readable resume text (D3),
but bearer tokens and user ids are still personal data.

## Where to look
| Signal | Where |
|---|---|
| Liveness / readiness | `GET /healthz` (process up), `GET /readyz` (the DB answers in under 2 s and the newest migration is applied). Uptime checks: `ops/uptime.yml`. |
| Logs | stdout JSON (pino): method + path + status only, never query strings, IPs, headers or bodies. A 500 logs only an error code. |
| Traces | OTLP to `OTEL_EXPORTER_OTLP_ENDPOINT` (off when unset), scrubbed (no query, IP, user agent or pg values). |
| Errors | Sentry when `SENTRY_DSN` is set: 500s and pg-boss errors, with type + code + frames only. |
| Crawl | `SELECT status, count(*) FROM crawl_runs WHERE started_at > now() - interval '1 day' GROUP BY 1;` |

## 1. Outage (uptime alert, 5xx spike)
1. Which probe failed? `/healthz` down = the process or host is down. `/healthz` up but `/readyz` 503 = the DB or migrations.
2. Process down: check the logs for the crash (`OIDC discovery failed` = the issuer is unreachable or misconfigured; `… is not set` = missing env). Restart **[host]**. The api is stateless: replacing it loses nothing.
3. `/readyz` 503: can the DB be reached? If yes and a deploy just happened, the migrate step didn't run: run the `migrate` target (`docker compose -f compose.preview.yml run --rm migrate`, or the host's one-shot job). If the DB is down, see section 2.
4. A 5xx spike with no crash: Sentry gives the error code; a pg code (e.g. `53300` too many connections, `57014` statement timeout) points at the DB.
5. Bad deploy: roll back to the previous image tag **[host]**. Migrations are additive and have down-migrations, but **never run a down-migration on production data without a fresh backup**. It drops columns.
6. Afterwards: write up the cause and the fix in the incident note.

## 2. Database restore
Backups: **[host]** managed Postgres with point-in-time recovery, plus a daily `pg_dump -Fc` kept off-host. The DB holds users (issuer + sub only), encrypted sync blobs, jobs, sources, crawl runs, idempotency keys, rate buckets and the pgboss schema.
1. Stop the writers first: scale `api` and `worker` to 0, so nothing writes to a database you are about to replace.
2. Create a new, empty database **[host]**. Never restore over the live one.
3. Restore and verify in one step: `scripts/db_restore_drill.sh <source-url> <new-url>`. The source must be a database, not a file: a PITR clone **[host]**, or, for the daily dump, a scratch database you first `pg_restore` the file into. The script dumps the source, restores it, then compares every table's row count and checksum and every sequence. Anything but `restore drill OK` means **stop**.
   If the tools don't match the server's major version, set `PG_TOOLS="docker exec -i <pgvector:pg17 container>"`.
4. Rerun `ops/db_roles.sh` on the new database. The restore hands every object to the restoring user, so without this the app role can't read the tables or the pgboss queue. Then point `DATABASE_URL` at it, start `migrate` (a no-op if the schema is current), then api, then worker, and check that `/readyz` returns 200.
5. Data written after the backup is lost. Sync clients hold their own copy: a client whose version is ahead gets a 409 and pushes again. Say so in the user notice if there is one.
6. Drill: the restore test runs in `scripts/test.sh cloud`. Run the script by hand against a production clone every quarter and record the time it took.

## 3. Key or secret leak
| What leaked | Do now | Then |
|---|---|---|
| DB passwords (`APP_DB_PASSWORD` for api + worker, `POSTGRES_PASSWORD` for the owner, used only by `migrate`) | Rotate the leaked one: rerun `ops/db_roles.sh` with the new `APP_DB_PASSWORD` (it resets the password); the new password reaches the server as SQL text, so make sure `log_statement` is not `ddl`/`all` while you do it, or `ALTER ROLE` the owner **[host]**. Update the secret, restart api + worker. | Check the DB logs for unknown clients. The ciphertext is unreadable without the users' keys (D3), but the user and job tables are readable. |
| `SENTRY_DSN` | Rotate the DSN's client key in Sentry and redeploy. | A leaked DSN only lets someone send fake events. Filter the noise out. |
| OTLP endpoint credentials | Rotate them at the collector and redeploy. | |
| OIDC signing key (provider side) | The provider rotates it. The API fetches the JWKS itself (jose: an unknown key id triggers a refetch, and the cache lasts at most 10 min), so a new key works without a redeploy. A removed key is dropped within 10 min; restart the api to drop it at once. | Tokens live until `exp`, so keep the provider's access-token lifetime short. |
| A user's bearer token | Revoke the session at the provider. | **Gap:** the server has no per-user block, so the token works until `exp`. |
| A user's sync key / recovery key | Nothing to do server side: the server never had them. The user rotates them in the app (SYNC_CRYPTO.md). | |
| `OIDC_ALLOW_LOCAL_HTTP=1` seen on a deploy | Remove it and redeploy at once: it lets the API trust an http issuer on localhost. Only `compose.dev.yml` may set it. | Check which tokens were accepted while it was set. |
| Anything in git | Rotate first, then remove it. Never rewrite shared history; the secret scan in `scripts/test.sh` should have caught it, so find out why it didn't. | |

## 4. Abuse and rate limits
- Each user has token buckets in `rate_buckets`: sync 60 burst at 1/s, jobs and api 120 at 2/s. An empty bucket gets 429 + `Retry-After`. Tune them in `DEFAULT_RULES` (`src/ratelimit.ts`) and redeploy.
- **Unauthenticated traffic is not limited by the app.** The edge (load balancer / CDN / WAF **[host]**) must limit by IP, at minimum on `/v1/*` (401 floods) and on the probes.
- One abusive account: disable it at the OIDC provider. **Gap:** there is no server-side block list. Until there is, a disabled account keeps working until its token's `exp`. Look up who it is with `SELECT oidc_issuer, oidc_sub FROM users WHERE id = '<id>'`; only the provider maps that to a person.
- A flood of `Idempotency-Key` rows: the worker's 15-minute tick prunes keys older than 24 h. To check the size: `SELECT count(*) FROM idempotency_keys;`.

## 5. Crawl ban or a complaint from a job board
1. Stop that source at once: `UPDATE job_sources SET enabled = false WHERE ats = '<ats>' AND company_slug = '<slug>';` (or `WHERE ats = '<ats>'` for a whole ATS). The next tick skips it, and a running tick finishes only the source it is on.
2. A whole ATS for good: remove it from `CRAWL_ENABLED` in `src/ats.ts` and deploy. The crawl refuses it and logs a `refused` crawl run. Workable and Workday are already off (terms unclear, P0 note 5).
3. The jobs already stored stay until a human decides. If the complaint requires it, remove them: `DELETE FROM jobs WHERE source_id IN (SELECT id FROM job_sources WHERE ats = '<ats>' AND company_slug = '<slug>');`, and record the decision.
4. Politeness is built in (`ats.ts`: 0.35 s per host, honours 429 Retry-After, ETag/If-Modified-Since, a 6 h interval). A ban despite that means a human has to check that board's terms (docs/SOURCES.md) before re-enabling it.
5. Never route around a ban (new IPs, user-agent changes). That breaks the job-source terms decision (P0.5).
