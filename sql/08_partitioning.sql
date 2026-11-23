-- =====================================================================
-- YouTube Video Sharing Database
-- Phase 5 / CP4: Declarative Table Partitioning Experiment
-- Target Database: youtube_large (PostgreSQL 15+)
--
-- File: sql/08_partitioning.sql
-- Schema: youtube_part (Isolated experimental namespace)
--
-- Objective:
--   Demonstrates PostgreSQL declarative table partitioning by RANGE on
--   started_at for watch_events, without modifying or dropping the verified
--   baseline schema (youtube) or its tables (youtube.watch_events).
--
-- Execution Precondition Warning (Stage 6B Preflight Requirements):
--   Before executing this script in Stage 6B, the operator MUST verify:
--   1. The schema youtube_part does NOT already exist, or has been verified
--      to be completely empty and dedicated to this experiment.
--   2. No unrelated user or production objects exist in youtube_part.
--   3. The baseline schema youtube and its 10 tables are present and intact.
--   4. The source table youtube.watch_events contains exactly 4,000,000 rows.
--   5. IF A PRIOR EXECUTION FAILED PARTIALLY: Do NOT rerun this script blindly.
--      Perform a manual catalog inspection and execute the explicit safe
--      cleanup procedure (Section 8) before restarting.
--   6. Automatic DROP statements are deliberately OMITTED from the start of
--      this script to prevent accidental destructive overwrites.
--
-- Safety Guarantees:
--   1. Zero modification to youtube schema, tables, indexes, or constraints.
--   2. ad_impressions remains untouched and continues referencing youtube.watch_events.
--   3. All experimental objects reside exclusively in youtube_part.
--   4. Cleanup uses RESTRICT semantics to fail closed if any unexpected dependency exists.
-- =====================================================================

-- Ensure strict error handling and session parameters
\set ON_ERROR_STOP on
SET client_min_messages TO warning;
SET timezone TO 'Asia/Kolkata';

-- =====================================================================
-- Section 1: Create Dedicated Experimental Schema
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS youtube_part;

COMMENT ON SCHEMA youtube_part IS
    'Isolated experimental schema for CP4 declarative partitioning demonstration';

-- =====================================================================
-- Section 2: Create Partitioned Parent Table
--
-- Note on Primary Key & Referential Integrity:
--   PostgreSQL requires that any PRIMARY KEY or UNIQUE constraint on a
--   partitioned table include all columns of the partition key (started_at).
--   Therefore, the primary key is composite: PRIMARY KEY (watch_id, started_at).
--
--   IMPORTANT ARCHITECTURAL LIMITATION:
--   The composite PK guarantees uniqueness for the (watch_id, started_at) tuple,
--   but does NOT enforce global uniqueness of watch_id alone across partitions.
--   In the loaded dataset, watch_id values are verified to be globally unique
--   (COUNT(DISTINCT watch_id) = 4,000,000), but this is a property of the data,
--   not a database-enforced constraint for future inserts.
-- =====================================================================

CREATE TABLE youtube_part.watch_events_partitioned (
    watch_id        bigint       NOT NULL,
    user_id         integer,
    video_id        varchar(11)  NOT NULL,
    started_at      timestamptz  NOT NULL,
    watch_seconds   integer      NOT NULL,
    device          text         NOT NULL,
    traffic_source  text         NOT NULL,

    -- Partition-compatible composite primary key
    CONSTRAINT watch_events_part_pkey
        PRIMARY KEY (watch_id, started_at),

    -- Outgoing foreign keys to baseline dimension tables
    CONSTRAINT watch_events_part_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES youtube.users (user_id)
        ON DELETE SET NULL,
    CONSTRAINT watch_events_part_video_id_fkey
        FOREIGN KEY (video_id) REFERENCES youtube.videos (video_id)
        ON DELETE RESTRICT,

    -- Domain CHECK constraints (exact reproduction of sql/01_schema.sql)
    CONSTRAINT watch_events_part_watch_seconds_check
        CHECK (watch_seconds >= 0),
    CONSTRAINT watch_events_part_device_check
        CHECK (device IN ('ANDROID', 'IOS', 'WEB', 'TV')),
    CONSTRAINT watch_events_part_traffic_source_check
        CHECK (traffic_source IN ('SHORTS_FEED', 'HOME', 'SUGGESTED',
                                  'EXTERNAL', 'SUBSCRIPTION', 'SEARCH'))
) PARTITION BY RANGE (started_at);

COMMENT ON TABLE youtube_part.watch_events_partitioned IS
    'RANGE-partitioned copy of watch_events partitioned monthly on started_at';

-- =====================================================================
-- Section 3: Create Discrete Monthly Partitions (18 Contiguous Months)
--
-- Boundaries:
--   Covers January 1, 2025 through July 1, 2026 (exclusive).
--   All boundaries use explicit Asia/Kolkata (+05:30) timezone offsets.
--   Half-open intervals: [start_inclusive, end_exclusive).
--
-- Why Omit a DEFAULT Partition:
--   1. Strict validation: in this fixed historical dataset, all 4,000,000 rows
--      fall strictly between 2025-01-01 and 2026-07-01. Any out-of-range insert
--      fails immediately rather than silently routing into a catch-all partition.
--   2. Future DDL efficiency: in PostgreSQL, creating a new partition when a
--      DEFAULT partition exists requires an ACCESS EXCLUSIVE lock while scanning
--      the entire DEFAULT partition. Omission avoids this lock penalty.
-- =====================================================================

CREATE TABLE youtube_part.watch_events_2025_01 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-01-01 00:00:00+05:30') TO ('2025-02-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_02 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-02-01 00:00:00+05:30') TO ('2025-03-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_03 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-03-01 00:00:00+05:30') TO ('2025-04-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_04 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-04-01 00:00:00+05:30') TO ('2025-05-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_05 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-05-01 00:00:00+05:30') TO ('2025-06-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_06 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-06-01 00:00:00+05:30') TO ('2025-07-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_07 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-07-01 00:00:00+05:30') TO ('2025-08-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_08 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-08-01 00:00:00+05:30') TO ('2025-09-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_09 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-09-01 00:00:00+05:30') TO ('2025-10-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_10 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-10-01 00:00:00+05:30') TO ('2025-11-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_11 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-11-01 00:00:00+05:30') TO ('2025-12-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2025_12 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2025-12-01 00:00:00+05:30') TO ('2026-01-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2026_01 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2026-01-01 00:00:00+05:30') TO ('2026-02-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2026_02 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2026-02-01 00:00:00+05:30') TO ('2026-03-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2026_03 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2026-03-01 00:00:00+05:30') TO ('2026-04-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2026_04 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2026-04-01 00:00:00+05:30') TO ('2026-05-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2026_05 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2026-05-01 00:00:00+05:30') TO ('2026-06-01 00:00:00+05:30');

CREATE TABLE youtube_part.watch_events_2026_06 PARTITION OF youtube_part.watch_events_partitioned
    FOR VALUES FROM ('2026-06-01 00:00:00+05:30') TO ('2026-07-01 00:00:00+05:30');

-- =====================================================================
-- Section 4: Secondary Indexes on Partitioned Parent
--
-- Index Cascading:
--   Defining indexes on the parent partitioned table automatically creates
--   partition-local indexes across all 18 monthly sub-tables (4 parent indexes
--   and 72 local partition indexes total).
--   Definitions match sql/05_indexes.sql exactly.
-- =====================================================================

CREATE INDEX watch_events_part_user_started_idx
    ON youtube_part.watch_events_partitioned (user_id, started_at DESC)
    INCLUDE (watch_seconds, video_id);

CREATE INDEX watch_events_part_video_started_idx
    ON youtube_part.watch_events_partitioned (video_id, started_at)
    INCLUDE (user_id, traffic_source, watch_seconds);

CREATE INDEX watch_events_part_started_idx
    ON youtube_part.watch_events_partitioned (started_at);

-- =====================================================================
-- Section 5: Data Ingestion from Baseline
--
-- Preserves all 4,000,000 records from youtube.watch_events, including
-- the 999,604 logged-out view records where user_id IS NULL.
-- =====================================================================

INSERT INTO youtube_part.watch_events_partitioned (
    watch_id,
    user_id,
    video_id,
    started_at,
    watch_seconds,
    device,
    traffic_source
)
SELECT 
    watch_id,
    user_id,
    video_id,
    started_at,
    watch_seconds,
    device,
    traffic_source
FROM youtube.watch_events;

-- Refresh planner statistics across the partitioned hierarchy
ANALYZE youtube_part.watch_events_partitioned;

-- =====================================================================
-- Section 6: Query Demonstrations (Baseline vs Partitioned)
--
-- The queries below demonstrate partition pruning using EXPLAIN (ANALYZE, BUFFERS).
-- Session timezone MUST be Asia/Kolkata (+05:30).
-- =====================================================================

/*
-- ---------------------------------------------------------------------
-- Demo Query 1: R20 (Platform Analytics - June 2026)
-- Expected Behavior: Static planning-time partition pruning. Only
-- watch_events_2026_06 is scanned; 17 partitions are pruned.
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT day, hours, sum(hours) OVER (ORDER BY day) AS running_hours
FROM (
    SELECT started_at::date AS day, round(sum(watch_seconds) / 3600.0, 1) AS hours
    FROM youtube_part.watch_events_partitioned
    WHERE started_at >= '2026-06-01 00:00:00+05:30'
      AND started_at <  '2026-07-01 00:00:00+05:30'
    GROUP BY 1
) d
ORDER BY day;

-- ---------------------------------------------------------------------
-- Demo Query 2: R10 (Shorts Shelf - Last 7 Days of June 2026)
-- Expected Behavior: Untyped literal '2026-06-24' is resolved via timestamptz_in
-- under Asia/Kolkata (+05:30). Pruning eliminates 17 earlier partitions.
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT v.video_id, v.title, count(*) AS views
FROM youtube_part.watch_events_partitioned w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.is_short
  AND w.started_at >= '2026-06-24'
GROUP BY v.video_id, v.title
ORDER BY views DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- Demo Query 3: R12 (Growth: Device Share - Whole Table Aggregation)
-- Expected Behavior: Negative pruning test. No filter on started_at.
-- Demonstrates that whole-table analytics scan all 18 partitions (Append node).
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT device,
       count(*) AS views,
       round(100.0 * count(*) FILTER (WHERE user_id IS NULL) / count(*), 1) AS logged_out_pct
FROM youtube_part.watch_events_partitioned
GROUP BY device
ORDER BY views DESC;
*/

-- =====================================================================
-- Section 7: Verification SQL (Diagnostic Read-Only Checks)
--
-- These queries verify data fidelity, uniqueness, boundary containment,
-- monthly equivalence, query-result equivalence, and catalog inventory.
-- =====================================================================

/*
-- Check 1: Total row counts match baseline exactly (4,000,000 rows)
SELECT 
    'baseline' AS source, count(*) AS row_count FROM youtube.watch_events
UNION ALL
SELECT 
    'partitioned' AS source, count(*) AS row_count FROM youtube_part.watch_events_partitioned;

-- Check 2: Current-data watch_id uniqueness (4,000,000 distinct values)
-- Confirms that in this dataset, watch_id is unique across all partitions.
SELECT 
    count(DISTINCT watch_id) AS distinct_watch_ids,
    count(*) AS total_rows,
    CASE WHEN count(DISTINCT watch_id) = count(*) THEN 'PASS' ELSE 'FAIL' END AS uniqueness_check
FROM youtube_part.watch_events_partitioned;

-- Check 3: NULL user_id count matches baseline (999,604 logged-out views)
SELECT 
    count(*) FILTER (WHERE user_id IS NULL) AS null_user_count,
    CASE WHEN count(*) FILTER (WHERE user_id IS NULL) = 999604 THEN 'PASS' ELSE 'FAIL' END AS null_check
FROM youtube_part.watch_events_partitioned;

-- Check 4: Boundary timestamps match baseline exactly
SELECT 
    min(started_at) AS min_started_at,
    max(started_at) AS max_started_at,
    CASE WHEN min(started_at) = '2025-01-01 00:00:00+05:30' 
          AND max(started_at) = '2026-06-30 23:59:48+05:30' 
         THEN 'PASS' ELSE 'FAIL' END AS boundary_check
FROM youtube_part.watch_events_partitioned;

-- Check 5: Zero rows outside configured monthly ranges
SELECT 
    count(*) FILTER (WHERE started_at < '2025-01-01 00:00:00+05:30' 
                        OR started_at >= '2026-07-01 00:00:00+05:30') AS out_of_bounds_count
FROM youtube_part.watch_events_partitioned;

-- Check 6: Genuine Monthly Baseline Comparison
-- Directly compares baseline and partitioned counts for every month, identifying
-- any missing months, unexpected months, or row-count divergences.
WITH baseline_months AS (
    SELECT to_char(started_at, 'YYYY-MM') AS month_slice, count(*) AS b_count
    FROM youtube.watch_events
    GROUP BY 1
),
part_months AS (
    SELECT to_char(started_at, 'YYYY-MM') AS month_slice, count(*) AS p_count
    FROM youtube_part.watch_events_partitioned
    GROUP BY 1
)
SELECT 
    coalesce(b.month_slice, p.month_slice) AS month_slice,
    coalesce(b.b_count, 0) AS baseline_rows,
    coalesce(p.p_count, 0) AS partitioned_rows,
    coalesce(p.p_count, 0) - coalesce(b.b_count, 0) AS count_difference,
    CASE 
        WHEN b.b_count IS NULL THEN 'FAIL (Unexpected month in partitioned table)'
        WHEN p.p_count IS NULL THEN 'FAIL (Missing month in partitioned table)'
        WHEN b.b_count = p.p_count THEN 'PASS'
        ELSE 'FAIL (Row count mismatch)'
    END AS status
FROM baseline_months b
FULL OUTER JOIN part_months p ON b.month_slice = p.month_slice
ORDER BY 1;

-- Check 7: Query-Result Equivalence Checks (Bidirectional EXCEPT ALL)
-- Verifies row-for-row and duplicate-count equivalence between baseline and partitioned queries.
-- Returns 0 rows if result sets are identical (PASS).

-- 7A: R20 Result Equivalence
WITH r20_baseline AS (
    SELECT day, hours, sum(hours) OVER (ORDER BY day) AS running_hours
    FROM (
        SELECT started_at::date AS day, round(sum(watch_seconds) / 3600.0, 1) AS hours
        FROM youtube.watch_events
        WHERE started_at >= '2026-06-01 00:00:00+05:30'
          AND started_at <  '2026-07-01 00:00:00+05:30'
        GROUP BY 1
    ) d
),
r20_part AS (
    SELECT day, hours, sum(hours) OVER (ORDER BY day) AS running_hours
    FROM (
        SELECT started_at::date AS day, round(sum(watch_seconds) / 3600.0, 1) AS hours
        FROM youtube_part.watch_events_partitioned
        WHERE started_at >= '2026-06-01 00:00:00+05:30'
          AND started_at <  '2026-07-01 00:00:00+05:30'
        GROUP BY 1
    ) d
),
r20_diff AS (
    (SELECT * FROM r20_baseline EXCEPT ALL SELECT * FROM r20_part)
    UNION ALL
    (SELECT * FROM r20_part EXCEPT ALL SELECT * FROM r20_baseline)
)
SELECT 'R20 Result Equivalence' AS query_id,
       count(*) AS differing_rows,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM r20_diff;

-- 7B: R10 Aggregation Equivalence (Pre-LIMIT Deterministic Comparison)
-- Note on R10 Determinism:
-- The original R10 workload query uses `ORDER BY views DESC LIMIT 20` without a secondary
-- tie-breaker (e.g., video_id). When multiple videos share equal view counts near the 20th position,
-- baseline and partitioned executions could legitimately select different subsets of tied videos,
-- causing a false FAIL in strict result set comparison despite identical underlying data.
-- To provide 100% deterministic mathematical verification without modifying the original R10
-- query definition in Section 6, this check compares the complete pre-LIMIT aggregated result set
-- (all qualifying short videos and their view counts) across both tables via bidirectional EXCEPT ALL.
-- Identical full aggregation proves partition pruning and aggregation fidelity; any difference in
-- the top-20 slice would be solely an artifact of non-deterministic tie-breaking.
WITH r10_baseline AS (
    SELECT v.video_id, v.title, count(*) AS views
    FROM youtube.watch_events w
    JOIN youtube.videos v ON v.video_id = w.video_id
    WHERE v.is_short
      AND w.started_at >= '2026-06-24'
    GROUP BY v.video_id, v.title
),
r10_part AS (
    SELECT v.video_id, v.title, count(*) AS views
    FROM youtube_part.watch_events_partitioned w
    JOIN youtube.videos v ON v.video_id = w.video_id
    WHERE v.is_short
      AND w.started_at >= '2026-06-24'
    GROUP BY v.video_id, v.title
),
r10_diff AS (
    (SELECT * FROM r10_baseline EXCEPT ALL SELECT * FROM r10_part)
    UNION ALL
    (SELECT * FROM r10_part EXCEPT ALL SELECT * FROM r10_baseline)
)
SELECT 'R10 Aggregation Equivalence (Pre-LIMIT)' AS query_id,
       count(*) AS differing_rows,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM r10_diff;

-- 7C: R12 Result Equivalence
WITH r12_baseline AS (
    SELECT device,
           count(*) AS views,
           round(100.0 * count(*) FILTER (WHERE user_id IS NULL) / count(*), 1) AS logged_out_pct
    FROM youtube.watch_events
    GROUP BY device
),
r12_part AS (
    SELECT device,
           count(*) AS views,
           round(100.0 * count(*) FILTER (WHERE user_id IS NULL) / count(*), 1) AS logged_out_pct
    FROM youtube_part.watch_events_partitioned
    GROUP BY device
),
r12_diff AS (
    (SELECT * FROM r12_baseline EXCEPT ALL SELECT * FROM r12_part)
    UNION ALL
    (SELECT * FROM r12_part EXCEPT ALL SELECT * FROM r12_baseline)
)
SELECT 'R12 Result Equivalence' AS query_id,
       count(*) AS differing_rows,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM r12_diff;

-- Check 8: Comprehensive Catalog Inventory Audit
-- Verifies relation objects, constraints, triggers, routines, types, policies, and rules.

-- 8A: Relation Inventory in pg_class (Expected: exactly 95 relations)
-- 1 partitioned parent + 18 child partitions + 4 parent indexes + 72 local indexes = 95
SELECT 
    CASE c.relkind
        WHEN 'p' THEN 'partitioned parent table'
        WHEN 'r' THEN 'child partition table'
        WHEN 'I' THEN 'partitioned parent index'
        WHEN 'i' THEN 'partition-local index'
        WHEN 'S' THEN 'sequence (unexpected)'
        WHEN 'v' THEN 'view (unexpected)'
        WHEN 'm' THEN 'materialized view (unexpected)'
        ELSE c.relkind::text
    END AS object_class,
    count(*) AS object_count
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'youtube_part'
GROUP BY c.relkind
ORDER BY 1;

-- 8B: Constraint Inventory in pg_constraint
-- Expected: 6 top-level constraints on parent (1 PK, 2 FK, 3 CHECK)
-- Expected: 108 cascaded child constraints (18 partitions * 6 constraints)
SELECT 
    CASE con.contype
        WHEN 'p' THEN 'PRIMARY KEY'
        WHEN 'f' THEN 'FOREIGN KEY'
        WHEN 'c' THEN 'CHECK'
        WHEN 'u' THEN 'UNIQUE'
        ELSE con.contype::text
    END AS constraint_type,
    con.conparentid = 0 AS is_top_level_parent_constraint,
    count(*) AS constraint_count
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'youtube_part'
GROUP BY con.contype, con.conparentid = 0
ORDER BY is_top_level_parent_constraint DESC, constraint_type;

-- 8C: Other Catalog Checks (Expected: 0 for all categories)
-- Triggers, routines, standalone types/enums/domains, policies, and rules
SELECT 'triggers' AS object_category, count(*) AS object_count
FROM pg_trigger trg
JOIN pg_class c ON c.oid = trg.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'youtube_part' AND NOT trg.tgisinternal
UNION ALL
SELECT 'routines (functions/procedures)', count(*)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'youtube_part'
UNION ALL
SELECT 'standalone types/enums/domains', count(*)
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'youtube_part'
  AND t.typtype IN ('e', 'd', 'c')
  AND t.typrelid = 0
UNION ALL
SELECT 'row-level security policies', count(*)
FROM pg_policy pol
JOIN pg_class c ON c.oid = pol.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'youtube_part'
UNION ALL
SELECT 'rewrite rules (non-view)', count(*)
FROM pg_rewrite r
JOIN pg_class c ON c.oid = r.ev_class
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'youtube_part' AND r.rulename <> '_RETURN';
*/

-- =====================================================================
-- Section 8: Safe Rollback Procedure (Documentation Only - DO NOT EXECUTE)
--
-- Dependency Accounting & Semantics:
--   PostgreSQL pg_depend.deptype categories:
--     'n' = DEPENDENCY_NORMAL: Standard external references (e.g. external views, FKs).
--     'a' = DEPENDENCY_AUTO: Automatic dependencies (e.g. table columns on table).
--     'i' = DEPENDENCY_INTERNAL: Internal system dependencies (e.g. index on constraint).
--     'e' = DEPENDENCY_EXTENSION: Extension membership.
--     'P' = DEPENDENCY_PARTITION_PRI: Partition dependency on parent table.
--     'S' = DEPENDENCY_PARTITION_SEC: Secondary partition attachment dependency.
--
-- Dependency-Type Handling and Rationale:
--   - Automated Assertion Filter ('n', 'a', 'P', 'S'):
--     These represent hazardous external relationships created by users or external DDL:
--       * 'n' (NORMAL): External objects (foreign keys from baseline tables, external views,
--         functions) explicitly referencing youtube_part objects.
--       * 'a' (AUTO): Objects scheduled to drop automatically with the referenced object.
--       * 'P' / 'S' (PARTITION_PRI / PARTITION_SEC): External partitions attached to this table.
--     Any incoming external reference of these types indicates an unexpected cross-schema coupling
--     that must immediately abort rollback.
--   - Why INTERNAL ('i') and EXTENSION ('e') Are Treated Differently:
--     * 'i' (INTERNAL): Represents internal system relationships created implicitly by PostgreSQL
--       (e.g., indexes enforcing constraints, system toast tables, table columns). Objects with
--       deptype 'i' cannot be dropped independently and are dropped automatically by the engine
--       as an internal consequence of dropping the owning object. While an external object should
--       never have an 'i' reference to youtube_part in standard operation, treating 'i' as an external
--       drop-hazard is semantically distinct from user-created couplings.
--     * 'e' (EXTENSION): Represents membership of an object within a PostgreSQL extension. Objects
--       with deptype 'e' can only be dropped via DROP EXTENSION, not via DROP TABLE/SCHEMA.
--
-- Multi-Layer Safeguard Hierarchy:
--   1. Step 1 (Mandatory Human Review): Displays ALL incoming dependencies across all 6 types
--      ('n', 'a', 'i', 'e', 'P', 'S') for exhaustive visual inspection by the DBA.
--   2. Step 2 (Automated Pre-Cleanup Assertion): A fail-closed preliminary gate checking for
--      hazardous external references ('n', 'a', 'P', 'S').
--      *NOTE*: The automated assertion is a helpful preflight sanity check, NOT a complete
--      substitute for human dependency inspection in Step 1.
--   3. Step 3 (Lock Timeout): Sets lock_timeout = '2s' to prevent blocking concurrent queries.
--   4. Steps 4-5 (Engine-Level Authoritative Safeguards):
--      DROP TABLE ... RESTRICT and DROP SCHEMA ... RESTRICT are the ultimate, authoritative,
--      engine-enforced safeguards. If ANY external dependent object exists anywhere in the database,
--      the PostgreSQL engine itself unconditionally rejects the DROP command and raises an error.
--   5. CASCADE Prohibition: CASCADE is strictly prohibited to guarantee zero accidental drops.
-- =====================================================================

/*
-- Step 1: Human Inspection Diagnostic — Display all external dependencies across all 6 types
-- All 6 dependency types ('n', 'a', 'i', 'e', 'P', 'S') must be displayed and manually reviewed.
-- This diagnostic provides exhaustive visibility into any catalog dependency pointing into youtube_part.
SELECT 
    d.classid::regclass AS dependent_catalog,
    d.objid AS dependent_objid,
    dep.type AS dependent_type,
    coalesce(dep.schema, '(no schema)') AS dependent_schema,
    dep.identity AS dependent_identity,
    d.refclassid::regclass AS referenced_catalog,
    d.refobjid AS referenced_objid,
    ref.type AS referenced_type,
    ref.schema AS referenced_schema,
    ref.identity AS referenced_identity,
    d.deptype,
    CASE d.deptype
        WHEN 'n' THEN 'NORMAL'
        WHEN 'a' THEN 'AUTO'
        WHEN 'i' THEN 'INTERNAL'
        WHEN 'e' THEN 'EXTENSION'
        WHEN 'P' THEN 'PARTITION_PRI'
        WHEN 'S' THEN 'PARTITION_SEC'
        ELSE d.deptype::text
    END AS deptype_meaning
FROM pg_depend d
CROSS JOIN LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) dep
CROSS JOIN LATERAL pg_identify_object(d.refclassid, d.refobjid, d.refobjsubid) ref
WHERE (ref.schema = 'youtube_part' OR (ref.type = 'schema' AND ref.name = 'youtube_part'))
  AND (coalesce(dep.schema, '') <> 'youtube_part')
ORDER BY d.deptype, dep.schema, dep.identity;

-- Step 2: Automated Pre-Cleanup Assertion — Fail closed if external dependencies ('n', 'a', 'P', 'S') exist
-- Note: This automated assertion specifically checks for hazardous external references ('n', 'a', 'P', 'S').
-- It serves as a fail-closed preliminary gate, but is NOT a complete substitute for human review of Step 1.
DO $$
DECLARE
    ext_deps integer;
BEGIN
    SELECT count(*) INTO ext_deps
    FROM pg_depend d
    CROSS JOIN LATERAL pg_identify_object(d.classid, d.objid, d.objsubid) dep
    CROSS JOIN LATERAL pg_identify_object(d.refclassid, d.refobjid, d.refobjsubid) ref
    WHERE (ref.schema = 'youtube_part' OR (ref.type = 'schema' AND ref.name = 'youtube_part'))
      AND (coalesce(dep.schema, '') <> 'youtube_part')
      AND d.deptype IN ('n', 'a', 'P', 'S');

    IF ext_deps > 0 THEN
        RAISE EXCEPTION 'Cleanup aborted: % external dependencies point into youtube_part', ext_deps;
    END IF;
END $$;

-- Step 3: Set short lock timeout to avoid queuing behind concurrent queries
SET lock_timeout = '2s';

-- Step 4: Safely drop experimental parent table with RESTRICT
-- In PostgreSQL declarative partitioning, dropping the parent partitioned table
-- automatically removes all 18 partitions and all 76 indexes.
-- RESTRICT is the authoritative engine-level safeguard: if ANY external object outside
-- youtube_part depends on this table, PostgreSQL unconditionally aborts the statement with an error.
-- CASCADE is strictly prohibited.
DROP TABLE IF EXISTS youtube_part.watch_events_partitioned RESTRICT;

-- Step 5: Safely drop empty experimental schema with RESTRICT
-- Fails closed if any unexpected table, view, sequence, or function remains.
-- RESTRICT guarantees that if any object exists in youtube_part, the drop is rejected.
-- CASCADE is strictly prohibited.
DROP SCHEMA IF EXISTS youtube_part RESTRICT;
*/
