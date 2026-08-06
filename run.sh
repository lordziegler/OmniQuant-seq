#!/usr/bin/env bash
# OmniQuant-seq — RNA-seq expression pipeline for any organism with a genome
# and an annotation. Single entry point: parses the CLI, then delegates to the
# modules in lib/ and steps/.

set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${PIPELINE_DIR}/config/pipeline.sh"
source "${PIPELINE_DIR}/config/species.sh"
source "${PIPELINE_DIR}/lib/utils.sh"
source "${PIPELINE_DIR}/lib/species_config.sh"
source "${PIPELINE_DIR}/lib/cleanup.sh"
source "${PIPELINE_DIR}/lib/sample_tracker.sh"
source "${PIPELINE_DIR}/steps/validate_inputs.sh"
source "${PIPELINE_DIR}/steps/build_references.sh"
source "${PIPELINE_DIR}/steps/parse_samples.sh"
source "${PIPELINE_DIR}/steps/prefetch.sh"
source "${PIPELINE_DIR}/steps/fastq_dump.sh"
source "${PIPELINE_DIR}/steps/fastqc.sh"
source "${PIPELINE_DIR}/steps/trim.sh"
source "${PIPELINE_DIR}/steps/align.sh"
source "${PIPELINE_DIR}/steps/quantify.sh"
source "${PIPELINE_DIR}/steps/process_sample.sh"
source "${PIPELINE_DIR}/steps/postprocess.sh"

# --- Example run -------------------------------------------------------------
# Reference dataset shipped with the repository: one small paired-end
# Helicoverpa armigera RNA-seq run (~620 MB SRA, 10.5 M spots).
EXAMPLE_SPECIES="Helicoverpa_armigera"
EXAMPLE_RUN_TABLE="${PIPELINE_DIR}/examples/SraRunTable.example.csv"
EXAMPLE_READS=25000

usage() {
    cat <<EOF
OmniQuant-seq — RNA-seq TPM/FPKM quantification for any organism.

Usage: bash pipeline/run.sh [MODE]

Modes:
  --build-refs   Download genome + annotation for every active species in
                 config/species.sh and build the STAR and RSEM indexes, then
                 exit. Run once per species; safe to re-run.
  --test         Full pipeline on every sample, limited to TEST_READS
                 (${TEST_READS}) reads each. Use to validate a setup.
  --full         Full pipeline on all reads. Production run.
  --example      Self-contained demo on ${EXAMPLE_SPECIES}, using
                 examples/SraRunTable.example.csv (1 paired-end run) and
                 ${EXAMPLE_READS} reads. Runs every stage — prefetch,
                 fastq-dump, FastQC, BBDuk, STAR, RSEM, matrices — and keeps
                 the intermediate files so each stage can be inspected. The
                 ${EXAMPLE_SPECIES} references are built first if
                 they do not exist yet.
  -h, --help     Show this message.

With no mode, the pipeline runs with the TEST_MODE value from
config/pipeline.sh (currently: ${TEST_MODE}).

Inputs are read from the current directory: exactly one SRA RunTable
(*RunTable*.csv or .xlsx) is required; a local *.fna.gz plus *.gtf.gz is used
in place of the download URLs when exactly one species is active.

Outputs:
  pipeline/results/tables/   expression matrix + STAR/BBDuk QC matrices
  pipeline/results/rsem/     per-sample RSEM results
  pipeline/results/qc/       MultiQC reports
  pipeline/logs/             per-sample and per-tool logs

Species are configured in config/species.sh. To add one interactively
(with genome download):  bash pipeline/setup.sh --add-species
EOF
}

# --- Argument parsing --------------------------------------------------------
BUILD_REFS_ONLY=false
EXAMPLE_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)       TEST_MODE=true;      shift ;;
        --full)       TEST_MODE=false;     shift ;;
        --build-refs) BUILD_REFS_ONLY=true; shift ;;
        --example)    EXAMPLE_MODE=true;   shift ;;
        -h|--help)    usage; exit 0 ;;
        *)
            echo "[ABORT] Unknown argument: $1" >&2
            echo "" >&2
            usage >&2
            exit 1 ;;
    esac
done

# --- Example mode overrides --------------------------------------------------
# Restricts the run to the bundled dataset and keeps intermediates so the
# demo is inspectable.
if [[ "$EXAMPLE_MODE" == true ]]; then
    require_file "$EXAMPLE_RUN_TABLE" "The example RunTable is missing from the repository."

    RUN_TABLE="$EXAMPLE_RUN_TABLE"
    TEST_MODE=true
    TEST_READS="$EXAMPLE_READS"
    CLEAN_SRA_AFTER_FASTQ=false
    CLEAN_RAW_FASTQ_AFTER_RSEM=false
    CLEAN_FASTQ_AFTER_RSEM=false

    # Only the example species, regardless of what config/species.sh enables.
    species_config_load "${PIPELINE_DIR}/config/species.sh"
    example_idx="$(species_config_index "$EXAMPLE_SPECIES")"
    (( example_idx >= 0 )) || die \
        "${EXAMPLE_SPECIES} is not in config/species.sh — restore it or run: bash pipeline/setup.sh --add-species"
    SPECIES_CONFIG=( "${EXAMPLE_SPECIES}|${SP_FNA[$example_idx]}|${SP_GTF[$example_idx]}|true" )
fi

# --- Setup -------------------------------------------------------------------
mkdir -p "$LOG_DIR" "$TMP_DIR" "$RESULTS_DIR/rsem" \
         sra fastq clean_fastq fastqc_out

RUN_MODE="quantify"
[[ "$BUILD_REFS_ONLY" == true ]] && RUN_MODE="build-refs"
[[ "$EXAMPLE_MODE"    == true ]] && RUN_MODE="example"

echo "============================================================"
echo " OmniQuant-seq — RNA-seq expression pipeline"
echo " Mode      : ${RUN_MODE}"
echo " Test mode : ${TEST_MODE}"
echo " Test reads: ${TEST_READS}"
echo " Species   : $(species_config_active_keys | paste -sd, - )"
echo "============================================================"

# --- Pre-flight --------------------------------------------------------------
check_tools prefetch fastq-dump fasterq-dump fastqc multiqc \
            bbduk.sh STAR rsem-prepare-reference rsem-calculate-expression

disk_usage "pipeline-start"

# --- References --------------------------------------------------------------
detect_local_references "."
build_all_references

if [[ "$BUILD_REFS_ONLY" == true ]]; then
    echo "[DONE] References built."
    exit 0
fi

# --- Samples -----------------------------------------------------------------
# Only quantification runs need a RunTable, so this check comes after
# --build-refs has had its chance to exit.
detect_run_table "."
parse_samples
tracker_init
run_sample_loop

# --- Post-processing ---------------------------------------------------------
postprocess_all
