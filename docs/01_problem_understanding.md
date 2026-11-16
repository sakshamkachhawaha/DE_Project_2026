# Phase 1: Problem Understanding & Workload Classification

This document analyzes the 9 core database operational problems (P1–P9) reported across YouTube India's services, mapping them to business needs, affected stakeholders, operational classifications (SLAs), and workload query IDs.

---

## 1. Problem Statements & Business Analysis

### P1: Core Video Consumption & Page Latency
- **Business Need:** High-traffic consumer surfaces (video watch page, channel page, playlist sequence) must render with near-zero latency. Slow page assembly leads to viewer drop-off and diminished creator visibility. Queries must retrieve indexed video metadata, channel details, top comments, and playlist items without full-table scans.
- **Affected Stakeholders:** Viewers (consumers), Content Creators.
- **Classification:** Customer-Facing / Real-Time (SLA: < 5 ms).
- **Related Queries:** `R01` (channel newest videos), `R02` (watch page metadata), `R15` (pinned & top comments), `R21` (ordered playlist items).

### P2: Personalized Viewer Feeds & History Retrieval
- **Business Need:** Authenticated viewers frequently check their subscriptions feed and watch history. Aggregating recent uploads across dozens of subscribed channels and scanning user watch histories across millions of rows causes multi-second stalls, directly hurting daily active user (DAU) retention.
- **Affected Stakeholders:** Logged-In Viewers, Content Creators.
- **Classification:** Customer-Facing / Real-Time (SLA: < 5 ms).
- **Related Queries:** `R03` (subscriptions feed), `R05` (last 50 watched videos).

### P3: Free-Text Search & Content Discovery
- **Business Need:** Viewers rely on search to discover relevant videos by keyword. Substring matching (`ILIKE '%tutorial%'`) combined with view-count ordering triggers sequential scans across the entire video catalog, producing unacceptably slow search response times.
- **Affected Stakeholders:** Viewers, Content Creators.
- **Classification:** Customer-Facing / Interactive Search (SLA: < 250 ms).
- **Related Queries:** `R04` (keyword video search ordered by views).

### P4: Creator Studio Telemetry & Analytics
- **Business Need:** Creators require responsive telemetry (daily view trends, watch hours, traffic sources, audience retention, and engagement metrics) to make data-driven content decisions. Heavy aggregation across large event and reaction tables degrades dashboard interactivity.
- **Affected Stakeholders:** Content Creators, YouTube Studio Product Team.
- **Classification:** Reporting / Interactive Analytics (SLA: < 250 ms).
- **Related Queries:** `R07` (daily views & hours), `R08` (traffic source breakdown), `R09` (watch percentage retention), `R14` (likes/dislikes ratio), `R24` (subscriber growth).

### P5: Inactive Subscriber Anomaly & Audience Auditing
- **Business Need:** Creators need to audit dormant or ghost subscribers who have never watched their content. The current query returns zero rows because logged-out views introduce `NULL` values in `watch_events.user_id`, causing SQL `NOT IN` subqueries to evaluate to unknown/empty. Fixing this semantic bug is required for true audience insights.
- **Affected Stakeholders:** Content Creators, Studio Analytics Team.
- **Classification:** Reporting / Interactive Analytics (SLA: < 250 ms).
- **Related Queries:** `R13` (subscribers with zero channel views).

### P6: Algorithmic Feeds & Trending Shelf Recomputation
- **Business Need:** Algorithmic recommendation shelves (Shorts shelf, category trending) require continuous recalculation using multi-day window aggregations and rank partitioning. Sluggish batch recalculations lead to stale recommendations and delayed viral distribution.
- **Affected Stakeholders:** Viewers, Creators, Recommendations Engineering.
- **Classification:** Reporting / Background Analytics (SLA: < 5,000 ms).
- **Related Queries:** `R10` (top Shorts in past 7 days), `R11` (top 5 trending videos per category).

### P7: Scheduled Video Ingestion & High-Throughput OLTP Counters
- **Business Need:** The publishing daemon must reliably detect and activate scheduled videos when their release timestamp passes without skipping broadcasts. Simultaneously, rapid watch logging (`W02`), video uploads (`W01`), and real-time view increments (`W03`) suffer concurrency bottlenecks and row locking.
- **Affected Stakeholders:** Creators, Viewers, Publishing & Ingestion Pipeline.
- **Classification:** Customer-Facing OLTP Writes & Ingestion Service (Writes SLA: < 5 ms; Polling/Batch SLA: < 250 ms).
- **Related Queries:** `R06` (scheduled video scan), `W01` (video upload), `W02` (watch event log), `W03` (view counter increment), `W05` (publish scheduled videos).

### P8: Partner Program Eligibility, Monetization & Premium Auditing
- **Business Need:** Financial pipelines must accurately compute ad revenues for creator payouts, identify newly qualified channels crossing watch-hour thresholds, and strictly verify that YouTube Premium subscribers are never served ads (avoiding contractual breach and refund overhead).
- **Affected Stakeholders:** Monetized Creators, Finance Team, Premium Subscribers, Advertisers.
- **Classification:** Reporting / Financial Audit & Batch Processing (Reports SLA: < 5,000 ms; Batch `W04` SLA: < 2,000 ms).
- **Related Queries:** `R16` (ad revenue per channel), `R17` (monetization eligibility threshold), `R19` (monetized channel summaries), `R25` (Premium ad-free audit), `W04` (subscriber count sync).

### P9: Trust & Safety, Copyright Detection & Platform Scalability
- **Business Need:** Legal and safety teams must enforce COPPA compliance (disabling comments on "Made for Kids" content), detect copyright re-uploads across channels, and review reported content through deeply paginated moderation queues without performance collapse as traffic scales 20×.
- **Affected Stakeholders:** Trust & Safety Officers, Legal & Copyright Teams, Content Moderators, Platform Architects.
- **Classification:** Reporting / Regulatory Audit & Governance (SLA: < 5,000 ms).
- **Related Queries:** `R12` (device logged-out viewing share), `R18` (child safety comments check), `R20` (daily & running watch hours), `R22` (copyright duplicate upload detection), `R23` (moderation queue deep pagination).

---

## 2. Workload Classification Matrix

| Category | SLA Target | Queries | Characteristics |
|---|---|---|---|
| **Customer-Facing / Real-Time** | < 5 ms | R01, R02, R03, R05, R15, R21, W01, W02, W03 | Point lookups, shallow index scans, high-frequency single-row OLTP writes. |
| **Interactive Studio & Search** | < 250 ms | R04, R06, R07, R08, R09, R13, R14, R24, W05 | Filtered aggregate metrics, text search, scheduled status sweeps. |
| **Reporting & Analytical Audits** | < 5,000 ms | R10, R11, R12, R16, R17, R18, R19, R20, R22, R23, R25 | Multi-table joins, window functions (`RANK()`, `SUM() OVER`), heavy aggregations. |
| **Batch System Jobs** | < 2,000 ms | W04 | Periodic whole-table bulk recalculations and synchronization. |

---

## 3. Assumptions

1. **Dual OLTP / OLAP Architecture:** The database serves mixed workloads where customer-facing read/write queries cannot be starved or blocked by intensive reporting and audit queries.
2. **Anonymous / Logged-Out Viewing:** `watch_events.user_id` allows `NULL` values to record viewing activity by unauthenticated users, necessitating null-safe SQL patterns (`NOT EXISTS` or `WHERE user_id IS NOT NULL`) in subqueries.
3. **Data Integrity & Consistency:** Video uploads (`W01`), views (`W02`), and increments (`W03`) require ACID guarantees; scheduled publishing (`W05`) runs periodically (e.g., cron minutely).
4. **Scale Projections:** The database must be optimized to withstand a 20× data volume increase (≈4M watch events) without violating the defined category SLAs.
