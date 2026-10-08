#!/usr/bin/env bash
# bash tests/test_pipeline.sh — no bioinformatics tools, no network.
# shellcheck disable=SC2154,SC2030,SC2329  # printf -v targets; subshells isolate tests; stubs called via "$star"
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOG_DIR="$(mktemp -d)"
DISK_WARN_GB=5
REFERENCES_DIR="${LOG_DIR}/references"
trap 'rm -rf "$LOG_DIR"' EXIT

source "${PIPELINE_DIR}/lib/utils.sh"
source "${PIPELINE_DIR}/lib/species_config.sh"
source "${PIPELINE_DIR}/lib/prompt.sh"
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

# Runs in a subshell: the function may call exit.
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

assert_fails "require_file missing" require_file "/no/such/file" ""

tmpf="$(mktemp)"
assert_eq "require_file exists" "$(require_file "$tmpf" "" && echo ok)" "ok"
rm -f "$tmpf"

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

species_config_save "${tmpd}/species.sh"
SP_KEYS=(); SP_FNA=(); SP_GTF=(); SP_ACTIVE=()
species_config_load "${tmpd}/species.sh"
assert_eq "species_config save/load: key"    "${SP_KEYS[0]}"   "Danio_rerio"
assert_eq "species_config save/load: gtf"    "${SP_GTF[0]}"    "b.gtf.gz"
assert_eq "species_config save/load: active" "${SP_ACTIVE[0]}" "false"
assert_eq "species_config_index: absent key" "$(species_config_index Nope)" "-1"
rm -rf "$tmpd"

prompt_int p_threads "Threads" 8 1 16 </dev/null
assert_eq "prompt_int: EOF keeps the current value" "$p_threads" "8"

prompt_storage p_size "Max size" "100G" </dev/null
assert_eq "prompt_storage: EOF keeps the current value" "$p_size" "100G"

prompt_choice p_qtrim "Trim mode" "rl" rl r l f </dev/null
assert_eq "prompt_choice: EOF keeps the current value" "$p_qtrim" "rl"

prompt_path p_adapters "Adapters" "" </dev/null
assert_eq "prompt_path: EOF keeps the current value" "$p_adapters" ""

prompt_int p_ram "RAM" 32 1 7 <<< ""
assert_eq "prompt_int: Enter keeps a current value above the detected maximum" \
    "$p_ram" "32"

assert_fails "prompt_url: EOF aborts instead of looping" \
    bash -c "source '${PIPELINE_DIR}/lib/utils.sh'; source '${PIPELINE_DIR}/lib/prompt.sh'; prompt_url u 'URL' </dev/null"

tmpd="$(mktemp -d)"
SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" )
touch "${tmpd}/genome.fna.gz" "${tmpd}/annotation.gtf.gz" "${tmpd}/SraRunTable.csv"
RUN_TABLE=""
detect_local_references "$tmpd" >/dev/null
detect_run_table "$tmpd" >/dev/null
assert_eq "detect_run_table: RUN_TABLE set" "$RUN_TABLE" "${tmpd}/SraRunTable.csv"
assert_eq "detect_local_references: FNA_FILE set"  "$FNA_FILE"  "${tmpd}/genome.fna.gz"
assert_eq "detect_local_references: GTF_FILE set"  "$GTF_FILE"  "${tmpd}/annotation.gtf.gz"

SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" "Danio_rerio|f|g|true" )
RUN_TABLE=""
detect_local_references "$tmpd" >/dev/null
detect_run_table "$tmpd" >/dev/null
assert_eq "detect_local_references: local genome ignored for multi-species" "$FNA_FILE" ""

SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" )
EXAMPLE_MODE=true
detect_local_references "$tmpd" >/dev/null
EXAMPLE_MODE=false
assert_eq "detect_local_references: local genome refused in example mode" "$FNA_FILE" ""

SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" )
touch "${tmpd}/other_RunTable.csv"
RUN_TABLE=""
assert_fails "detect_run_table: two RunTables abort" detect_run_table "$tmpd"
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
touch "${tmpd}/SraRunTable.csv"
RUN_TABLE=""
detect_local_references "$tmpd" >/dev/null
detect_run_table "$tmpd" >/dev/null
assert_eq "detect_local_references: no local genome needed" "$FNA_FILE" ""
rm -rf "$tmpd"
unset RUN_TABLE

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

# 21 runs of 2x150, one mislabelled SINGLE: n=20 of N=21, overhang 149 not 299.
tmpd="$(mktemp -d)"
{
    echo "Run,AvgSpotLen"
    printf 'SRR3000%02d,300\n' $(seq 0 20)
} > "${tmpd}/SraRunTable.csv"
{
    printf 'SRR\tSPECIES\tLAYOUT\n'
    printf 'SRR3000%02d\tX_y\tPAIRED\n' $(seq 0 19)
    printf 'SRR300020\tX_y\tSINGLE\n'
} > "${tmpd}/samples.tsv"
sr_out="$(python3 "${PIPELINE_DIR}/helpers/sample_runtable.py" \
    --runtable "${tmpd}/SraRunTable.csv" --samples "${tmpd}/samples.tsv" \
    --output "${tmpd}/pilot.csv")"
assert_eq "sample_runtable: Cochran n with finite population correction" \
    "$(grep -o 'n = [0-9]*' <<< "$sr_out")" "n = 20"
assert_eq "sample_runtable: pilot RunTable has n rows" \
    "$(awk 'NR>1' "${tmpd}/pilot.csv" | wc -l | tr -d ' ')" "20"
assert_eq "sample_runtable: overhang ignores a mislabelled outlier" \
    "$(grep -o 'census) = [0-9]*' <<< "$sr_out")" "census) = 149"
rm -rf "$tmpd"

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

tmpd="$(mktemp -d)"
cat > "${tmpd}/genomic.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR600001,RNA-Seq,GENOMIC,PAIRED,Helicoverpa armigera
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/genomic.csv" --output "${tmpd}/genomic.tsv" >/dev/null 2>&1 || true
gen_rows="0"
[[ -f "${tmpd}/genomic.tsv" ]] && gen_rows="$(awk 'NR>1' "${tmpd}/genomic.tsv" | wc -l | tr -d ' ')"
assert_eq "parse_runtable: GENOMIC excluded by default" "$gen_rows" "0"

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/genomic.csv" --output "${tmpd}/genomic.tsv" \
    --allow-genomic-source >/dev/null 2>&1
gen_rows2="$(awk 'NR>1' "${tmpd}/genomic.tsv" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "parse_runtable: --allow-genomic-source admits it" "$gen_rows2" "1"
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
cat > "${tmpd}/nolayout.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR700001,RNA-Seq,TRANSCRIPTOMIC,,Helicoverpa armigera
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/nolayout.csv" --output "${tmpd}/nolayout.tsv" >/dev/null 2>&1 || true
nl_rows="0"
[[ -f "${tmpd}/nolayout.tsv" ]] && nl_rows="$(awk 'NR>1' "${tmpd}/nolayout.tsv" | wc -l | tr -d ' ')"
assert_eq "parse_runtable: unresolved layout excluded by default" "$nl_rows" "0"

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/nolayout.csv" --output "${tmpd}/nolayout.tsv" \
    --assume-layout SINGLE >/dev/null 2>&1
nl_layout="$(awk -F'\t' 'NR==2{print $3}' "${tmpd}/nolayout.tsv" 2>/dev/null || true)"
assert_eq "parse_runtable: --assume-layout includes it with the given layout" "$nl_layout" "SINGLE"
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
cat > "${tmpd}/spotlen.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism,AvgSpotLen
SRR800001,RNA-Seq,TRANSCRIPTOMIC,SINGLE,Helicoverpa armigera,300
CSV

overhang_out="$(python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/spotlen.csv" --output "${tmpd}/spotlen.tsv" \
    --star-overhang 99 2>&1)"
assert_eq "parse_runtable: --star-overhang warns on mismatched read length" \
    "$(grep -qi "far from STAR_OVERHANG" <<< "$overhang_out" && echo yes || echo no)" "yes"
ov_rows="$(awk 'NR>1' "${tmpd}/spotlen.tsv" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "parse_runtable: --star-overhang keeps the sample" "$ov_rows" "1"

printf 'SRR800002,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera,300\n' >> "${tmpd}/spotlen.csv"
paired_out="$(python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/spotlen.csv" --output "${tmpd}/spotlen.tsv" --star-overhang 99 2>&1)"
assert_eq "parse_runtable: --star-overhang compares a PAIRED run per mate (2x150)" \
    "$(grep -c "SRR800002" <<< "$paired_out")" "0"
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
cat > "${tmpd}/meta.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism,tissue,tissue_type,Platform,BioProject,sex
SRR900001,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera,missing,Gut,ILLUMINA,PRJNA579505,
CSV
python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/meta.csv" --output "${tmpd}/meta.tsv" >/dev/null 2>&1 || true
assert_eq "parse_runtable: sample-sheet header" \
    "$(head -1 "${tmpd}/meta.tsv" 2>/dev/null)" \
    "$(printf 'SRR\tSPECIES\tLAYOUT\tTISSUE\tPLATFORM\tINSTRUMENT\tBIOPROJECT\tDEV_STAGE\tSEX\tTREATMENT')"
assert_eq "parse_runtable: metadata skips placeholders and fills NA" \
    "$(awk -F'\t' 'NR==2{print $4"|"$5"|"$7"|"$9}' "${tmpd}/meta.tsv" 2>/dev/null)" \
    "Gut|ILLUMINA|PRJNA579505|NA"
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
cat > "${tmpd}/runs.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR910001,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera
SRR910002,RNA-Seq,TRANSCRIPTOMIC,SINGLE,Helicoverpa armigera
SRR910003,WGS,GENOMIC,PAIRED,Helicoverpa armigera
CSV
python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/runs.csv" --output "${tmpd}/runs.tsv" --runs srr910002 >/dev/null 2>&1 || true
cat > "${tmpd}/platforms.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism,Platform
SRR920001,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera,ILLUMINA
SRR920002,RNA-Seq,TRANSCRIPTOMIC,SINGLE,Helicoverpa armigera,OXFORD_NANOPORE
SRR920003,RNA-Seq,TRANSCRIPTOMIC,SINGLE,Helicoverpa armigera,ABI_SOLID
CSV
python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/platforms.csv" --output "${tmpd}/platforms.tsv" >/dev/null 2>&1 || true
assert_eq "parse_runtable: long reads are kept, colorspace is excluded" \
    "$(awk -F'\t' 'NR>1{print $1}' "${tmpd}/platforms.tsv" 2>/dev/null | paste -sd, -)" "SRR920001,SRR920002"
assert_fails "parse_runtable: --runs aborts on a run from an excluded platform" \
    python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/platforms.csv" --output "${tmpd}/platforms2.tsv" --runs SRR920003
assert_eq "parse_runtable: --runs keeps only the named accession" \
    "$(awk -F'\t' 'NR>1{print $1"/"$3}' "${tmpd}/runs.tsv" 2>/dev/null)" "SRR910002/SINGLE"
assert_fails "parse_runtable: --runs aborts on an accession filtered out" \
    python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input "${tmpd}/runs.csv" --output "${tmpd}/runs2.tsv" --runs SRR910001,SRR910003
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
SPECIES_CONFIG=( "Helicoverpa_armigera|f|g|true" )
RUN_TABLE="${PIPELINE_DIR}/examples/SraRunTable.example.csv"
SAMPLES_TSV="${tmpd}/samples.tsv"
parse_samples >/dev/null 2>&1 || true

ex_rows="$(awk 'NR>1' "$SAMPLES_TSV" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
assert_eq "example RunTable: 2 samples" "$ex_rows" "2"
assert_eq "example RunTable: species"  \
    "$(awk -F'\t' 'NR>1{print $2}' "$SAMPLES_TSV" 2>/dev/null | sort -u | tr '\n' ',' || true)" \
    "Helicoverpa_armigera,"
assert_eq "example RunTable: layout"   \
    "$(awk -F'\t' 'NR>1{print $3}' "$SAMPLES_TSV" 2>/dev/null | sort -u | tr '\n' ',' || true)" \
    "PAIRED,"
rm -rf "$tmpd"
unset RUN_TABLE SAMPLES_TSV

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

tmpd="$(mktemp -d)"
mkdir -p "${tmpd}/logs" "${tmpd}/rsem/SRR1" "${tmpd}/rsem/SRR2"
cat > "${tmpd}/logs/SRR1_STAR_Log.final.out" <<'LOG'
                                 Number of input reads |	1000
LOG
cat > "${tmpd}/logs/SRR1_STAR_ReadsPerGene.out.tab" <<'TAB'
N_unmapped	0	0	0
N_multimapping	0	0	0
N_noFeature	0	0	0
N_ambiguous	0	0	0
gene1	100	90	10
gene2	100	90	10
TAB

# geneA only in SRR1, geneD only in SRR2.
cat > "${tmpd}/rsem/SRR1/SRR1.genes.results" <<'TSV'
gene_id	transcript_id(s)	length	effective_length	expected_count	TPM	FPKM
geneA	geneA_t1	1000	900	10	5.0	6.0
geneB	geneB_t1	1000	900	20	15.0	16.0
geneC	geneC_t1	1000	900	30	25.0	26.0
TSV
cat > "${tmpd}/rsem/SRR2/SRR2.genes.results" <<'TSV'
gene_id	transcript_id(s)	length	effective_length	expected_count	TPM	FPKM
geneB	geneB_t1	1000	900	40	35.0	36.0
geneC	geneC_t1	1000	900	50	45.0	46.0
geneD	geneD_t1	1000	900	60	55.0	56.0
TSV

python3 "${PIPELINE_DIR}/helpers/build_matrix.py" \
    --rsem-dir "${tmpd}/rsem" --output "${tmpd}/expr.tsv" \
    --star-logs "${tmpd}/logs" --bbduk-logs "${tmpd}/logs" \
    --star-out "${tmpd}/star_qc.tsv" --bbduk-out "${tmpd}/bbduk_qc.tsv" >/dev/null 2>&1

sr_val="$(awk -F'\t' '$1 ~ /strand_ratio/ {print $2}' "${tmpd}/star_qc.tsv" 2>/dev/null || true)"
assert_eq "build_matrix: strand_ratio = fwd/(fwd+rev)" "$sr_val" "0.900"

assert_eq "build_matrix: header lists both samples' TPM/FPKM columns" \
    "$(head -1 "${tmpd}/expr.tsv")" \
    "$(printf 'gene_id\ttranscript_id(s)\tlength\teffective_length\texpected_count\tSRR1_TPM\tSRR1_FPKM\tSRR2_TPM\tSRR2_FPKM')"

expr_rows="$(awk 'NR>1' "${tmpd}/expr.tsv" | wc -l | tr -d ' ')"
assert_eq "build_matrix: inner join keeps only the 2 shared genes" "$expr_rows" "2"

expr_genes="$(awk -F'\t' 'NR>1{print $1}' "${tmpd}/expr.tsv" | paste -sd, -)"
assert_eq "build_matrix: inner join drops the sample-exclusive genes" "$expr_genes" "geneB,geneC"

geneC_row="$(awk -F'\t' '$1=="geneC"' "${tmpd}/expr.tsv")"
assert_eq "build_matrix: shared gene keeps its per-sample TPM/FPKM values" \
    "$geneC_row" "$(printf 'geneC\tgeneC_t1\t1000\t900\t30\t25.0\t26.0\t45.0\t46.0')"

rm -rf "$tmpd"

run_help="$(bash "${PIPELINE_DIR}/run.sh" --help)"
for flag in --build-refs --test --full --example --manual --interactive --no-preview; do
    assert_eq "run.sh --help documents ${flag}" \
        "$(grep -q -- "$flag" <<< "$run_help" && echo yes || echo no)" "yes"
done
assert_fails "run.sh rejects unknown flags" bash "${PIPELINE_DIR}/run.sh" --nope
assert_fails "run.sh --manual needs an accession list" bash "${PIPELINE_DIR}/run.sh" --manual --full
assert_succeeds "setup.sh --help" bash "${PIPELINE_DIR}/setup.sh" --help
assert_fails "setup.sh rejects unknown flags" bash "${PIPELINE_DIR}/setup.sh" --nope

setup_help="$(bash "${PIPELINE_DIR}/setup.sh" --help)"
for flag in --resources --species --add-species --interactive; do
    assert_eq "setup.sh --help documents ${flag}" \
        "$(grep -q -- "$flag" <<< "$setup_help" && echo yes || echo no)" "yes"
done

tmpd="$(mktemp -d)"
mkdir -p "${tmpd}/config" "${tmpd}/lib" "${tmpd}/steps"
cp "${PIPELINE_DIR}/setup.sh" "$tmpd/"
cp "${PIPELINE_DIR}"/config/*.sh "${tmpd}/config/"
cp "${PIPELINE_DIR}"/lib/*.sh    "${tmpd}/lib/"
cp "${PIPELINE_DIR}"/steps/*.sh  "${tmpd}/steps/"

# One answer per _ANALYSIS_PARAMS row; empty keeps the current value.
printf 'true\n5000\n\n\n\n120\n10\nf\n20\n50\nnone\ny\n' \
    | bash "${tmpd}/setup.sh" --analysis >/dev/null 2>&1

assert_eq "setup --analysis: writes a choice" \
    "$(grep '^TEST_MODE=' "${tmpd}/config/pipeline.sh")" 'TEST_MODE="true"'
assert_eq "setup --analysis: writes an int unquoted" \
    "$(grep '^TEST_READS=' "${tmpd}/config/pipeline.sh")" 'TEST_READS=5000'
assert_eq "setup --analysis: writes BBDuk settings" \
    "$(grep '^BBDUK_QTRIM=' "${tmpd}/config/pipeline.sh")" 'BBDUK_QTRIM="f"'
assert_eq "setup --analysis: empty answer keeps the current value" \
    "$(grep '^PIPELINE_RETRY_PASSES=' "${tmpd}/config/pipeline.sh")" 'PIPELINE_RETRY_PASSES=3'
assert_eq "setup --analysis: 'none' clears the adapter path" \
    "$(grep '^BBDUK_REF=' "${tmpd}/config/pipeline.sh")" 'BBDUK_REF=""'

cp "${PIPELINE_DIR}/config/pipeline.sh" "${tmpd}/config/pipeline.sh"
printf 'true\n5000\n\n\n\n120\n10\nf\n20\n50\nnone\nn\n' \
    | bash "${tmpd}/setup.sh" --analysis >/dev/null 2>&1
assert_eq "setup --analysis: declining writes nothing" \
    "$(diff -q "${PIPELINE_DIR}/config/pipeline.sh" "${tmpd}/config/pipeline.sh" >/dev/null && echo same)" "same"
rm -rf "$tmpd"

EXAMPLE_SPECIES="Helicoverpa_armigera"
menu_out="$(printf '99\nzz\n\n8\n' | menu_main)"
assert_eq "menu: rejects a non-listed number" \
    "$(grep -c "'99' is not a valid option" <<< "$menu_out")" "1"
assert_eq "menu: rejects non-numeric input" \
    "$(grep -c "'zz' is not a valid option" <<< "$menu_out")" "1"
assert_eq "menu: option 8 exits" \
    "$(grep -c 'Bye.' <<< "$menu_out")" "1"
assert_eq "menu: redraws after every answer" \
    "$(grep -c '\[8\] Exit' <<< "$menu_out")" "4"

assert_succeeds "menu: exits on EOF" bash -c \
    "PIPELINE_DIR='${PIPELINE_DIR}' EXAMPLE_SPECIES=X; source '${PIPELINE_DIR}/lib/menu.sh'; menu_main </dev/null"

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

ENABLE_PREVIEW=true
rm -f "${tmpd}/tables/gene_expression_matrix.tsv"
assert_eq "preview: missing matrix warns" \
    "$(preview_expression_matrix | grep -c '\[WARN\]')" "1"
assert_succeeds "preview: missing matrix is not fatal" preview_expression_matrix
rm -rf "$tmpd"
unset RESULTS_DIR ENABLE_PREVIEW PREVIEW_LINES

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

tmpd="$(mktemp -d)"
printf 'not gzip at all' > "${tmpd}/broken.fna.gz"
assert_fails "fetch_and_decompress: rejects a corrupt archive" \
    fetch_and_decompress "${tmpd}/genome.fa" "" "file:///dev/null"
assert_eq "fetch_and_decompress: corrupt archive left no output" \
    "$([[ -f "${tmpd}/genome.fa" ]] && echo yes || echo no)" "no"

assert_fails "fetch_and_decompress: rejects a corrupt local archive" \
    fetch_and_decompress "${tmpd}/g2.fa" "${tmpd}/broken.fna.gz" ""
assert_eq "fetch_and_decompress: user-supplied archive is kept" \
    "$([[ -f "${tmpd}/broken.fna.gz" ]] && echo yes || echo no)" "yes"

printf '>chr1\nACGT\n' | gzip > "${tmpd}/good.fna.gz"
assert_succeeds "fetch_and_decompress: accepts a valid archive" \
    fetch_and_decompress "${tmpd}/good.fa" "${tmpd}/good.fna.gz" ""
assert_eq "fetch_and_decompress: decompressed content" \
    "$(head -1 "${tmpd}/good.fa" 2>/dev/null)" ">chr1"
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
mkdir -p "${tmpd}/src" "${tmpd}/out"
printf '>chr1\nACGT\n' | gzip > "${tmpd}/src/genome.fna.gz"
good_md5="$(md5sum "${tmpd}/src/genome.fna.gz" | awk '{print $1}')"
printf '%s  ./genome.fna.gz\n' "$good_md5" > "${tmpd}/src/md5checksums.txt"

assert_succeeds "fetch_and_decompress: verifies a matching checksum" \
    fetch_and_decompress "${tmpd}/out/genome.fa" "" "file://${tmpd}/src/genome.fna.gz"
assert_eq "fetch_and_decompress: content survives checksum verification" \
    "$(head -1 "${tmpd}/out/genome.fa" 2>/dev/null)" ">chr1"
rm -rf "${tmpd}/out"; mkdir -p "${tmpd}/out"

printf '>chr1\nTTTT\n' | gzip > "${tmpd}/src/genome.fna.gz"
assert_fails "fetch_and_decompress: rejects a checksum mismatch" \
    fetch_and_decompress "${tmpd}/out/genome.fa" "" "file://${tmpd}/src/genome.fna.gz"
assert_eq "fetch_and_decompress: mismatch left no output" \
    "$([[ -f "${tmpd}/out/genome.fa" ]] && echo yes || echo no)" "no"
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
(
    source "${PIPELINE_DIR}/steps/build_references.sh"
    REFERENCES_DIR="${tmpd}/references"
    LOG_DIR="${tmpd}/logs"
    MAX_MEMORY_GB=8 THREADS_STAR=1 STAR_OVERHANG=99 STAR_SA_INDEX_NBASES=11
    mkdir -p "$LOG_DIR"
    fetch_species_references() { :; }
    STAR() {
        printf '%s\n' "$@" > "${tmpd}/star_args"
        touch "${REFERENCES_DIR}/sp/STAR_genome_index/SA"
    }
    rsem-prepare-reference() { touch "${REFERENCES_DIR}/sp/rsem_ref.grp"; }
    build_reference "sp|f|g|true"
) >/dev/null 2>&1
assert_eq "build_reference: MAX_MEMORY_GB reaches --limitGenomeGenerateRAM" \
    "$(grep -A1 -x -- '--limitGenomeGenerateRAM' "${tmpd}/star_args" | tail -1)" "8589934592"
assert_eq "step_star: no --limitBAMsortRAM, the alignment does not sort" \
    "$(grep -c -- '--limitBAMsortRAM' "${PIPELINE_DIR}/steps/align.sh" || true)" "0"
rm -rf "$tmpd"

tmpd="$(mktemp -d)"
mkdir -p "${tmpd}/config" "${tmpd}/lib" "${tmpd}/steps"
cp "${PIPELINE_DIR}/setup.sh" "$tmpd/"
cp "${PIPELINE_DIR}"/config/*.sh "${tmpd}/config/"
cp "${PIPELINE_DIR}"/lib/*.sh    "${tmpd}/lib/"
cp "${PIPELINE_DIR}"/steps/*.sh  "${tmpd}/steps/"

# toggle, delete, add one species with unreachable URLs, no more, write, fetch.
species_status=0
species_out="$( cd "$tmpd" && printf '\n\ny\nGenus_species\nhttp://127.0.0.1:1/g.fna.gz\nhttp://127.0.0.1:1/g.gtf.gz\ny\nn\ny\ny\n' \
    | bash "${tmpd}/setup.sh" --species 2>&1 )" || species_status=$?
assert_eq "setup --species: a failed download still exits non-zero" \
    "$(( species_status != 0 ))" "1"
assert_eq "setup --species: the next steps are printed even when a download fails" \
    "$(grep -c 'Setup complete. Next steps' <<< "$species_out")" "1"
rm -rf "$tmpd"

if command -v flock &>/dev/null; then
    tmpd="$(mktemp -d)"
    mkdir -p "${tmpd}/tmp"
    exec 201>"${tmpd}/tmp/pipeline.lock"
    flock -n 201
    lock_out="$( cd "$tmpd" && bash "${PIPELINE_DIR}/run.sh" --build-refs 2>&1 )" || true
    exec 201>&-
    assert_eq "run.sh: refuses to start while another run holds the lock" \
        "$(grep -c 'already running (lock:' <<< "$lock_out")" "1"
    rm -rf "$tmpd"
fi

tmpd="$(mktemp -d)"
printf 'SRR\tSPECIES\tLAYOUT\nA\tsp\tPAIRED\nB\tsp\tSINGLE\nC\tsp\tPAIRED\n' \
    > "${tmpd}/samples.tsv"
loop_seen="$(
    source "${PIPELINE_DIR}/steps/process_sample.sh"
    SAMPLES_TSV="${tmpd}/samples.tsv"
    PIPELINE_RETRY_PASSES=1
    log_step() { :; }
    tracker_is_complete() { return 1; }
    process_sample() { echo "seen:$1"; cat >/dev/null; }
    run_sample_loop </dev/null | grep -c '^seen:'
)" || true
assert_eq "run_sample_loop: visits every sample when a stage reads stdin" "$loop_seen" "3"

printf 'SRR\tSPECIES\tLAYOUT\tTISSUE\nA\tsp\tPAIRED\tGut\n' > "${tmpd}/samples.tsv"
loop_layout="$(
    source "${PIPELINE_DIR}/steps/process_sample.sh"
    SAMPLES_TSV="${tmpd}/samples.tsv"
    PIPELINE_RETRY_PASSES=1
    log_step() { :; }
    tracker_is_complete() { return 1; }
    process_sample() { echo "layout:$3"; }
    run_sample_loop </dev/null | grep '^layout:'
)" || true
assert_eq "run_sample_loop: metadata columns do not leak into layout" "$loop_layout" "layout:PAIRED"
rm -rf "$tmpd"

source "${PIPELINE_DIR}/steps/align.sh"
tmpd="$(mktemp -d)"
LOG_DIR="$tmpd"
strand_case() {
    printf 'N_a\t0\t0\t0\nN_b\t0\t0\t0\nN_c\t0\t0\t0\nN_d\t0\t0\t0\ng\t100\t%s\t%s\n' "$1" "$2" \
        > "${tmpd}/rpg.tab"
    _infer_strandedness S "${tmpd}/rpg.tab" >/dev/null
    echo "${STRAND_RATIO}/${FORWARD_PROB}"
}
assert_eq "_infer_strandedness: 0.9 is forward-stranded"  "$(strand_case 90 10)" "0.900/1"
assert_eq "_infer_strandedness: 0.8 stays unstranded"     "$(strand_case 80 20)" "0.800/0.5"
assert_eq "_infer_strandedness: 0.1 is reverse-stranded"  "$(strand_case 10 90)" "0.100/0"
assert_eq "_infer_strandedness: no counts leaves defaults" "$(strand_case 0 0)"  "NA/0.5"

star_case() {
    (
        TMP_DIR="$tmpd" THREADS_STAR=1 STAR_INDEX=x CLEAN_SE="${tmpd}/r.fq" MIN_UNIQUE_MAPPED_PCT=10
        pct="$1"
        disk_usage() { :; }
        STAR() {
            touch "${tmpd}/S_star/Aligned.toTranscriptome.out.bam"
            printf '                        Uniquely mapped reads %% |\t%s%%\n' "$pct" \
                > "${tmpd}/S_star/Log.final.out"
        }
        step_star S SINGLE >/dev/null 2>&1 && echo pass || echo fail
    )
}
assert_eq "step_star: a sample mapping 0% fails (small-RNA library)" "$(star_case 0.00)" "fail"
assert_eq "step_star: a sample mapping 85% passes" "$(star_case 85.20)" "pass"

aligner_case() {
    (
        TMP_DIR="$tmpd" THREADS_STAR=8 MAX_MEMORY_GB=3 STAR_INDEX=x CLEAN_SE="${tmpd}/r.fq"
        printf '@r\n%s\n+\n%s\n' "$(printf 'A%.0s' $(seq "$1"))" "$(printf 'I%.0s' $(seq "$1"))" > "$CLEAN_SE"
        disk_usage() { :; }
        fake_star() {
            echo "$1/$3" > "${tmpd}/aligner"
            touch "${tmpd}/S_star/Aligned.toTranscriptome.out.bam"
        }
        STAR() { fake_star STAR "$@"; }
        STARlong() { fake_star STARlong "$@"; }
        step_star S SINGLE >/dev/null 2>&1
        cat "${tmpd}/aligner"
    )
}
assert_eq "step_star: 150 nt reads go to STAR, all threads" "$(aligner_case 150)" "STAR/8"
assert_eq "step_star: 800 nt reads go to STARlong, threads capped by MAX_MEMORY_GB" \
    "$(aligner_case 800)" "STARlong/1"

source "${PIPELINE_DIR}/steps/quantify.sh"
rsem_args() {
    (
        TMP_DIR="$tmpd" THREADS_RSEM=1 BAM_PATH=b RSEM_REF=r READ_MAX_NT="$1"
        disk_usage() { :; }
        rsem-calculate-expression() { echo "$*" > "${tmpd}/rsem_args"; touch "${tmpd}/out/S.genes.results"; }
        mkdir -p "${tmpd}/out"
        step_rsem S SINGLE "${tmpd}/out" >/dev/null 2>&1
        grep -o -- '--fragment-length-max [0-9]*' "${tmpd}/rsem_args" || echo none
    )
}
assert_eq "step_rsem: reads past 1000 nt raise --fragment-length-max" "$(rsem_args 1181)" "--fragment-length-max 1181"
assert_eq "step_rsem: short reads keep RSEM's default" "$(rsem_args "")" "none"
rm -rf "$tmpd"

source "${PIPELINE_DIR}/steps/trim.sh"

assert_eq "step_bbduk: BBDuk runs with assertions disabled" \
    "${BBDUK_JVM_ARGS[*]}" "-da"

tmpd="$(mktemp -d)"
touch "${tmpd}/a" "${tmpd}/b"
assert_succeeds "_files_present: true when every file exists" \
    _files_present "${tmpd}/a" "${tmpd}/b"
assert_fails "_files_present: false when one file is missing" \
    _files_present "${tmpd}/a" "${tmpd}/missing"
rm -rf "$tmpd"

syntax_errors=0
while IFS= read -r script; do
    bash -n "$script" || (( ++syntax_errors ))
done < <(find "$PIPELINE_DIR" -name '*.sh' -type f | sort)
assert_eq "all shell scripts parse" "$syntax_errors" "0"

echo ""
echo "Results: ${_pass} passed, ${_fail} failed."
[[ "$_fail" -eq 0 ]]
