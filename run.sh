#!/usr/bin/env bash
# OmniQuant-seq — RNA-seq expression pipeline for any organism with a genome
# and an annotation. Single entry point: parses the CLI, then delegates to the
# modules in lib/ and steps/.

set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${PIPELINE_DIR}/config/pipeline.sh"
source "${PIPELINE_DIR}/config/species.sh"
source "${PIPELINE_DIR}/lib/utils.sh"
source "${PIPELINE_DIR}/lib/menu.sh"
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

# Reference dataset shipped with the repository: one small paired-end
# Helicoverpa armigera RNA-seq run (~620 MB SRA, 10.5 M spots).
# EXAMPLE_SPECIES and EXAMPLE_READS come from config/pipeline.sh.
EXAMPLE_RUN_TABLE="${PIPELINE_DIR}/examples/SraRunTable.example.csv"

usage() {
    cat <<EOF
OmniQuant-seq — RNA-seq TPM/FPKM quantification for any organism.

Usage:
  bash run.sh              Interactive menu (on a terminal)
  bash run.sh [MODE]       Non-interactive, scriptable run

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

Options:
  -i, --interactive  Show the menu even when other arguments are given.
  --no-preview       Do not print the expression matrix preview at the end.
  -h, --help         Show this message.

Examples:
  bash run.sh                      # menu: configure, build, run
  bash run.sh --example            # bundled ${EXAMPLE_SPECIES} demo
  bash run.sh --build-refs         # indexes only, once per species
  bash run.sh --test               # smoke test on your samples
  bash run.sh --full --no-preview  # production run, quiet ending
  bash setup.sh --add-species      # add an organism + fetch its genome

With no mode and no terminal attached (cron, cluster job), the pipeline runs
with the TEST_MODE value from config/pipeline.sh (currently: ${TEST_MODE}).

Inputs are read from the current directory: exactly one SRA RunTable
(*RunTable*.csv or .xlsx) is required; a local *.fna.gz plus *.gtf.gz is used
in place of the download URLs when exactly one species is active.

Outputs:
  results/tables/   expression matrix + STAR/BBDuk QC matrices
  results/rsem/     per-sample RSEM results
  results/qc/       MultiQC reports
  logs/             per-sample and per-tool logs

A run ends by printing the first ${PREVIEW_LINES} lines of
results/tables/gene_expression_matrix.tsv (the inner join of every sample).
Change PREVIEW_LINES / ENABLE_PREVIEW in config/pipeline.sh, or pass
--no-preview.

Species are configured in config/species.sh. To add one interactively
(with genome download):  bash setup.sh --add-species
EOF
}

# --- Argument parsing --------------------------------------------------------
BUILD_REFS_ONLY=false
EXAMPLE_MODE=false
FORCE_MENU=false
NO_ARGS=false
[[ $# -eq 0 ]] && NO_ARGS=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)          TEST_MODE=true;       shift ;;
        --full)          TEST_MODE=false;      shift ;;
        --build-refs)    BUILD_REFS_ONLY=true; shift ;;
        --example)       EXAMPLE_MODE=true;    shift ;;
        --no-preview)    ENABLE_PREVIEW=false; shift ;;
        -i|--interactive) FORCE_MENU=true;     shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "[ABORT] Unknown argument: $1" >&2
            echo "" >&2
            usage >&2
            exit 1 ;;
    esac
done

# --- Interactive menu --------------------------------------------------------
# Bare `run.sh` on a terminal is a request for help, not for a production run;
# without a terminal it keeps behaving as a scriptable default run.
if [[ "$FORCE_MENU" == true ]] || { [[ "$NO_ARGS" == true ]] && [[ -t 0 ]]; }; then
    menu_main
    exit 0
fi

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
        "${EXAMPLE_SPECIES} is not in config/species.sh — restore it or run: bash setup.sh --add-species"
    SPECIES_CONFIG=( "${EXAMPLE_SPECIES}|${SP_FNA[$example_idx]}|${SP_GTF[$example_idx]}|true" )
fi

# --- Setup -------------------------------------------------------------------
mkdir -p "$LOG_DIR" "$TMP_DIR" "$RESULTS_DIR/rsem" \
         sra fastq clean_fastq fastqc_out

# One run at a time: two pipelines sharing sra/, fastq/ and the tracker would
# overwrite each other's intermediates. flock is Linux-only, so a system
# without it simply runs unlocked rather than refusing to start.
if command -v flock &>/dev/null; then
    LOCK_FILE="${TMP_DIR}/pipeline.lock"
    exec 200>"$LOCK_FILE"
    flock -n 200 || die "Another run.sh is already running (lock: ${LOCK_FILE})."
fi

trap on_interrupt SIGINT SIGTERM

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
