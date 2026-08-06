#!/usr/bin/env bash
# Unit tests for the pure-bash and Python layers.
# No bioinformatics tool and no network access is required.
#
#   bash pipeline/tests/test_pipeline.sh
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOG_DIR="$(mktemp -d)"
DISK_WARN_GB=5
REFERENCES_DIR="${LOG_DIR}/references"
trap 'rm -rf "$LOG_DIR"' EXIT

source "${PIPELINE_DIR}/lib/utils.sh"
source "${PIPELINE_DIR}/lib/species_config.sh"
source "${PIPELINE_DIR}/lib/menu.sh"
source "${PIPELINE_DIR}/steps/validate_inputs.sh"
source "${PIPELINE_DIR}/steps/parse_samples.sh"
source "${PIPELINE_DIR}/steps/postprocess.sh"

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
    if ! ( "$@" >/dev/null 2>&1 ); then
        echo "PASS: ${desc} (expected failure)"
        (( ++_pass ))
    else
        echo "FAIL: ${desc} (expected failure, but succeeded)"
        (( ++_fail )) || true
    fi
}

assert_succeeds() {
    local desc="$1"; shift
    if ( "$@" >/dev/null 2>&1 ); then
        echo "PASS: ${desc}"
        (( ++_pass ))
    else
        echo "FAIL: ${desc} (expected success, but failed)"
        (( ++_fail )) || true
    fi
}

# --- normalize_layout --------------------------------------------------------
assert_eq "PAIRED literal"    "$(normalize_layout PAIRED)"     "PAIRED"
assert_eq "paired lowercase"  "$(normalize_layout paired)"     "PAIRED"
assert_eq "PE"                "$(normalize_layout PE)"         "PAIRED"
assert_eq "Paired-End"        "$(normalize_layout Paired-End)" "PAIRED"
assert_eq "SINGLE literal"    "$(normalize_layout SINGLE)"     "SINGLE"
assert_eq "SE"                "$(normalize_layout SE)"         "SINGLE"
assert_eq "Single-End"        "$(normalize_layout Single-End)" "SINGLE"
assert_fails "unknown layout" normalize_layout UNKNOWN

# --- require_file ------------------------------------------------------------
assert_fails "require_file missing" require_file "/no/such/file" ""

tmpf="$(mktemp)"
assert_eq "require_file exists" "$(require_file "$tmpf" "" && echo ok)" "ok"
rm -f "$tmpf"

# --- species_config ----------------------------------------------------------
# Entries are written with backslash continuations; splitting must strip them.
species_entry_split "Genus_species|\
http://example.org/g.fna.gz|\
http://example.org/g.gtf.gz|\
true" sc_key sc_fna sc_gtf sc_active
assert_eq "species_entry_split: key"    "$sc_key"    "Genus_species"
assert_eq "species_entry_split: fna"    "$sc_fna"    "http://example.org/g.fna.gz"
assert_eq "species_entry_split: active" "$sc_active" "true"

SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" "Danio_rerio|f|g|false" )
assert_eq "species_config_active_keys: only active" \
    "$(species_config_active_keys | paste -sd, -)" "Helicoverpa_armigera"

tmpd="$(mktemp -d)"
SP_KEYS=(); SP_FNA=(); SP_GTF=(); SP_ACTIVE=()
species_config_upsert Danio_rerio a.fna.gz a.gtf.gz true
assert_eq "species_config_upsert: new entry" "$SPECIES_CONFIG_LAST_ACTION" "added"
species_config_upsert Danio_rerio b.fna.gz b.gtf.gz false
assert_eq "species_config_upsert: existing entry" "$SPECIES_CONFIG_LAST_ACTION" "updated"
assert_eq "species_config_upsert: no duplicate row" "${#SP_KEYS[@]}" "1"
assert_eq "species_config_upsert: value replaced"   "${SP_FNA[0]}"   "b.fna.gz"

# Round-trip: what save writes, load must read back identically.
species_config_save "${tmpd}/species.sh"
SP_KEYS=(); SP_FNA=(); SP_GTF=(); SP_ACTIVE=()
species_config_load "${tmpd}/species.sh"
assert_eq "species_config save/load: key"    "${SP_KEYS[0]}"   "Danio_rerio"
assert_eq "species_config save/load: gtf"    "${SP_GTF[0]}"    "b.gtf.gz"
assert_eq "species_config save/load: active" "${SP_ACTIVE[0]}" "false"
assert_eq "species_config_index: absent key" "$(species_config_index Nope)" "-1"
rm -rf "$tmpd"

# --- detect_inputs -----------------------------------------------------------
# One active species: a local FASTA + GTF override the download URLs.
tmpd="$(mktemp -d)"
SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" )
touch "${tmpd}/genome.fna.gz" "${tmpd}/annotation.gtf.gz" "${tmpd}/SraRunTable.csv"
RUN_TABLE=""
detect_inputs "$tmpd" >/dev/null
assert_eq "detect_inputs: RUN_TABLE set" "$RUN_TABLE" "${tmpd}/SraRunTable.csv"
assert_eq "detect_inputs: FNA_FILE set"  "$FNA_FILE"  "${tmpd}/genome.fna.gz"
assert_eq "detect_inputs: GTF_FILE set"  "$GTF_FILE"  "${tmpd}/annotation.gtf.gz"

# Two active species: a single local genome cannot be assigned, so it is ignored
# rather than silently used for every organism.
SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" "Danio_rerio|f|g|true" )
RUN_TABLE=""
detect_inputs "$tmpd" >/dev/null
assert_eq "detect_inputs: local genome ignored for multi-species" "$FNA_FILE" ""

# A second RunTable is ambiguous and must abort.
SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" )
touch "${tmpd}/other_RunTable.csv"
RUN_TABLE=""
assert_fails "detect_inputs: two RunTables abort" detect_inputs "$tmpd"
rm -rf "$tmpd"

# References are optional — a RunTable alone is a valid input set.
tmpd="$(mktemp -d)"
touch "${tmpd}/SraRunTable.csv"
RUN_TABLE=""
detect_inputs "$tmpd" >/dev/null
assert_eq "detect_inputs: no local genome needed" "$FNA_FILE" ""
rm -rf "$tmpd"
unset RUN_TABLE

# --- parse_runtable.py -------------------------------------------------------
tmpd="$(mktemp -d)"
cat > "${tmpd}/SraRunTable.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR123456,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera
SRR999999,WGS,GENOMIC,SINGLE,Helicoverpa armigera
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input  "${tmpd}/SraRunTable.csv" \
    --output "${tmpd}/samples.tsv" >/dev/null

rows="$(awk 'NR>1' "${tmpd}/samples.tsv" | wc -l | tr -d ' ')"
assert_eq "parse_runtable: 1 RNA-Seq row"  "$rows"  "1"

got_srr="$(awk -F'\t' 'NR==2{print $1}' "${tmpd}/samples.tsv")"
assert_eq "parse_runtable: correct SRR"    "$got_srr"  "SRR123456"

got_layout="$(awk -F'\t' 'NR==2{print $3}' "${tmpd}/samples.tsv")"
assert_eq "parse_runtable: correct layout" "$got_layout" "PAIRED"

got_species="$(awk -F'\t' 'NR==2{print $2}' "${tmpd}/samples.tsv")"
assert_eq "parse_runtable: species key from Organism" "$got_species" "Helicoverpa_armigera"
rm -rf "$tmpd"

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

# --species restricts the output to the configured species.
tmpd="$(mktemp -d)"
cat > "${tmpd}/multi.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR300001,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera
SRR300002,RNA-Seq,TRANSCRIPTOMIC,SINGLE,Danio rerio
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/multi.csv" --output "${tmpd}/multi.tsv" \
    --species Helicoverpa_armigera >/dev/null 2>&1 || true

multi_rows="$(awk 'NR>1' "${tmpd}/multi.tsv" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "parse_runtable: --species keeps only listed species" "$multi_rows" "1"

multi_sp="$(awk -F'\t' 'NR==2{print $2}' "${tmpd}/multi.tsv" 2>/dev/null || true)"
assert_eq "parse_runtable: --species kept the right species" "$multi_sp" "Helicoverpa_armigera"
rm -rf "$tmpd"

# --fallback covers rows with an empty or unresolvable Organism field.
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

# --- Bundled example RunTable ------------------------------------------------
# run.sh --example depends on this file parsing to exactly one usable sample.
tmpd="$(mktemp -d)"
SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" )
RUN_TABLE="${PIPELINE_DIR}/examples/SraRunTable.example.csv"
SAMPLES_TSV="${tmpd}/samples.tsv"
parse_samples >/dev/null 2>&1 || true

ex_rows="$(awk 'NR>1' "$SAMPLES_TSV" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "example RunTable: 1 sample" "$ex_rows" "1"
assert_eq "example RunTable: species"  \
    "$(awk -F'\t' 'NR==2{print $2}' "$SAMPLES_TSV" 2>/dev/null || true)" "Helicoverpa_armigera"
assert_eq "example RunTable: layout"   \
    "$(awk -F'\t' 'NR==2{print $3}' "$SAMPLES_TSV" 2>/dev/null || true)" "PAIRED"
rm -rf "$tmpd"
unset RUN_TABLE SAMPLES_TSV

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
parse_samples >/dev/null 2>&1 || true

ps_rows="$(awk 'NR>1' "${tmpd}/samples.tsv" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "parse_samples: restricts to active species" "$ps_rows" "1"
ps_sp="$(awk -F'\t' 'NR==2{print $2}' "${tmpd}/samples.tsv" 2>/dev/null || true)"
assert_eq "parse_samples: kept the active species" "$ps_sp" "Helicoverpa_armigera"
rm -rf "$tmpd"
unset SPECIES_CONFIG RUN_TABLE SAMPLES_TSV

# --- CLI ---------------------------------------------------------------------
# --help must work without any external tool installed, so it has to be handled
# before the pre-flight check.
run_help="$(bash "${PIPELINE_DIR}/run.sh" --help)"
for flag in --build-refs --test --full --example --interactive --no-preview; do
    assert_eq "run.sh --help documents ${flag}" \
        "$(grep -q -- "$flag" <<< "$run_help" && echo yes || echo no)" "yes"
done
assert_fails "run.sh rejects unknown flags" bash "${PIPELINE_DIR}/run.sh" --nope
assert_succeeds "setup.sh --help" bash "${PIPELINE_DIR}/setup.sh" --help
assert_fails "setup.sh rejects unknown flags" bash "${PIPELINE_DIR}/setup.sh" --nope

setup_help="$(bash "${PIPELINE_DIR}/setup.sh" --help)"
for flag in --resources --species --add-species --interactive; do
    assert_eq "setup.sh --help documents ${flag}" \
        "$(grep -q -- "$flag" <<< "$setup_help" && echo yes || echo no)" "yes"
done

# --- Interactive menu --------------------------------------------------------
# The menu must reject junk, keep asking, and leave on option 7 — all without
# running any pipeline command.
EXAMPLE_SPECIES="Helicoverpa_armigera"
menu_out="$(printf '99\nzz\n\n7\n' | menu_main)"
assert_eq "menu: rejects a non-listed number" \
    "$(grep -c "'99' is not a valid option" <<< "$menu_out")" "1"
assert_eq "menu: rejects non-numeric input" \
    "$(grep -c "'zz' is not a valid option" <<< "$menu_out")" "1"
assert_eq "menu: option 7 exits" \
    "$(grep -c 'Bye.' <<< "$menu_out")" "1"
assert_eq "menu: redraws after every answer" \
    "$(grep -c '\[7\] Exit' <<< "$menu_out")" "4"

# Closed stdin must end the menu instead of looping on EOF.
assert_succeeds "menu: exits on EOF" bash -c \
    "PIPELINE_DIR='${PIPELINE_DIR}' EXAMPLE_SPECIES=X; source '${PIPELINE_DIR}/lib/menu.sh'; menu_main </dev/null"

# --- Expression matrix preview ----------------------------------------------
tmpd="$(mktemp -d)"
RESULTS_DIR="$tmpd"
mkdir -p "${tmpd}/tables"
printf 'gene_id\tSRR1_TPM\n' > "${tmpd}/tables/gene_expression_matrix.tsv"
for i in 1 2 3 4 5; do printf 'g%s\t%s.0\n' "$i" "$i"; done \
    >> "${tmpd}/tables/gene_expression_matrix.tsv"

ENABLE_PREVIEW=true
PREVIEW_LINES=3
preview_out="$(preview_expression_matrix)"
assert_eq "preview: announces the inner join" \
    "$(grep -c 'Preview of gene_expression_matrix.tsv' <<< "$preview_out")" "1"
assert_eq "preview: honours PREVIEW_LINES" \
    "$(grep -c $'^g[0-9]\t' <<< "$preview_out")" "2"   # header + 2 gene rows

ENABLE_PREVIEW=false
assert_eq "preview: ENABLE_PREVIEW=false prints nothing" \
    "$(preview_expression_matrix)" ""

# A missing matrix warns but must never abort the run.
ENABLE_PREVIEW=true
rm -f "${tmpd}/tables/gene_expression_matrix.tsv"
assert_eq "preview: missing matrix warns" \
    "$(preview_expression_matrix | grep -c '\[WARN\]')" "1"
assert_succeeds "preview: missing matrix is not fatal" preview_expression_matrix
rm -rf "$tmpd"
unset RESULTS_DIR ENABLE_PREVIEW PREVIEW_LINES

# --- Failure cleanup ---------------------------------------------------------
# A failed stage must drop its own half-written output and must never touch a
# different sample's files.
tmpd="$(mktemp -d)"
RESULTS_DIR="$tmpd"
TMP_DIR="${tmpd}/tmp"
TEST_MODE=false
TEST_READS=100
mkdir -p "${tmpd}/rsem/Genus_species" "$TMP_DIR"
source "${PIPELINE_DIR}/lib/cleanup.sh"
source "${PIPELINE_DIR}/lib/sample_tracker.sh"
source "${PIPELINE_DIR}/steps/process_sample.sh"
tracker_init

RAW_1="${tmpd}/SRR2_1.fastq"; RAW_2=""; RAW_SE=""
CLEAN_1=""; CLEAN_2=""; CLEAN_SE=""; SINGLETONS=""
other_sample="${tmpd}/SRR1_1.fastq"
partial_genes="${tmpd}/rsem/Genus_species/SRR2.genes.results"
touch "$RAW_1" "$other_sample" "$partial_genes"

prefetch_status=OK; fastq_status=FAILED; trim_status=PENDING
star_status=PENDING; rsem_status=PENDING
_record_sample_failure SRR2 Genus_species PAIRED fastq-dump >/dev/null 2>&1

assert_eq "failure cleanup: removes the failed sample's FASTQ" \
    "$([[ -e "$RAW_1" ]] && echo yes || echo no)" "no"
assert_eq "failure cleanup: removes the partial RSEM output" \
    "$([[ -e "$partial_genes" ]] && echo yes || echo no)" "no"
assert_eq "failure cleanup: keeps another sample's files" \
    "$([[ -e "$other_sample" ]] && echo yes || echo no)" "yes"
assert_eq "failure cleanup: records the failed stage" \
    "$(awk -F'\t' 'NR>1{print $1"/"$7}' "$SUMMARY_FILE")" "SRR2/FAILED"
rm -rf "$tmpd"
unset RESULTS_DIR TMP_DIR RAW_1 RAW_2 RAW_SE CLEAN_1 CLEAN_2 CLEAN_SE SINGLETONS

# --- Syntax ------------------------------------------------------------------
syntax_errors=0
while IFS= read -r script; do
    bash -n "$script" || (( ++syntax_errors ))
done < <(find "$PIPELINE_DIR" -name '*.sh' -type f | sort)
assert_eq "all shell scripts parse" "$syntax_errors" "0"

# --- Summary -----------------------------------------------------------------
echo ""
echo "Results: ${_pass} passed, ${_fail} failed."
[[ "$_fail" -eq 0 ]]
