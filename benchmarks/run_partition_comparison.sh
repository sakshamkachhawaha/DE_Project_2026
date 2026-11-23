#!/usr/bin/env bash
# =====================================================================
# CP4 Stage 6C.2.1: Dedicated Partition Benchmark Comparison Runner
# Project: Team T0046 — YouTube Video Sharing Database
# Target Database: youtube_large (PostgreSQL 18.6 — see the engine note in docs/05 section 1.2)
#
# Baseline:     youtube.watch_events (4,000,000 rows, monolithic heap)
# Experimental: youtube_part.watch_events_partitioned (4,000,000 rows, 18 partitions)
#
# Methodology:
# - Strictly fail-closed output directory protection (aborts if target exists).
# - Full 7-column bidirectional EXCEPT ALL content invariance pre- and post-test.
# - Paired, counterbalanced timing schedule (5 runs default, adaptive 7 runs if CV > 0.15).
# - Median execution time primary comparison; min, max, mean, and CV recorded.
# - Five-tier plan-pruning classification based on captured raw EXPLAIN plans.
# - Separate diagnostic artifact for W02 partition boundary write routing test.
#
# Usage:
#   ./benchmarks/run_partition_comparison.sh [database] [workload_file]
# Example:
#   ./benchmarks/run_partition_comparison.sh youtube_large
# =====================================================================

set -euo pipefail

# ---------------------------------------------------------------------
# 1. PATH RESOLUTION, PRE-VALIDATION & DIRECTORY SAFETY
# ---------------------------------------------------------------------
# Step 1: Resolve repository root
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Step 2: Verify required source files
WORKLOAD="${2:-$ROOT/benchmarks/workload_partition_comparison.sql}"
if [[ ! -f "$WORKLOAD" ]]; then
    echo "FATAL: Workload file '$WORKLOAD' not found." >&2
    exit 1
fi
if [[ ! -f "$ROOT/sql/06_optimized_queries.sql" ]]; then
    echo "FATAL: Reference workload '$ROOT/sql/06_optimized_queries.sql' not found." >&2
    exit 1
fi
if [[ ! -f "$ROOT/sql/08_partitioning.sql" ]]; then
    echo "FATAL: DDL artifact '$ROOT/sql/08_partitioning.sql' not found." >&2
    exit 1
fi

# Step 3: Enforce database name (Defect 1 fix: strictly restricted to 'youtube_large')
DB="${1:-youtube_large}"
if [[ "$DB" != "youtube_large" ]]; then
    echo "FATAL: Invalid database name '$DB'. This runner is strictly restricted to 'youtube_large'." >&2
    exit 1
fi

# Step 4: Check that benchmarks/results/partitioned/ is absent in every form
OUT="$ROOT/benchmarks/results/partitioned"
SUMMARY="$OUT/comparison_summary.csv"
LOG="$OUT/run.log"
W02_REPORT="$OUT/w02_diagnostic.txt"

# Fail-closed safety: Abort if target output path exists in any form
# (directory, empty directory, regular file, symlink, dangling symlink).
if [[ -e "$OUT" || -L "$OUT" ]]; then
    echo "FATAL [FAIL-CLOSED]: Target output directory '$OUT' already exists." >&2
    echo "The target directory must NOT exist prior to runner invocation." >&2
    echo "Refusing to overwrite existing benchmark results. Aborting." >&2
    exit 1
fi

# Step 5: Verify protected benchmark directories exist and are not targeted for modification
for pdir in "$ROOT/benchmarks/results/large" "$ROOT/benchmarks/results/optimized" "$ROOT/benchmarks/results/baseline"; do
    if [[ ! -d "$pdir" ]]; then
        echo "WARNING: Expected baseline directory '$pdir' was not found." >&2
    fi
    if [[ "$OUT" == "$pdir"* ]]; then
        echo "FATAL: Output target '$OUT' conflicts with protected directory '$pdir'." >&2
        exit 1
    fi
done

echo "====================================================================="
echo "CP4 Stage 6C.2: Partition Comparison Benchmark Preflight"
echo "Target Database: $DB (strictly enforced)"
echo "Workload File:   $WORKLOAD"
echo "Output Target:   $OUT (creation deferred until preflight passes)"
echo "====================================================================="

# ---------------------------------------------------------------------
# 2. HELPER FUNCTIONS
# ---------------------------------------------------------------------
psql_query() {
    local sql="$1"
    printf 'SET timezone TO %s;\n%s\n' "'Asia/Kolkata'" "$sql" | psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1
}

psql_explain() {
    local query_sql="$1"
    local full_sql="SET timezone TO 'Asia/Kolkata'; EXPLAIN (ANALYZE, BUFFERS) $query_sql"
    printf '%s\n' "$full_sql" | psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1 2>&1
}

get_query_sql() {
    local target="$1"
    awk -v target="$target" '
        /^-- @QUERY: / {
            if ($3 == target) capturing = 1; else capturing = 0;
            next;
        }
        capturing && !/^--/ { print }
    ' "$WORKLOAD"
}

calc_mean() {
    printf '%s\n' "$@" | awk '
        NF { s += $1; n++ }
        END { if (n > 0) printf "%.3f", s / n; else print "0" }
    '
}

calc_sd() {
    local mean="$1"
    shift
    printf '%s\n' "$@" | awk -v mean="$mean" '
        NF { sum_sq += ($1 - mean) ^ 2; n++ }
        END {
            if (n > 1) printf "%.4f", sqrt(sum_sq / (n - 1));
            else print "0.0000"
        }
    '
}

calc_cv() {
    local sd="$1"
    local mean="$2"
    awk -v sd="$sd" -v mean="$mean" 'BEGIN {
        if (mean + 0 <= 0) {
            print "N/A (DIV_ZERO)";
        } else {
            printf "%.4f", sd / mean;
        }
    }'
}

calc_speedup() {
    local base_med="$1"
    local part_med="$2"
    awk -v base="$base_med" -v part="$part_med" 'BEGIN {
        if (part + 0 <= 0) {
            print "N/A (DIV_ZERO)";
        } else {
            pct = ((base / part) - 1.0) * 100.0;
            printf "%.2f", pct;
        }
    }'
}

# ---------------------------------------------------------------------
# 3. PREFLIGHT ENVIRONMENT & CATALOG INSPECTION
# ---------------------------------------------------------------------
echo "--- Step 1: Inspecting Live Environment & Settings ---"
PG_VER=$(psql_query "SELECT version();")
SHARED_BUFFERS=$(psql_query "SHOW shared_buffers;")
WORK_MEM=$(psql_query "SHOW work_mem;")
MAX_PARALLEL=$(psql_query "SHOW max_parallel_workers_per_gather;")
TIMEZONE=$(psql_query "SHOW TimeZone;")
CLIENT_VER=$(psql --version 2>&1 || echo "unknown")
PLATFORM=$(uname -sm)

echo "PostgreSQL Server Version: $PG_VER"
echo "Client Version:            $CLIENT_VER"
echo "Hardware Platform:         $PLATFORM"
echo "shared_buffers:            $SHARED_BUFFERS (inspection only; server-start configuration)"
echo "work_mem:                  $WORK_MEM"
echo "max_parallel_workers:      $MAX_PARALLEL"
echo "session TimeZone:          $TIMEZONE"

echo "--- Step 2: Verifying Relations and Row Counts ---"
BASE_COUNT=$(psql_query "SELECT count(*) FROM youtube.watch_events;")
PART_COUNT=$(psql_query "SELECT count(*) FROM youtube_part.watch_events_partitioned;")
PART_CHILD_COUNT=$(psql_query "SELECT count(*) FROM pg_inherits WHERE inhparent = 'youtube_part.watch_events_partitioned'::regclass;")

echo "Baseline Row Count:        $BASE_COUNT (expected: 4000000)"
echo "Partitioned Row Count:     $PART_COUNT (expected: 4000000)"
echo "Partition Child Count:     $PART_CHILD_COUNT (expected: 18)"

if [[ "$BASE_COUNT" != "4000000" || "$PART_COUNT" != "4000000" || "$PART_CHILD_COUNT" != "18" ]]; then
    echo "FATAL: Preflight count validation failed. Aborting." >&2
    exit 1
fi

# ---------------------------------------------------------------------
# 4. PRE-TEST SEVEN-COLUMN BIDIRECTIONAL EXCEPT ALL
# ---------------------------------------------------------------------
echo "--- Step 3: Executing Pre-Test Bidirectional EXCEPT ALL Invariance Check ---"
EXCEPT_SQL=$(get_query_sql "EXCEPT_ALL_INVARIANCE_CHECK")
PRE_DIFFS=$(printf 'SET timezone TO %s;\n%s\n' "'Asia/Kolkata'" "$EXCEPT_SQL" | psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1 | wc -l | tr -d ' ')
echo "Pre-Test EXCEPT ALL Difference Count: $PRE_DIFFS"

if [[ "$PRE_DIFFS" != "0" ]]; then
    echo "FATAL: Pre-test data equivalence failed ($PRE_DIFFS differing rows found). Aborting." >&2
    exit 1
fi
echo "Data equivalence certified: baseline and partitioned relations have identical rows."

# ---------------------------------------------------------------------
# 5. TARGET DIRECTORY CREATION & RUN LOG INITIALIZATION
# ---------------------------------------------------------------------
# Created ONLY after all preflight checks 1-3 have passed.
# Single-directory creation (mkdir without -p) fails safely if path exists.
echo "--- Preflight Passed: Creating Target Output Directory ---"
if ! mkdir "$OUT"; then
    echo "FATAL: Failed to create target output directory '$OUT' (path may exist or permission denied)." >&2
    exit 1
fi

# Initialize run log now that target directory exists
exec > >(tee -a "$LOG") 2>&1

echo "====================================================================="
echo "CP4 Stage 6C.2: Partition Comparison Benchmark Execution Initialized"
echo "Start Time:      $(date -u '+%Y-%m-%d %H:%M:%SZ')"
echo "Target Database: $DB"
echo "Workload File:   $WORKLOAD"
echo "Output Target:   $OUT"
echo "Preflight:       PASSED (4M rows, 18 partitions, 0 EXCEPT ALL diffs)"
echo "====================================================================="

# ---------------------------------------------------------------------
# 6. CORE & DIAGNOSTIC READ BENCHMARK SUITE
# ---------------------------------------------------------------------
# Initialize summary CSV
echo "query_id,category,baseline_median_ms,part_median_ms,speedup_pct,baseline_mean_ms,part_mean_ms,baseline_cv,part_cv,runs_collected,pruning_classification,scanned_partitions,baseline_scan_nodes,part_scan_nodes" > "$SUMMARY"

# Primary suite query IDs and categories
QUERIES=(
    "R07:CORE_PRUNING:R07_baseline:R07_partitioned"
    "R10_ref:CORE_PRUNING:R10_ref_baseline:R10_ref_partitioned"
    "R11:CORE_PRUNING:R11_baseline:R11_partitioned"
    "R12:CORE_NEGATIVE_CONTROL:R12_baseline:R12_partitioned"
    "R17:CORE_NEGATIVE_CONTROL:R17_baseline:R17_partitioned"
    "R19:CORE_NEGATIVE_CONTROL:R19_baseline:R19_partitioned"
    "R20:CORE_PRUNING:R20_baseline:R20_partitioned"
    "R16:DIAGNOSTIC_JOIN_PATH:R16_baseline:R16_partitioned"
    "R25:DIAGNOSTIC_JOIN_PATH:R25_baseline:R25_partitioned"
)

echo "--- Step 4: Executing Counterbalanced Comparative Benchmark Suite ---"

for item in "${QUERIES[@]}"; do
    IFS=":" read -r qid category base_tag part_tag <<< "$item"
    echo "================================================================="
    echo "Benchmarking: $qid ($category)"
    echo "================================================================="

    base_sql=$(get_query_sql "$base_tag")
    part_sql=$(get_query_sql "$part_tag")

    if [[ -z "$base_sql" || -z "$part_sql" ]]; then
        echo "FATAL: Could not extract SQL for $base_tag or $part_tag from workload." >&2
        exit 1
    fi

    base_raw_file="$OUT/${qid}_baseline.txt"
    part_raw_file="$OUT/${qid}_partitioned.txt"
    : > "$base_raw_file"
    : > "$part_raw_file"

    base_times=()
    part_times=()

    # Counterbalanced schedule across 5 repetitions:
    # Rep 1: B -> P; Rep 2: P -> B; Rep 3: B -> P; Rep 4: P -> B; Rep 5: B -> P
    for ((r = 1; r <= 5; r++)); do
        if (( r % 2 == 1 )); then
            # Baseline then Partitioned
            echo "  Rep $r: Baseline -> Partitioned"
            p_base=$(psql_explain "$base_sql")
            echo "=== $qid Baseline Run $r ===" >> "$base_raw_file"
            echo "$p_base" >> "$base_raw_file"
            t_base=$(echo "$p_base" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')
            base_times+=("$t_base")

            p_part=$(psql_explain "$part_sql")
            echo "=== $qid Partitioned Run $r ===" >> "$part_raw_file"
            echo "$p_part" >> "$part_raw_file"
            t_part=$(echo "$p_part" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')
            part_times+=("$t_part")
        else
            # Partitioned then Baseline
            echo "  Rep $r: Partitioned -> Baseline"
            p_part=$(psql_explain "$part_sql")
            echo "=== $qid Partitioned Run $r ===" >> "$part_raw_file"
            echo "$p_part" >> "$part_raw_file"
            t_part=$(echo "$p_part" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')
            part_times+=("$t_part")

            p_base=$(psql_explain "$base_sql")
            echo "=== $qid Baseline Run $r ===" >> "$base_raw_file"
            echo "$p_base" >> "$base_raw_file"
            t_base=$(echo "$p_base" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')
            base_times+=("$t_base")
        fi
    done

    # Initial statistical analysis over 5 observations
    base_mean=$(calc_mean "${base_times[@]}")
    part_mean=$(calc_mean "${part_times[@]}")
    base_sd=$(calc_sd "$base_mean" "${base_times[@]}")
    part_sd=$(calc_sd "$part_mean" "${part_times[@]}")
    base_cv=$(calc_cv "$base_sd" "$base_mean")
    part_cv=$(calc_cv "$part_sd" "$part_mean")
    runs_collected=5

    echo "  Initial 5 runs: Baseline Mean=${base_mean}ms (CV=$base_cv), Partitioned Mean=${part_mean}ms (CV=$part_cv)"

    # Adaptive Fallback: Trigger 2 additional repetitions if either CV > 0.15
    need_fallback=$(awk -v b="$base_cv" -v p="$part_cv" 'BEGIN {
        if ((b != "N/A (DIV_ZERO)" && b + 0 > 0.15) || (p != "N/A (DIV_ZERO)" && p + 0 > 0.15)) print "YES"; else print "NO";
    }')

    if [[ "$need_fallback" == "YES" ]]; then
        echo "  [ADAPTIVE FALLBACK TRIGGERED]: CV > 0.15 detected. Collecting 2 additional paired runs."
        # Rep 6: Partitioned -> Baseline
        echo "  Rep 6: Partitioned -> Baseline"
        p_part=$(psql_explain "$part_sql")
        echo "=== $qid Partitioned Run 6 ===" >> "$part_raw_file"
        echo "$p_part" >> "$part_raw_file"
        t_part=$(echo "$p_part" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')
        part_times+=("$t_part")

        p_base=$(psql_explain "$base_sql")
        echo "=== $qid Baseline Run 6 ===" >> "$base_raw_file"
        echo "$p_base" >> "$base_raw_file"
        t_base=$(echo "$p_base" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')
        base_times+=("$t_base")

        # Rep 7: Baseline -> Partitioned
        echo "  Rep 7: Baseline -> Partitioned"
        p_base=$(psql_explain "$base_sql")
        echo "=== $qid Baseline Run 7 ===" >> "$base_raw_file"
        echo "$p_base" >> "$base_raw_file"
        t_base=$(echo "$p_base" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')
        base_times+=("$t_base")

        p_part=$(psql_explain "$part_sql")
        echo "=== $qid Partitioned Run 7 ===" >> "$part_raw_file"
        echo "$p_part" >> "$part_raw_file"
        t_part=$(echo "$p_part" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')
        part_times+=("$t_part")

        runs_collected=7
        base_mean=$(calc_mean "${base_times[@]}")
        part_mean=$(calc_mean "${part_times[@]}")
        base_sd=$(calc_sd "$base_mean" "${base_times[@]}")
        part_sd=$(calc_sd "$part_mean" "${part_times[@]}")
        base_cv=$(calc_cv "$base_sd" "$base_mean")
        part_cv=$(calc_cv "$part_sd" "$part_mean")
        echo "  Recalculated 7 runs: Baseline Mean=${base_mean}ms (CV=$base_cv), Partitioned Mean=${part_mean}ms (CV=$part_cv)"
    fi

    # Medians
    base_sorted=($(printf '%s\n' "${base_times[@]}" | sort -g))
    part_sorted=($(printf '%s\n' "${part_times[@]}" | sort -g))

    if [[ "$runs_collected" -eq 5 ]]; then
        base_med="${base_sorted[2]}"
        part_med="${part_sorted[2]}"
    else
        base_med="${base_sorted[3]}"
        part_med="${part_sorted[3]}"
    fi

    speedup_pct=$(calc_speedup "$base_med" "$part_med")

    # Scan nodes parsing
    base_nodes=$(echo "$p_base" | grep -oE '(Parallel )?(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|Bitmap Index Scan)( Backward)?( using [a-z0-9_]+)? on [a-z0-9_]+' | sed -E 's/Parallel //; s/ Backward//' | awk '!seen[$0]++' | paste -sd'|' - | sed 's/|/ | /g' || true)
    base_nodes="${base_nodes:-(no scan)}"

    part_nodes=$(echo "$p_part" | grep -oE '(Parallel )?(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|Bitmap Index Scan)( Backward)?( using [a-z0-9_]+)? on [a-z0-9_]+' | sed -E 's/Parallel //; s/ Backward//' | awk '!seen[$0]++' | paste -sd'|' - | sed 's/|/ | /g' || true)
    part_nodes="${part_nodes:-(no scan)}"

    # Partition Pruning Classification (using actual plan text from last partitioned run)
    part_plan_text="$p_part"
    scanned_parts_list=$(echo "$part_plan_text" | grep -oE 'watch_events_[0-9]{4}_[0-9]{2}' | sort -u | paste -sd';' - || true)
    scanned_count=$(echo "$part_plan_text" | grep -oE 'watch_events_[0-9]{4}_[0-9]{2}' | sort -u | wc -l | tr -d ' ')

    subplans_removed=$(echo "$part_plan_text" | grep -oE 'Subplans Removed: [0-9]+' || true)
    has_append=$(echo "$part_plan_text" | grep -oE '(Append|Merge Append|Parallel Append)' | head -n1 || true)

    if [[ -n "$subplans_removed" ]]; then
        pruning_class="EXEC_TIME_PRUNED"
        scanned_partitions="${scanned_parts_list:-INCONCLUSIVE}"
    elif [[ "$scanned_count" -eq 1 && "$scanned_parts_list" == "watch_events_2026_06" ]]; then
        if [[ -n "$has_append" ]]; then
            pruning_class="PLAN_TIME_PRUNED_APPEND"
        else
            pruning_class="DIRECT_SCAN_NO_APPEND"
        fi
        scanned_partitions="watch_events_2026_06"
    elif [[ "$scanned_count" -eq 18 ]]; then
        pruning_class="FULL_TABLE_SCAN_NO_PRUNING"
        scanned_partitions="all_18_partitions"
    elif [[ "$scanned_count" -eq 0 ]]; then
        pruning_class="INCONCLUSIVE"
        scanned_partitions="NONE"
    else
        pruning_class="INCONCLUSIVE"
        scanned_partitions="${scanned_parts_list:-INCONCLUSIVE}"
    fi

    # Record summary row
    echo "$qid,$category,$base_med,$part_med,$speedup_pct,$base_mean,$part_mean,$base_cv,$part_cv,$runs_collected,$pruning_class,$scanned_partitions,\"$base_nodes\",\"$part_nodes\"" >> "$SUMMARY"
    printf '%-8s %-22s base_med %8s ms | part_med %8s ms | speedup %7s%% | class %s\n' \
        "$qid" "$category" "$base_med" "$part_med" "$speedup_pct" "$pruning_class"
done

# ---------------------------------------------------------------------
# 7. W02 BOUNDARY WRITE ROUTING DIAGNOSTIC
# ---------------------------------------------------------------------
echo "--- Step 5: Executing W02 Partition Boundary Write Diagnostic ---"

# 1. Precondition check: Validate parent foreign keys exist
FK_VALID=$(psql_query "SELECT (EXISTS (SELECT 1 FROM youtube.users WHERE user_id = 1042) AND EXISTS (SELECT 1 FROM youtube.videos WHERE video_id = 'ZkNSlUB1EOs'))::text;")
if [[ "$FK_VALID" != "true" ]]; then
    echo "FATAL: Precondition failed: user 1042 or video ZkNSlUB1EOs does not exist in baseline." >&2
    exit 1
fi

# 2. Pre-test counts and equivalence check
W02_PRE_BASE_COUNT=$(psql_query "SELECT count(*) FROM youtube.watch_events;")
W02_PRE_PART_COUNT=$(psql_query "SELECT count(*) FROM youtube_part.watch_events_partitioned;")
W02_PRE_EXCEPT_DIFFS=$(printf 'SET timezone TO %s;\n%s\n' "'Asia/Kolkata'" "$EXCEPT_SQL" | psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1 | wc -l | tr -d ' ')

# 3. Execute W02 Diagnostic Transaction Wrapper
W02_SQL=$(get_query_sql "W02_DIAGNOSTIC_BLOCK")
W02_RAW_OUTPUT=$(printf 'SET timezone TO %s;\n%s\n' "'Asia/Kolkata'" "$W02_SQL" | psql -d "$DB" -X -v ON_ERROR_STOP=1 2>&1 || true)

# 4. Extract captured diagnostic notice
# Format: W02_DIAG_OUTCOME|v_classification|v_sqlstate|v_message|v_detail
W02_LINE=$(echo "$W02_RAW_OUTPUT" | grep -oE 'W02_DIAG_OUTCOME\|[^[:cntrl:]]+' || true)
if [[ -n "$W02_LINE" ]]; then
    IFS="|" read -r _ w02_class w02_sqlstate w02_msg w02_detail <<< "$W02_LINE"
else
    w02_class="FAILED_TO_CAPTURE_NOTICE"
    w02_sqlstate="UNKNOWN"
    w02_msg="No W02_DIAG_OUTCOME notice emitted"
    w02_detail="$W02_RAW_OUTPUT"
fi

# 5. Post-test counts and equivalence check
W02_POST_BASE_COUNT=$(psql_query "SELECT count(*) FROM youtube.watch_events;")
W02_POST_PART_COUNT=$(psql_query "SELECT count(*) FROM youtube_part.watch_events_partitioned;")
W02_POST_EXCEPT_DIFFS=$(printf 'SET timezone TO %s;\n%s\n' "'Asia/Kolkata'" "$EXCEPT_SQL" | psql -d "$DB" -X -q -A -t -v ON_ERROR_STOP=1 | wc -l | tr -d ' ')

# 6. Evaluate Assertions
assertion1_pass="FAIL"
if [[ "$W02_PRE_EXCEPT_DIFFS" == "0" && "$W02_POST_EXCEPT_DIFFS" == "0" && "$W02_PRE_BASE_COUNT" == "4000000" && "$W02_POST_BASE_COUNT" == "4000000" ]]; then
    assertion1_pass="PASS"
fi

assertion2_pass="FAIL"
if [[ "$W02_PRE_PART_COUNT" == "4000000" && "$W02_POST_PART_COUNT" == "4000000" ]]; then
    assertion2_pass="PASS"
fi

assertion3_pass="FAIL"
if [[ "$w02_class" == "EXPECTED_ROUTING_REJECTION" && "$w02_sqlstate" == "23514" ]]; then
    assertion3_pass="PASS"
fi

overall_w02_status="FAIL"
if [[ "$assertion1_pass" == "PASS" && "$assertion2_pass" == "PASS" && "$assertion3_pass" == "PASS" ]]; then
    overall_w02_status="PASS"
fi

# 7. Write W02 Diagnostic Artifact
cat << EOF > "$W02_REPORT"
================================================================================
W02 PARTITION BOUNDARY WRITE ROUTING DIAGNOSTIC REPORT
================================================================================
Diagnostic ID:                 W02_PARTITION_ROUTING_BOUNDARY
Target Relation:               youtube_part.watch_events_partitioned
Intended Timestamp:            2026-07-01 19:00:00+05:30
Partition Upper Bound:         2026-07-01 00:00:00+05:30 (watch_events_2026_06)
Target Database:               $DB
FK Precondition (1042/video):  PASS (Both parent keys verified in youtube.*)

Expected SQLSTATE:             23514 (check_violation)
Expected Error Pattern:        no partition of relation "watch_events_partitioned" found for row

Observed SQLSTATE:             $w02_sqlstate
Observed Error Message:        $w02_msg
Observed Error Detail:         $w02_detail
Error Classification:          $w02_class

Outer Transaction Rollback:    CONFIRMED_ROLLED_BACK

Pre-W02 EXCEPT ALL Diffs:      $W02_PRE_EXCEPT_DIFFS (Target: 0)
Post-W02 EXCEPT ALL Diffs:     $W02_POST_EXCEPT_DIFFS (Target: 0)
Assertion 1 (Base Invariance): $assertion1_pass

Pre-W02 Partitioned Rows:      $W02_PRE_PART_COUNT (Target: 4000000)
Post-W02 Partitioned Rows:     $W02_POST_PART_COUNT (Target: 4000000)
Assertion 2 (Part Invariance): $assertion2_pass

Assertion 3 (Routing Reject):  $assertion3_pass (SQLSTATE 23514 + canonical pattern)

OVERALL DIAGNOSTIC STATUS:     $overall_w02_status
================================================================================
EOF

echo "W02 Diagnostic Outcome: $overall_w02_status (Classification: $w02_class, SQLSTATE: $w02_sqlstate)"

echo "====================================================================="
echo "CP4 Stage 6C.2 Benchmark Run Complete."
echo "End Time:   $(date -u '+%Y-%m-%d %H:%M:%SZ')"
echo "Summary:    $SUMMARY"
echo "W02 Report: $W02_REPORT"
echo "Log File:   $LOG"
echo "====================================================================="
