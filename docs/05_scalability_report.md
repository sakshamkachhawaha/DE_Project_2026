# Phase 5 / CP4 — Scalability Report & Partitioning Evaluation

**Project:** Team T0046 — YouTube Video Sharing Database  
**Academic Year:** B.Tech 2nd Year, Database Management Systems (2026)  
**Section:** A · **Group Lead:** Saksham Kachhawaha  
**Phase 5 Owner:** Barnak Das (Phase 5 Lead)  
**Contributing Members:** Saksham Paliwal, Arnav Bansal, Saksham Kachhawaha  

**Target Database:** `youtube_large` (PostgreSQL 18.6 Postgres.app on macOS `aarch64-apple-darwin23.6.0`, 64-bit)  
**Historical Baseline Environment:** `youtube_cp3` / `youtube_phase2_final` (documented as PostgreSQL 15.18 Postgres.app)  
**Session Configuration:** `shared_buffers = 128MB`, `work_mem = 4MB`, `maintenance_work_mem = 64MB`, `max_parallel_workers_per_gather = 2`, `session timezone = Asia/Kolkata (+05:30)`  
**Client Interface:** `psql` 17.11 (Homebrew)  
**Benchmark Machine:** Apple MacBook Pro, Apple M4 SoC, 16 GB Unified Memory  
**Target File:** [`docs/05_scalability_report.md`](05_scalability_report.md)  
**Primary Evidence Artifacts:**  
- Seed Baseline Timings: [`docs/03_baseline_timings.md`](03_baseline_timings.md) & [`benchmarks/results/baseline/`](../benchmarks/results/baseline)  
- Seed Optimized Evidence: [`docs/04_optimization_report.md`](04_optimization_report.md) & [`benchmarks/results/optimized/`](../benchmarks/results/optimized)  
- Large Dataset Workload Evidence: [`benchmarks/results/large/summary.csv`](../benchmarks/results/large/summary.csv) & [`benchmarks/results/large/`](../benchmarks/results/large)  
- Partitioning DDL Implementation: [`sql/08_partitioning.sql`](../sql/08_partitioning.sql)  
- Controlled Partition Comparison: [`benchmarks/results/partitioned/comparison_summary.csv`](../benchmarks/results/partitioned/comparison_summary.csv), [`benchmarks/results/partitioned/w02_diagnostic.txt`](../benchmarks/results/partitioned/w02_diagnostic.txt), and [`benchmarks/results/partitioned/run.log`](../benchmarks/results/partitioned/run.log)

---

## Executive Summary

Phase 5 evaluates the scalability, physical storage footprint, and query performance of the YouTube Video Sharing Database when subjected to institutional-scale data volumes. The institutional dataset expands production volume by approximately **$20.02\times$**, scaling from **640,689 rows** in the seed benchmark to **12,828,190 rows**, anchored by **4,000,000 watch events**, **2,598,598 subscriptions**, and **1,200,000 comments**.

This report evaluates two primary database configurations:
1. **Secondary Indexing and Workload Scaling on Monolithic Tables:** The 15 secondary indexes and four query rewrites developed in Phase 4 were executed against the full $12.8\text{M}$-row dataset in `youtube_large`. Under single-client benchmark testing, total execution time across all 30 queries scaled from **$389.12\text{ ms}$** on seed data to **$3,269.41\text{ ms}$** on large data—an aggregate observed timing growth ratio of **$8.40\times$** for a $20.02\times$ row expansion. Every query met its documented single-client SLA threshold:
   - **Real-Time / Viewer-Facing Queries (SLA $< 5\text{ ms}$):** All 9 operations executed in under $2.3\text{ ms}$ (e.g., [`R01`](../benchmarks/results/large/R01.txt) at $0.371\text{ ms}$, [`R05`](../benchmarks/results/large/R05.txt) at $0.507\text{ ms}$, [`W02`](../benchmarks/results/large/W02.txt) at $1.177\text{ ms}$).
   - **Interactive Studio & Search Queries (SLA $< 250\text{ ms}$):** All 9 operations executed in under $40\text{ ms}$ (e.g., [`R04`](../benchmarks/results/large/R04.txt) GIN trigram search at $39.340\text{ ms}$, [`R07`](../benchmarks/results/large/R07.txt) at $4.200\text{ ms}$).
   - **Reporting & Analytical Queries (SLA $< 5,000\text{ ms}$):** All 11 operations completed within limits (slowest was [`R19`](../benchmarks/results/large/R19.txt) at $622.161\text{ ms}$).
   - **Batch Maintenance (SLA $< 2,000\text{ ms}$):** Nightly subscriber recomputation ([`W04`](../benchmarks/results/large/W04.txt)) completed in $811.345\text{ ms}$.

2. **Controlled Declarative RANGE Partitioning Evaluation:** In Stage 6B and 6C, an isolated experimental copy of `watch_events` was established in schema `youtube_part` using PostgreSQL declarative RANGE partitioning by `started_at` across **18 contiguous monthly child partitions** (January 2025 through June 2026). A controlled, counterbalanced benchmark suite (5 to 7 paired runs) compared monolithic heap execution directly against partitioned execution under identical data and index configurations:
   - **Partition Pruning Speedups:** For queries bounded by narrow date ranges, static partition pruning eliminates 17 of 18 partitions, yielding direct performance gains: [`R07`](../benchmarks/results/partitioned/R07_partitioned.txt) achieved a **$+22.26\%$ speedup** ($0.324\text{ ms} \rightarrow 0.265\text{ ms}$ median; cold run 1 dropped from $49.0\text{ ms}$ to $8.9\text{ ms}$), and [`R20`](../benchmarks/results/partitioned/R20_partitioned.txt) achieved a **$+9.61\%$ speedup** ($46.842\text{ ms} \rightarrow 42.737\text{ ms}$) as the planner substituted a sequential scan over the single 219k-row child partition for an index scan.
   - **Partitioning Regressions & Planner Behavior:** Partitioning is not a universal performance accelerator. For queries filtering on non-partition keys, partitioning imposes substantial overhead: [`R17`](../benchmarks/results/partitioned/R17_partitioned.txt) experienced a **$-79.51\%$ regression** ($100.55\text{ ms} \rightarrow 490.82\text{ ms}$) because the engine executed an `Append` node scanning all 18 child partition indexes for each of 58,849 outer video loops, increasing buffer hits from 320k to **3.19 million**. Furthermore, partition-level cost misestimations triggered an optimizer plan flip in [`R11`](../benchmarks/results/partitioned/R11_partitioned.txt), causing a **$-48.17\%$ regression** ($177.66\text{ ms} \rightarrow 342.78\text{ ms}$) when the planner selected a Nested Loop with 173,632 Memoize cache misses over a Parallel Hash Join.
   - **Boundary Enforcement (W02 Diagnostic):** The runner verified strict partition routing. Attempting an out-of-bounds insert on `2026-07-01 19:00:00+05:30` triggered canonical `SQLSTATE 23514 (check_violation)` with zero rows leaked into storage, certified by bidirectional `EXCEPT ALL` diffs.

---

## 1. Institutional Dataset Scale & Benchmark Environment

### 1.1 Dataset Volume Expansion

The institutional dataset expands production volume by approximately $20\times$ over the Phase 2/3/4 seed data. Table-by-table record counts were independently verified using `sql/02_load_large_data.sql`:

| Table Name | Entity Description | Seed Rows | Large Dataset Rows | Row Growth Factor |
|---|---|---:|---:|---:|
| `users` | Registered viewer accounts | 30,000 | 600,000 | $20.00\times$ |
| `channels` | Creator channels | 3,000 | 60,000 | $20.00\times$ |
| `videos` | Uploaded long videos & Shorts | 30,000 | 600,000 | $20.00\times$ |
| `subscriptions` | User-to-channel subscription graph | 129,253 | 2,598,598 | $20.10\times$ |
| `watch_events` | Monolithic video playback fact relation | 200,000 | 4,000,000 | $20.00\times$ |
| `video_reactions` | Likes and dislikes | 67,417 | 1,350,452 | $20.03\times$ |
| `comments` | Video comments & reply hierarchy | 60,000 | 1,200,000 | $20.00\times$ |
| `playlists` | User-curated playlists | 8,000 | 160,000 | $20.00\times$ |
| `playlist_items` | Ordered playlist item mappings | 56,005 | 1,120,003 | $20.00\times$ |
| `ad_impressions` | Monetized ad display & revenue events | 57,014 | 1,139,137 | $19.98\times$ |
| **Total Database Records** | **All 10 Relational Tables** | **640,689** | **12,828,190** | **$20.02\times$** |

### 1.2 Benchmark Execution Environment & Methodology Disclosures

All measurements were conducted locally on the official team benchmark hardware:
- **Processor & Architecture:** Apple M4 SoC (8-core CPU, 10-core GPU, ARM64 `aarch64-apple-darwin23.6.0`).
- **Memory & Storage:** 16 GB Unified Memory; high-speed Apple APFS solid-state NVMe storage.
- **Server Engine:** PostgreSQL 18.6 (Postgres.app distribution), compiled for ARM64 64-bit.
- **Client Protocol:** `psql` 17.11 (Homebrew release), connected via Unix domain socket.
- **Server Configuration Parameters:**
  - `shared_buffers = 128MB`
  - `work_mem = 4MB`
  - `maintenance_work_mem = 64MB`
  - `max_parallel_workers_per_gather = 2`
  - `TimeZone = 'Asia/Kolkata'` (`+05:30` offset matching all dataset timestamps).

> [!NOTE]
> **Methodological Disclosure on Cross-Phase Comparison:**  
> Phase 3 (baseline) and Phase 4 (optimized seed) benchmarks were executed under PostgreSQL 15.18 using 5 runs per query. The Phase 5 large dataset evaluation was executed under PostgreSQL 18.6 using 3 runs per query with `EXPLAIN (ANALYZE, BUFFERS)` per faculty instructions. While the historical seed environment is documented as PostgreSQL 15.18, this runtime version cannot be independently verified from static artifacts alone. Furthermore, PostgreSQL 18 includes engine-level scheduler and JIT enhancements. Consequently, timing comparisons between seed and large data represent observed empirical benchmark growth, not strict controlled experiments across isolated data volume variables alone.

---

## 2. Large Dataset Workload Performance & SLA Compliance

### 2.1 Master Workload Results Table

The 30 workload queries defined in [`queries/workload_30.sql`](../queries/workload_30.sql) (incorporating the four verified rewrites in [`sql/06_optimized_queries.sql`](../sql/06_optimized_queries.sql)) were executed against `youtube_large`. Timing results from [`benchmarks/results/large/summary.csv`](../benchmarks/results/large/summary.csv) (arithmetic mean of 3 runs) are compared against seed optimized numbers from [`benchmarks/results/optimized/summary.csv`](../benchmarks/results/optimized/summary.csv) (arithmetic mean of 5 runs):

| Query ID | Query Type & Business Description | Seed Avg (ms) | Large Avg (ms) | Observed Ratio $R = \frac{T_{\text{large}}}{T_{\text{seed}}}$ | Target SLA | Meets Target? | Primary Scan Nodes (Large Dataset) |
|---|---|---:|---:|---:|---:|:---:|---|
| **R01** | Channel page: 20 newest public videos | 0.130 | 0.371 | $2.85\times$ | $< 5.0\text{ ms}$ | **YES** | Bitmap Scan on `videos_public_channel_published_idx` |
| **R02** | Watch page: video metadata + channel | 0.080 | 0.210 | $2.62\times$ | $< 5.0\text{ ms}$ | **YES** | Index Scan on `videos_pkey` & `channels_pkey` |
| **R03** | Subscriptions feed: newest public uploads | 0.874 | 0.706 | $0.81\times$ | $< 5.0\text{ ms}$ | **YES** | Index Only Scan on `subscriptions_pkey`, Index Scan on `videos_channel_uploaded_idx` |
| **R04** | Title search: `ILIKE '%tutorial%'` | 4.704 | 39.340 | $8.36\times$ | $< 250.0\text{ ms}$ | **YES** | Bitmap Heap Scan using `videos_title_trgm_idx` (GIN) |
| **R05** | Watch history: last 50 viewed videos | 0.210 | 0.507 | $2.41\times$ | $< 5.0\text{ ms}$ | **YES** | Index Only Scan on `watch_events_user_started_idx` |
| **R06** | Publishing: scheduled for early July 2026 | 0.267 | 0.592 | $2.22\times$ | $< 250.0\text{ ms}$ | **YES** | Bitmap Scan on `videos_scheduled_published_idx` |
| **R07** | Studio: daily views/hours in June 2026 | 0.399 | 4.200 | $10.53\times$ | $< 250.0\text{ ms}$ | **YES** | Bitmap Scan on `videos_channel_uploaded_idx`, Index Only Scan on `watch_events_video_started_idx` |
| **R08** | Studio: traffic sources for single video | 0.301 | 0.144 | $0.48\times$ | $< 250.0\text{ ms}$ | **YES** | Index Only Scan on `watch_events_video_started_idx` |
| **R09** | Studio: average watch percentage | 1.057 | 0.513 | $0.49\times$ | $< 250.0\text{ ms}$ | **YES** | Bitmap Scan on `videos_channel_uploaded_idx`, Index Only Scan on `watch_events_video_started_idx` |
| **R10** | Shorts shelf: top viewed in last 7 days | 6.015 | 28.206 | $4.69\times$ | $< 5,000.0\text{ ms}$ | **YES** | Index Scan on `watch_events_started_idx` & `videos_short_idx` |
| **R11** | Trending tab: top 5 per category | 19.903 | 175.222 | $8.80\times$ | $< 5,000.0\text{ ms}$ | **YES** | Parallel Seq Scan on `videos`, Parallel Index Scan on `watch_events_started_idx` |
| **R12** | Growth: logged-out device share | 26.454 | 146.318 | $5.53\times$ | $< 5,000.0\text{ ms}$ | **YES** | Parallel Seq Scan on `watch_events` (4M rows) |
| **R13** | Insights: subscribers who never watched | 0.804 | 2.490 | $3.10\times$ | $< 250.0\text{ ms}$ | **YES** | Hash Anti Join via `subscriptions_channel_subscribed_idx`, `videos_channel_uploaded_idx`, `watch_events_video_started_idx` |
| **R14** | Studio: likes/dislikes ratio per video | 0.383 | 4.244 | $11.08\times$ | $< 250.0\text{ ms}$ | **YES** | Bitmap Scan on `videos_channel_uploaded_idx` & `video_reactions_video_reaction_idx` |
| **R15** | Watch page: pinned & top 10 comments | 0.147 | 0.146 | $0.99\times$ | $< 5.0\text{ ms}$ | **YES** | Index Scan using `comments_video_idx` |
| **R16** | Finance: top 20 channels by ad revenue | 24.232 | 173.005 | $7.14\times$ | $< 5,000.0\text{ ms}$ | **YES** | Seq Scan on `watch_events`, Index Only Scan on `ad_impressions_shown_idx`, PK on `videos` |
| **R17** | Partner: channels nearing monetization | 30.781 | 192.360 | $6.25\times$ | $< 5,000.0\text{ ms}$ | **YES** | Parallel Seq Scan on `videos` & `channels`, Index Only Scan on `watch_events_video_started_idx` |
| **R18** | Trust: comments on made-for-kids videos | 2.241 | 32.431 | $14.47\times$ | $< 5,000.0\text{ ms}$ | **YES** | Index Scan on `videos_kids_idx`, Index Only Scan on `comments_video_idx` |
| **R19** | Partner: latest upload & total views | 56.159 | 622.161 | $11.08\times$ | $< 5,000.0\text{ ms}$ | **YES** | Hash Left Joins; Index Scan on `channels_pkey`, Index Only Scan on `videos_channel_uploaded_idx`, Seq Scan on `watch_events` |
| **R20** | Platform: daily & running watch hours | 3.901 | 47.255 | $12.11\times$ | $< 5,000.0\text{ ms}$ | **YES** | Index Scan using `watch_events_started_idx` |
| **R21** | Playlist page: playlist 501 in order | 0.133 | 0.263 | $1.98\times$ | $< 5.0\text{ ms}$ | **YES** | Index Scan on `playlist_items_playlist_id_position_key`, Index Scan on `videos_pkey` |
| **R22** | Copyright: duplicate title & duration | 41.024 | 506.086 | $12.34\times$ | $< 5,000.0\text{ ms}$ | **YES** | Seq Scan on `videos` (600k rows), single-threaded |
| **R23** | Moderation: page 1,201 (OFFSET 30000) | 5.110 | 5.508 | $1.08\times$ | $< 5,000.0\text{ ms}$ | **YES** | Index Scan using `comments_created_idx` |
| **R24** | Studio: monthly new subscribers | 0.383 | 0.256 | $0.67\times$ | $< 250.0\text{ ms}$ | **YES** | Index Only Scan on `subscriptions_channel_subscribed_idx` |
| **R25** | Premium audit: ads shown to members | 91.404 | 460.058 | $5.03\times$ | $< 5,000.0\text{ ms}$ | **YES** | Parallel Seq Scan on `watch_events`, `ad_impressions`, and `users` |
| **W01** | Write: upload new public video | 2.566 | 2.201 | $0.86\times$ | $< 5.0\text{ ms}$ | **YES** | Single-row insert into `videos` (maintains 6 indexes) |
| **W02** | Write: record video playback event | 1.738 | 1.177 | $0.68\times$ | $< 5.0\text{ ms}$ | **YES** | Single-row insert into `watch_events` (maintains 4 indexes) |
| **W03** | Write: increment video view counter | 2.814 | 1.088 | $0.39\times$ | $< 5.0\text{ ms}$ | **YES** | Single-row update via `videos_pkey` |
| **W04** | Batch: nightly subscriber recount | 63.299 | 811.345 | $12.82\times$ | $< 2,000.0\text{ ms}$ | **YES** | Seq Scan on `channels` (60k) and `subscriptions` (2.6M) |
| **W05** | Batch: publish due scheduled videos | 1.606 | 11.005 | $6.85\times$ | $< 250.0\text{ ms}$ | **YES** | Bitmap Scan on `videos_scheduled_published_idx` |
| **Total** | **Full Workload Suite (30 Queries)** | **389.119** | **3,269.408** | **$8.40\times$** | **—** | **YES** | **100% SLA Target Compliance Across All Queries** |

---

### 2.2 Growth Analysis (Observed Benchmark Growth Ratio $R = \frac{T_{\text{large}}}{T_{\text{seed}}}$)

Per the requirements of [`README.md`](../README.md) §5.3, queries are evaluated by grouping them according to how observed execution times scaled when the underlying dataset expanded $20.02\times$ by total rows.

The faculty specification establishes three conceptual growth archetypes:
1. *Stayed about the same* (e.g., index lookups where execution time scales with B-tree depth $\log N$);
2. *Grew about 20×* (queries that read a fixed share of the table, scaling roughly with data volume);
3. *Grew more than 20×* (queries that degrade super-linearly, such as unindexed nested-loop joins).

Because [`README.md`](../README.md) §5.3 specifies conceptual categories rather than prescribed numerical cutoffs, this report defines continuous, non-overlapping operational intervals to classify the observed results:
- **Stayed About the Same:** $R \le 3.5\times$
- **Grew with Data Volume (Faculty's $\approx 20\times$ Category):** $3.5\times < R \le 20.0\times$
- **Grew More than Data Volume:** $R > 20.0\times$

```mermaid
pie title Query Distribution by Observed Timing Growth Ratio (R = T_large / T_seed)
    "Stayed About the Same (R <= 3.5x)" : 15
    "Grew with Data Volume (3.5x < R <= 20x)" : 15
    "Grew More than 20x (R > 20x)" : 0
```

> [!IMPORTANT]
> **Operational Boundary & Complexity Qualifications:**  
> - **Operational Thresholds vs. Conceptual Guidance:** The numerical boundaries ($3.5\times$ and $20.0\times$) are report-defined operational boundaries chosen by the team to segment the empirical results, not rigid cutoffs mandated by the faculty. In the measured data, a wide natural gap exists between the highest Group 1 ratio ($3.10\times$ for [`R13`](../benchmarks/results/large/R13.txt)) and the lowest Group 2 ratio ($4.69\times$ for [`R10`](../benchmarks/results/large/R10.txt)). Every measured query falls unambiguously into its respective category without edge ambiguity.
> - **Conceptual Benchmark Scaling:** The faculty's "grew about 20×" category serves as a conceptual baseline against the $20.02\times$ table row expansion; it does not require queries to scale by an exact factor of $20.00\times$. Observed plan features, including multi-core parallel execution where verified and selective date-range predicates, are plausible contributors to the observed Group 2 growth of 4.69×–14.47×. OS/storage prefetching remains an unmeasured technical hypothesis. This benchmark does not isolate the individual causal contribution of these factors.
> - **Absence of Severe Degradation:** Exactly zero queries exceeded the $20\times$ volume growth factor (the highest measured ratio was $14.47\times$ for [`R18`](../benchmarks/results/large/R18.txt)).
> - **Complexity Qualification:** Observed timing ratios ($R = T_{\text{large}} / T_{\text{seed}}$) reflect empirical growth between two measured data points and hardware/runtime configurations. They do not constitute formal mathematical proof of asymptotic Big-O complexity classes.

#### Group 1: Stayed About the Same ($R \le 3.5\times$)
**Queries (15 operations):**
- *Near-constant or faster ($R \le 2.0\times$):* [`R03`](../benchmarks/results/large/R03.txt) ($0.81\times$), [`R08`](../benchmarks/results/large/R08.txt) ($0.48\times$), [`R09`](../benchmarks/results/large/R09.txt) ($0.49\times$), [`R15`](../benchmarks/results/large/R15.txt) ($0.99\times$), [`R21`](../benchmarks/results/large/R21.txt) ($1.98\times$), [`R23`](../benchmarks/results/large/R23.txt) ($1.08\times$), [`R24`](../benchmarks/results/large/R24.txt) ($0.67\times$), [`W01`](../benchmarks/results/large/W01.txt) ($0.86\times$), [`W02`](../benchmarks/results/large/W02.txt) ($0.68\times$), [`W03`](../benchmarks/results/large/W03.txt) ($0.39\times$).
- *Mild timing variance ($2.0\times < R \le 3.5\times$):* [`R01`](../benchmarks/results/large/R01.txt) ($2.85\times$), [`R02`](../benchmarks/results/large/R02.txt) ($2.62\times$), [`R05`](../benchmarks/results/large/R05.txt) ($2.41\times$), [`R06`](../benchmarks/results/large/R06.txt) ($2.22\times$), [`R13`](../benchmarks/results/large/R13.txt) ($3.10\times$).

**Underlying Factors:**  
These queries target single records, highly selective index ranges, or fixed row limits. In a balanced B-tree index, depth scales logarithmically with table size. Expanding records from 200,000 to 4,000,000 increases B-tree height by at most one level. While additional tree levels add index page traversal work, frequently accessed branch pages benefit from buffer-cache prioritization in memory, keeping execution times under $3\text{ ms}$. For single-row writes ([`W01`](../benchmarks/results/large/W01.txt)–[`W03`](../benchmarks/results/large/W03.txt)), warm buffer pages and engine-level write path optimizations in PostgreSQL 18 contributed to lower average execution latencies. In [`R23`](../benchmarks/results/large/R23.txt) (`OFFSET 30000 LIMIT 25`), execution time remained flat ($1.08\times$) because the query scanned exactly 30,025 index entries in both datasets.

#### Group 2: Grew with Data Volume ($3.5\times < R \le 20\times$)
**Queries (15 operations):**  
[`R10`](../benchmarks/results/large/R10.txt) ($4.69\times$), [`R25`](../benchmarks/results/large/R25.txt) ($5.03\times$), [`R12`](../benchmarks/results/large/R12.txt) ($5.53\times$), [`R17`](../benchmarks/results/large/R17.txt) ($6.25\times$), [`W05`](../benchmarks/results/large/W05.txt) ($6.85\times$), [`R16`](../benchmarks/results/large/R16.txt) ($7.14\times$), [`R04`](../benchmarks/results/large/R04.txt) ($8.36\times$), [`R11`](../benchmarks/results/large/R11.txt) ($8.80\times$), [`R07`](../benchmarks/results/large/R07.txt) ($10.53\times$), [`R14`](../benchmarks/results/large/R14.txt) ($11.08\times$), [`R19`](../benchmarks/results/large/R19.txt) ($11.08\times$), [`R20`](../benchmarks/results/large/R20.txt) ($12.11\times$), [`R22`](../benchmarks/results/large/R22.txt) ($12.34\times$), [`W04`](../benchmarks/results/large/W04.txt) ($12.82\times$), [`R18`](../benchmarks/results/large/R18.txt) ($14.47\times$).

**Underlying Factors:**  
These queries read a substantial proportion of rows from tables or indexes. Their observed timing growth was less than the $20.02\times$ row expansion ratio due to verified plan optimizations and technical scaling factors:
1. **Parallel Worker Execution:** Analytical scans ([`R11`](../benchmarks/results/large/R11.txt), [`R12`](../benchmarks/results/large/R12.txt), [`R17`](../benchmarks/results/large/R17.txt), [`R25`](../benchmarks/results/large/R25.txt)) engaged parallel workers (`max_parallel_workers_per_gather = 2`), distributing page processing across CPU cores.
2. **Selective Date Ranges:** Range queries on `started_at` ([`R07`](../benchmarks/results/large/R07.txt), [`R10`](../benchmarks/results/large/R10.txt), [`R20`](../benchmarks/results/large/R20.txt)) isolate specific time windows (e.g., June 2026), filtering out earlier data.
3. **Plausible OS/Storage Prefetching Hypothesis:** Sequential page-access patterns may benefit from operating-system readahead or storage-controller caching. However, these effects were not independently measured in this benchmark. PostgreSQL's EXPLAIN buffer statistics do not establish OS-level readahead or physical-device prefetching, so this remains a possible explanation rather than a demonstrated cause.

#### Group 3: Grew More than Data Volume ($R > 20\times$)
- **Observed Result:** **Zero queries** grew more than $20\times$. The Phase 4 index set and query rewrites prevented unindexed nested-loop scans and catastrophic $O(N^2)$ degradation.

---

## 3. Scale Bottlenecks & Operational Behaviors

### 3.1 Memory Pressure and Disk Spills in [`R11`](../benchmarks/results/large/R11.txt)

On seed data, [`R11`](../benchmarks/results/optimized/R11.txt) processed approximately 11,000 June watch events within the default session allocation of `work_mem = 4MB`. On the large dataset, June 2026 encompasses **219,780 watch events** across **173,632 distinct videos**.

The raw plan file [`benchmarks/results/large/R11.txt`](../benchmarks/results/large/R11.txt) reveals that the window aggregation sort exceeded allocated memory:
```
Sort Key: v.category, (count(*)) DESC
Sort Method: external merge  Disk: 11368kB
Buffers: shared hit=13965 read=2210, temp read=2859 written=2866
```
Because the sort required $11,368\text{ kB}$ of working memory, PostgreSQL spilled intermediate runs to temporary disk files, writing and reading **2,859 temporary blocks**. Despite this disk spill, total execution time remained at **$175.22\text{ ms}$**, meeting the $5,000\text{ ms}$ SLA.

> [!TIP]
> **Tuning Hypothesis for Analytical Roles:**  
> In production environments with dedicated analytical sessions, increasing `work_mem` (e.g., to $32\text{MB}$ or $64\text{MB}$) is a standard tuning hypothesis to keep large sorts in memory. However, increasing `work_mem` must be validated with controlled benchmarks under concurrent load, as `work_mem` is allocated per sort/hash operation and can lead to memory exhaustion under high connection concurrency.

### 3.2 Buffer Cache Sizing and Cold-Run Latency Spikes

With `shared_buffers = 128MB` and a combined database physical size of $3.33\text{ GB}$, the database operates under a partial-cache model. While warm runs execute rapidly, cold runs incur additional page access latency:
- [`R07`](../benchmarks/results/large/R07.txt) Run 1 (Cold): **$11.954\text{ ms}$** vs Run 2 (Warm): **$0.317\text{ ms}$**
- [`R14`](../benchmarks/results/large/R14.txt) Run 1 (Cold): **$11.492\text{ ms}$** vs Run 2 (Warm): **$0.612\text{ ms}$**
- [`R17`](../benchmarks/results/large/R17.txt) Run 1 (Cold): **$370.800\text{ ms}$** vs Run 2 (Warm): **$104.864\text{ ms}$**

PostgreSQL buffer-cache residency depends on query access patterns and cache eviction pressure. PostgreSQL `shared read` counts in execution plans indicate that requested blocks were not found in `shared_buffers`; they may subsequently be served from OS file cache or physical disk storage.

### 3.3 Pagination Analysis in [`R23`](../benchmarks/results/large/R23.txt)

Workload query [`R23`](../benchmarks/results/large/R23.txt) was benchmarked using `OFFSET 30000 LIMIT 25`:
```sql
SELECT comment_id, video_id, user_id, body, created_at
FROM comments
ORDER BY created_at DESC
OFFSET 30000 LIMIT 25;
```
The raw plan file [`benchmarks/results/large/R23.txt`](../benchmarks/results/large/R23.txt) confirms that `Index Scan using comments_created_idx` scanned **30,025 leaf index entries in order and stopped**, executing in **$5.508\text{ ms}$** on average. Because the offset was fixed at 30,000, the work performed on 1.2M rows was identical to the work on 60k rows.

#### Architectural Recommendation: Keyset Pagination
For applications supporting deep arbitrary pagination (e.g., navigating to page 40,000 via `OFFSET 1000000`), offset pagination forces the engine to scan and discard 1,000,000 index tuples. To avoid this scan overhead at deep offsets, an application can adopt **Keyset Pagination** (Seek Method):
```sql
-- Architectural Proposal: Keyset Seek Alternative (Not benchmarked in CP4 workload)
SELECT comment_id, video_id, user_id, body, created_at
FROM youtube.comments
WHERE (created_at, comment_id) < ($last_seen_created_at, $last_seen_comment_id)
ORDER BY created_at DESC, comment_id DESC
LIMIT 25;
```
*Note:* Keyset pagination was not implemented or benchmarked in this project workload; the official benchmark suite evaluated the required `OFFSET 30000` query.

---

## 4. Physical Storage & Index Accounting

### 4.1 Measured Whole-Database Storage Breakdown

The physical footprint of database `youtube_large` was measured across implementation stages:
- **Baseline Database Footprint (Pre-Partition Experiment):** `2,311,182,015` bytes ($\approx 2,204.1\text{ MiB}$). This represents the complete physical storage of the baseline `youtube` schema (10 tables, 14 primary/unique indexes, 15 secondary indexes, toast relations, and free-space maps).
- **Combined Database Footprint (Post-Partition Experiment):** `3,491,083,967` bytes ($\approx 3,329.4\text{ MiB}$). At the time of final measurement, `youtube_large` hosted both the baseline schema `youtube` and the experimental schema `youtube_part`.
- **Measured Database Size Increase:** `1,179,901,952` bytes ($\approx 1,125.2\text{ MiB}$).
- **Experimental Schema Footprint (`youtube_part` Heap + Indexes):** `1,179,254,784` bytes ($\approx 1,124.6\text{ MiB}$).

```mermaid
flowchart TD
    subgraph Total Database Footprint: 3,491 MB (3,329 MiB)
        Base["Baseline Schema (youtube): 2,311 MB (66.2%)"]
        Part["Partition Experiment (youtube_part): 1,179 MB (33.8%)"]
        Diff["Unitemized Accounting Difference: 0.65 MB (0.02%)"]
    end
```

The small difference of **$647,168\text{ bytes}$** ($632\text{ KiB}$) is an unitemized accounting difference between the measured whole-database physical expansion ($1,179,901,952$ bytes) and the sum of the experimental schema's measured relation storage ($1,179,254,784$ bytes). Its individual components were not separately measured.

### 4.2 Estimated Baseline Table Storage Allocations

The following table provides estimated physical allocations across the baseline relations, derived by scaling verified Phase 4 seed measurements ([`docs/04_optimization_report.md`](04_optimization_report.md) §7) by the $20.02\times$ row expansion factor:

| Table Name | Estimated Heap Size | Estimated Primary Key Size | Estimated Secondary Index Size | Estimated Total Footprint |
|---|---:|---:|---:|---:|
| `watch_events` | $\approx 321\text{ MB}$ | $\approx 108\text{ MB}$ | $\approx 536\text{ MB}$ (3 indexes) | $\approx 965\text{ MB}$ |
| `subscriptions` | $\approx 143\text{ MB}$ | $\approx 92\text{ MB}$ | $\approx 84\text{ MB}$ (1 index) | $\approx 319\text{ MB}$ |
| `videos` | $\approx 102\text{ MB}$ | $\approx 26\text{ MB}$ | $\approx 128\text{ MB}$ (6 indexes) | $\approx 256\text{ MB}$ |
| `comments` | $\approx 110\text{ MB}$ | $\approx 44\text{ MB}$ | $\approx 82\text{ MB}$ (2 indexes) | $\approx 236\text{ MB}$ |
| `video_reactions` | $\approx 79\text{ MB}$ | $\approx 48\text{ MB}$ | $\approx 39\text{ MB}$ (1 index) | $\approx 166\text{ MB}$ |
| `ad_impressions` | $\approx 76\text{ MB}$ | $\approx 38\text{ MB}$ | $\approx 78\text{ MB}$ (2 indexes) | $\approx 192\text{ MB}$ |
| `playlist_items` | $\approx 69\text{ MB}$ | $\approx 42\text{ MB}$ | — | $\approx 111\text{ MB}$ |
| `users` | $\approx 48\text{ MB}$ | $\approx 21\text{ MB}$ | — | $\approx 69\text{ MB}$ |
| `playlists` | $\approx 12\text{ MB}$ | $\approx 6\text{ MB}$ | — | $\approx 18\text{ MB}$ |
| `channels` | $\approx 7\text{ MB}$ | $\approx 3\text{ MB}$ | — | $\approx 10\text{ MB}$ |
| **Baseline Estimated Totals** | **$\approx 967\text{ MB}$** | **$\approx 428\text{ MB}$** | **$\approx 947\text{ MB}$** | **$\approx 2,342\text{ MB}$** |

*Note on Source Attribution:* The detailed table-level allocations above are approximations derived from seed catalog metrics. The independently measured total physical footprint for the baseline database prior to partitioning is **$2,311,182,015\text{ bytes}$**.

### 4.3 Storage Footprint of Declarative Partitioning Experiment (`youtube_part`)

The declarative partitioning experiment in schema `youtube_part` duplicates the 4,000,000 watch event rows across 18 monthly child partitions and establishes 4 parent indexes cascading to 72 local partition indexes (76 indexes total).
- **Measured Schema Heap + Index Total:** `1,179,254,784` bytes ($\approx 1,124.6\text{ MiB}$).
- **Relation Inventory in Catalog:** Exactly 95 relation objects (1 partitioned parent table, 18 child partitions, 4 parent partitioned indexes, 72 partition-local indexes) and 114 constraints.

---

## 5. Declarative RANGE Partitioning Design & Controlled Comparison

### 5.1 Architecture & Implementation (`sql/08_partitioning.sql`)

1. **Schema Isolation:** The experiment resides in dedicated schema `youtube_part` to guarantee zero modification to verified baseline production data in `youtube`.
2. **Partition Key & Granularity:** Partitioned by `RANGE (started_at)` into **18 contiguous monthly partitions** spanning `2025-01-01 00:00:00+05:30` to `2026-07-01 00:00:00+05:30`.
3. **Primary Key Rule for Partitioned Tables:** PostgreSQL requires that any unique or primary key constraint on a partitioned table include all columns of the partition key. Therefore, the primary key is composite:
   ```sql
   CONSTRAINT watch_events_part_pkey PRIMARY KEY (watch_id, started_at)
   ```
   > [!IMPORTANT]
   > **Architectural Limitation on Global Uniqueness:**  
   > The composite PK guarantees uniqueness for `(watch_id, started_at)` within each partition, but does not enforce global uniqueness of `watch_id` alone across partitions. While all 4,000,000 records in this dataset have distinct `watch_id` values, cross-partition uniqueness of surrogate keys in PostgreSQL requires application-level generation (e.g., Snowflake IDs) or global indexing extensions.
4. **Intentional Omission of DEFAULT Partition:** A catch-all `DEFAULT` partition was omitted so that out-of-bounds records fail immediately upon ingestion, and future partition attachments avoid scanning default data under exclusive table locks.

---

### 5.2 Controlled Comparison Benchmark Results

The benchmark runner ([`benchmarks/run_partition_comparison.sh`](../benchmarks/run_partition_comparison.sh)) executed 9 planned query comparisons between baseline monolithic `youtube.watch_events` and partitioned `youtube_part.watch_events_partitioned` in `youtube_large`.

#### Paired Counterbalancing Protocol
Executions alternated order across paired repetitions: Rep 1 (Base $\rightarrow$ Part), Rep 2 (Part $\rightarrow$ Base), Rep 3 (Base $\rightarrow$ Part), Rep 4 (Part $\rightarrow$ Base), Rep 5 (Base $\rightarrow$ Part). If the coefficient of variation (CV) exceeded $0.15$, two additional counterbalanced pairs (Reps 6 & 7) were collected.

#### Official Benchmark Evidence Table (`comparison_summary.csv`)

| Query ID | Workload Category | Baseline Median (ms) | Part. Median (ms) | Speedup (%) | Baseline Mean (ms) | Part. Mean (ms) | Baseline CV | Part. CV | Runs | Pruning Classification | Partitions Scanned |
|---|---|---:|---:|---:|---:|---:|---:|---:|:---:|---|---|
| **R07** | Core Pruning | 0.324 | 0.265 | **+22.26%** | 7.272 | 1.494 | 2.5306 | 2.1930 | 7 | `DIRECT_SCAN_NO_APPEND` | `watch_events_2026_06` (1 of 18) |
| **R10_ref** | Core Pruning | 25.401 | 26.183 | **-2.99%** | 64.055 | 26.559 | 1.5987 | 0.0640 | 7 | `DIRECT_SCAN_NO_APPEND` | `watch_events_2026_06` (1 of 18) |
| **R11** | Core Pruning | 177.664 | 342.783 | **-48.17%** | 180.319 | 362.930 | 0.0314 | 0.1700 | 7 | `DIRECT_SCAN_NO_APPEND` | `watch_events_2026_06` (1 of 18) |
| **R12** | Negative Control | 133.923 | 193.412 | **-30.76%** | 133.388 | 195.032 | 0.0377 | 0.0289 | 5 | `FULL_TABLE_SCAN_NO_PRUNING` | All 18 Partitions |
| **R17** | Negative Control | 100.549 | 490.822 | **-79.51%** | 138.248 | 581.068 | 0.7082 | 0.4300 | 7 | `FULL_TABLE_SCAN_NO_PRUNING` | All 18 Partitions |
| **R19** | Negative Control | 561.364 | 583.892 | **-3.86%** | 554.878 | 577.437 | 0.0568 | 0.0338 | 5 | `FULL_TABLE_SCAN_NO_PRUNING` | All 18 Partitions |
| **R20** | Core Pruning | 46.842 | 42.737 | **+9.61%** | 47.758 | 42.774 | 0.0760 | 0.0235 | 5 | `DIRECT_SCAN_NO_APPEND` | `watch_events_2026_06` (1 of 18) |
| **R16** | Diagnostic Join | 152.700 | 222.739 | **-31.44%** | 153.187 | 223.544 | 0.0375 | 0.0122 | 5 | `FULL_TABLE_SCAN_NO_PRUNING` | All 18 Partitions |
| **R25** | Diagnostic Join | 424.240 | 452.117 | **-6.17%** | 457.828 | 457.684 | 0.1256 | 0.0199 | 5 | `FULL_TABLE_SCAN_NO_PRUNING` | All 18 Partitions |

*Speedup Formula:* $\text{Speedup \%} = \frac{\text{Baseline Median} - \text{Partitioned Median}}{\text{Baseline Median}} \times 100$.

---

### 5.3 Execution Plan Analysis: Pruning Wins vs. Regressions

#### The Pruning Wins: [`R07`](../benchmarks/results/partitioned/R07_partitioned.txt) (+22.26%) & [`R20`](../benchmarks/results/partitioned/R20_partitioned.txt) (+9.61%)
- In [`R07`](../benchmarks/results/partitioned/R07_partitioned.txt), static partition pruning eliminates 17 partitions. The engine executes an Index Only Scan on `watch_events_2026_06`, reducing median execution time from $0.324\text{ ms}$ to **$0.265\text{ ms}$** and cold run 1 from $49.0\text{ ms}$ to $8.9\text{ ms}$.
- In [`R20`](../benchmarks/results/partitioned/R20_partitioned.txt), isolating single partition `watch_events_2026_06` led the planner to substitute a sequential scan over the 219k child partition (`2,239` buffer hits) for an index scan (`2,843` buffer hits), speeding up execution from $46.84\text{ ms}$ to **$42.74\text{ ms}$**.

#### The Optimizer Plan Flip: [`R11`](../benchmarks/results/partitioned/R11_partitioned.txt) (-48.17%)
- Baseline executed a Parallel Hash Join ($177.66\text{ ms}$, 16,000 buffer hits). In partitioned execution, smaller partition row estimates led the planner to select a Nested Loop with Memoize. Due to 173,632 distinct videos across 219,780 events, the cache incurred 173,632 misses, forcing **173,632 B-tree index searches on `videos_pkey`** and exploding buffer hits to **696,000 blocks** ($342.78\text{ ms}$).

#### Multi-Partition Append Overhead: [`R17`](../benchmarks/results/partitioned/R17_partitioned.txt) (-79.51%)
- [`R17`](../benchmarks/results/partitioned/R17_partitioned.txt) filters on channels without date predicates. The engine dispatched an `Append` node scanning all 18 partitions for each of 58,849 outer video loops, performing **$1,059,282$ index searches** and expanding buffer hits from 320,000 to **3.19 million blocks** ($100.55\text{ ms} \rightarrow 490.82\text{ ms}$).

#### Whole-Table Append Overhead: [`R12`](../benchmarks/results/partitioned/R12_partitioned.txt), [`R16`](../benchmarks/results/partitioned/R16_partitioned.txt), [`R19`](../benchmarks/results/partitioned/R19_partitioned.txt), [`R25`](../benchmarks/results/partitioned/R25_partitioned.txt)
- Scanning all 4,000,000 rows across 18 separate child partitions introduces relation locking and scan-coordination overhead compared to a contiguous sequential heap scan, adding a $4\%$ to $31\%$ latency penalty.

---

### 5.4 W02 Partition Boundary Write Routing Diagnostic

Stage 6C evaluated boundary enforcement by attempting an out-of-bounds insert on `youtube_part.watch_events_partitioned`:
- **Attempted Timestamp:** `'2026-07-01 19:00:00+05:30'` (19 hours beyond partition upper bound `2026-07-01 00:00:00+05:30`).
- **Observed Behavior:** Trapped expected `SQLSTATE 23514 (check_violation)` with error message `no partition of relation "watch_events_partitioned" found for row`.
- **Transaction Safety:** Outer transaction confirmed rolled back (`CONFIRMED_ROLLED_BACK`).
- **Fidelity:** Post-diagnostic row counts remained invariant at 4,000,000 rows, with 0 bidirectional `EXCEPT ALL` differences.

---

## 6. Production Roadmap & Architectural Proposals (100× Scale)

Scaling to $100\times$ volume (400 million watch events, $\approx 350\text{ GB}$ storage) requires evaluating distributed designs.

### 6.1 Architectural System Classification

To distinguish benchmarked evidence from engineering proposals:

```mermaid
flowchart TD
    subgraph Implemented & Tested Systems
        M1[Monolithic youtube Schema - 12.8M rows]
        M2[15 Secondary Indexes & 4 Query Rewrites]
        M3[18-Partition RANGE youtube_part Experiment]
        M4[9 Paired Partition Benchmark Comparisons]
        M5[W02 Rollback & Boundary Diagnostic]
    end
    subgraph Proposed Target Architecture (100x Scale)
        P1[Horizontal Sharding / Citus]
        P2[Kafka Event Streaming]
        P3[Redis In-Memory Caching]
        P4[Read-Only Replica Pool Routing]
        P5[Parquet Cold Storage Archival]
        P6[Autovacuum aggressive scale_factor]
    end
```

### 6.2 Sharding Dimension Trade-Off Analysis

| Sharding Dimension | Colocation Benefits | Workload Advantages | Critical Cross-Shard Penalties | Architecture Status |
|---|---|---|---|---|
| **By `user_id`** | Colocates user watch history, subscriptions, and reactions. | Single-shard viewer reads ([`R03`](../benchmarks/results/large/R03.txt), [`R05`](../benchmarks/results/large/R05.txt)) and playback writes ([`W02`](../benchmarks/results/large/W02.txt)). | 25% of watch events have `user_id IS NULL`, causing hash skew. Creator Studio analytics become cross-shard scatter-gather. | Proposed / Unimplemented |
| **By `video_id`** | Colocates video metadata, comments, reactions, and view counts. | Video watch page ([`R02`](../benchmarks/results/large/R02.txt), [`R15`](../benchmarks/results/large/R15.txt)) and view count increments ([`W03`](../benchmarks/results/large/W03.txt)) are single-shard. | User watch history requires scatter-gather across all shards. Viral video hotspots create CPU skew. | Proposed / Unimplemented |
| **By `channel_id`** | Colocates channel metadata, uploaded videos, and associated playback events. | Studio analytics ([`R07`](../benchmarks/results/large/R07.txt), [`R09`](../benchmarks/results/large/R09.txt), [`R14`](../benchmarks/results/large/R14.txt), [`R24`](../benchmarks/results/large/R24.txt)) and channel homepages ([`R01`](../benchmarks/results/large/R01.txt)) execute locally. | Viewer history and platform-wide trending require multi-node scatter-gather. | Proposed / Unimplemented |
| **By `started_at`** | Groups data by timeline slices. | Efficient for time-window reporting ([`R20`](../benchmarks/results/large/R20.txt)). | Ingestion writes target only the active time shard, creating write bottlenecks. | Rejected Proposal |

### 6.3 Proposed Target Tiering (Replicas & Caching)

- **Primary Write Node (Transactional Operations):** Writes ([`W01`](../benchmarks/results/large/W01.txt)–[`W05`](../benchmarks/results/large/W05.txt)) and immediate read-your-own-writes queries ([`R02`](../benchmarks/results/large/R02.txt), [`R05`](../benchmarks/results/large/R05.txt)).
- **Read-Only Replica Pool (Proposed):** Offloads analytical reports ([`R11`](../benchmarks/results/large/R11.txt), [`R12`](../benchmarks/results/large/R12.txt), [`R16`](../benchmarks/results/large/R16.txt), [`R17`](../benchmarks/results/large/R17.txt), [`R19`](../benchmarks/results/large/R19.txt), [`R20`](../benchmarks/results/large/R20.txt), [`R22`](../benchmarks/results/large/R22.txt), [`R25`](../benchmarks/results/large/R25.txt)) from write transactions.
- **In-Memory Caching (Proposed):** Caching public video grids ([`R01`](../benchmarks/results/large/R01.txt)), popular search results ([`R04`](../benchmarks/results/large/R04.txt)), and Shorts shelves ([`R10`](../benchmarks/results/large/R10.txt)) in Redis.

### 6.4 Proposed Maintenance & Archival Engineering

- **Autovacuum Configuration Proposal:** For high-volume append tables, setting `autovacuum_vacuum_scale_factor = 0.02` and `autovacuum_vacuum_cost_limit = 2000` is proposed to ensure regular table vacuuming and index cleanup before freeze debt accumulates.
- **Partition Lifecycle Proposal:** Automated monthly partition creation combined with `ALTER TABLE ... DETACH CONCURRENTLY` for partitions older than 24 months, offloading historical data to columnar Parquet format on object storage.

---

## 7. Conclusion & Operational Evaluation Assessment

### 7.1 Assessment Against Checkpoint 4 Objectives

The empirical measurements and engineering evaluations establish that the database schema and secondary index set successfully scale to the institutional dataset volume under benchmark conditions:

1. **SLA Compliance:** 100% of the 30 workload queries met documented single-client latency targets on the tested large dataset. Real-time viewer queries executed in $< 2.3\text{ ms}$, search and creator tools in $< 40\text{ ms}$, and batch maintenance in $< 820\text{ ms}$.
2. **Workload Scalability:** Across the 30 queries, total single-client execution time increased by an observed factor of $8.40\times$ for a $20.02\times$ row expansion. Fifteen queries stayed about the same ($R \le 3.5\times$), fifteen scaled with volume ($3.5\times < R \le 20\times$), and zero queries grew more than $20\times$ ($R > 20\times$).
3. **Partitioning Findings:** The Stage 6C declarative RANGE partitioning experiment demonstrated that while static pruning accelerates bounded time-window queries ([`R07`](../benchmarks/results/partitioned/R07_partitioned.txt) $+22.26\%$, [`R20`](../benchmarks/results/partitioned/R20_partitioned.txt) $+9.61\%$), it degrades non-partitioned access paths ([`R17`](../benchmarks/results/partitioned/R17_partitioned.txt) $-79.51\%$) and can induce optimizer plan flips ([`R11`](../benchmarks/results/partitioned/R11_partitioned.txt) $-48.17\%$). In PostgreSQL, partitioning functions primarily as an operational data lifecycle mechanism rather than a general query optimization tool.
4. **Untested Production Factors:** The benchmarks validate single-client query execution in a local environment. They do not evaluate multi-client concurrent throughput, connection-pool limits, transaction lock contention, replica replication lag, or network serialization latency. These operational factors must be validated with load testing prior to production deployment.

---

**Prepared by the Phase 5 report owner for Team T0046 review. This report records the measured results and technical assessment for review before final team submission.**
