# Phase 1: Problem Understanding & Workload Classification

This document breaks down the 9 database performance issues (P1–P9) reported across YouTube India, mapping each to its real business context, affected stakeholders, query requirements, and workload classification.

---

## 1. Problem Breakdown (P1–P9)

### P1: Core Browsing and Watch Pages
- **Business Context:** The watch page, channel page, and playlists are the most visited parts of the platform. Loading video metadata, channel handles, subscriber counts, the pinned comment, top comments, or playlist order must feel instant. Without indexes on foreign keys (`channel_id`, `video_id`, `playlist_id`), Postgres scans full tables, causing high latency and viewer drop-off.
- **Stakeholders:** Viewers, Content Creators.
- **Classification:** Customer-Facing / Real-Time (Target: < 5 ms).
- **Related Queries:** `R01`, `R02`, `R15`, `R21`.

### P2: Subscriptions Feed & Watch History
- **Business Context:** Active users constantly check their feed for new uploads and revisit their watch history. Query `R03` joins subscriptions, videos, and channels to find recent uploads, while `R05` pulls the last 50 watch events for a user. Without composite indexes on `(user_id, started_at)` and `(channel_id, published_at)`, filtering large event tables takes several seconds per user.
- **Stakeholders:** Logged-in Viewers.
- **Classification:** Customer-Facing / Real-Time (Target: < 5 ms).
- **Related Queries:** `R03`, `R05`.

### P3: Video Title Search
- **Business Context:** Viewers rely on search to discover content. Query `R04` performs case-insensitive substring matching (`ILIKE '%tutorial%'`) ordered by `view_count`. Standard B-trees cannot index leading wildcards, forcing a sequential scan across all video titles on every search request.
- **Stakeholders:** Viewers, Creators.
- **Classification:** Customer-Facing / Interactive Search (Target: < 250 ms).
- **Related Queries:** `R04`.

### P4: Creator Studio Analytics
- **Business Context:** Creators need responsive studio dashboards to check daily view counts, watch hours, traffic sources, audience retention percentages, like/dislike ratios, and subscriber gains. These queries aggregate large chunks of `watch_events` and `video_reactions`. While not real-time like video playback, lagging charts make the creator portal feel broken.
- **Stakeholders:** Creators, YouTube Studio Team.
- **Classification:** Reporting / Interactive Analytics (Target: < 250 ms).
- **Related Queries:** `R07`, `R08`, `R09`, `R14`, `R24`.

### P5: Inactive Subscriber Report Bug
- **Business Context:** Creators want to see subscribers who have never watched any of their videos. Currently, this report always returns zero rows. This is caused by a SQL three-valued logic bug: `watch_events` contains rows with `NULL` `user_id` (from logged-out viewers), causing `NOT IN (SELECT user_id ...)` to evaluate to unknown/empty. Fixing this logic and indexing the join is required for clean creator analytics.
- **Stakeholders:** Creators, Studio Team.
- **Classification:** Reporting / Interactive Analytics (Target: < 250 ms).
- **Related Queries:** `R13`.

### P6: Trending Tab & Shorts Shelf
- **Business Context:** The Shorts shelf and category Trending feeds highlight viral content over rolling time windows (e.g., top Shorts in the last 7 days, top 5 videos per category using `RANK()`). These heavy aggregation queries scan hundreds of thousands of recent watch events. They run on a periodic schedule; if recomputation lags, recommendations become stale.
- **Stakeholders:** Viewers, Creators, Recommendations Team.
- **Classification:** Reporting / Periodic Analytics (Target: < 5,000 ms).
- **Related Queries:** `R10`, `R11`.

### P7: Video Publishing & Transactional Counters
- **Business Context:** This is the core write pipeline. Creators upload videos (`W01`), a background publishing worker scans for scheduled videos whose release time has arrived (`R06`, `W05`), viewers log watch events (`W02`), and view counts increment on playback (`W03`). If publishing sweeps are slow, scheduled videos go live late. High-frequency counter updates also risk row-level locking bottlenecks under heavy traffic.
- **Stakeholders:** Creators, Viewers, Publishing Service.
- **Classification:** Customer-Facing OLTP Writes & Ingestion (Writes < 5 ms, Worker Sweeps < 250 ms).
- **Related Queries:** `R06`, `W01`, `W02`, `W03`, `W05`.

### P8: Partner Program Eligibility & Premium Audits
- **Business Context:** Finance needs to calculate monthly ad payouts per channel (`R16`), identify unmonetized channels crossing the 100-subscriber / 40-hour threshold (`R17`), sync subscriber totals (`W04`), and audit whether ads were mistakenly shown to paying Premium users (`R25`). Showing ads to Premium members violates subscription agreements, making reliable audit reports critical.
- **Stakeholders:** Monetized Creators, Finance Team, Premium Subscribers, Advertisers.
- **Classification:** Reporting / Financial Audits & Nightly Batch (Reports < 5,000 ms, Batch `W04` < 2,000 ms).
- **Related Queries:** `R16`, `R17`, `R19`, `R25`, `W04`.

### P9: Safety Compliance, Copyright & Scaling
- **Business Context:** Trust & Safety must enforce COPPA compliance by catching "Made for Kids" videos that still have comments enabled (`R18`). Legal needs to detect potential copyright infringement where different channels upload identical titles and durations (`R22`). Moderators review flagged comments page-by-page, where deep offset pagination (`R23` at `OFFSET 30000`) crawls. Meanwhile, platform growth tracks logged-out viewing shares (`R12`) and total watch hours (`R20`) to prepare for 20× data growth.
- **Stakeholders:** Trust & Safety, Legal/Copyright, Content Moderators, System Architects.
- **Classification:** Reporting / Legal, Safety & Platform Analytics (Target: < 5,000 ms).
- **Related Queries:** `R12`, `R18`, `R20`, `R22`, `R23`.

---

## 2. Workload Classification Summary

| Workload Group | Target SLA | Queries | Workload Behavior |
|---|---|---|---|
| **Customer-Facing Real-Time** | < 5 ms | R01, R02, R03, R05, R15, R21, W01, W02, W03 | High-frequency point lookups, single-row inserts, fast counter increments. |
| **Interactive Studio & Search** | < 250 ms | R04, R06, R07, R08, R09, R13, R14, R24, W05 | Filtered channel aggregates, text search, scheduled state transitions. |
| **Reporting & Analytical Audits** | < 5,000 ms | R10, R11, R12, R16, R17, R18, R19, R20, R22, R23, R25 | Multi-table joins, window functions (`RANK()`, `SUM() OVER`), multi-day scans. |
| **Batch Maintenance** | < 2,000 ms | W04 | Bulk periodic synchronization across the entire channel table. |

---

## 3. Assumptions

1. **Anonymous Viewing:** `watch_events.user_id` is nullable because logged-out users can watch videos. Subqueries referencing `user_id` must handle nulls safely (e.g. `NOT EXISTS` instead of `NOT IN`).
2. **Workload Isolation:** Customer-facing queries (watch pages, feeds) cannot be blocked by long-running analytical queries (finance reports, moderation pagination).
3. **Write vs. Read Volume:** View events (`W02`) and view count increments (`W03`) happen millions of times more often than video uploads (`W01`). Indexes on `watch_events` and `videos` must not create excessive write overhead.
4. **Scale Expectation:** All schema designs and query optimization strategies must handle a 20× increase in data volume (approx. 4 million watch events) while still meeting SLA targets.
