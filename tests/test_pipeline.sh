#!/usr/bin/env bash
# Minimal unit tests — no external tools required.
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOG_DIR="/tmp/pipeline_test_logs"
DISK_WARN_GB=5
mkdir -p "$LOG_DIR"

source "${PIPELINE_DIR}/lib/utils.sh"
source "${PIPELINE_DIR}/steps/validate_inputs.sh"

_pass=0
_fail=0

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        echo "PASS: ${desc}"
        (( ++_pass ))
    else
        echo "FAIL: ${desc}  (got='${got}', want='${want}')"
        (( ++_fail )) || true
    fi
}

# A function that calls exit 1 must run in a subshell so it can't kill the test.
assert_fails() {
    local desc="$1"; shift
    if ! ( "$@" 2>/dev/null ); then
        echo "PASS: ${desc} (expected failure)"
        (( ++_pass ))
    else
        echo "FAIL: ${desc} (expected failure, but succeeded)"
        (( ++_fail )) || true
    fi
}

# --- normalize_layout --------------------------------------------------------
assert_eq "PAIRED literal"    "$(normalize_layout PAIRED)"    "PAIRED"
assert_eq "paired lowercase"  "$(normalize_layout paired)"    "PAIRED"
assert_eq "PE"                "$(normalize_layout PE)"        "PAIRED"
assert_eq "Paired-End"        "$(normalize_layout Paired-End)" "PAIRED"
assert_eq "SINGLE literal"    "$(normalize_layout SINGLE)"    "SINGLE"
assert_eq "SE"                "$(normalize_layout SE)"        "SINGLE"
assert_eq "Single-End"        "$(normalize_layout Single-End)" "SINGLE"
assert_fails "unknown layout" normalize_layout UNKNOWN

# --- require_file ------------------------------------------------------------
assert_fails "require_file missing" require_file "/no/such/file" ""

tmpf="$(mktemp)"
assert_eq "require_file exists" "$(require_file "$tmpf" "" && echo ok)" "ok"
rm -f "$tmpf"

# --- detect_inputs -----------------------------------------------------------
tmpd="$(mktemp -d)"
touch "${tmpd}/genome.fna.gz" "${tmpd}/annotation.gtf.gz" "${tmpd}/SraRunTable.csv"
detect_inputs "$tmpd"
assert_eq "FNA_FILE set"   "$FNA_FILE"   "${tmpd}/genome.fna.gz"
assert_eq "GTF_FILE set"   "$GTF_FILE"   "${tmpd}/annotation.gtf.gz"
assert_eq "RUN_TABLE set"  "$RUN_TABLE"  "${tmpd}/SraRunTable.csv"

# Two FASTA files should abort
touch "${tmpd}/extra.fa.gz"
assert_fails "detect_inputs two FASTAs" detect_inputs "$tmpd"
rm -rf "$tmpd"

# --- parse_runtable.py -------------------------------------------------------
tmpd="$(mktemp -d)"
cat > "${tmpd}/SraRunTable.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR123456,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera
SRR999999,WGS,GENOMIC,SINGLE,Helicoverpa armigera
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input  "${tmpd}/SraRunTable.csv" \
    --output "${tmpd}/samples.tsv"

rows="$(awk 'NR>1' "${tmpd}/samples.tsv" | wc -l | tr -d ' ')"
assert_eq "parse_runtable: 1 RNA-Seq row"  "$rows"  "1"

got_srr="$(awk -F'\t' 'NR==2{print $1}' "${tmpd}/samples.tsv")"
assert_eq "parse_runtable: correct SRR"    "$got_srr"  "SRR123456"

got_layout="$(awk -F'\t' 'NR==2{print $3}' "${tmpd}/samples.tsv")"
assert_eq "parse_runtable: correct layout" "$got_layout" "PAIRED"

got_species="$(awk -F'\t' 'NR==2{print $2}' "${tmpd}/samples.tsv")"
assert_eq "parse_runtable: species key from Organism" "$got_species" "Helicoverpa_armigera"
rm -rf "$tmpd"

# --- parse_runtable.py: generic organism (no hardcoded species list) ---------
# Any organism must resolve to a Genus_species key derived from the Organism
# field, so the pipeline is not tied to a fixed taxon.
tmpd="$(mktemp -d)"
cat > "${tmpd}/generic.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR200001,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Danio rerio
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/generic.csv" --output "${tmpd}/generic.tsv" >/dev/null 2>&1 || true

got_generic="$(awk -F'\t' 'NR==2{print $2}' "${tmpd}/generic.tsv" 2>/dev/null || true)"
assert_eq "parse_runtable: derives key for any organism" "$got_generic" "Danio_rerio"
rm -rf "$tmpd"

# --- parse_runtable.py: --species restricts to configured species ------------
tmpd="$(mktemp -d)"
cat > "${tmpd}/multi.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR300001,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera
SRR300002,RNA-Seq,TRANSCRIPTOMIC,SINGLE,Bombyx mori
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/multi.csv" --output "${tmpd}/multi.tsv" \
    --species Helicoverpa_armigera >/dev/null 2>&1 || true

multi_rows="$(awk 'NR>1' "${tmpd}/multi.tsv" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "parse_runtable: --species keeps only listed species" "$multi_rows" "1"

multi_sp="$(awk -F'\t' 'NR==2{print $2}' "${tmpd}/multi.tsv" 2>/dev/null || true)"
assert_eq "parse_runtable: --species kept the right species" "$multi_sp" "Helicoverpa_armigera"
rm -rf "$tmpd"

# --- parse_runtable.py: --fallback for empty/unresolvable Organism -----------
tmpd="$(mktemp -d)"
cat > "${tmpd}/fallback.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR400001,RNA-Seq,TRANSCRIPTOMIC,PAIRED,
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/fallback.csv" --output "${tmpd}/fallback.tsv" \
    --fallback My_species >/dev/null 2>&1 || true

fb_sp="$(awk -F'\t' 'NR==2{print $2}' "${tmpd}/fallback.tsv" 2>/dev/null || true)"
assert_eq "parse_runtable: --fallback assigns key when Organism is empty" "$fb_sp" "My_species"
rm -rf "$tmpd"

# --- parse_samples: restricts output to the active SPECIES_CONFIG species -----
tmpd="$(mktemp -d)"
cat > "${tmpd}/runtable.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR500001,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera
SRR500002,RNA-Seq,TRANSCRIPTOMIC,SINGLE,Danio rerio
CSV

SPECIES_CONFIG=( "Helicoverpa_armigera|url|url|true" "Danio_rerio|url|url|false" )
RUN_TABLE="${tmpd}/runtable.csv"
SAMPLES_TSV="${tmpd}/samples.tsv"
source "${PIPELINE_DIR}/steps/parse_samples.sh"
parse_samples >/dev/null 2>&1 || true

ps_rows="$(awk 'NR>1' "${tmpd}/samples.tsv" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "parse_samples: restricts to active species" "$ps_rows" "1"
ps_sp="$(awk -F'\t' 'NR==2{print $2}' "${tmpd}/samples.tsv" 2>/dev/null || true)"
assert_eq "parse_samples: kept the active species" "$ps_sp" "Helicoverpa_armigera"
rm -rf "$tmpd"
unset SPECIES_CONFIG RUN_TABLE SAMPLES_TSV

# --- Summary -----------------------------------------------------------------
echo ""
echo "Results: ${_pass} passed, ${_fail} failed."
[[ "$_fail" -eq 0 ]]
