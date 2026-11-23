-- =====================================================================
-- YouTube Video Sharing Database
-- Phase 5: load the ten CSV exports of the large dataset into the Phase 2 schema
-- Target: PostgreSQL 15+
--
-- Run from the repository root, after placing/extracting large_data:
--   psql -d youtube_large -v ON_ERROR_STOP=1 -f sql/02_load_large_data.sql
--
-- \copy is a psql meta-command (not server-side COPY), so the relative
-- paths below are resolved from the directory in which psql is started.
-- Running this file from the repository root is therefore required.
--
-- Load order follows the foreign keys: parents before children.
-- comments.parent_comment_id is self-referencing; every parent comment
-- appears earlier in comments.csv (verified), so one ordered load works.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO youtube;

\echo 'Loading users ...'
\copy users (user_id, email, display_name, country_code, birth_year, premium_until, created_at) FROM 'large_data/users.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading channels ...'
\copy channels (channel_id, owner_user_id, handle, channel_name, country_code, is_verified, monetization_status, subscriber_count, created_at) FROM 'large_data/channels.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading videos ...'
\copy videos (video_id, channel_id, title, description, category, duration_sec, is_short, is_made_for_kids, visibility, uploaded_at, published_at, view_count) FROM 'large_data/videos.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading subscriptions ...'
\copy subscriptions (user_id, channel_id, notifications, subscribed_at) FROM 'large_data/subscriptions.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading watch_events ...'
\copy watch_events (watch_id, user_id, video_id, started_at, watch_seconds, device, traffic_source) FROM 'large_data/watch_events.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading video_reactions ...'
\copy video_reactions (user_id, video_id, reaction, reacted_at) FROM 'large_data/video_reactions.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading comments ...'
\copy comments (comment_id, video_id, user_id, parent_comment_id, body, like_count, is_pinned, created_at) FROM 'large_data/comments.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading playlists ...'
\copy playlists (playlist_id, owner_user_id, title, visibility, created_at) FROM 'large_data/playlists.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading playlist_items ...'
\copy playlist_items (playlist_id, position, video_id, added_at) FROM 'large_data/playlist_items.csv' WITH (FORMAT csv, HEADER true)

\echo 'Loading ad_impressions ...'
\copy ad_impressions (impression_id, watch_id, ad_format, revenue_inr, shown_at) FROM 'large_data/ad_impressions.csv' WITH (FORMAT csv, HEADER true)

-- Fresh planner statistics after a bulk load. This is required before the
-- Phase 5 benchmark, and it is not an index or a server-tuning trick.
ANALYZE;

\echo 'Load complete. Expected row counts: users 600000, channels 60000, videos 600000, subscriptions 2598598, watch_events 4000000, video_reactions 1350452, comments 1200000, playlists 160000, playlist_items 1120003, ad_impressions 1139137.'
