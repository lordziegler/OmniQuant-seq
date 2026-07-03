#!/usr/bin/env bash
# Lepidoptera RNA-seq TPM pipeline — main entry point.
#
# Usage:
#   bash pipeline/run.sh
#   bash pipeline/run.sh --test
#   bash pipeline/run.sh --full
#   bash pipeline/run.sh --build-refs   # only build references, then exit

set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Source config and all modules -------------------------------------------
source "${PIPELINE_DIR}/config/pipeline.sh"
source "${PIPELINE_DIR}/config/species.sh"
source "${PIPELINE_DIR}/lib/utils.sh"
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
source "${PIPELINE_DIR}/steps/postprocess.sh"

# --- Argument parsing --------------------------------------------------------
BUILD_REFS_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)       TEST_MODE=true;  shift ;;
        --full)       TEST_MODE=false; shift ;;
        --build-refs) BUILD_REFS_ONLY=true; shift ;;
        *)
            echo "[ABORT] Unknown argument: $1"
            echo "Usage: bash pipeline/run.sh [--test|--full|--build-refs]"
            exit 1 ;;
    esac
done

# --- Setup -------------------------------------------------------------------
mkdir -p "$LOG_DIR" "$TMP_DIR" "$RESULTS_DIR/rsem" \
         sra fastq clean_fastq fastqc_out

echo "============================================================"
echo " Lepidoptera RNA-seq TPM pipeline"
echo " Test mode : ${TEST_MODE}"
echo " Test reads: ${TEST_READS}"
echo "============================================================"

# --- Pre-flight --------------------------------------------------------------
check_tools prefetch fastq-dump fasterq-dump fastqc multiqc \
            bbduk.sh STAR rsem-prepare-reference rsem-calculate-expression

disk_usage "pipeline-start"

# --- References --------------------------------------------------------------
detect_inputs "."
build_all_references

[[ "$BUILD_REFS_ONLY" == true ]] && { echo "[DONE] References built."; exit 0; }

# --- Sample preparation ------------------------------------------------------
parse_samples
tracker_init

# --- Per-sample loop with retry passes ---------------------------------------
_process_sample() {
    local srr="$1" species="$2" layout="$3"
    local species_out="${RESULTS_DIR}/rsem/${species}"
    local pre_s="PENDING" fq_s="PENDING" trim_s="PENDING" \
          star_s="PENDING" rsem_s="PENDING" genes="NA"

    resolve_reference_paths "$species"
    mkdir -p "$species_out"

    step_prefetch "$srr"                                   && pre_s="OK"  || { tracker_update "$srr" "$species" "$layout" "FAILED" "NA"  "NA"   "NA"   "NA"  "NA"; return; }
    step_fastq_dump "$srr" "$layout"                       && fq_s="OK"   || { cleanup_on_error "$srr" "${RAW_1:-}" "${RAW_2:-}" "${RAW_SE:-}"; tracker_update "$srr" "$species" "$layout" "$pre_s" "FAILED" "NA" "NA"   "NA"  "NA"; return; }

    [[ "$CLEAN_SRA_AFTER_FASTQ" == true ]] && cleanup_sra "$srr" "$SRA_PATH"

    if [[ "$layout" == "PAIRED" ]]; then
        step_fastqc "$srr" "RAW" "$RAW_1" "$RAW_2"
    else
        step_fastqc "$srr" "RAW" "$RAW_SE"
    fi

    step_bbduk "$srr" "$layout"                            && trim_s="OK" || { cleanup_on_error "$srr" "${CLEAN_1:-}" "${CLEAN_2:-}" "${CLEAN_SE:-}" "${SINGLETONS:-}"; tracker_update "$srr" "$species" "$layout" "$pre_s" "$fq_s" "FAILED" "NA" "NA" "NA"; return; }

    [[ "$CLEAN_RAW_FASTQ_AFTER_RSEM" == true ]] && cleanup_raw_fastq "$srr" "${RAW_1:-}" "${RAW_2:-}" "${RAW_SE:-}"

    if [[ "$layout" == "PAIRED" ]]; then
        step_fastqc "$srr" "CLEAN" "$CLEAN_1" "$CLEAN_2"
        step_multiqc_sample "$srr" "PAIRED"
        cleanup_raw_fastq "$srr" "$SINGLETONS"
    else
        step_fastqc "$srr" "CLEAN" "$CLEAN_SE"
        step_multiqc_sample "$srr" "SINGLE"
    fi

    step_star "$srr" "$layout"                             && star_s="OK" || { cleanup_on_error "$srr"; tracker_update "$srr" "$species" "$layout" "$pre_s" "$fq_s" "$trim_s" "FAILED" "NA" "NA"; return; }

    step_rsem "$srr" "$layout" "$species_out"              && rsem_s="OK" || { cleanup_on_error "$srr" "${species_out}/${srr}.genes.results" "${species_out}/${srr}.isoforms.results"; tracker_update "$srr" "$species" "$layout" "$pre_s" "$fq_s" "$trim_s" "$star_s" "FAILED" "NA"; return; }

    genes="${species_out}/${srr}.genes.results"
    cleanup_star_tmp "$srr"
    cleanup_rsem_tmp "$srr"
    cleanup_rsem_bam "$srr" "$species_out"
    [[ "$CLEAN_FASTQ_AFTER_RSEM" == true ]] && cleanup_clean_fastq "$srr" \
        "${CLEAN_1:-}" "${CLEAN_2:-}" "${CLEAN_SE:-}"

    tracker_update "$srr" "$species" "$layout" \
        "$pre_s" "$fq_s" "$trim_s" "$star_s" "$rsem_s" "$genes"

    log_step "$srr" "DONE" "Sample complete."
    disk_usage "post-sample [${srr}]"
}

for (( pass=1; pass<=PIPELINE_RETRY_PASSES; pass++ )); do
    echo ""
    echo "============================================================"
    echo " Pass ${pass}/${PIPELINE_RETRY_PASSES}"
    echo "============================================================"

    while IFS=$'\t' read -r SRR SPECIES LAYOUT; do
        [[ "$SRR" == "SRR" || -z "$SRR" ]] && continue

        if tracker_is_complete "$SRR"; then
            log_step "$SRR" "SKIP" "Already done."
            continue
        fi

        echo ""
        echo "--- ${SRR} | ${SPECIES} | ${LAYOUT} ---"
        _process_sample "$SRR" "$SPECIES" "$LAYOUT"

    done < "$SAMPLES_TSV"
done

# --- Post-processing ---------------------------------------------------------
postprocess_all
