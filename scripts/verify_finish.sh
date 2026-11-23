#!/usr/bin/env bash
# Last check before committing. Every line is pass or fail, nothing advisory.
#   bash scripts/verify_finish.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
[[ -d sql ]] || { echo "FATAL: run from the DE project root (needs sql/, docs/, benchmarks/)" >&2; exit 1; }

PASS=0
FAIL=0
ok()   { printf '  OK   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '  ..   %s\n' "$1"; }

DOC=docs/05_scalability_report.md

echo "== 1. engine and provenance =========================================="
if grep -qE 'Server Engine:\*\* PostgreSQL 18' "$DOC"; then
    bad "the report still says the 30-query timings came from PostgreSQL 18"
else
    ok "no 'Server Engine: PostgreSQL 18' claim"
fi
if grep -qE 'Target Database:\*\* .*PostgreSQL 18' "$DOC"; then
    bad "the report still names PostgreSQL 18 as the target database engine"
else
    ok "target database line does not name 18"
fi
if grep -q '5 runs per query' "$DOC"; then
    bad "'5 runs per query' is still in the report (baseline used 3)"
else
    ok "no '5 runs per query' claim"
fi
if grep -q 'large_data.zip' "$DOC"; then
    ok "dataset provenance is stated"
else
    bad "nothing in the report says where the large dataset came from"
fi
grep -q '12,828,190' "$DOC" && ok "official row total 12,828,190 present" || bad "row total 12,828,190 missing"

echo
echo "== 2. the run actually happened on 15.18 ============================="
if [[ -f benchmarks/results/large/environment.txt ]]; then
    ok "benchmarks/results/large/environment.txt exists"
    grep -qE 'server version +: 15\.' benchmarks/results/large/environment.txt \
        && ok "recorded server version is 15.x" || bad "environment.txt does not record server 15.x"
    grep -q '12828190' benchmarks/results/large/environment.txt \
        && ok "environment.txt records the official 12,828,190 rows" || bad "row count not recorded"
else
    bad "benchmarks/results/large/environment.txt missing — reproduce_large.sh was not run"
fi

echo
echo "== 3. raw plans ====================================================="
NPLANS=$(ls benchmarks/results/large/*.txt 2>/dev/null | grep -cE '/(R|W)[0-9]{2}\.txt$')
[[ "$NPLANS" == "30" ]] && ok "30 plan files in benchmarks/results/large/" || bad "found $NPLANS plan files, expected 30"
THIN=$(for f in benchmarks/results/large/[RW][0-9][0-9].txt; do
           [[ $(grep -c ' run [123] ===' "$f") -ge 3 ]] || echo "$f"
       done | wc -l | tr -d ' ')
[[ "$THIN" == "0" ]] && ok "every plan file holds 3 runs (a fresh 3-run measurement)" \
                     || bad "$THIN plan file(s) do not hold 3 runs — old results not overwritten"

echo
echo "== 4. every number matches the CSVs ================================="
if python3 scripts/verify_numbers.py; then
    ok "report numbers match benchmarks/results/*/summary.csv"
else
    bad "report numbers do not match the CSVs (see the list above)"
fi

echo
echo "== 5. nothing else was touched ======================================"
DIRTY=$(git status --porcelain 2>/dev/null | awk '{print $2}' | grep -E '^(sql|queries)/' || true)
[[ -z "$DIRTY" ]] && ok "sql/ and queries/ are untouched" || bad "changes outside the report: $DIRTY"
if git status --porcelain 2>/dev/null | grep -qE 'docs/0[1-4]_'; then
    bad "docs/01..04 were modified — this fix must not touch earlier checkpoints"
else
    ok "docs/01..04 untouched"
fi

echo
echo "================================================================"
if [[ "$FAIL" == "0" ]]; then
    echo "READY: $PASS checks passed. Commit and open the pull request."
    exit 0
fi
echo "NOT READY: $PASS passed, $FAIL failed. Fix the failures above and run again."
exit 1
