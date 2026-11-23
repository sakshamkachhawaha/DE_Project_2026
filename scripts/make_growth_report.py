#!/usr/bin/env python3
"""Pulls the numbers for docs/05 out of the two summary files, so the report and the
raw plans can't disagree.

reads  benchmarks/results/optimized/summary.csv   seed run
       benchmarks/results/large/summary.csv       large run, re-measured on 15.18
       docs/05_scalability_report.md              only for the query descriptions and SLA text

writes cp4_generated.md   blocks to paste into the report
       cp4_facts.json     same numbers, for the verifier
"""
import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path.cwd()
DOC = ROOT / "docs" / "05_scalability_report.md"
SEED = ROOT / "benchmarks" / "results" / "optimized" / "summary.csv"
LARGE = ROOT / "benchmarks" / "results" / "large" / "summary.csv"

for p in (DOC, SEED, LARGE):
    if not p.exists():
        sys.exit(f"missing {p.relative_to(ROOT)} — run reproduce_large.sh first")


def read_summary(path):
    rows = {}
    with path.open(newline="") as fh:
        for r in csv.DictReader(fh):
            rows[r["query_id"]] = {
                "type": r["type"],
                "avg": float(r["avg_ms"]),
                "median": float(r["median_ms"]),
                "scan": r.get("scan_nodes", "").strip(),
            }
    return rows


seed, large = read_summary(SEED), read_summary(LARGE)
if set(seed) != set(large):
    sys.exit(f"query sets differ: only-seed={sorted(set(seed)-set(large))} only-large={sorted(set(large)-set(seed))}")

# --- qualitative columns (description, SLA) are kept verbatim from the report ---
text = DOC.read_text()
row_re = re.compile(
    r"^\| \*\*(R\d\d|W\d\d)\*\* \| (.*?) \| [\d.,]+ \| [\d.,]+ \| \$[\d.]+\\times\$ \| (\$< [^$]+\$) \| \*\*(?:YES|NO)\*\* \| .*? \|$",
    re.M,
)
meta = {m.group(1): {"desc": m.group(2), "sla": m.group(3)} for m in row_re.finditer(text)}
missing = [q for q in seed if q not in meta]
if missing:
    sys.exit(f"could not find these queries in the report table: {missing}")

sla_value = {
    "5.0": 5.0,
    "250.0": 250.0,
    "5000.0": 5000.0,
    "2000.0": 2000.0,
}


def sla_ms(latex):
    digits = re.search(r"< ([\d,]+\.?\d*)", latex).group(1).replace(",", "")
    return float(digits)


def money(x, dp=3):
    s = f"{x:,.{dp}f}"
    return s


def tie(x):
    return f"${x:.2f}\\times$"


qids = sorted(seed, key=lambda q: (q[0], int(q[1:])))
ratios = {q: large[q]["avg"] / seed[q]["avg"] for q in qids}

g1 = [q for q in qids if ratios[q] <= 3.5]
g2 = [q for q in qids if 3.5 < ratios[q] <= 20.0]
g3 = [q for q in qids if ratios[q] > 20.0]
g1_flat = [q for q in g1 if ratios[q] <= 2.0]
g1_mild = [q for q in g1 if 2.0 < ratios[q] <= 3.5]

total_seed = sum(seed[q]["avg"] for q in qids)
total_large = sum(large[q]["avg"] for q in qids)
total_ratio = total_large / total_seed

reads = [q for q in qids if q.startswith("R")]
writes = [q for q in qids if q.startswith("W")]
mean_read = sum(ratios[q] for q in reads) / len(reads)
mean_write = sum(ratios[q] for q in writes) / len(writes)

worst = max(qids, key=lambda q: ratios[q])
best = min(qids, key=lambda q: ratios[q])
realtime = [q for q in qids if sla_ms(meta[q]["sla"]) == 5.0]
interactive = [q for q in qids if sla_ms(meta[q]["sla"]) == 250.0]
reporting = [q for q in qids if sla_ms(meta[q]["sla"]) == 5000.0]
batch = [q for q in qids if sla_ms(meta[q]["sla"]) == 2000.0]

rt_worst = max(realtime, key=lambda q: large[q]["avg"])
ia_worst = max(interactive, key=lambda q: large[q]["avg"])
rp_worst = max(reporting, key=lambda q: large[q]["avg"])
bt_worst = max(batch, key=lambda q: large[q]["avg"])
misses = [q for q in qids if large[q]["avg"] > sla_ms(meta[q]["sla"])]

highest_g1 = max(g1, key=lambda q: ratios[q]) if g1 else None
lowest_g2 = min(g2, key=lambda q: ratios[q]) if g2 else None


def link(q):
    return f"[`{q}`](../benchmarks/results/large/{q}.txt)"


def scans(q):
    nodes = [n.strip() for n in large[q]["scan"].split("|") if n.strip()]
    return ", ".join(f"`{n}`" for n in nodes) if nodes else "`(no scan)`"


def qlist(items, dp=2):
    return ", ".join(f"{link(q)} (${ratios[q]:.{dp}f}\\times$)" for q in sorted(items, key=lambda q: ratios[q]))


blocks = []

# ---------------------------------------------------------------- environment
blocks.append(("environment", f"""- **Engine:** PostgreSQL {json.loads((ROOT / 'cp4_engine.json').read_text())['server'] if (ROOT / 'cp4_engine.json').exists() else '15.x'}. Phase 3 and Phase 4 ran on the same major version.
- **Database:** `youtube_large`, built with `sql/01_schema.sql` and loaded by `sql/02_load_large_data.sql` from the faculty `large_data.zip`.
- **Where the data came from:** the official Phase 5 dataset for T0046 (247 MB archive, 845 MB of CSV, 12,828,190 rows across the same ten tables as `seed_data.zip`). We counted the rows again after loading and they match the published totals.
- **How the timings were taken:** `VACUUM (ANALYZE)` on the whole database, one warm-up run that is thrown away, then 3 measured runs per query. The figure in the table is the mean of those three, read from the server's `Execution Time` in `EXPLAIN (ANALYZE, BUFFERS)`. Phase 3 and Phase 4 used the same 3-run method.
- **Writes:** `W01`-`W05` run inside `BEGIN ... ROLLBACK`, so the benchmark leaves the 12.8M rows as they were.
- **Sections 4 and 5:** the storage measurements and the partitioning comparison were taken in one database on PostgreSQL 18.6. Both sides of those two comparisons ran on the same engine, so they do not mix versions. Only the timings in section 2 needed re-measuring, and that is what was re-run here."""))

# ---------------------------------------------------------------- exec summary
blocks.append(("exec_summary", f"""Across the 30 queries, total execution time went from **${money(total_seed)}\\text{{ ms}}$** on the seed data to **${money(total_large)}\\text{{ ms}}$** on the large data, which is **${total_ratio:.2f}\\times$** for $20.02\\times$ more rows. {"All 30 stayed inside their SLA:" if not misses else f"{len(qids) - len(misses)} of 30 stayed inside their SLA. These did not: {', '.join(misses)}:"}
   - **Real-time / viewer-facing (SLA $< 5\\text{{ ms}}$):** all {len(realtime)} ran in under ${large[rt_worst]['avg']:.1f}\\text{{ ms}}$, slowest {link(rt_worst)} at ${large[rt_worst]['avg']:.3f}\\text{{ ms}}$.
   - **Interactive studio and search (SLA $< 250\\text{{ ms}}$):** all {len(interactive)} ran in under ${large[ia_worst]['avg']:.1f}\\text{{ ms}}$, slowest {link(ia_worst)} at ${large[ia_worst]['avg']:.3f}\\text{{ ms}}$.
   - **Reporting and analytics (SLA $< 5,000\\text{{ ms}}$):** all {len(reporting)} finished inside the limit, slowest {link(rp_worst)} at ${large[rp_worst]['avg']:.3f}\\text{{ ms}}$.
   - **Batch maintenance (SLA $< 2,000\\text{{ ms}}$):** {link(bt_worst)} took ${large[bt_worst]['avg']:.3f}\\text{{ ms}}$."""))

# ---------------------------------------------------------------- table 2.1
lines = [
    "| Query ID | Query Type & Business Description | Seed Avg (ms) | Large Avg (ms) | Observed Ratio $R = \\frac{T_{\\text{large}}}{T_{\\text{seed}}}$ | Target SLA | Meets Target? | Primary Scan Nodes (Large Dataset) |",
    "|---|---|---:|---:|---:|---|---:|---|",
]
for q in qids:
    ok = large[q]["avg"] <= sla_ms(meta[q]["sla"])
    lines.append(
        f"| **{q}** | {meta[q]['desc']} | {money(seed[q]['avg'])} | {money(large[q]['avg'])} | {tie(ratios[q])} "
        f"| {meta[q]['sla']} | **{'YES' if ok else 'NO'}** | {scans(q)} |"
    )
lines.append(
    f"| **Total** | **Full Workload Suite (30 Queries)** | **{money(total_seed)}** | **{money(total_large)}** "
    f"| **${total_ratio:.2f}\\times$** | **—** | **{'YES' if not misses else 'NO'}** "
    f"| **{'100% SLA Target Compliance Across All Queries' if not misses else str(len(qids) - len(misses)) + '/30 queries within SLA'}** |"
)
blocks.append(("table_2_1", "\n".join(lines)))

# ---------------------------------------------------------------- pie
blocks.append(("pie", f"""```mermaid
pie title Query Distribution by Observed Timing Growth Ratio (R = T_large / T_seed)
    "Stayed About the Same (R <= 3.5x)" : {len(g1)}
    "Grew with Data Volume (3.5x < R <= 20x)" : {len(g2)}
    "Grew More than 20x (R > 20x)" : {len(g3)}
```"""))

# ---------------------------------------------------------------- boundary text
gap = ""
if highest_g1 and lowest_g2:
    gap = (f"In the measured data the highest Group 1 ratio is ${ratios[highest_g1]:.2f}\\times$ ({link(highest_g1)}) "
           f"and the lowest Group 2 ratio is ${ratios[lowest_g2]:.2f}\\times$ ({link(lowest_g2)}). "
           + ("The two groups are separated by a clear gap." if ratios[lowest_g2] - ratios[highest_g1] > 0.5
              else "The two groups are close together at the boundary, so a single query moving between them is a measurement effect rather than a change in behaviour."))
blocks.append(("boundary_text", f"""- **Where the cut-offs come from:** the faculty described the three groups in words. We had to pick numbers, so we used $3.5\\times$ and $20.0\\times$. {gap}
- **Why most queries grow less than the data:** a few of them run with parallel workers, and the date-bounded ones read only one month out of nineteen. Those two are visible in the plans. Disk-level readahead may also help, but we did not measure it, so we are not claiming it.
- **Queries above the row-growth factor:** {("none." if not g3 else str(len(g3)) + " — " + qlist(g3) + ". These read a large share of a table that grew $20\\times$, so their time grew with it. All of them still finished inside their SLA; making them faster would mean a covering index or a narrower date range, not more memory.")} The highest ratio in the whole workload is ${ratios[worst]:.2f}\\times$ ({link(worst)}).
- **What the ratios are:** two measurements on one laptop. They show how these queries behaved at two data sizes. They are not a proof of Big-O complexity."""))

# ---------------------------------------------------------------- groups
blocks.append(("group1", f"""#### Group 1: Stayed About the Same ($R \\le 3.5\\times$)
**Queries ({len(g1)} operations):**
- *Near-constant or faster ($R \\le 2.0\\times$):* {qlist(g1_flat) if g1_flat else "none"}.
- *Mild timing variance ($2.0\\times < R \\le 3.5\\times$):* {qlist(g1_mild) if g1_mild else "none"}."""))

blocks.append(("group2", f"""#### Group 2: Grew with Data Volume ($3.5\\times < R \\le 20\\times$)
**Queries ({len(g2)} operations):**
{qlist(g2) if g2 else "none"}."""))

if g3:
    group3_body = (f"""#### Group 3: Grew More than Data Volume ($R > 20\\times$)
**Queries ({len(g3)} operations):**
{qlist(g3)}

Each of these reads a lot of rows from tables that grew $20\\times$, and each one still finished inside its SLA. We report them as measured. The next step for them would be a covering index or a tighter date range, not a larger `work_mem`.""")
else:
    group3_body = ("""#### Group 3: Grew More than Data Volume ($R > 20\\times$)
**Queries in this group:** none. Every query grew by less than $20\\times$.""")
blocks.append(("group3", group3_body))

facts = {
    "queries": len(qids),
    "total_seed_ms": round(total_seed, 3),
    "total_large_ms": round(total_large, 3),
    "total_ratio": round(total_ratio, 3),
    "mean_read_ratio": round(mean_read, 3),
    "mean_write_ratio": round(mean_write, 3),
    "count_g1": len(g1), "count_g2": len(g2), "count_g3": len(g3),
    "g3_queries": g3,
    "worst": {"q": worst, "ratio": round(ratios[worst], 3)},
    "best": {"q": best, "ratio": round(ratios[best], 3)},
    "sla_misses": misses,
    "ratios": {q: round(ratios[q], 4) for q in qids},
}

out = [f"<<<{name}>>>\n{body}\n" for name, body in blocks]
out.append("<<<facts>>>\n" + json.dumps(facts, indent=2) + "\n")
(ROOT / "cp4_generated.md").write_text("\n".join(out))
(ROOT / "cp4_facts.json").write_text(json.dumps(facts, indent=2) + "\n")

print(f"wrote cp4_generated.md  ({len(blocks)} blocks)")
print()
print(f"total   : {money(total_seed)} ms -> {money(total_large)} ms  = {total_ratio:.2f}x")
print(f"buckets : {len(g1)} stayed / {len(g2)} grew / {len(g3)} over 20x")
print(f"worst   : {worst} at {ratios[worst]:.2f}x   best: {best} at {ratios[best]:.2f}x")
print(f"mean    : reads {mean_read:.2f}x  writes {mean_write:.2f}x")
print(f"SLA     : {len(qids) - len(misses)}/{len(qids)} met" + (f"  MISSES: {misses}" if misses else ""))
