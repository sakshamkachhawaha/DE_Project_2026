-- =====================================================================
-- CP4 Stage 6C.2.1: Partition Benchmark Workload Definitions
-- Project: Team T0046 — YouTube Video Sharing Database
-- Database: youtube_large
--
-- Baseline:     youtube.watch_events (4,000,000 rows, monolithic heap)
-- Experimental: youtube_part.watch_events_partitioned (4,000,000 rows, 18 RANGE partitions)
--
-- This workload file defines explicitly schema-qualified, symmetric queries
-- for comparative performance benchmarking and boundary testing.
--
-- Design Principles:
-- 1. Symmetrical Semantics: Baseline and partitioned versions of each query
--    use identical projections, joins, grouping, ordering, filters, and limits.
--    Only relation references are substituted (youtube.watch_events vs.
--    youtube_part.watch_events_partitioned). Dimension tables remain in youtube.*.
-- 2. Sargable Boundary Precision: Time boundaries use explicit +05:30 offsets
--    where specified in the original optimized workload (sql/06_optimized_queries.sql).
-- 3. Boundary Diagnostic Isolation: W02 is isolated as a write routing diagnostic
--    and must never be included in the performance CSV.
-- 4. Result Equivalence: Full-table content equivalence uses bidirectional EXCEPT ALL
--    on all 7 physical columns to detect missing, extra, or duplicate multiplicity rows.
-- =====================================================================

-- =====================================================================
-- SECTION 1: CORE READ-QUERY SUITE
-- =====================================================================

-- ---------------------------------------------------------------------
-- R07: YouTube Studio: channel 217 daily views & watch hours (June 2026)
-- Target: Prunes to single partition (watch_events_2026_06)
-- ---------------------------------------------------------------------
-- @QUERY: R07_baseline
SELECT DATE(w.started_at) AS day, count(*) AS views, round(sum(w.watch_seconds) / 3600.0, 2) AS watch_hours
FROM youtube.watch_events w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.channel_id = 217
  AND w.started_at >= '2026-06-01 00:00:00+05:30'
  AND w.started_at <  '2026-07-01 00:00:00+05:30'
GROUP BY 1
ORDER BY 1;

-- @QUERY: R07_partitioned
SELECT DATE(w.started_at) AS day, count(*) AS views, round(sum(w.watch_seconds) / 3600.0, 2) AS watch_hours
FROM youtube_part.watch_events_partitioned w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.channel_id = 217
  AND w.started_at >= '2026-06-01 00:00:00+05:30'
  AND w.started_at <  '2026-07-01 00:00:00+05:30'
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------
-- R10-Reference: Shorts shelf: most viewed Shorts in last 7 days of June 2026
-- Preserves verbatim untyped date literal '2026-06-24'
-- Target: Prunes to single partition (watch_events_2026_06)
-- ---------------------------------------------------------------------
-- @QUERY: R10_ref_baseline
SELECT v.video_id, v.title, count(*) AS views
FROM youtube.watch_events w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.is_short
  AND w.started_at >= '2026-06-24'
GROUP BY v.video_id, v.title
ORDER BY views DESC
LIMIT 20;

-- @QUERY: R10_ref_partitioned
SELECT v.video_id, v.title, count(*) AS views
FROM youtube_part.watch_events_partitioned w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.is_short
  AND w.started_at >= '2026-06-24'
GROUP BY v.video_id, v.title
ORDER BY views DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- R10-Normalized (Optional Variant): Explicit +05:30 timestamp literal
-- ---------------------------------------------------------------------
-- @QUERY: R10_norm_baseline
SELECT v.video_id, v.title, count(*) AS views
FROM youtube.watch_events w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.is_short
  AND w.started_at >= '2026-06-24 00:00:00+05:30'
GROUP BY v.video_id, v.title
ORDER BY views DESC
LIMIT 20;

-- @QUERY: R10_norm_partitioned
SELECT v.video_id, v.title, count(*) AS views
FROM youtube_part.watch_events_partitioned w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.is_short
  AND w.started_at >= '2026-06-24 00:00:00+05:30'
GROUP BY v.video_id, v.title
ORDER BY views DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- R10-Deterministic (Optional Variant): Deterministic tie-breaker
-- ---------------------------------------------------------------------
-- @QUERY: R10_det_baseline
SELECT v.video_id, v.title, count(*) AS views
FROM youtube.watch_events w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.is_short
  AND w.started_at >= '2026-06-24'
GROUP BY v.video_id, v.title
ORDER BY views DESC, v.video_id ASC
LIMIT 20;

-- @QUERY: R10_det_partitioned
SELECT v.video_id, v.title, count(*) AS views
FROM youtube_part.watch_events_partitioned w
JOIN youtube.videos v ON v.video_id = w.video_id
WHERE v.is_short
  AND w.started_at >= '2026-06-24'
GROUP BY v.video_id, v.title
ORDER BY views DESC, v.video_id ASC
LIMIT 20;

-- ---------------------------------------------------------------------
-- R11: Trending tab: top 5 videos per category in June 2026
-- Target: Prunes to single partition (watch_events_2026_06)
-- ---------------------------------------------------------------------
-- @QUERY: R11_baseline
SELECT *
FROM (
    SELECT v.category, v.video_id, v.title, count(*) AS views,
           RANK() OVER (PARTITION BY v.category ORDER BY count(*) DESC) AS rnk
    FROM youtube.watch_events w
    JOIN youtube.videos v ON v.video_id = w.video_id
    WHERE w.started_at >= '2026-06-01'
    GROUP BY v.category, v.video_id, v.title
) t
WHERE rnk <= 5
ORDER BY category, rnk;

-- @QUERY: R11_partitioned
SELECT *
FROM (
    SELECT v.category, v.video_id, v.title, count(*) AS views,
           RANK() OVER (PARTITION BY v.category ORDER BY count(*) DESC) AS rnk
    FROM youtube_part.watch_events_partitioned w
    JOIN youtube.videos v ON v.video_id = w.video_id
    WHERE w.started_at >= '2026-06-01'
    GROUP BY v.category, v.video_id, v.title
) t
WHERE rnk <= 5
ORDER BY category, rnk;

-- ---------------------------------------------------------------------
-- R12: Growth: share of logged-out viewing per device type
-- Target: Negative control; scans all 18 partitions (no time filter)
-- ---------------------------------------------------------------------
-- @QUERY: R12_baseline
SELECT device,
       count(*) AS views,
       round(100.0 * count(*) FILTER (WHERE user_id IS NULL) / count(*), 1) AS logged_out_pct
FROM youtube.watch_events
GROUP BY device
ORDER BY views DESC;

-- @QUERY: R12_partitioned
SELECT device,
       count(*) AS views,
       round(100.0 * count(*) FILTER (WHERE user_id IS NULL) / count(*), 1) AS logged_out_pct
FROM youtube_part.watch_events_partitioned
GROUP BY device
ORDER BY views DESC;

-- ---------------------------------------------------------------------
-- R17: Partner program: NOT_ELIGIBLE channels with 100+ subs and 40+ watch hours
-- Target: Negative control; lifetime analytics across all 18 partitions
-- ---------------------------------------------------------------------
-- @QUERY: R17_baseline
SELECT c.channel_id, c.handle, c.subscriber_count, round(sum(w.watch_seconds) / 3600.0, 1) AS watch_hours
FROM youtube.channels c
JOIN youtube.videos v       ON v.channel_id = c.channel_id
JOIN youtube.watch_events w ON w.video_id = v.video_id
WHERE c.monetization_status = 'NOT_ELIGIBLE'
  AND c.subscriber_count >= 100
GROUP BY c.channel_id, c.handle, c.subscriber_count
HAVING sum(w.watch_seconds) / 3600.0 >= 40
ORDER BY watch_hours DESC;

-- @QUERY: R17_partitioned
SELECT c.channel_id, c.handle, c.subscriber_count, round(sum(w.watch_seconds) / 3600.0, 1) AS watch_hours
FROM youtube.channels c
JOIN youtube.videos v                       ON v.channel_id = c.channel_id
JOIN youtube_part.watch_events_partitioned w ON w.video_id = v.video_id
WHERE c.monetization_status = 'NOT_ELIGIBLE'
  AND c.subscriber_count >= 100
GROUP BY c.channel_id, c.handle, c.subscriber_count
HAVING sum(w.watch_seconds) / 3600.0 >= 40
ORDER BY watch_hours DESC;

-- ---------------------------------------------------------------------
-- R19: Partner report: latest upload and total views for monetized channels
-- Target: Negative control; lifetime views across all 18 partitions
-- ---------------------------------------------------------------------
-- @QUERY: R19_baseline
SELECT c.channel_id, c.handle,
       u.last_upload,
       coalesce(w.total_views, 0) AS total_views
FROM youtube.channels c
LEFT JOIN (
    SELECT channel_id, max(uploaded_at) AS last_upload
    FROM youtube.videos
    GROUP BY channel_id
) u ON u.channel_id = c.channel_id
LEFT JOIN (
    SELECT v.channel_id, count(*) AS total_views
    FROM youtube.watch_events w
    JOIN youtube.videos v ON v.video_id = w.video_id
    GROUP BY v.channel_id
) w ON w.channel_id = c.channel_id
WHERE c.monetization_status = 'ELIGIBLE'
ORDER BY total_views DESC;

-- @QUERY: R19_partitioned
SELECT c.channel_id, c.handle,
       u.last_upload,
       coalesce(w.total_views, 0) AS total_views
FROM youtube.channels c
LEFT JOIN (
    SELECT channel_id, max(uploaded_at) AS last_upload
    FROM youtube.videos
    GROUP BY channel_id
) u ON u.channel_id = c.channel_id
LEFT JOIN (
    SELECT v.channel_id, count(*) AS total_views
    FROM youtube_part.watch_events_partitioned w
    JOIN youtube.videos v ON v.video_id = w.video_id
    GROUP BY v.channel_id
) w ON w.channel_id = c.channel_id
WHERE c.monetization_status = 'ELIGIBLE'
ORDER BY total_views DESC;

-- ---------------------------------------------------------------------
-- R20: Platform analytics: June 2026 daily watch hours and running total
-- Target: Prunes to single partition (watch_events_2026_06)
-- ---------------------------------------------------------------------
-- @QUERY: R20_baseline
SELECT day, hours, sum(hours) OVER (ORDER BY day) AS running_hours
FROM (
    SELECT started_at::date AS day, round(sum(watch_seconds) / 3600.0, 1) AS hours
    FROM youtube.watch_events
    WHERE started_at >= '2026-06-01 00:00:00+05:30'
      AND started_at <  '2026-07-01 00:00:00+05:30'
    GROUP BY 1
) d
ORDER BY day;

-- @QUERY: R20_partitioned
SELECT day, hours, sum(hours) OVER (ORDER BY day) AS running_hours
FROM (
    SELECT started_at::date AS day, round(sum(watch_seconds) / 3600.0, 1) AS hours
    FROM youtube_part.watch_events_partitioned
    WHERE started_at >= '2026-06-01 00:00:00+05:30'
      AND started_at <  '2026-07-01 00:00:00+05:30'
    GROUP BY 1
) d
ORDER BY day;


-- =====================================================================
-- SECTION 2: DIAGNOSTIC READ SUITE (Cross-Partition Join / Key Access)
-- =====================================================================

-- ---------------------------------------------------------------------
-- R16: Finance: ad revenue per channel in June 2026 (top 20)
-- Join: w.watch_id = a.watch_id (no filter on watch_events.started_at)
-- Architectural Note: Evaluates composite PK (watch_id, started_at) vs. global PK
-- ---------------------------------------------------------------------
-- @QUERY: R16_baseline
SELECT v.channel_id, count(*) AS impressions, sum(a.revenue_inr) AS revenue_inr
FROM youtube.ad_impressions a
JOIN youtube.watch_events w ON w.watch_id = a.watch_id
JOIN youtube.videos v       ON v.video_id = w.video_id
WHERE a.shown_at >= '2026-06-01' AND a.shown_at < '2026-07-01'
GROUP BY v.channel_id
ORDER BY revenue_inr DESC
LIMIT 20;

-- @QUERY: R16_partitioned
SELECT v.channel_id, count(*) AS impressions, sum(a.revenue_inr) AS revenue_inr
FROM youtube.ad_impressions a
JOIN youtube_part.watch_events_partitioned w ON w.watch_id = a.watch_id
JOIN youtube.videos v                       ON v.video_id = w.video_id
WHERE a.shown_at >= '2026-06-01' AND a.shown_at < '2026-07-01'
GROUP BY v.channel_id
ORDER BY revenue_inr DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- R25: Premium audit: ads shown to users with active Premium membership
-- Join: w.watch_id = a.watch_id, u.user_id = w.user_id (no filter on w.started_at)
-- Architectural Note: Multi-table join across partitioned fact relation
-- ---------------------------------------------------------------------
-- @QUERY: R25_baseline
SELECT a.impression_id, w.user_id, u.premium_until, a.shown_at, a.revenue_inr
FROM youtube.ad_impressions a
JOIN youtube.watch_events w ON w.watch_id = a.watch_id
JOIN youtube.users u        ON u.user_id = w.user_id
WHERE u.premium_until >= a.shown_at::date
ORDER BY a.shown_at DESC;

-- @QUERY: R25_partitioned
SELECT a.impression_id, w.user_id, u.premium_until, a.shown_at, a.revenue_inr
FROM youtube.ad_impressions a
JOIN youtube_part.watch_events_partitioned w ON w.watch_id = a.watch_id
JOIN youtube.users u                        ON u.user_id = w.user_id
WHERE u.premium_until >= a.shown_at::date
ORDER BY a.shown_at DESC;


-- =====================================================================
-- SECTION 3: EXACT BIDIRECTIONAL CONTENT-INVARIANCE CHECK
-- =====================================================================
-- Full 7-column bidirectional EXCEPT ALL comparison between baseline and partitioned.
-- Preserves duplicate multiplicity and NULL semantics. Must return 0 rows.
-- ---------------------------------------------------------------------
-- @QUERY: EXCEPT_ALL_INVARIANCE_CHECK
(
    SELECT watch_id, user_id, video_id, started_at, watch_seconds, device, traffic_source
    FROM youtube.watch_events
    EXCEPT ALL
    SELECT watch_id, user_id, video_id, started_at, watch_seconds, device, traffic_source
    FROM youtube_part.watch_events_partitioned
)
UNION ALL
(
    SELECT watch_id, user_id, video_id, started_at, watch_seconds, device, traffic_source
    FROM youtube_part.watch_events_partitioned
    EXCEPT ALL
    SELECT watch_id, user_id, video_id, started_at, watch_seconds, device, traffic_source
    FROM youtube.watch_events
);


-- =====================================================================
-- SECTION 4: W02 PARTITION BOUNDARY WRITE ROUTING DIAGNOSTIC
-- =====================================================================
-- Targets: youtube_part.watch_events_partitioned (NEVER baseline).
-- Timestamp: '2026-07-01 19:00:00+05:30' (outside the 18 partitions).
--
-- Critical Transaction Handling Design:
-- 1. Outer transaction begins with BEGIN.
-- 2. PL/pgSQL block creates an internal subtransaction (savepoint).
-- 3. If an exception occurs, the subtransaction rolls back to the savepoint,
--    leaving the outer transaction open and valid.
-- 4. The exception is NOT re-raised immediately inside the block, preventing
--    psql with ON_ERROR_STOP=1 from aborting before ROLLBACK.
-- 5. Instead, the outcome is captured and emitted via RAISE NOTICE.
-- 6. The outer transaction is explicitly rolled back via ROLLBACK.
-- 7. Post-test row counts and bidirectional EXCEPT ALL certify invariance.
-- ---------------------------------------------------------------------
-- @QUERY: W02_DIAGNOSTIC_BLOCK
BEGIN;

DO $$
DECLARE
    v_sqlstate text;
    v_message  text;
    v_detail   text;
    v_classification text;
BEGIN
    -- Subtransaction: Attempt out-of-bounds insert inside exception-trapping block
    BEGIN
        INSERT INTO youtube_part.watch_events_partitioned (
            watch_id, user_id, video_id, started_at, watch_seconds, device, traffic_source
        ) VALUES (
            90000001, 1042, 'ZkNSlUB1EOs', '2026-07-01 19:00:00+05:30', 180, 'ANDROID', 'HOME'
        );

        -- If insert succeeded, partition routing failed to enforce boundary
        v_sqlstate := '00000';
        v_message  := 'Insert completed without raising an exception';
        v_detail   := 'Row was unexpectedly accepted by youtube_part.watch_events_partitioned';
        v_classification := 'UNEXPECTED_INSERT_SUCCESS';
    EXCEPTION
        WHEN check_violation THEN
            GET STACKED DIAGNOSTICS
                v_sqlstate = RETURNED_SQLSTATE,
                v_message  = MESSAGE_TEXT,
                v_detail   = PG_EXCEPTION_DETAIL;

            -- Validate canonical PostgreSQL partition routing error text
            IF v_message ILIKE '%no partition of relation%found for row%' THEN
                v_classification := 'EXPECTED_ROUTING_REJECTION';
            ELSE
                v_classification := 'UNEXPECTED_CHECK_FAILURE';
            END IF;

        WHEN foreign_key_violation THEN
            GET STACKED DIAGNOSTICS
                v_sqlstate = RETURNED_SQLSTATE,
                v_message  = MESSAGE_TEXT,
                v_detail   = PG_EXCEPTION_DETAIL;
            v_classification := 'FOREIGN_KEY_VIOLATION';

        WHEN unique_violation THEN
            GET STACKED DIAGNOSTICS
                v_sqlstate = RETURNED_SQLSTATE,
                v_message  = MESSAGE_TEXT,
                v_detail   = PG_EXCEPTION_DETAIL;
            v_classification := 'UNIQUE_VIOLATION';

        WHEN not_null_violation THEN
            GET STACKED DIAGNOSTICS
                v_sqlstate = RETURNED_SQLSTATE,
                v_message  = MESSAGE_TEXT,
                v_detail   = PG_EXCEPTION_DETAIL;
            v_classification := 'NOT_NULL_VIOLATION';

        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_sqlstate = RETURNED_SQLSTATE,
                v_message  = MESSAGE_TEXT,
                v_detail   = PG_EXCEPTION_DETAIL;
            v_classification := 'UNEXPECTED_ERROR';
    END;

    -- Emit structured diagnostic line to client stdout/stderr (survives outer rollback)
    RAISE NOTICE 'W02_DIAG_OUTCOME|%|%|%|%',
        v_classification,
        v_sqlstate,
        replace(v_message, '|', ' '),
        replace(coalesce(v_detail, 'NONE'), '|', ' ');
END $$;

-- Explicitly rollback the outer transaction
ROLLBACK;
