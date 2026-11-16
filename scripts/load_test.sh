#!/usr/bin/env bash
# H4 load test (P2.9): the production images via compose.preview.yml + the local dev issuer, api capped at 1 vCPU / 1 GB.
# Target: 50 req/s mixed (sync GET/PUT + job search) for 60 s, p95 < 300 ms, 0 errors.
# Usage: scripts/load_test.sh   (env: RATE, DURATION, USERS, JOBS, P95_MS override the defaults)
# The figure is a LOCAL DOCKER number (the host's CPU behind a 1-CPU cgroup), not a cloud instance, until hosting exists (H3).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${JOBS:-20000}" =~ ^[0-9]+$ ]] || { echo "JOBS must be a number" >&2; exit 2; }
export POSTGRES_PASSWORD="$(openssl rand -hex 24)" APP_DB_PASSWORD="$(openssl rand -hex 24)" OIDC_ISSUER=dev OIDC_AUDIENCE=dev API_PORT=18787 ISSUER_PORT=19000
dc() { docker compose -p offerlane-load -f compose.preview.yml -f compose.dev.yml "$@"; }
trap 'dc down -v >/dev/null 2>&1' EXIT

dc up -d --build --wait >/dev/null 2>&1 || { dc logs --tail 30; exit 1; }
# A realistic index to search: JOBS synthetic postings over 50 companies (the FTS column and indexes come from the migrations).
dc exec -T db psql -U postgres -d offerlane -qtA -v ON_ERROR_STOP=1 -v jobs="${JOBS:-20000}" > /dev/null <<'SQL'
INSERT INTO job_sources (ats, company_slug, company_name) SELECT 'greenhouse', 'co' || c, 'Company ' || c FROM generate_series(1, 50) c;
INSERT INTO jobs (source_id, external_id, url, apply_url, title, company, location, remote, description, posted_at, dedupe_hash)
SELECT s.id, n::text, 'https://boards.example/' || n, 'https://boards.example/' || n,
       (ARRAY['Senior', 'Staff', 'Junior', 'Lead'])[1 + n % 4] || ' ' || (ARRAY['Backend Engineer', 'Product Designer', 'Data Analyst', 'Product Manager', 'Swift Engineer'])[1 + n % 5],
       s.company_name, (ARRAY['Remote', 'London', 'Berlin', 'New York'])[1 + n % 4], n % 4 = 0,
       repeat('Build and ship reliable systems with a small team. ', 20), current_date - (n % 60), md5(n::text)
FROM generate_series(1, :jobs) n JOIN job_sources s ON s.company_slug = 'co' || (1 + n % 50);
ANALYZE;
SQL

cid="$(dc ps -q api)"
(cd apps/api && node --import tsx test/load/run.ts) & gen=$!
# Samples the api container every ~2 s while the generator runs (setup included), then reports the peak.
peak=0; mem=""
while kill -0 "$gen" 2>/dev/null; do
  read -r cpu mem < <(docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$cid" | tr -d '%') || break
  peak=$(awk -v a="$peak" -v b="$cpu" 'BEGIN { print (b > a ? b : a) }')
done
echo "api container: peak ${peak}% of one CPU, memory ${mem}"
wait "$gen"
