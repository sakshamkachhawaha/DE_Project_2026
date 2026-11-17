# Phase 3 — Baseline Timings

**Team:** T0046 · Section A · Group Lead: Saksham Kachhawaha
**Phase owner:** Arnav Bansal (2501010643, `arnavbansal12`)
**Database:** PostgreSQL 15.18 (Postgres.app) on macOS arm64
**Benchmark laptop:** MacBook Pro M4, 16 GB RAM (the machine named in `team.json`)
**Workload:** `queries/workload_30.sql` — 25 reads (`R01`–`R25`) and 5 writes (`W01`–`W05`)
**Raw evidence:** `benchmarks/results/baseline/` (`summary.csv` and `R01.txt` … `W05.txt`)

## 1. Method

The database was recreated from the Phase 2 schema and load script, with **no indexes beyond the 14 primary-key/unique indexes that Phase 2 creates automatically**. No Phase 4 indexes were present.

```bash
createdb youtube_phase2_final
psql -d youtube_phase2_final -v ON_ERROR_STOP=1 -f sql/01_schema.sql
unzip -o seed_data.zip
psql -d youtube_phase2_final -v ON_ERROR_STOP=1 -f sql/02_load_data.sql

./benchmarks/run_benchmark.sh youtube_phase2_final baseline
```

The helper script ran every query with `EXPLAIN (ANALYZE, BUFFERS)`, three times, and recorded the `Execution Time` of each run. Writes (`W01`–`W05`) were executed inside `BEGIN … ROLLBACK`, so the loaded data was not changed. The average is the arithmetic mean of the three runs; all three raw plans are committed.

R05 shows the expected cold-cache effect: its first run was 31.268 ms while the next two were 7.789 ms and 7.626 ms. The three-run average (15.561 ms) is reported exactly as required by the protocol; do not replace it with the warm-only time.

## 2. Timing table

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Channel page: the 20 newest public videos of channel 217 | READ | 3.722 | 3.104 | 2.795 | 3.207 |
| R02: Watch page: one video with its channel | READ | 0.289 | 0.051 | 0.039 | 0.126 |
| R03: Subscriptions feed: public videos from channels user 1042 subscribes to, newest first | READ | 5.695 | 5.124 | 5.093 | 5.304 |
| R04: Search: public videos with "tutorial" in the title, most viewed first | READ | 9.740 | 9.994 | 10.768 | 10.167 |
| R05: History page: the last 50 videos user 1042 watched | READ | 31.268 | 7.789 | 7.626 | 15.561 |
| R06: Publishing service: videos scheduled to go live in the first week of July 2026 | READ | 3.790 | 3.375 | 3.318 | 3.494 |
| R07: YouTube Studio: channel 217's daily views and watch hours in June 2026 | READ | 15.810 | 16.570 | 19.190 | 17.190 |
| R08: YouTube Studio: where views of video ZkNSlUB1EOs come from | READ | 9.377 | 9.472 | 9.580 | 9.476 |
| R09: YouTube Studio: average percentage watched for each of channel 217's videos | READ | 15.781 | 15.660 | 15.652 | 15.698 |
| R10: Shorts shelf: most viewed Shorts in the last 7 days of June 2026 | READ | 15.730 | 15.790 | 16.723 | 16.081 |
| R11: Trending tab: top 5 videos per category by views in June 2026 | READ | 26.847 | 27.911 | 28.331 | 27.696 |
| R12: Growth: share of logged-out viewing per device type | READ | 23.565 | 22.793 | 22.488 | 22.949 |
| R13: Creator insights: subscribers of channel 217 who have never watched any of its videos | READ | 38.332 | 27.340 | 28.426 | 31.366 |
| R14: YouTube Studio: likes, dislikes and like ratio per video of channel 217 | READ | 18.363 | 16.925 | 16.984 | 17.424 |
| R15: Watch page: pinned comment and top 10 comments of video ZkNSlUB1EOs | READ | 6.823 | 3.972 | 4.249 | 5.015 |
| R16: Finance: ad revenue per channel in June 2026, top 20 | READ | 26.250 | 21.770 | 21.416 | 23.145 |
| R17: Partner program: NOT_ELIGIBLE channels that now have 100+ subscribers and 40+ watch hours | READ | 24.285 | 23.856 | 24.067 | 24.069 |
| R18: Child safety: "made for kids" videos that still have comments (comments must be disabled) | READ | 19.991 | 20.527 | 19.524 | 20.014 |
| R19: Partner report: for every monetized channel, its latest upload and its total views | READ | 25087.544 | 25083.295 | 25081.407 | 25084.082 |
| R20: Platform analytics: daily watch hours and running total for June 2026 | READ | 14.037 | 14.034 | 13.920 | 13.997 |
| R21: Playlist page: playlist 501 in order | READ | 0.634 | 0.088 | 0.084 | 0.269 |
| R22: Copyright team: same title and duration uploaded by more than one channel | READ | 37.541 | 36.647 | 37.790 | 37.326 |
| R23: Moderation queue: all comments, newest first, page 1,201 (25 per page) | READ | 26.433 | 26.841 | 27.891 | 27.055 |
| R24: YouTube Studio: new subscribers per month for channel 217 | READ | 3.536 | 2.927 | 2.886 | 3.116 |
| R25: Premium audit: ads that were shown to users with an active Premium membership | READ | 62.873 | 64.335 | 66.966 | 64.725 |
| W01: Upload: a new public video on channel 217 | WRITE | 2.191 | 0.701 | 0.713 | 1.202 |
| W02: Player: record a view of video ZkNSlUB1EOs by user 1042 | WRITE | 1.281 | 0.731 | 0.704 | 0.905 |
| W03: View counter: add one view to video ZkNSlUB1EOs | WRITE | 0.979 | 0.366 | 0.300 | 0.548 |
| W04: Nightly job: recompute every channel's subscriber count | WRITE | 59.035 | 69.390 | 55.774 | 61.400 |
| W05: Publishing service: make scheduled videos public once their time has come (run at 3 Jul 2026 00:00) | WRITE | 4.229 | 3.684 | 3.678 | 3.864 |
| **Total (sum of all 30 averages)** | | | | | **25566.471** |

R19 accounts for **25,084.082 ms of the 25,566.471 ms total (98.1%)**. Excluding R19, all 29 other queries total 482.389 ms.

## 3. Scan type and reason per query

The scan types below are from the committed raw plans. `Seq Scan` on a large table is not automatically an error: some queries must read most of a table, while others are slow because a usable index is missing.

| Query | Scan type from the plan | Why it is slow or fast |
|---|---|---|
| R01 | Seq Scan on videos | No index on `(channel_id, visibility, published_at)`; reads 30,000 videos and sorts for the top 20. |
| R02 | Index Scan using `videos_pkey`; Index Scan using `channels_pkey` | Two primary-key point lookups; the fastest query in the workload. |
| R03 | Seq Scan on videos; Index Only Scan using `subscriptions_pkey`; Index Scan using `channels_pkey` | Needs `(channel_id, visibility, published_at)` on videos; currently scans all 30,000 videos. |
| R04 | Seq Scan on videos | Leading-wildcard `ILIKE '%tutorial%'` cannot use a normal B-tree; scans all titles. |
| R05 | Seq Scan on watch_events; Index Scan using `videos_pkey` | No `(user_id, started_at)` index; scans 200,000 events. Run 1 is a cold-cache outlier (31.268 ms). |
| R06 | Seq Scan on videos | No partial index for `visibility = 'SCHEDULED'`; scans 30,000 videos to find 19 rows. |
| R07 | Seq Scan on watch_events; Seq Scan on videos | `DATE(started_at)` is non-sargable and there is no video-channel join index; reads both large tables. |
| R08 | Seq Scan on watch_events | No index on `video_id`; scans 200,000 events to aggregate 14 rows for one video. |
| R09 | Seq Scan on watch_events; Seq Scan on videos | No channel/video join index; aggregates channel 217's events after scanning both tables. |
| R10 | Seq Scan on watch_events; Seq Scan on videos | No `is_short`/`started_at` support; scans and filters the event and video tables. |
| R11 | Seq Scan on watch_events; Seq Scan on videos | June window plus grouping and `RANK()` over 200,000 events and 30,000 videos. |
| R12 | Seq Scan on watch_events | Must read every event to group by device; a full scan is expected for this platform-wide metric. |
| R13 | Index Scan using `subscriptions_pkey`; Seq Scan on watch_events; Seq Scan on videos | The `NOT IN` subquery contains NULL `user_id`s, so the query returns 0 rows instead of 88; the plan also scans both large tables. |
| R14 | Seq Scan on video_reactions; Seq Scan on videos | No `(video_id, reaction)` index; scans 67,417 reactions and 30,000 videos. |
| R15 | Seq Scan on comments | No composite index for video, top-level comments and ordering; scans 60,000 comments. |
| R16 | Seq Scan on ad_impressions; Seq Scan on watch_events; Index Scan using `videos_pkey` | No `shown_at` index; joins 57,014 ads to 200,000 watch events. |
| R17 | Seq Scan on channels; Seq Scan on videos; Seq Scan on watch_events | Full aggregation of watch hours for every NOT_ELIGIBLE channel; scans all three tables. |
| R18 | Seq Scan on comments; Seq Scan on videos | `EXISTS` semi-join over 60,000 comments; no partial index for made-for-kids videos. |
| R19 | Seq Scan on channels; correlated subplans scan videos and watch_events | Two subqueries run once per eligible channel (1,087 loops); this is the intentional multi-second query. |
| R20 | Seq Scan on watch_events | `started_at::date` is non-sargable; scans 200,000 events for the June aggregation. |
| R21 | Index Scan using `playlist_items_playlist_id_position_key`; Index Scan using `videos_pkey` | The unique position index provides playlist 501's order; only 11 items, so this is fast. |
| R22 | Seq Scan on videos | Groups all 30,000 videos by title and duration; the whole table must be read. |
| R23 | Seq Scan on comments; Sort | `OFFSET 30000` still scans/sorts 60,000 comments; the deep offset is the problem. |
| R24 | Index Scan using `subscriptions_pkey` | `channel_id = 217` uses the leading column of the composite PK; only 88 rows. |
| R25 | Seq Scan on ad_impressions; Seq Scan on watch_events; Seq Scan on users | No time/Premium index; joins 57,014 ads to 200,000 watches and 30,000 users. |
| W01 | Insert (no scan) | Single-row insert. The first run (2.191 ms) includes cold overhead; later runs are about 0.7 ms. |
| W02 | Insert (no scan) | Single-row insert into `watch_events`; no scan. |
| W03 | Index Scan using `videos_pkey`; Update | Primary-key update of one counter row. |
| W04 | Seq Scan on channels; Seq Scan on subscriptions; Update | Recomputes all 3,000 channels from 129,253 subscriptions; full scans plus 3,000 updates. |
| W05 | Seq Scan on videos; Update | No partial index on `visibility = 'SCHEDULED'`; scans 30,000 videos and updates 7. |

## 4. Observations for Phase 4

- **R19 is the dominant cost.** 25.0 seconds out of 25.6 seconds total. It runs two correlated subqueries for each of 1,087 eligible channels. A set-based rewrite and supporting indexes should be the first priority.
- **R13 is the wrong-result query.** The baseline returns 0 rows, but the correct answer is 88. The subquery includes NULL `user_id` values from logged-out watch events, so `NOT IN` evaluates to `UNKNOWN`. This is a Phase 4 correctness fix, not a regression.
- **R05 includes a cold-cache first run.** Keep the three-run average as the protocol requires; do not silently use only the warm runs.
- **Some scans are legitimate.** R12 must group every watch event by device and R22 must group every video by title/duration. Phase 4 should report these honestly rather than adding indexes that do not help.
- **Several queries are already fast.** R02, R21, W01, W02 and W03 are under 1.3 ms; they mainly need to stay fast, not be “optimized.”
- **The baseline has no Phase 4 indexes.** Only the 14 PK/UNIQUE indexes from Phase 2 exist. This is the correct starting point for the before/after comparison.
