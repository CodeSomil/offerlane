# P2 Cloud plan (approved by the human 2026-11-12: H1–H6 as proposed)

Scope comes from OFFERLANE_V4.md P2 and D2/D3. The server never holds readable resume or profile text.

## Decisions needed before code (human)
H1. Folder layout. macOS ignores case, so `packages/` would be the Swift `Packages/` folder (P0 note 7).
    Proposal: pnpm workspace at the repo root with `apps/api`, `apps/worker` and `libs/{contract,shared}`. `Packages/design-tokens` stays put. P3 adds `libs/core`.
H2. Auth provider (hosted OIDC: Google, Apple, email link). The code checks standard OIDC JWTs (issuer + JWKS), so any provider works. Pick one: Auth0, Clerk, WorkOS, Supabase Auth, Cognito. Until then, tests use a local fake issuer.
H3. Hosting, domain, budget, Sentry account (HUMAN BLOCKERS). Until these exist: local Docker only, Sentry off (no DSN), preview environments and the uptime check are written but not deployed.
H4. Load-test target. Proposal: 1 small instance (1 vCPU / 1 GB) holds 50 req/s mixed (sync GET/PUT + job search), p95 < 300 ms, 0 errors.
H5. Server-side matching vs D3. A profile embedding sent to the server leaks profile content. Proposal: the server pre-filters only on fields the client sends (title words, location, remote, posted-since) plus Postgres full-text search. pgvector is used job-to-job (dedupe, "similar roles"), never on profile text. The client still ranks locally.
H6. Dependencies (Protocol 7). All are MIT/Apache/BSD/ISC; the sizes are install sizes, roughly.
| name | license | why | ~size | alternative |
|---|---|---|---|---|
| fastify | MIT | HTTP server, schema hooks | 2 MB | node:http (more code) |
| zod + @asteasolutions/zod-to-openapi | MIT | one schema → validation + OpenAPI | 3 MB | hand-written OpenAPI |
| pg | MIT | Postgres driver | 1 MB | postgres.js |
| node-pg-migrate | MIT | SQL migrations with down/rollback | 1 MB | hand-rolled runner |
| pg-boss | MIT | Postgres-backed queue + cron (D2) | 1 MB | graphile-worker |
| jose | MIT | OIDC JWT/JWKS verify | 0.3 MB | none sensible |
| pino | MIT | structured logs with redaction | 1 MB | console JSON |
| @opentelemetry/sdk-node + auto-instr. (http, pg) | Apache-2 | traces/metrics | 15 MB | skip OTel |
| @sentry/node | MIT | errors (off until DSN) | 6 MB | OTel errors only |
| vitest, typescript, tsx | MIT/Apache | tests, build, dev run | 40 MB dev | node:test |
| openapi-typescript + openapi-fetch | MIT | typed TS client | 1 MB | hand-written client |
| swift-openapi-generator + runtime + urlsession transport (Apple) | Apache-2 | typed Swift client (build plugin) | 5 MB src | hand-written Swift client |
| autocannon (dev) | MIT | load test from npm | 2 MB | k6 binary |
| Docker image pgvector/pgvector:pg17 | PostgreSQL | local DB + pgvector | 450 MB | Homebrew postgres |

## Tasks (one commit each, `v4 P2.<t>`; about 3 to 4 sessions)
P2.1 Workspace: pnpm via corepack, TS strict, `docker-compose.yml` (Postgres + pgvector), `scripts/test.sh cloud` (typecheck, vitest, secret scan over apps/libs), CI job. Tests: health endpoint.
P2.2 Schema + migrations (with down): users, devices, sync_blobs, jobs, job_sources, crawl_runs, idempotency_keys, rate_buckets. Test: up → down → up on an empty DB.
P2.3 Auth: OIDC JWT verify (issuer, audience, exp, JWKS cache), user upsert by `sub`; no passwords anywhere. Tests: fake issuer, a wrong audience or expired token gets 401, alg=none is refused.
P2.4 Encrypted sync: `PUT/GET /v1/sync/{kind}` takes an opaque ciphertext + version + key id; If-Match version gives 409 on conflict; size cap. Client crypto spec (`docs/v4/SYNC_CRYPTO.md`): AES-256-GCM (CryptoKit / WebCrypto) with a per-account key kept in Keychain plus a printed recovery key. The server can't recover it (that's the design).
     Gate test "server cannot read resume text": push a blob holding a canary resume, then grep a pg_dump, the logs and the traces for it. Zero hits.
P2.5 Job index adapters: port the six ATS adapters (greenhouse, lever, ashby, workable, smartrecruiters, workday) to TS. The same JSON fixtures as the Swift tests must give the same `Posting` fields (shared fixtures dir).
     Workable/Workday terms are still unclear (P0 note 5), so they ship disabled in the crawl until the human decides.
P2.6 Crawl + dedupe + search: a pg-boss cron per source (polite rate, ETag/If-Modified-Since), dedupe on (ats, company, external_id), then a normalized title+company+location hash; job embeddings → pgvector for near-duplicates. `GET /v1/jobs` with structured filters + full-text, cursor pagination.
P2.7 Platform hardening: `Idempotency-Key` on every POST/PUT (stored response, 24 h), per-user token-bucket limits (429 + Retry-After), pino with redaction (auth headers, bodies of sync routes never logged), OTel (no body attributes), Sentry behind a DSN env var (`beforeSend` strips bodies).
P2.8 Contract + clients: the OpenAPI document is generated from zod into `libs/contract/openapi.json` and committed; a drift check runs in the gate. Contract tests validate every real response against the spec. The generated TS client goes in libs/contract; the generated Swift client goes in a new `Packages/OfferlaneAPI`, with no app UI wiring this phase.
P2.9 Ops: production Dockerfiles (non-root, distroless or slim), a preview-env compose file, a `/healthz` + `/readyz` uptime definition, `scripts/db_restore_drill.sh` (dump → fresh DB → restore → row counts + checksums), `docs/v4/RUNBOOK.md` (outage, DB restore, key leak, abuse/rate limit, crawl ban), and the load test against the H4 target.

## Gates (from P2)
1. Contract tests pass, and the spec drift check is clean.  2. Load test meets the agreed H4 target (local Docker figure, labelled as such until hosting exists).
3. The restore drill passes.  4. The privacy test proves the server can't read resume text.  5. The runbook is written.
6. Existing gates stay green: `scripts/test.sh` (full), privacy gate, secret scan, contrast.  7. A fresh-subagent review has no open High/Medium.

## Risks
- Recovery-key UX: if the user loses both the Keychain and the recovery key, their synced data is gone. That's intended under D3, and the UI must say it plainly (P3/Mac wiring).
- Crawl terms and IP bans: per-source rate limits and an on/off switch per source in config.
- No remote yet, so CI for P2 can't be seen green (same as P0).
- Docker Desktop must be running for the cloud tests. If it isn't, the gate skips them loudly instead of passing quietly.
