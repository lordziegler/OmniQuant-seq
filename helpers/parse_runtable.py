#!/usr/bin/env python3
"""Parses an NCBI SRA RunTable (CSV or XLSX) and writes samples.tsv."""

import argparse
import csv
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Optional

ACCESSION_RE = re.compile(r"^[SED]RR\d+$")
RUN_KEYS = ("Run", "Run Accession", "RunAccession", "Accession")

# Sample-sheet columns written after LAYOUT, each mapped to the RunTable fields
# it may come from; the first informative one wins. Submitters spread the same
# attribute over differently named BioSample fields.
METADATA = {
    "TISSUE":     ("tissue", "tissue_type", "Organism_part"),
    "PLATFORM":   ("Platform",),
    "INSTRUMENT": ("Instrument",),
    "BIOPROJECT": ("BioProject",),
    "DEV_STAGE":  ("dev_stage", "Developmental_Stage", "Development_stage", "lifestage"),
    "SEX":        ("sex", "gender"),
    "TREATMENT":  ("treatment", "Diet"),
}

# INSDC null placeholders. Kept out of the sample sheet so a design formula
# never sees "missing" as a factor level.
_NULLS = {"", "missing", "not applicable", "not collected", "not provided",
          "not determined", "unknown", "na", "n/a"}


def _load(path: Path) -> list[dict]:
    if path.suffix.lower() in {".xlsx", ".xls"}:
        try:
            import openpyxl
        except ImportError:
            sys.exit("[ABORT] openpyxl not installed: pip install openpyxl")
        wb   = openpyxl.load_workbook(str(path), read_only=True)
        rows = list(wb.worksheets[0].iter_rows(values_only=True))
        wb.close()
    else:
        with path.open("r", encoding="utf-8-sig", newline="") as fh:
            rows = [tuple(r) for r in csv.reader(fh)]

    if not rows:
        sys.exit(f"[ABORT] RunTable is empty: {path}")

    headers = [str(h).strip() if h is not None else f"col_{i}"
               for i, h in enumerate(rows[0])]
    return [dict(zip(headers, row)) for row in rows[1:]
            if any(v is not None and str(v).strip() for v in row)]


def _get(row: dict, *keys: str) -> str:
    for k in keys:
        v = row.get(k)
        if v is not None and str(v).strip():
            return str(v).strip()
    return ""


def _meta(row: dict, keys: tuple) -> str:
    """First non-placeholder value among `keys`, or NA. Never empty: bash reads
    samples.tsv with IFS=tab, which collapses consecutive tabs. Inner whitespace
    is collapsed so free text cannot carry a tab or newline into the TSV."""
    for k in keys:
        v = _get(row, k)
        if v.lower() not in _NULLS:
            return " ".join(v.split())
    return "NA"


def _derive_key(organism: str) -> Optional[str]:
    """Turn a scientific name into a Genus_species key, matching the naming
    convention used by SPECIES_CONFIG in config/species.sh. Works for any taxon:
    'Helicoverpa armigera' -> 'Helicoverpa_armigera'."""
    tokens = organism.replace("_", " ").split()
    if len(tokens) >= 2:
        return f"{tokens[0].capitalize()}_{tokens[1].lower()}"
    if tokens:
        return tokens[0].capitalize()
    return None


def _species(organism: str, allowed: Optional[set], fallback: Optional[str]) -> Optional[str]:
    """Resolve a RunTable row to a species key. The key is derived from the
    Organism field (no hardcoded species list); `fallback` is used when the
    field is empty or unresolvable. When `allowed` is given, only keys in that
    set are kept, so a run processes only the species you have references for."""
    key = _derive_key(organism) or fallback
    if key is None:
        return None
    if allowed and key not in allowed:
        return None
    return key


def _layout(raw: str) -> str:
    v = raw.strip().upper().replace("-", " ").replace("_", " ")
    if v in {"PAIRED", "PAIRED END", "PE"}:
        return "PAIRED"
    if v in {"SINGLE", "SINGLE END", "SE"}:
        return "SINGLE"
    return ""


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--input",    "-i", required=True, type=Path)
    p.add_argument("--output",   "-o", default="samples.tsv", type=Path)
    p.add_argument("--fallback", "-f", default=None,
                   help="Species key for rows with an empty/unresolvable Organism field.")
    p.add_argument("--species",  "-s", default=None,
                   help="Comma-separated Genus_species keys to keep (e.g. "
                        "'Helicoverpa_armigera,Danio_rerio'). Others are dropped. "
                        "Omit to keep every organism found.")
    p.add_argument("--allow-genomic-source", action="store_true",
                   help="Also accept LibrarySource=GENOMIC rows. By default only "
                        "TRANSCRIPTOMIC is accepted; GENOMIC is a DNA-seq source and "
                        "rarely appropriate for an RNA-seq abundance workflow.")
    p.add_argument("--assume-layout", choices=["PAIRED", "SINGLE"], default=None,
                   help="Layout to assign to a row whose LibraryLayout is missing or "
                        "unrecognized. Omit to exclude such rows instead (safer default "
                        "than silently guessing PAIRED).")
    p.add_argument("--star-overhang", type=int, default=None,
                   help="STAR_OVERHANG in use for the shared index (sjdbOverhang). When "
                        "given, warns about samples whose AvgSpotLen is far from "
                        "overhang+1, since one index serves every run of a species.")
    p.add_argument("--runs", default=None,
                   help="Comma-separated accessions to keep (e.g. 'SRR10345445,SRR10345446'), "
                        "to retry or analyse single samples. Each one must pass the filters "
                        "above, or the run aborts naming it.")
    args = p.parse_args()

    wanted = ({s.strip().upper() for s in args.runs.split(",") if s.strip()}
              if args.runs else None)
    allowed = ({s.strip() for s in args.species.split(",") if s.strip()}
               if args.species else None)

    if not args.input.exists():
        sys.exit(f"[ABORT] Input not found: {args.input}")

    all_rows = _load(args.input)
    print(f"[INFO] RunTable loaded: {len(all_rows)} records.")
    if wanted:
        all_rows = [r for r in all_rows
                    if _get(r, *RUN_KEYS).replace("\r", "") in wanted]
        print(f"[INFO] After --runs filter: {len(all_rows)}")

    rnaseq = [r for r in all_rows
              if _get(r, "Assay Type", "AssayType", "assay_type") == "RNA-Seq"]
    print(f"[INFO] After RNA-Seq filter: {len(rnaseq)}")

    allowed_sources = {"TRANSCRIPTOMIC"} | ({"GENOMIC"} if args.allow_genomic_source else set())
    has_source = [r for r in rnaseq
                  if _get(r, "LibrarySource", "Library Source", "library_source")]
    if not has_source:
        print("[WARN] LibrarySource field not found or empty — using all RNA-Seq rows.")
        sourced = rnaseq
    else:
        sourced = [r for r in has_source
                   if _get(r, "LibrarySource", "Library Source", "library_source") in allowed_sources]
        if not sourced:
            print(f"[WARN] No records matched LibrarySource {sorted(allowed_sources)} — "
                  f"0 samples retained. Pass --allow-genomic-source to also accept GENOMIC.")

    mapped = []
    for r in sourced:
        sp = _species(_get(r, "Organism", "organism", "scientific_name"), allowed, args.fallback)
        if sp:
            mapped.append({**r, "_sp": sp})

    seen:  set   = set()
    clean: list  = []
    for r in mapped:
        srr = _get(r, *RUN_KEYS).replace("\r", "")
        if not ACCESSION_RE.match(srr) or srr in seen:
            continue
        seen.add(srr)
        layout = _layout(_get(r, "LibraryLayout", "Library Layout", "library_layout"))
        if not layout:
            if args.assume_layout:
                layout = args.assume_layout
                print(f"[WARN] Unknown layout for {srr} — assuming {layout} (--assume-layout).")
            else:
                print(f"[WARN] Unknown layout for {srr} — excluded. Re-run with "
                      f"--assume-layout PAIRED|SINGLE to include it.")
                continue

        if args.star_overhang is not None:
            avg_len_raw = _get(r, "AvgSpotLen", "avg_spot_len")
            expected = args.star_overhang + 1
            try:
                avg_len = float(avg_len_raw)
                if avg_len and not (0.5 * expected <= avg_len <= 2 * expected):
                    print(f"[WARN] {srr}: AvgSpotLen={avg_len:.0f} nt is far from "
                          f"STAR_OVERHANG+1={expected} nt — the shared per-species index "
                          f"may be poorly matched for this run's read length.")
            except ValueError:
                pass

        clean.append({"SRR": srr, "SPECIES": r["_sp"], "LAYOUT": layout,
                      **{col: _meta(r, keys) for col, keys in METADATA.items()}})

    # A requested accession that silently drops out would leave the user
    # believing it was processed.
    missing = sorted(wanted - {r["SRR"] for r in clean}) if wanted else []
    if missing:
        sys.exit(f"[ABORT] --runs: not in the RunTable or excluded by the filters "
                 f"above: {', '.join(missing)}")
    if not clean:
        sys.exit("[ABORT] No valid RNA-Seq samples found.")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["SRR", "SPECIES", "LAYOUT", *METADATA],
                           delimiter="\t", lineterminator="\n")
        w.writeheader()
        w.writerows(clean)

    by_layout  = Counter(r["LAYOUT"]  for r in clean)
    by_species = Counter(r["SPECIES"] for r in clean)
    print(f"[DONE] {len(clean)} samples written to: {args.output}")
    print(f"       Layout  : {dict(by_layout)}")
    print(f"       Tissue  : {dict(Counter(r['TISSUE'] for r in clean))}")
    for sp, n in sorted(by_species.items()):
        print(f"       {sp}: {n}")


if __name__ == "__main__":
    main()
