-- =====================================================================
-- YouTube Video Sharing Database
-- Phase 2: schema inferred from the ten CSV exports
-- Target: PostgreSQL 15+
--
-- How to run (from the repository root, on an empty database):
--   psql -d <database> -v ON_ERROR_STOP=1 -f sql/01_schema.sql
--
-- Design rules used here:
--   * Table and column names are exactly the CSV file names/headers,
--     because queries/workload_30.sql depends on them.
--   * Timestamps are timestamptz: every export carries a +05:30 offset.
--   * revenue_inr is numeric(10,4): it is money and the export has four
--     decimal places. Floating point would make revenue totals inexact.
--   * Phase 2 creates constraints only (PK, FK, UNIQUE, NOT NULL, CHECK).
--     No additional indexes are created; the baseline in Phase 3 must
--     reflect an untuned database. PostgreSQL automatically creates
--     indexes for PRIMARY KEY and UNIQUE constraints, and those are listed
--     in docs/02_schema_design.md.
--   * ON DELETE rules are deliberately not all CASCADE. Ownership,
--     content and financial history are protected with RESTRICT; child
--     rows whose meaning disappears with their parent use CASCADE;
--     watch_events.user_id uses SET NULL so aggregate view counts survive
--     account deletion (a deleted account becomes a logged-out view).
-- =====================================================================

CREATE SCHEMA youtube;
SET search_path TO youtube;

-- ---------------------------------------------------------------------
-- users: one row per signed-in account. Logged-out viewers are not users;
-- they appear only as watch_events.user_id IS NULL.
-- ---------------------------------------------------------------------
CREATE TABLE users (
    user_id        integer      NOT NULL,
    email          text         NOT NULL,
    display_name   text         NOT NULL,
    country_code   char(2)      NOT NULL,
    birth_year     smallint,
    premium_until  date,
    created_at     timestamptz  NOT NULL,

    CONSTRAINT users_pkey
        PRIMARY KEY (user_id),
    CONSTRAINT users_email_key
        UNIQUE (email),
    CONSTRAINT users_email_check
        CHECK (email ~ '^[^@ ]+@[^@ ]+\.[^@ ]+$'),
    CONSTRAINT users_display_name_check
        CHECK (length(btrim(display_name)) > 0),
    CONSTRAINT users_country_code_check
        CHECK (country_code ~ '^[A-Z]{2}$'),
    CONSTRAINT users_birth_year_check
        CHECK (birth_year IS NULL OR birth_year BETWEEN 1900 AND 2100)
);

COMMENT ON TABLE users IS
    'Signed-in accounts. country_code is a two-letter ISO-style code; premium_until is NULL for non-Premium users.';

-- ---------------------------------------------------------------------
-- channels: exactly one channel per owner in the export (owner_user_id is
-- UNIQUE). subscriber_count is a denormalized counter; subscriptions is
-- the source of truth and W04 recomputes this column.
-- ---------------------------------------------------------------------
CREATE TABLE channels (
    channel_id           integer      NOT NULL,
    owner_user_id        integer      NOT NULL,
    handle               varchar(31)  NOT NULL,
    channel_name         text         NOT NULL,
    country_code         char(2)      NOT NULL,
    is_verified          boolean      NOT NULL,
    monetization_status  text         NOT NULL,
    subscriber_count     bigint       NOT NULL,
    created_at           timestamptz  NOT NULL,

    CONSTRAINT channels_pkey
        PRIMARY KEY (channel_id),
    CONSTRAINT channels_owner_user_id_key
        UNIQUE (owner_user_id),
    CONSTRAINT channels_handle_key
        UNIQUE (handle),
    CONSTRAINT channels_owner_user_id_fkey
        FOREIGN KEY (owner_user_id) REFERENCES users (user_id)
        ON DELETE RESTRICT,
    CONSTRAINT channels_handle_check
        CHECK (handle ~ '^@[A-Za-z0-9_.-]{1,30}$'),
    CONSTRAINT channels_channel_name_check
        CHECK (length(btrim(channel_name)) > 0),
    CONSTRAINT channels_country_code_check
        CHECK (country_code ~ '^[A-Z]{2}$'),
    CONSTRAINT channels_monetization_status_check
        CHECK (monetization_status IN ('ELIGIBLE', 'NOT_ELIGIBLE', 'SUSPENDED')),
    CONSTRAINT channels_subscriber_count_check
        CHECK (subscriber_count >= 0)
);

COMMENT ON COLUMN channels.subscriber_count IS
    'Denormalized counter; subscriptions is the source of truth. Kept for R17/R02 read speed and recomputed by W04.';

-- ---------------------------------------------------------------------
-- videos: long videos and Shorts. published_at is NULL exactly for
-- PRIVATE videos; SCHEDULED videos already have a future publish time.
-- is_short and view_count are denormalized/derived columns kept for read
-- speed (R01/R10/R03) and maintained by the application (W03).
-- is_made_for_kids and view_count have defaults because W01 supplies
-- neither column; a new upload is not made-for-kids and has zero views
-- until the player increments it. description is nullable for uploads
-- without a description.
-- ---------------------------------------------------------------------
CREATE TABLE videos (
    video_id          varchar(11)  NOT NULL,
    channel_id        integer      NOT NULL,
    title             text         NOT NULL,
    description       text,
    category          text         NOT NULL,
    duration_sec      integer      NOT NULL,
    is_short          boolean      NOT NULL,
    is_made_for_kids  boolean      NOT NULL DEFAULT false,
    visibility        text         NOT NULL,
    uploaded_at       timestamptz  NOT NULL,
    published_at      timestamptz,
    view_count        bigint       NOT NULL DEFAULT 0,

    CONSTRAINT videos_pkey
        PRIMARY KEY (video_id),
    CONSTRAINT videos_channel_id_fkey
        FOREIGN KEY (channel_id) REFERENCES channels (channel_id)
        ON DELETE RESTRICT,
    CONSTRAINT videos_video_id_check
        CHECK (video_id ~ '^[A-Za-z0-9_-]{11}$'),
    CONSTRAINT videos_title_check
        CHECK (length(btrim(title)) > 0),
    CONSTRAINT videos_category_check
        CHECK (category IN ('Music', 'Gaming', 'Sports', 'Comedy', 'Cooking',
                            'Education', 'Film', 'Tech', 'Vlogs', 'News')),
    CONSTRAINT videos_duration_check
        CHECK (duration_sec > 0),
    CONSTRAINT videos_is_short_duration_check
        CHECK (NOT is_short OR duration_sec <= 60),
    CONSTRAINT videos_visibility_check
        CHECK (visibility IN ('PUBLIC', 'UNLISTED', 'PRIVATE', 'SCHEDULED')),
    CONSTRAINT videos_published_at_check
        CHECK ((visibility = 'PRIVATE' AND published_at IS NULL)
               OR (visibility <> 'PRIVATE' AND published_at IS NOT NULL)),
    CONSTRAINT videos_published_after_upload_check
        CHECK (published_at IS NULL OR published_at >= uploaded_at),
    CONSTRAINT videos_view_count_check
        CHECK (view_count >= 0)
);

COMMENT ON COLUMN videos.view_count IS
    'Denormalized counter; watch_events is the source of truth. Kept for R01/R02/R03 read speed and incremented by W03.';
COMMENT ON COLUMN videos.is_short IS
    'Derived flag (Shorts are at most 60 seconds). Kept because R10 filters on it; the CHECK keeps it consistent with duration_sec.';

-- ---------------------------------------------------------------------
-- subscriptions: M:N junction between users and channels.
-- ---------------------------------------------------------------------
CREATE TABLE subscriptions (
    user_id        integer      NOT NULL,
    channel_id     integer      NOT NULL,
    notifications  text         NOT NULL,
    subscribed_at  timestamptz  NOT NULL,

    CONSTRAINT subscriptions_pkey
        PRIMARY KEY (user_id, channel_id),
    CONSTRAINT subscriptions_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE CASCADE,
    CONSTRAINT subscriptions_channel_id_fkey
        FOREIGN KEY (channel_id) REFERENCES channels (channel_id)
        ON DELETE CASCADE,
    CONSTRAINT subscriptions_notifications_check
        CHECK (notifications IN ('ALL', 'PERSONALIZED', 'NONE'))
);

-- ---------------------------------------------------------------------
-- watch_events: one row per view. user_id is NULL for logged-out views.
-- video_id is RESTRICT because watch history is analytics history; videos
-- should be made private/removed through visibility, not hard-deleted.
-- ---------------------------------------------------------------------
CREATE TABLE watch_events (
    watch_id        bigint       NOT NULL,
    user_id         integer,
    video_id        varchar(11)  NOT NULL,
    started_at      timestamptz  NOT NULL,
    watch_seconds   integer      NOT NULL,
    device          text         NOT NULL,
    traffic_source  text         NOT NULL,

    CONSTRAINT watch_events_pkey
        PRIMARY KEY (watch_id),
    CONSTRAINT watch_events_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE SET NULL,
    CONSTRAINT watch_events_video_id_fkey
        FOREIGN KEY (video_id) REFERENCES videos (video_id)
        ON DELETE RESTRICT,
    CONSTRAINT watch_events_watch_seconds_check
        CHECK (watch_seconds >= 0),
    CONSTRAINT watch_events_device_check
        CHECK (device IN ('ANDROID', 'IOS', 'WEB', 'TV')),
    CONSTRAINT watch_events_traffic_source_check
        CHECK (traffic_source IN ('SHORTS_FEED', 'HOME', 'SUGGESTED',
                                  'EXTERNAL', 'SUBSCRIPTION', 'SEARCH'))
);

-- ---------------------------------------------------------------------
-- video_reactions: M:N junction for one reaction per user per video.
-- ---------------------------------------------------------------------
CREATE TABLE video_reactions (
    user_id     integer      NOT NULL,
    video_id    varchar(11)  NOT NULL,
    reaction    text         NOT NULL,
    reacted_at  timestamptz  NOT NULL,

    CONSTRAINT video_reactions_pkey
        PRIMARY KEY (user_id, video_id),
    CONSTRAINT video_reactions_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE CASCADE,
    CONSTRAINT video_reactions_video_id_fkey
        FOREIGN KEY (video_id) REFERENCES videos (video_id)
        ON DELETE CASCADE,
    CONSTRAINT video_reactions_reaction_check
        CHECK (reaction IN ('LIKE', 'DISLIKE'))
);

-- ---------------------------------------------------------------------
-- comments: adjacency-list threads via parent_comment_id. A reply cannot
-- be pinned, and a comment cannot be its own parent.
-- ---------------------------------------------------------------------
CREATE TABLE comments (
    comment_id         bigint       NOT NULL,
    video_id           varchar(11)  NOT NULL,
    user_id            integer      NOT NULL,
    parent_comment_id  bigint,
    body               text         NOT NULL,
    like_count         integer      NOT NULL,
    is_pinned          boolean      NOT NULL,
    created_at         timestamptz  NOT NULL,

    CONSTRAINT comments_pkey
        PRIMARY KEY (comment_id),
    CONSTRAINT comments_video_id_fkey
        FOREIGN KEY (video_id) REFERENCES videos (video_id)
        ON DELETE CASCADE,
    CONSTRAINT comments_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE CASCADE,
    CONSTRAINT comments_parent_comment_id_fkey
        FOREIGN KEY (parent_comment_id) REFERENCES comments (comment_id)
        ON DELETE CASCADE,
    CONSTRAINT comments_body_check
        CHECK (length(btrim(body)) > 0),
    CONSTRAINT comments_like_count_check
        CHECK (like_count >= 0),
    CONSTRAINT comments_pinned_reply_check
        CHECK (NOT is_pinned OR parent_comment_id IS NULL),
    CONSTRAINT comments_parent_not_self_check
        CHECK (parent_comment_id IS NULL OR parent_comment_id <> comment_id)
);

-- ---------------------------------------------------------------------
-- playlists and playlist_items.
-- playlist_items uses (playlist_id, video_id) as the PK so a video can
-- appear at most once in a playlist. Position is a separate ordering
-- attribute with a deferrable UNIQUE constraint, so positions can be
-- swapped inside a transaction without a temporary conflict.
-- ---------------------------------------------------------------------
CREATE TABLE playlists (
    playlist_id    integer      NOT NULL,
    owner_user_id  integer      NOT NULL,
    title          text         NOT NULL,
    visibility     text         NOT NULL,
    created_at     timestamptz  NOT NULL,

    CONSTRAINT playlists_pkey
        PRIMARY KEY (playlist_id),
    CONSTRAINT playlists_owner_user_id_fkey
        FOREIGN KEY (owner_user_id) REFERENCES users (user_id)
        ON DELETE CASCADE,
    CONSTRAINT playlists_title_check
        CHECK (length(btrim(title)) > 0),
    CONSTRAINT playlists_visibility_check
        CHECK (visibility IN ('PUBLIC', 'UNLISTED', 'PRIVATE'))
);

CREATE TABLE playlist_items (
    playlist_id  integer      NOT NULL,
    position     integer      NOT NULL,
    video_id     varchar(11)  NOT NULL,
    added_at     timestamptz  NOT NULL,

    CONSTRAINT playlist_items_pkey
        PRIMARY KEY (playlist_id, video_id),
    CONSTRAINT playlist_items_playlist_id_position_key
        UNIQUE (playlist_id, position) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT playlist_items_playlist_id_fkey
        FOREIGN KEY (playlist_id) REFERENCES playlists (playlist_id)
        ON DELETE CASCADE,
    CONSTRAINT playlist_items_video_id_fkey
        FOREIGN KEY (video_id) REFERENCES videos (video_id)
        ON DELETE CASCADE,
    CONSTRAINT playlist_items_position_check
        CHECK (position > 0)
);

-- ---------------------------------------------------------------------
-- ad_impressions: ads shown during a watch event. A watch can have more
-- than one ad (for example a preroll and a midroll). RESTRICT protects
-- revenue history from being deleted along with a watch event.
-- ---------------------------------------------------------------------
CREATE TABLE ad_impressions (
    impression_id  bigint         NOT NULL,
    watch_id       bigint         NOT NULL,
    ad_format      text           NOT NULL,
    revenue_inr    numeric(10,4)  NOT NULL,
    shown_at       timestamptz    NOT NULL,

    CONSTRAINT ad_impressions_pkey
        PRIMARY KEY (impression_id),
    CONSTRAINT ad_impressions_watch_id_fkey
        FOREIGN KEY (watch_id) REFERENCES watch_events (watch_id)
        ON DELETE RESTRICT,
    CONSTRAINT ad_impressions_ad_format_check
        CHECK (ad_format IN ('PREROLL', 'MIDROLL')),
    CONSTRAINT ad_impressions_revenue_check
        CHECK (revenue_inr >= 0)
);

-- Sanity: the schema is complete only if all ten tables are present.
-- (This is a development aid, not a data constraint.)
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema = 'youtube' ORDER BY table_name;
