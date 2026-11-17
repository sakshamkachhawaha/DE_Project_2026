-- =====================================================================
-- YouTube Video Sharing Database
-- Phase 4: indexes and supporting objects
-- Target: PostgreSQL 15+
--
-- Apply AFTER the Phase 2 schema and load:
--   psql -d <database> -v ON_ERROR_STOP=1 -f sql/05_indexes.sql
--
-- Phase 2 already created the primary-key and unique indexes. This file
-- adds only indexes that serve the fixed workload, plus the pg_trgm
-- extension needed for the R04 title search. Every index has a comment
-- saying which queries it serves and why the column order is correct.
--
-- The workload is append-heavy on watch_events, so indexes there cost
-- insert time but no update time; the write-overhead measurements are in
-- docs/04_optimization_report.md.
-- =====================================================================

-- R04 uses ILIKE '%tutorial%'. A B-tree cannot index a leading wildcard;
-- trigram GIN is the appropriate access method. Partial on PUBLIC because
-- R04 filters visibility = 'PUBLIC'. This requires the pg_trgm extension.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS videos_title_trgm_idx
    ON youtube.videos USING gin (title gin_trgm_ops)
    WHERE visibility = 'PUBLIC';

-- R01, R03: equality on channel_id + visibility, then published_at DESC
-- for ORDER BY ... LIMIT. Partial on PUBLIC because both queries only
-- return public videos. INCLUDE columns make the R01 lookup covering
-- (title, duration_sec, view_count) without a heap visit.
CREATE INDEX IF NOT EXISTS videos_public_channel_published_idx
    ON youtube.videos (channel_id, published_at DESC)
    INCLUDE (title, duration_sec, view_count)
    WHERE visibility = 'PUBLIC';

-- R06, W05: the scheduled state is rare (60 rows), so a partial index on
-- published_at serves both the "scheduled before date" read and the
-- "publish due videos" update without indexing 30,000 public videos.
CREATE INDEX IF NOT EXISTS videos_scheduled_published_idx
    ON youtube.videos (published_at)
    WHERE visibility = 'SCHEDULED';

-- R19: max(uploaded_at) per channel and the channel -> video join. The
-- composite (channel_id, uploaded_at) supports both the grouping and the
-- R07/R09/R14/R17 channel filters through its leading column.
CREATE INDEX IF NOT EXISTS videos_channel_uploaded_idx
    ON youtube.videos (channel_id, uploaded_at DESC);

-- R10: only 7,523 Shorts; a partial index on video_id lets the planner
-- find the Shorts side of the join without scanning all 30,000 videos.
CREATE INDEX IF NOT EXISTS videos_short_idx
    ON youtube.videos (video_id)
    WHERE is_short;

-- R18: only 499 made-for-kids videos. The partial index keeps the EXISTS
-- lookup small while the comments index below finds any comment.
CREATE INDEX IF NOT EXISTS videos_kids_idx
    ON youtube.videos (video_id)
    WHERE is_made_for_kids;

-- R05: user_id equality + started_at DESC for ORDER BY ... LIMIT. INCLUDE
-- watch_seconds and video_id so the 50-row page does not visit the heap
-- for the projected columns.
CREATE INDEX IF NOT EXISTS watch_events_user_started_idx
    ON youtube.watch_events (user_id, started_at DESC)
    INCLUDE (watch_seconds, video_id);

-- R07/R08/R09/R13/R17/R19: the workhorse video -> event index.
--   R08 filters video_id and needs traffic_source + watch_seconds;
--   R09 needs watch_seconds;
--   R13 needs user_id for NOT EXISTS;
--   R17 needs watch_seconds for the watch-hour sum;
--   R19 needs the video_id to channel join/count;
--   R07 needs video_id + started_at for the June range.
-- The leading video_id serves the equality/join; started_at is the second
-- key column for the R07 range; the remaining columns are INCLUDE payload.
CREATE INDEX IF NOT EXISTS watch_events_video_started_idx
    ON youtube.watch_events (video_id, started_at)
    INCLUDE (user_id, traffic_source, watch_seconds);

-- R10/R11/R20: range scans on started_at. B-tree is used instead of BRIN
-- because 200k rows are small and the seed plan needs precise range
-- selectivity; BRIN is a Phase 5 option once the table is 20x larger.
CREATE INDEX IF NOT EXISTS watch_events_started_idx
    ON youtube.watch_events (started_at);

-- R12: group by device and count logged-out rows. The planner still chose
-- a sequential scan for this platform-wide aggregate on the 200k-row seed;
-- no dedicated device index is kept, because it would add write/storage
-- cost without being used. A covering index is a Phase 5 option for large
-- data if the plan changes there.

-- R24 and W04: the subscriptions PK starts with user_id, so channel-based
-- grouping/filtering cannot use it. This index serves R24's
-- channel_id = 217 and W04's per-channel count.
CREATE INDEX IF NOT EXISTS subscriptions_channel_subscribed_idx
    ON youtube.subscriptions (channel_id, subscribed_at);

-- R14: channel 217's videos -> reactions, grouped by LIKE/DISLIKE.
-- (video_id, reaction) is the minimal composite index for the LEFT JOIN
-- and the FILTER counts.
CREATE INDEX IF NOT EXISTS video_reactions_video_reaction_idx
    ON youtube.video_reactions (video_id, reaction);

-- R15/R18: a plain video_id index serves both R15's top-level comment
-- lookup and R18's EXISTS check over all comments (including replies).
-- A partial top-level-only index was tested but the planner chose this
-- index for both, so the partial variant was not kept.
CREATE INDEX IF NOT EXISTS comments_video_idx
    ON youtube.comments (video_id);

-- R23: ORDER BY created_at DESC with LIMIT/OFFSET. The index removes the
-- 60,000-row sort; comment_id is the tie-breaker for a stable order and
-- for the Phase 5 keyset variant.
CREATE INDEX IF NOT EXISTS comments_created_idx
    ON youtube.comments (created_at DESC, comment_id DESC);

-- R16: June range on shown_at plus the join to watch_events. INCLUDE
-- avoids heap visits for the watch_id/revenue columns in the aggregate.
CREATE INDEX IF NOT EXISTS ad_impressions_shown_idx
    ON youtube.ad_impressions (shown_at)
    INCLUDE (watch_id, revenue_inr);

-- R16/R25: watch_id is a foreign key and is not indexed by Phase 2.
-- This index serves the ads -> watch join for R25 and the grouped R16
-- join; shown_at/revenue are included for R16's aggregate.
CREATE INDEX IF NOT EXISTS ad_impressions_watch_idx
    ON youtube.ad_impressions (watch_id)
    INCLUDE (shown_at, revenue_inr);

-- Refresh planner statistics after creating the indexes.
ANALYZE youtube.users;
ANALYZE youtube.channels;
ANALYZE youtube.videos;
ANALYZE youtube.subscriptions;
ANALYZE youtube.watch_events;
ANALYZE youtube.video_reactions;
ANALYZE youtube.comments;
ANALYZE youtube.playlists;
ANALYZE youtube.playlist_items;
ANALYZE youtube.ad_impressions;
