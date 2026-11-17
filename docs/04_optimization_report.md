# Phase 4 — Optimization Report

**Team:** T0046 · Section A · Group Lead: Saksham Kachhawaha
**Phase owner:** Saksham Paliwal (2501010398, `sakshampaliwal21`)
**Database:** PostgreSQL 15.18 (Postgres.app), session timezone `Asia/Kolkata`
**Benchmark laptop:** MacBook Pro M4, 16 GB RAM (the machine named in `team.json`)
**Baseline:** `docs/03_baseline_timings.md` and `benchmarks/results/baseline/`
**Optimized evidence:** `benchmarks/results/optimized/` (`summary.csv` and `R01.txt` … `W05.txt`)

## 1. What changed

The Phase 2 schema and data are unchanged. All 30 query texts are unchanged except four rewrites:

| Query | Rewrite |
|---|---|
| R07 | Replaced `DATE(w.started_at) BETWEEN …` with half-open `timestamptz` bounds using `Asia/Kolkata` (`+05:30`), keeping the `DATE()` grouping expression so the returned days are unchanged. |
| R13 | Replaced `NOT IN` with `NOT EXISTS`. This is a correctness fix: the original returned 0 rows because the subquery contains NULL `user_id` values; the correct result is 88 rows. |
| R19 | Replaced two correlated subqueries per eligible channel with one pre-aggregated videos join and one pre-aggregated watch-events join. `LEFT JOIN` + `coalesce` preserve the original NULL/0 semantics. |
| R20 | Replaced `started_at::date BETWEEN …` with half-open `timestamptz` bounds, keeping the date grouping expression. |

Everything else is index-only optimization. The baseline and optimized runs used the **same MacBook**, the same schema/data, and the same workload file. The baseline used 3 runs per query; the optimized run used 5 runs per query (the README's `optimized 5` command). The reported number is the arithmetic mean.

Result proofs:

- R07: baseline and optimized ordered output are identical (7 day rows).
- R20: baseline and optimized ordered output are identical (30 day rows plus the SET line).
- R19: baseline and optimized both return 1087 channel rows; compared after ordering by `channel_id`, `diff` is empty.
- R13: original returns 0; optimized returns 88; the correct answer independently confirmed as 88.
- All other queries are textually unchanged, so their result sets are unchanged by construction; indexes cannot change rows.

## 2. Headline result

| Metric | Baseline | Optimized | Change |
|---|---:|---:|---:|
| Total of all 30 averages | 25,566.471 ms | 389.119 ms | **98.48% faster** |
| R19 | 25,084.082 ms | 56.159 ms | 99.78% faster |
| R13 | 31.366 ms (0 rows) | 0.804 ms (88 rows) | correctness fixed |
| Slowest remaining query | R19 25.1 s | R25 91.4 ms | under the 5 s report target |

The remaining total is dominated by full-scan reports: R25, R22, R17, R12 and R16. Those are under their 5 s targets on the seed data and are discussed in §5.

### What we observed

On the team MacBook we measured a total runtime drop from 25,566.47 ms down to 389.12 ms (98.48% faster). Almost the entire baseline run was spent in R19, where 1,087 correlated subquery loops scanned `videos` and `watch_events` for every eligible channel, taking over 25 seconds; rewriting R19 to pre-aggregate videos and watch events into single passes before joining brought it down to 56.16 ms. In R13, our investigation of why the baseline returned 0 rows revealed a silent SQL bug: 24 logged-out watch events with NULL `user_id` values caused the `NOT IN` subquery to evaluate to `UNKNOWN`, filtering out all rows. Rewriting to `NOT EXISTS` fixed the three-valued logic, returning the true 88 subscribers who never watched in 0.80 ms. We also observed the physical cost of our index set: our 15 indexes total 44 MB, with 27 MB concentrated on `watch_events` alone, which exceeds the 16 MB table heap. Single-row writes take an expected maintenance penalty, clearest in W03 (+413.5%, rising from 0.55 ms to 2.81 ms) because updating a video now touches six indexes. We accepted the W03 overhead because it remains well inside our 5 ms interactive threshold, while full-scan-heavy reports (R12, R16, R17, R22, R25) show mixed results: R12/R16/R22 are flat or mildly slower, while R17 (-27.9%) and R25 (-41.2%) are material regressions. All remain under the 5 s report target because no index can avoid reading bulk heap pages for unselective queries.

## 3. Full before/after table

Improvement % = (before − after) / before × 100. Negative values are regressions and are reported honestly. “Same result?” is about rows; R13 is the one intentional correctness change.

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|---|---:|---|---|---:|---:|:---:|
| R01 | 3.207 | Seq Scan on 30k videos | Partial `(channel_id, published_at DESC)` INCLUDE covering index on PUBLIC | 0.130 | 95.95% | Yes |
| R02 | 0.126 | PK lookups already fast | No index change | 0.080 | 36.51% | Yes |
| R03 | 5.304 | Seq Scan on videos | Subscriptions PK + `videos(channel_id, uploaded_at)` index; channels PK | 0.874 | 83.52% | Yes |
| R04 | 10.167 | Leading-wildcard `ILIKE` cannot use B-tree | `pg_trgm` GIN index on public titles | 4.704 | 53.73% | Yes |
| R05 | 15.561 | Seq Scan on 200k watch events | `(user_id, started_at DESC)` INCLUDE covering index | 0.210 | 98.65% | Yes |
| R06 | 3.494 | Seq Scan on videos | Partial `(published_at) WHERE visibility='SCHEDULED'` | 0.267 | 92.36% | Yes |
| R07 | 17.190 | `DATE()` predicate, no channel/event join index | Sargable +05:30 range + channel/event covering index | 0.399 | 97.68% | Yes |
| R08 | 9.476 | Seq Scan on watch events | `(video_id, started_at)` INCLUDE traffic/watch_seconds | 0.301 | 96.82% | Yes |
| R09 | 15.698 | Seq scans on videos/events | Channel index + covering watch-event index | 1.057 | 93.27% | Yes |
| R10 | 16.081 | Seq scans on events/videos | `started_at` index + partial Shorts index | 6.015 | 62.60% | Yes |
| R11 | 27.696 | Seq scans, window aggregation | `started_at` index; videos still scanned for category | 19.903 | 28.14% | Yes |
| R12 | 22.949 | Full event scan for device share | No useful index; full scan retained | 26.454 | -15.27% | Yes |
| R13 | 31.366 | `NOT IN` + NULL; subplan scan | `NOT EXISTS`; channel/event indexes | 0.804 | 97.44% | **No — corrected 0 → 88** |
| R14 | 17.424 | Seq scans on reactions/videos | `(video_id, reaction)` index | 0.383 | 97.80% | Yes |
| R15 | 5.015 | Seq Scan on 60k comments | `comments(video_id)` index | 0.147 | 97.07% | Yes |
| R16 | 23.145 | Seq scans on ads/events | `shown_at` INCLUDE index; watch/video PK joins | 24.232 | -4.70% | Yes |
| R17 | 24.069 | Full channel/video/event aggregation | Covering watch-event index; full aggregate remains | 30.781 | -27.89% | Yes |
| R18 | 20.014 | Hash join over all comments | Partial kids-video index + comments(video_id) | 2.241 | 88.80% | Yes |
| R19 | 25,084.082 | Two correlated subqueries × 1,087 channels | Pre-aggregated joins; channel/upload and event indexes | 56.159 | 99.78% | Yes (1087 rows) |
| R20 | 13.997 | `::date` predicate | Sargable +05:30 range + `started_at` index | 3.901 | 72.13% | Yes |
| R21 | 0.269 | Already using playlist position index | No change | 0.133 | 50.56% | Yes |
| R22 | 37.326 | Full 30k-video group by title/duration | No useful index; full scan retained | 41.024 | -9.91% | Yes |
| R23 | 27.055 | Sort of 60k comments + deep OFFSET | `(created_at DESC, comment_id DESC)` index removes sort | 5.110 | 81.11% | Yes |
| R24 | 3.116 | PK starts with user_id, channel filter weak | `(channel_id, subscribed_at)` index | 0.383 | 87.71% | Yes |
| R25 | 64.725 | Seq scans ads/events/users | No selective index found; full joins retained | 91.404 | -41.22% | Yes |
| W01 | 1.202 | Single insert | Extra video indexes add maintenance | 2.566 | -113.48% | Yes (same row effect) |
| W02 | 0.905 | Single insert | Extra watch-event indexes add maintenance | 1.738 | -92.04% | Yes |
| W03 | 0.548 | PK update | Multiple video indexes add maintenance | 2.814 | -413.50% | Yes |
| W04 | 61.400 | Full channels/subscriptions scan | Subscription channel index | 63.299 | -3.09% | Yes (3000 rows) |
| W05 | 3.864 | Seq Scan on videos | Scheduled partial index | 1.606 | 58.44% | Yes (7 rows) |
| **Total** | **25,566.471** | | | **389.119** | **98.48%** | |

## 4. Before/after plans for the five biggest wins

Full plans are in `benchmarks/results/baseline/` and `benchmarks/results/optimized/`; these are the key lines.

### R19 — 25,084.082 ms → 56.159 ms

Before: one `Seq Scan on channels` with `SubPlan 1` and `SubPlan 2`; each subplan loops 1,087 times and scans `videos`/`watch_events`. The plan reports `loops=1087`, `Execution Time: 25087.544 ms`.

After: `Hash Left Join` + `Hash Right Join`; `Index Only Scan using videos_channel_uploaded_idx`, `Seq Scan on channels` once, and one aggregate over `watch_events`. `Execution Time: 55.397 ms` on run 1; 56.159 ms average. The 1,087-row result is identical.

### R13 — 31.366 ms → 0.804 ms, and 0 rows → 88 rows

Before: `Index Scan using subscriptions_pkey`, then `Filter: (NOT (hashed SubPlan 1))`; `rows=0`, `Rows Removed by Filter: 88`; `Execution Time: 38.332 ms` on run 1.

After: `Hash Anti Join` with `rows=88`; `Bitmap Index Scan on subscriptions_channel_subscribed_idx`, `videos_channel_uploaded_idx`, and `watch_events_video_started_idx`; `Execution Time: 0.858 ms` on run 1. The original query was wrong, not merely slow.

### R23 — 27.055 ms → 5.110 ms

Before: `Sort` with `external merge Disk: 3912kB` over a `Seq Scan on comments`, then `OFFSET 30000`; `Execution Time: 26.433 ms` on run 1.

After: `Index Scan using comments_created_idx`, reading 30,025 index entries in order and stopping at `LIMIT 25`; `Execution Time: 4.985 ms` on run 1. The deep OFFSET remains O(offset); keyset pagination is a Phase 5 improvement for the large data.

### R18 — 20.014 ms → 2.241 ms

Before: `Hash Join` after `HashAggregate` over a `Seq Scan on comments` (60,000 rows) and `Seq Scan on videos`; `Execution Time: 19.856 ms` on run 1.

After: `Nested Loop Semi Join`; `Bitmap Index Scan on videos_kids_idx` (499 rows) and `Index Only Scan using comments_video_idx`; `Execution Time: 2.112 ms` on run 1.

### R14 — 17.424 ms → 0.383 ms

Before: `Hash Right Join` with `Seq Scan on video_reactions` (67,417 rows) and `Seq Scan on videos`; `Execution Time: 18.302 ms` on run 1.

After: `Nested Loop Left Join`; `Bitmap Index Scan on videos_channel_uploaded_idx` and `Bitmap Index Scan on video_reactions_video_reaction_idx`; `Execution Time: 0.461 ms` on run 1.

## 5. Queries that did not improve

These are honest results, not hidden regressions. All remain under their Phase 5 targets on the seed data.

| Query | Before | After | Why |
|---|---:|---:|---|
| R12 | 22.949 | 26.454 | The platform-wide device share must read all 200k events; a device index was tested and not chosen, so it was removed. |
| R16 | 23.145 | 24.232 | The June ad range uses `ad_impressions_shown_idx`, but the watch/video joins still read most of `watch_events`; within run-to-run noise. |
| R17 | 24.069 | 30.781 | The watch-hour aggregate covers most channels/events; the covering event index is used, but the full aggregate remains. It is under the 5 s report target. |
| R22 | 37.326 | 41.024 | Grouping all 30k videos by title/duration requires reading the whole table; no useful index. |
| R25 | 64.725 | 91.404 | No selective predicate on ads; it joins nearly all 57k ads to events/users. Under the 5 s target; a Phase 5 summary/audit table is the realistic fix. |

Two candidate indexes were deliberately **not kept**: a `watch_events(device)` covering index (R12 still chose a seq scan) and a partial top-level-comments index (R15 used `comments_video_idx` for both R15 and R18). Removing them avoids storage and write cost for no read benefit.

## 6. Write overhead

The indexes make single-row writes slower; this is the expected trade-off. All write queries still meet the 5 ms real-time target except W04, which is a 2 s batch target.

| Query | Before | After | Overhead | Acceptable? |
|---|---:|---:|---:|---|
| W01 | 1.202 | 2.566 | +1.364 ms (+113.48%) | Yes, still under 5 ms |
| W02 | 0.905 | 1.738 | +0.833 ms (+92.04%) | Yes, still under 5 ms |
| W03 | 0.548 | 2.814 | +2.266 ms (+413.50%) | Yes, still under 5 ms; W03 updates a video row and maintains several video indexes |
| W04 | 61.400 | 63.299 | +1.899 ms (+3.09%) | Yes, still under the 2,000 ms batch target; the subscription channel index helps its aggregate |
| W05 | 3.864 | 1.606 | −2.258 ms (58.44% faster) | Yes; the scheduled partial index wins |

The largest relative overhead is W03 because it updates `videos`, which now has six indexes (PK, public-channel, scheduled, channel/uploaded, short, kids). It remains below 5 ms on the seed data. If write throughput became the bottleneck, the partial/trgm indexes could be reviewed first; the short/kids indexes are small and serve specific queries.

## 7. Index storage

15 new indexes were kept. Total new index storage is **46,096,384 bytes ≈ 44 MB**; the largest indexes are on `watch_events`, which is the append-heavy table.

| Index | Size | Table | Table size |
|---|---:|---|---:|
| watch_events_video_started_idx | 13 MB | watch_events | 16 MB |
| watch_events_user_started_idx | 9704 kB | watch_events | 16 MB |
| watch_events_started_idx | 4408 kB | watch_events | 16 MB |
| subscriptions_channel_subscribed_idx | 4008 kB | subscriptions | 7112 kB |
| ad_impressions_watch_idx | 2280 kB | ad_impressions | 3808 kB |
| ad_impressions_shown_idx | 2264 kB | ad_impressions | 3808 kB |
| videos_public_channel_published_idx | 2000 kB | videos | 5072 kB |
| comments_created_idx | 1856 kB | comments | 5528 kB |
| videos_title_trgm_idx | 1656 kB | videos | 5072 kB |
| video_reactions_video_reaction_idx | 1576 kB | video_reactions | 3968 kB |
| comments_video_idx | 1152 kB | comments | 5528 kB |
| videos_channel_uploaded_idx | 936 kB | videos | 5072 kB |
| videos_short_idx | 248 kB | videos | 5072 kB |
| videos_kids_idx | 32 kB | videos | 5072 kB |
| videos_scheduled_published_idx | 16 kB | videos | 5072 kB |

The three `watch_events` indexes are about 27 MB, larger than the 16 MB heap in total because they duplicate key/covering payload. On 4M events they will grow roughly linearly; Phase 5 should re-evaluate whether the `device`/R12 and full-report paths justify all three. The two unused candidates were already removed.

## 8. Summary of techniques and why

- **Composite B-tree column order:** equality columns first, then range/order. R05 `(user_id, started_at DESC)`, R01/R03 `(channel_id, published_at DESC)`, R24 `(channel_id, subscribed_at)`.
- **Partial indexes:** PUBLIC videos, SCHEDULED videos, Shorts, made-for-kids videos. They index only the rows the query can use.
- **Covering indexes:** `INCLUDE` payload on R01/R05/R07/R08/R16 makes index-only scans possible.
- **GIN + pg_trgm:** the only way to make R04's `ILIKE '%tutorial%'` sargable without changing the query.
- **Sargable rewrites:** R07 and R20 replace functions on `started_at` in the predicate with half-open `+05:30` ranges while keeping the output date expression.
- **Set-based rewrite:** R19 removes 1,087 correlated subquery executions.
- **Correctness rewrite:** R13's `NOT EXISTS` fixes the NULL semantics.
- **No server-setting hacks, no data changes, no external caching.**

## 9. Reproducibility

```bash
createdb youtube_cp3
psql -d youtube_cp3 -v ON_ERROR_STOP=1 -f sql/01_schema.sql
unzip -o seed_data.zip
psql -d youtube_cp3 -v ON_ERROR_STOP=1 -f sql/02_load_data.sql
psql -d youtube_cp3 -v ON_ERROR_STOP=1 -f sql/05_indexes.sql
psql -d youtube_cp3 -v ON_ERROR_STOP=1 -f sql/06_optimized_queries.sql   # correctness smoke test
./benchmarks/run_benchmark.sh youtube_cp3 optimized 5 sql/06_optimized_queries.sql
```

The optimized raw plans and summary in `benchmarks/results/optimized/` are the authoritative numbers for this report. Do not re-run them on a different laptop: the baseline and optimized comparisons must use the same benchmark machine.
