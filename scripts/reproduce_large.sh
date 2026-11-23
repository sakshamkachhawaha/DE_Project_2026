#!/usr/bin/env bash
# Rebuilds the large database on 15.18 and re-runs the 30 optimized queries on it.
#
#   bash scripts/reproduce_large.sh
#
# Unpacks large_data.zip if needed, drops and recreates youtube_large, loads the
# schema and the 10 CSVs, vacuums, checks the row count, then benchmarks 3 runs
# per query. Only writes inside benchmarks/results/large/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# If this script sits outside the repo, the caller passes the repo root.
if [[ ! -d "$ROOT/sql" ]]; then
    ROOT="${1:-$PWD}"
    cd "$ROOT"
fi
[[ -d sql && -d benchmarks ]] || { echo "FATAL: run this from the DE project root (needs sql/ and benchmarks/)" >&2; exit 1; }

DB="youtube_large"
OUT="$ROOT/benchmarks/results/large"

echo "=============================================================="
echo "STEP 1/8  engine check"
echo "=============================================================="
bash "$(dirname "${BASH_SOURCE[0]}")/check_engine.sh"

echo
echo "=============================================================="
echo "STEP 2/8  locate large_data/"
echo "=============================================================="
if [[ ! -d large_data ]]; then
    ZIP=""
    for c in ./large_data.zip ../large_data.zip "$HOME/Downloads/large_data.zip"; do
        [[ -f "$c" ]] && { ZIP="$c"; break; }
    done
    [[ -n "$ZIP" ]] || { echo "FATAL: no large_data/ folder and no large_data.zip found." >&2; exit 1; }
    echo "unzipping $ZIP ..."
    unzip -q -o "$ZIP"
fi
COUNT=$(ls -1 large_data/*.csv | wc -l | tr -d ' ')
[[ "$COUNT" == "10" ]] || { echo "FATAL: expected 10 CSV files in large_data/, found $COUNT" >&2; exit 1; }
echo "found 10 CSV files in large_data/"
du -sh large_data

echo
echo "=============================================================="
echo "STEP 3/8  create a fresh database"
echo "=============================================================="
dropdb --if-exists "$DB"
createdb "$DB"
echo "created database $DB"

echo
echo "=============================================================="
echo "STEP 4/8  load schema (sql/01_schema.sql)"
echo "=============================================================="
psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -f sql/01_schema.sql

echo
echo "=============================================================="
echo "STEP 5/8  load the 12.8M rows (sql/02_load_large_data.sql)"
echo "=============================================================="
psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -f sql/02_load_large_data.sql

echo
echo "=============================================================="
echo "STEP 5b/8 apply secondary indexes (sql/05_indexes.sql)"
echo "=============================================================="
psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -f sql/05_indexes.sql

echo
echo "=============================================================="
echo "STEP 6/8  VACUUM (ANALYZE)  -- same treatment the 18.6 run had"
echo "=============================================================="
psql -d "$DB" -X -q -c "VACUUM (ANALYZE);"
echo "done"

echo
echo "=============================================================="
echo "STEP 7/8  verify row counts against the official dataset"
echo "=============================================================="
TOTAL=$(psql -d "$DB" -X -At -c "
SELECT sum(n) FROM (
  SELECT count(*) n FROM youtube.users UNION ALL SELECT count(*) FROM youtube.channels
  UNION ALL SELECT count(*) FROM youtube.videos UNION ALL SELECT count(*) FROM youtube.subscriptions
  UNION ALL SELECT count(*) FROM youtube.watch_events UNION ALL SELECT count(*) FROM youtube.video_reactions
  UNION ALL SELECT count(*) FROM youtube.comments UNION ALL SELECT count(*) FROM youtube.playlists
  UNION ALL SELECT count(*) FROM youtube.playlist_items UNION ALL SELECT count(*) FROM youtube.ad_impressions) s;")
echo "total rows loaded: $TOTAL   (official: 12828190)"
[[ "$TOTAL" == "12828190" ]] || { echo "FATAL: row count is not the official dataset. Wrong CSVs loaded." >&2; exit 1; }

mkdir -p "$OUT"
SERVERVER="$(psql -d "$DB" -X -Atc 'SHOW server_version')"
printf '{\n  "server": "%s",\n  "machine": "%s"\n}\n' "$SERVERVER" "$(uname -m)" > "$ROOT/cp4_engine.json"
{
    echo "Re-measurement recorded by reproduce_large.sh"
    echo "date                : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "psql client         : $(psql --version)"
    echo "server version      : $(psql -d "$DB" -X -Atc 'SHOW server_version')"
    echo "server version_num  : $(psql -d "$DB" -X -Atc 'SHOW server_version_num')"
    echo "machine             : $(uname -m) / $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    echo "database            : $DB"
    echo "rows loaded         : $TOTAL"
    echo "db size             : $(psql -d "$DB" -X -Atc "SELECT pg_size_pretty(pg_database_size('$DB'))")"
    echo "db size bytes       : $(psql -d "$DB" -X -Atc "SELECT pg_database_size('$DB')")"
    echo "protocol            : ./benchmarks/run_benchmark.sh $DB large 3 sql/06_optimized_queries.sql"
} | tee "$OUT/environment.txt"

echo
echo "=============================================================="
echo "STEP 8/8  benchmark the 30 optimized queries (3 runs each)"
echo "=============================================================="
echo "this overwrites benchmarks/results/large/summary.csv and R/W*.txt"
./benchmarks/run_benchmark.sh "$DB" large 3 sql/06_optimized_queries.sql

echo
echo "=============================================================="
echo "DONE"
echo "=============================================================="
echo "summary: $OUT/summary.csv   ($(($(wc -l < "$OUT/summary.csv") - 1)) queries)"
echo "next   : python3 scripts/make_growth_report.py"
