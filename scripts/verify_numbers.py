#!/usr/bin/env python3
"""Checks every number in docs/05 against the two summary CSVs.

Exits 1 and lists what disagrees. Run it after pasting the blocks and again
before the commit.
"""
import csv
import re
import sys
from pathlib import Path

ROOT = Path.cwd()
DOC = ROOT / "docs" / "05_scalability_report.md"
SEED = ROOT / "benchmarks" / "results" / "optimized" / "summary.csv"
LARGE = ROOT / "benchmarks" / "results" / "large" / "summary.csv"

problems = []


def read(path):
    with path.open(newline="") as fh:
        return {r["query_id"]: float(r["avg_ms"]) for r in csv.DictReader(fh)}


seed, large = read(SEED), read(LARGE)
text = DOC.read_text()

# ---- table rows -------------------------------------------------------------
row_re = re.compile(
    r"^\| \*\*(R\d\d|W\d\d)\*\* \| .*? \| ([\d,]+\.\d+) \| ([\d,]+\.\d+) \| \$([\d.]+)\\times\$ \|",
    re.M,
)
found = 0
for m in row_re.finditer(text):
    q, sd, lg, rt = m.group(1), m.group(2), m.group(3), m.group(4)
    if q not in seed or q not in large:
        problems.append(f"{q}: in the report but not in the CSVs")
        continue
    found += 1
    sd_c, lg_c, rt_c = float(sd.replace(",", "")), float(lg.replace(",", "")), float(rt)
    if abs(sd_c - seed[q]) > 0.002:
        problems.append(f"{q}: seed {sd_c} in report, {seed[q]:.3f} in CSV")
    if abs(lg_c - large[q]) > 0.002:
        problems.append(f"{q}: large {lg_c} in report, {large[q]:.3f} in CSV")
    if abs(rt_c - large[q] / seed[q]) > 0.01:
        problems.append(f"{q}: ratio {rt_c} in report, {large[q]/seed[q]:.2f} from CSV")

if found != len(seed):
    problems.append(f"report table has {found} query rows, CSVs have {len(seed)}")

# ---- total row --------------------------------------------------------------
tot = re.search(r"^\| \*\*Total\*\* .*?\| \*\*([\d,]+\.\d+)\*\* \| \*\*([\d,]+\.\d+)\*\* \| \*\*\$([\d.]+)\\times\$\*\*",
                text, re.M)
if not tot:
    problems.append("total row not found in the report")
else:
    s_c, l_c, r_c = (float(tot.group(1).replace(",", "")), float(tot.group(2).replace(",", "")),
                     float(tot.group(3)))
    s_e, l_e = sum(seed.values()), sum(large.values())
    if abs(s_c - s_e) > 0.02:
        problems.append(f"total seed {s_c} in report, {s_e:.3f} from CSV")
    if abs(l_c - l_e) > 0.02:
        problems.append(f"total large {l_c} in report, {l_e:.3f} from CSV")
    if abs(r_c - l_e / s_e) > 0.01:
        problems.append(f"total ratio {r_c} in report, {l_e/s_e:.2f} from CSV")

# ---- growth buckets ---------------------------------------------------------
g1 = sum(1 for q in seed if large[q] / seed[q] <= 3.5)
g2 = sum(1 for q in seed if 3.5 < large[q] / seed[q] <= 20.0)
g3 = sum(1 for q in seed if large[q] / seed[q] > 20.0)
pie = re.search(r'"Stayed About the Same[^"]*" : (\d+)\s*\n\s*"Grew with Data Volume[^"]*" : (\d+)\s*\n\s*"Grew More than 20x[^"]*" : (\d+)',
                text)
if not pie:
    problems.append("the three numbers in the pie chart were not found")
elif (int(pie.group(1)), int(pie.group(2)), int(pie.group(3))) != (g1, g2, g3):
    problems.append(f"pie says {pie.group(1)}/{pie.group(2)}/{pie.group(3)}, data says {g1}/{g2}/{g3}")

# ---- language that must be gone --------------------------------------------
for line in text.splitlines():
    if "PostgreSQL 18" in line and not line.startswith("- **Sections 4 and 5:**"):
        problems.append('found "PostgreSQL 18" outside the sections 4-5 disclosure: ' + line.strip()[:90])
for needle in ("5 runs per query", "not strict controlled experiments"):
    if needle in text:
        problems.append(f'found "{needle}" — that claim was wrong or is no longer true')

if "12,828,190" not in text:
    problems.append("the dataset row total 12,828,190 is not stated")
if "large_data.zip" not in text and "faculty" not in text.lower():
    problems.append("the provenance of the large dataset is still not stated")

# ---- report -----------------------------------------------------------------
if problems:
    print(f"FAIL — {len(problems)} problem(s):\n")
    for p in problems:
        print("  -", p)
    print("\nFix the report, or re-run make_growth_report.py and paste its blocks again.")
    sys.exit(1)

print(f"OK — {found} query rows, the total row, and the three bucket counts all match the CSVs.")
print(f"     total {sum(seed.values()):,.3f} ms -> {sum(large.values()):,.3f} ms "
      f"= {sum(large.values())/sum(seed.values()):.2f}x   buckets {g1}/{g2}/{g3}")
