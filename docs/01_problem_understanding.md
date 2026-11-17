# Phase 1 — Problem Understanding & Workload Classification

**Team T0046 · Section A · Group Lead: Saksham Kachhawaha**

| ID | What the business needs | Stakeholder(s) | Classification and target | Queries |
|---|---|---|---|---|
| P1 | Fast channel, watch and playlist pages: video metadata, channel details, comments and playlist order. | Viewers; creators | Customer-facing / real-time; < 5 ms | R01, R02, R15, R21 |
| P2 | Fast subscriptions feed and watch history for active users. | Logged-in viewers | Customer-facing / real-time; < 5 ms | R03, R05 |
| P3 | Fast title substring search, ranked by views. | Viewers; creators; search team | Customer-facing / interactive; < 250 ms | R04 |
| P4 | Fast Studio charts: views, watch hours, traffic, retention, likes and subscriber growth. | Creators; YouTube Studio team | Reporting / analytics (interactive); < 250 ms | R07, R08, R09, R14, R24 |
| P5 | The "subscribers who never watched" report must return the real 88 subscribers, not empty; the empty result is a NULL `NOT IN` bug. | Creators; YouTube Studio team | Reporting / analytics (interactive); < 250 ms | R13 |
| P6 | Fast Shorts shelf and Trending recomputation. | Viewers; creators; trending/recommendations team | Reporting / analytics (periodic); < 5,000 ms | R10, R11 |
| P7 | Reliable uploads, scheduled publishing, view logging and view counters under load. | Creators; viewers; publishing service | Customer-facing / real-time writes; writes < 5 ms, sweeps < 250 ms | R06, W01, W02, W03, W05 |
| P8 | Finance and partner reports: ad revenue, channel eligibility, subscriber totals and Premium-ad audits. | Monetized creators; partner program; finance team; Premium subscribers | Reporting / analytics; reports < 5,000 ms, W04 < 2,000 ms | R16, R17, R19, R25, W04 |
| P9 | Child safety, copyright, moderation, growth trends and 20× scale reporting. | Trust & Safety / child safety; copyright team; content moderators; growth team | Reporting / analytics; < 5,000 ms | R12, R18, R20, R22, R23 |

**Binary classification:** customer-facing / real-time: **P1, P2, P3, P7** (P3 is interactive at 250 ms; P7 sweeps are 250 ms). Reporting / analytics: **P4, P5, P6, P8, P9** (P4/P5 are interactive Studio queries).

## Assumptions

1. `watch_events.user_id IS NULL` means a logged-out viewer, not missing data; R13 must use `NOT EXISTS` or filter NULLs, not `NOT IN`.
2. Customer-facing queries must not be blocked by long reports; they have separate latency targets.
3. Writes are far more frequent than uploads: 200,000 watch events vs 30,000 videos in the seed (about 7×), and the workload stays write-heavy at 4 million events.
4. The business expects 20× growth; data-quality issues are documented, not silently deleted or altered.
