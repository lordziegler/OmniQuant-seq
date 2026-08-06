#!/usr/bin/env bash
# Per-sample orchestration: runs every stage for one accession, records the
# outcome in the tracker, and drives the retry passes over samples.tsv.
#
# The individual stages live in the other steps/*.sh modules; this file only
# decides the order, what to clean up, and what to do on failure.

# Stage status variables, in tracker column order.
_SAMPLE_STAGES=( prefetch_status fastq_status trim_status star_status rsem_status )

# Accession being processed right now, or empty between samples. Read by the
# signal handler, which is the only thing that runs outside process_sample.
CURRENT_SRR=""

# Every output a stage may have half-written for one sample. The names come
# from the globals the step functions set; process_sample clears them per
# sample, so this never names a previous accession's files.
_sample_partial_files() {
    local srr="$1" species="$2"
    printf '%s\n' "${RAW_1:-}" "${RAW_2:-}" "${RAW_SE:-}" \
                  "${CLEAN_1:-}" "${CLEAN_2:-}" "${CLEAN_SE:-}" "${SINGLETONS:-}" \
                  "${RESULTS_DIR}/rsem/${species}/${srr}.genes.results" \
                  "${RESULTS_DIR}/rsem/${species}/${srr}.isoforms.results"
}

# Record a sample that stopped early: the failed stage keeps its FAILED value,
# stages that never ran become NA.
_record_sample_failure() {
    local srr="$1" species="$2" layout="$3" stage="$4"
    local var
    for var in "${_SAMPLE_STAGES[@]}"; do
        if [[ "${!var}" == "PENDING" ]]; then
            printf -v "$var" '%s' "NA"
        fi
    done

    # Every failure path routes through here, so this is the one place that has
    # to drop what the failed stage left half-written — otherwise the next pass
    # reads a truncated FASTQ or BAM as if it were complete.
    local partials=()
    mapfile -t partials < <(_sample_partial_files "$srr" "$species")
    cleanup_on_error "$srr" "${partials[@]}"

    tracker_update "$srr" "$species" "$layout" \
        "$prefetch_status" "$fastq_status" "$trim_status" \
        "$star_status" "$rsem_status" "NA"
    log_step "$srr" "ERROR" "Sample stopped at ${stage}."
}

# SIGINT/SIGTERM handler, registered by run.sh. A Ctrl-C between stages leaves
# the same partial output a failed stage does, so it gets the same treatment.
on_interrupt() {
    echo ""
    echo "[INTERRUPT] Signal received — cleaning up the sample in progress ..."
    if [[ -n "$CURRENT_SRR" ]]; then
        local partials=()
        mapfile -t partials < <(_sample_partial_files "$CURRENT_SRR" "${CURRENT_SPECIES:-}")
        cleanup_on_error "$CURRENT_SRR" "${partials[@]}"
        log_step "$CURRENT_SRR" "INTERRUPT" "Run interrupted by signal; partial files removed."
    fi
    exit 130
}

process_sample() {
    local srr="$1" species="$2" layout="$3"
    local species_out="${RESULTS_DIR}/rsem/${species}"
    local prefetch_status="PENDING" fastq_status="PENDING" trim_status="PENDING" \
          star_status="PENDING" rsem_status="PENDING"

    # The stage functions communicate through these globals; clear them so a
    # failure early in this sample can never delete the previous sample's files.
    CURRENT_SRR="$srr"; CURRENT_SPECIES="$species"
    RAW_1=""; RAW_2=""; RAW_SE=""
    CLEAN_1=""; CLEAN_2=""; CLEAN_SE=""; SINGLETONS=""

    resolve_reference_paths "$species"
    mkdir -p "$species_out"

    if step_prefetch "$srr"; then prefetch_status="OK"; else
        prefetch_status="FAILED"; _record_sample_failure "$srr" "$species" "$layout" prefetch; return 0
    fi

    if step_fastq_dump "$srr" "$layout"; then fastq_status="OK"; else
        fastq_status="FAILED"; _record_sample_failure "$srr" "$species" "$layout" fastq-dump; return 0
    fi

    if [[ "$CLEAN_SRA_AFTER_FASTQ" == true ]]; then
        cleanup_sra "$srr" "$SRA_PATH"
    fi

    if [[ "$layout" == "PAIRED" ]]; then
        step_fastqc "$srr" "RAW" "$RAW_1" "$RAW_2"
    else
        step_fastqc "$srr" "RAW" "$RAW_SE"
    fi

    if step_bbduk "$srr" "$layout"; then trim_status="OK"; else
        trim_status="FAILED"; _record_sample_failure "$srr" "$species" "$layout" bbduk; return 0
    fi

    if [[ "$CLEAN_RAW_FASTQ_AFTER_RSEM" == true ]]; then
        cleanup_raw_fastq "$srr" "${RAW_1:-}" "${RAW_2:-}" "${RAW_SE:-}"
    fi

    if [[ "$layout" == "PAIRED" ]]; then
        step_fastqc "$srr" "CLEAN" "$CLEAN_1" "$CLEAN_2"
        step_multiqc_sample "$srr" "PAIRED"
        cleanup_raw_fastq "$srr" "$SINGLETONS"
    else
        step_fastqc "$srr" "CLEAN" "$CLEAN_SE"
        step_multiqc_sample "$srr" "SINGLE"
    fi

    if step_star "$srr" "$layout"; then star_status="OK"; else
        star_status="FAILED"; _record_sample_failure "$srr" "$species" "$layout" star; return 0
    fi

    if step_rsem "$srr" "$layout" "$species_out"; then rsem_status="OK"; else
        rsem_status="FAILED"; _record_sample_failure "$srr" "$species" "$layout" rsem; return 0
    fi

    cleanup_star_tmp "$srr"
    cleanup_rsem_tmp "$srr"
    cleanup_rsem_bam "$srr" "$species_out"
    if [[ "$CLEAN_FASTQ_AFTER_RSEM" == true ]]; then
        cleanup_clean_fastq "$srr" "${CLEAN_1:-}" "${CLEAN_2:-}" "${CLEAN_SE:-}"
    fi

    tracker_update "$srr" "$species" "$layout" \
        "$prefetch_status" "$fastq_status" "$trim_status" \
        "$star_status" "$rsem_status" "${species_out}/${srr}.genes.results"

    log_step "$srr" "DONE" "Sample complete."
    disk_usage "post-sample [${srr}]"
    CURRENT_SRR=""
}

# Walk samples.tsv up to PIPELINE_RETRY_PASSES times; samples already marked
# complete in the tracker are skipped, so an interrupted run resumes cleanly.
run_sample_loop() {
    local pass srr species layout

    for (( pass = 1; pass <= PIPELINE_RETRY_PASSES; pass++ )); do
        echo ""
        echo "============================================================"
        echo " Pass ${pass}/${PIPELINE_RETRY_PASSES}"
        echo "============================================================"

        while IFS=$'\t' read -r srr species layout; do
            [[ "$srr" == "SRR" || -z "$srr" ]] && continue

            if tracker_is_complete "$srr"; then
                log_step "$srr" "SKIP" "Already done."
                continue
            fi

            echo ""
            echo "--- ${srr} | ${species} | ${layout} ---"
            process_sample "$srr" "$species" "$layout"
        done < "$SAMPLES_TSV"
    done
}
