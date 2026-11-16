#!/usr/bin/env bash
# Backup restore drill (P2.9): dump SOURCE, restore into an empty TARGET, then compare every table's row count and checksum.
# Usage: scripts/db_restore_drill.sh <source-url> <target-url>
#   TARGET must be an existing, empty database (create it first; the drill refuses one that has tables).
#   PG_TOOLS: optional prefix for pg_dump/pg_restore/psql, so they match the server's major version, e.g.
#     PG_TOOLS="docker exec -i <pgvector container>"  (URLs are then as the container sees them: localhost:5432).
#   DRILL_AFTER_RESTORE: TEST HOOK only — SQL run on TARGET after the restore (the test uses it to prove a tamper is caught).
# Exit 0 = the restore matches the source table by table. RUNBOOK.md ("DB restore") uses this before any real cut-over.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <source-url> <target-url>" >&2; exit 2; }
SRC="$1"; DST="$2"
read -r -a tools <<< "${PG_TOOLS:-}"
pgq() { "${tools[@]}" psql -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

# Every table in the app's schemas (public, plus pgboss when the worker has created it), sorted, one per line.
TABLES_SQL="SELECT format('%I.%I', schemaname, tablename) FROM pg_tables WHERE schemaname IN ('public', 'pgboss') ORDER BY 1"
# Sequences too: a restore that leaves one behind passes on rows, then the first insert after cut-over hits a duplicate key.
SEQS_SQL="SELECT format('%I.%I', schemaname, sequencename) || ' seq ' || coalesce(last_value::text, 'unused') FROM pg_sequences WHERE schemaname IN ('public', 'pgboss') ORDER BY 1"
# Row count and an order-independent checksum of each table's rows as text, then the sequences.
# Every query is checked by hand: `set -e` doesn't reach into $(...) on bash 3.2, and a query that failed the same way on
# both sides would otherwise compare equal.
fingerprint() {
  local url="$1" t tables fp
  tables="$(pgq "$url" -c "$TABLES_SQL" < /dev/null)" || exit 1
  [[ -n "$tables" ]] || { echo "error: no tables in $2" >&2; exit 1; }
  while read -r t; do
    # < /dev/null: `docker exec -i psql` would otherwise swallow the rest of the loop's input.
    fp="$(pgq "$url" -c "SELECT count(*) || ' ' || coalesce(md5(string_agg(r::text, E'\n' ORDER BY r::text)), '-') FROM $t r" < /dev/null)" || exit 1
    printf '%s %s\n' "$t" "$fp"
  done <<< "$tables"
  pgq "$url" -c "$SEQS_SQL" < /dev/null || exit 1
}

existing="$(pgq "$DST" -c "$TABLES_SQL" < /dev/null)"
[[ -z "$existing" ]] || { echo "error: target database is not empty" >&2; exit 1; }
dump="$(mktemp)"; trap 'rm -f "$dump"' EXIT
start=$SECONDS
"${tools[@]}" pg_dump --format=custom --no-owner --no-privileges "$SRC" > "$dump"
"${tools[@]}" pg_restore --no-owner --no-privileges --exit-on-error -d "$DST" < "$dump"
restored=$((SECONDS - start))
[[ -z "${DRILL_AFTER_RESTORE:-}" ]] || pgq "$DST" -c "$DRILL_AFTER_RESTORE" > /dev/null

want="$(fingerprint "$SRC" source)"; got="$(fingerprint "$DST" target)"
if [[ "$want" != "$got" ]]; then
  echo "restore drill FAILED: these tables differ (source < > restored):" >&2
  diff <(echo "$want") <(echo "$got") >&2 || true
  exit 1
fi
rows=$(awk '$2 != "seq" { s += $2 } END { print s + 0 }' <<< "$want")
echo "restore drill OK: $(grep -vc ' seq ' <<< "$want") tables, $(grep -c ' seq ' <<< "$want") sequences, $rows rows match; dump $(wc -c < "$dump" | tr -d ' ') bytes, dump + restore ${restored}s"
