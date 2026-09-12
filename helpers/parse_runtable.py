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
    args = p.parse_args()

    allowed = ({s.strip() for s in args.species.split(",") if s.strip()}
               if args.species else None)

    if not args.input.exists():
        sys.exit(f"[ABORT] Input not found: {args.input}")

    all_rows = _load(args.input)
    print(f"[INFO] RunTable loaded: {len(all_rows)} records.")

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
        srr = _get(r, "Run", "Run Accession", "RunAccession", "Accession").replace("\r", "")
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

        clean.append({"SRR": srr, "SPECIES": r["_sp"], "LAYOUT": layout})

    if not clean:
        sys.exit("[ABORT] No valid RNA-Seq samples found.")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["SRR", "SPECIES", "LAYOUT"],
                           delimiter="\t", lineterminator="\n")
        w.writeheader()
        w.writerows(clean)

    by_layout  = Counter(r["LAYOUT"]  for r in clean)
    by_species = Counter(r["SPECIES"] for r in clean)
    print(f"[DONE] {len(clean)} samples written to: {args.output}")
    print(f"       Layout  : {dict(by_layout)}")
    for sp, n in sorted(by_species.items()):
        print(f"       {sp}: {n}")


if __name__ == "__main__":
    main()
