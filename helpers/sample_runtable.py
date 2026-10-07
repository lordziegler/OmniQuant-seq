#!/usr/bin/env python3
"""Draws a random pilot subset of a RunTable, sized with Cochran's formula
(95% confidence, finite population correction), and reports the STAR_OVERHANG
that covers 95% of the runs' read lengths.

The population is samples.tsv, so the size is computed over the runs the
pipeline would actually process, not over every row of the RunTable."""

import argparse
import csv
import math
import random
from pathlib import Path

from parse_runtable import RUN_KEYS, _get, _load

Z95 = 1.96


def cochran(population: int, margin: float = 0.05, p: float = 0.5) -> int:
    n0 = Z95 ** 2 * p * (1 - p) / margin ** 2
    return min(population, math.ceil(n0 / (1 + (n0 - 1) / population)))


# STAR's ideal sjdbOverhang is max(read length) - 1. The 95th percentile
# instead of the max keeps one mislabelled run (a PAIRED spot length read as
# SINGLE doubles it) from setting the index for everyone.
def overhang(mate_lengths: list, coverage: float = 0.95) -> int:
    ranked = sorted(mate_lengths)
    return math.ceil(ranked[math.ceil(coverage * len(ranked)) - 1]) - 1


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--runtable", required=True, type=Path)
    p.add_argument("--samples",  required=True, type=Path,
                   help="samples.tsv from parse_runtable.py: the population.")
    p.add_argument("--output",   default=Path("pilot_SraRunTable.csv"), type=Path,
                   help="Pilot RunTable, usable as run.sh input in its own directory.")
    p.add_argument("--margin",   default=0.05, type=float,
                   help="Margin of error at 95%% confidence (default 0.05).")
    p.add_argument("--seed",     default=1, type=int)
    args = p.parse_args()

    by_run = {_get(r, *RUN_KEYS): r for r in _load(args.runtable)}
    population, skipped = [], 0
    with args.samples.open(newline="") as fh:
        for s in csv.DictReader(fh, delimiter="\t"):
            row = by_run.get(s["SRR"])
            spot = _get(row, "AvgSpotLen", "avg_spot_len") if row else ""
            if not spot:
                skipped += 1
                continue
            mate = float(spot) / (2 if s["LAYOUT"] == "PAIRED" else 1)
            population.append((row, mate))
    if not population:
        raise SystemExit("[ABORT] No run in samples.tsv has an AvgSpotLen in the RunTable.")

    n = cochran(len(population), args.margin)
    pilot = random.Random(args.seed).sample(population, n)
    pilot_oh = overhang([m for _, m in pilot])
    census = [m for _, m in population]
    covered = sum(m <= pilot_oh + 1 for m in census) / len(census)

    with args.output.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(pilot[0][0]), lineterminator="\n")
        w.writeheader()
        w.writerows(r for r, _ in pilot)

    print(f"[INFO] Population N = {len(population)}"
          + (f"  ({skipped} runs without AvgSpotLen excluded)" if skipped else ""))
    print(f"[INFO] Sample size n = {n}  (95% CI, margin ±{args.margin:.0%}, seed {args.seed})")
    print(f"[DONE] Pilot RunTable: {args.output}")
    print(f"STAR_OVERHANG (pilot)  = {pilot_oh}  -> covers {covered:.1%} of all runs")
    print(f"STAR_OVERHANG (census) = {overhang(census)}")


if __name__ == "__main__":
    main()
