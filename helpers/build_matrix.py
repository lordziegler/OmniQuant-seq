#!/usr/bin/env python3
import argparse
import csv
import re
from pathlib import Path

_BASE = ["gene_id", "transcript_id(s)", "length", "effective_length", "expected_count"]

_BBDUK_RE = re.compile(
    r"^\s*(?P<label>Input|QTrimmed|Total Removed|Result):\s+"
    r"(?P<reads>\d+)\s+reads(?:\s+\((?P<rpct>[\d.]+)%\))?\s+"
    r"(?P<bases>\d+)\s+bases(?:\s+\((?P<bpct>[\d.]+)%\))?"
)


def expression_matrix(rsem_dir: Path, output: Path) -> None:
    files = sorted(rsem_dir.glob("*/*.genes.results"))
    if not files:
        print(f"[WARN] No genes.results in {rsem_dir}")
        return

    sample_data: dict = {}
    gene_ann: dict = {}

    needed = {*_BASE, "TPM", "FPKM"}
    for f in files:
        sample = f.stem.replace(".genes", "")
        rows: dict = {}
        with f.open(newline="") as fh:
            reader = csv.DictReader(fh, delimiter="\t")
            if needed - set(reader.fieldnames or []):
                print(f"[WARN] Skipping {f} — missing columns.")
                continue
            for row in reader:
                g = row["gene_id"]
                gene_ann.setdefault(g, [row[c] for c in _BASE])
                rows[g] = (row["TPM"], row["FPKM"])
        if rows:
            sample_data[sample] = rows

    if not sample_data:
        print("[WARN] No valid samples.")
        return

    common = sorted(set.intersection(*map(set, sample_data.values())))
    samples = sorted(sample_data)

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(_BASE + [f"{s}_{m}" for s in samples for m in ("TPM", "FPKM")])
        for g in common:
            row = gene_ann[g][:]
            for s in samples:
                row += list(sample_data[s][g])
            w.writerow(row)
    print(
        f"[DONE] Expression matrix: {output}  ({len(common)} genes, {len(samples)} samples)"
    )


def _strand_ratio(log_dir: Path, sample: str) -> str:
    # Same ratio steps/align.sh uses to set RSEM --forward-prob.
    f = log_dir / f"{sample}_STAR_ReadsPerGene.out.tab"
    if not f.exists():
        return "NA"
    fwd = rev = 0
    for line in f.read_text(errors="ignore").splitlines()[4:]:
        cols = line.split("\t")
        if len(cols) < 4:
            continue
        fwd += int(cols[2])
        rev += int(cols[3])
    return f"{fwd / (fwd + rev):.3f}" if fwd + rev else "NA"


def star_qc(log_dir: Path, output: Path) -> None:
    files = sorted(log_dir.glob("*_STAR_Log.final.out"))
    if not files:
        print("[WARN] No STAR Log.final.out files found.")
        return

    metrics_order: list = []
    data: dict = {}

    for f in files:
        sample = f.name.replace("_STAR_Log.final.out", "")
        metrics: dict = {}
        for line in f.read_text(errors="ignore").splitlines():
            if "|" not in line:
                continue
            k, _, v = line.partition("|")
            k = k.strip()
            if k not in metrics_order:
                metrics_order.append(k)
            metrics[k] = v.strip()
        metrics["strand_ratio (fwd/(fwd+rev))"] = _strand_ratio(log_dir, sample)
        data[sample] = metrics
    metrics_order.append("strand_ratio (fwd/(fwd+rev))")

    samples = sorted(data)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(["STAR_metric"] + samples)
        for m in metrics_order:
            w.writerow([m] + [data[s].get(m, "NA") for s in samples])
    print(f"[DONE] STAR QC matrix: {output}")


def bbduk_qc(log_dir: Path, output: Path) -> None:
    files = sorted(log_dir.glob("*_bbduk.log"))
    if not files:
        print("[WARN] No BBDuk logs found.")
        return

    fields = [
        "Sample",
        "Input_reads",
        "Input_bases",
        "QTrimmed_reads",
        "QTrimmed_reads_percent",
        "QTrimmed_bases",
        "QTrimmed_bases_percent",
        "Total_Removed_reads",
        "Total_Removed_reads_percent",
        "Total_Removed_bases",
        "Total_Removed_bases_percent",
        "Result_reads",
        "Result_reads_percent",
        "Result_bases",
        "Result_bases_percent",
    ]
    rows = []
    for f in files:
        d = dict.fromkeys(fields, "NA")
        d["Sample"] = f.name.replace("_bbduk.log", "")
        for line in f.read_text(errors="ignore").splitlines():
            m = _BBDUK_RE.search(line)
            if not m:
                continue
            lbl = m.group("label").replace(" ", "_")
            # The Input line has no percentage columns.
            for column, value in (
                (f"{lbl}_reads", m.group("reads")),
                (f"{lbl}_bases", m.group("bases")),
                (f"{lbl}_reads_percent", m.group("rpct")),
                (f"{lbl}_bases_percent", m.group("bpct")),
            ):
                if column in d:
                    d[column] = value or "NA"
        rows.append(d)

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, delimiter="\t", lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"[DONE] BBDuk QC matrix: {output}")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--rsem-dir", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--star-logs", required=True, type=Path)
    p.add_argument("--bbduk-logs", required=True, type=Path)
    p.add_argument("--star-out", required=True, type=Path)
    p.add_argument("--bbduk-out", required=True, type=Path)
    args = p.parse_args()

    expression_matrix(args.rsem_dir, args.output)
    star_qc(args.star_logs, args.star_out)
    bbduk_qc(args.bbduk_logs, args.bbduk_out)


if __name__ == "__main__":
    main()
