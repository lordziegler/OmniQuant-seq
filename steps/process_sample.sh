#!/usr/bin/env bash

_SAMPLE_STAGES=( prefetch_status fastq_status trim_status star_status rsem_status )

# Read by the signal handler.
CURRENT_SRR=""

_sample_partial_files() {
    local srr="$1" species="$2"
    printf '%s\n' "${RAW_1:-}" "${RAW_2:-}" "${RAW_SE:-}" \
                  "${CLEAN_1:-}" "${CLEAN_2:-}" "${CLEAN_SE:-}" "${SINGLETONS:-}" \
                  "${RESULTS_DIR}/rsem/${species}/${srr}.genes.results" \
                  "${RESULTS_DIR}/rsem/${species}/${srr}.isoforms.results"
}

_record_sample_failure() {
    local srr="$1" species="$2" layout="$3" stage="$4"
    local var
    for var in "${_SAMPLE_STAGES[@]}"; do
        if [[ "${!var}" == "PENDING" ]]; then
            printf -v "$var" '%s' "NA"
        fi
    done

    # Every failure path ends here: drop half-written output so the next pass
    # cannot take it for complete.
    local partials=()
    mapfile -t partials < <(_sample_partial_files "$srr" "$species")
    cleanup_on_error "$srr" "${partials[@]}"

    tracker_update "$srr" "$species" "$layout" \
        "$prefetch_status" "$fastq_status" "$trim_status" \
        "$star_status" "$rsem_status" "NA"
    log_step "$srr" "ERROR" "Sample stopped at ${stage}."
}

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

    # Reset so an early failure can never delete the previous sample's files.
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
        cleanup_files "$srr" "Raw FASTQ" "${RAW_1:-}" "${RAW_2:-}" "${RAW_SE:-}"
    fi

    if [[ "$layout" == "PAIRED" ]]; then
        step_fastqc "$srr" "CLEAN" "$CLEAN_1" "$CLEAN_2"
        step_multiqc_sample "$srr" "PAIRED"
        cleanup_files "$srr" "BBDuk singletons" "$SINGLETONS"
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

    cleanup_tmp "$srr"
    cleanup_rsem_bam "$srr" "$species_out"
    if [[ "$CLEAN_FASTQ_AFTER_RSEM" == true ]]; then
        cleanup_files "$srr" "Clean FASTQ" "${CLEAN_1:-}" "${CLEAN_2:-}" "${CLEAN_SE:-}"
    fi

    tracker_update "$srr" "$species" "$layout" \
        "$prefetch_status" "$fastq_status" "$trim_status" \
        "$star_status" "$rsem_status" "${species_out}/${srr}.genes.results"

    log_step "$srr" "DONE" "Sample complete."
    disk_usage "post-sample [${srr}]"
    CURRENT_SRR=""
}

run_sample_loop() {
    local pass srr species layout line
    local rows=()

    # Read up front: prefetch and STAR consume stdin.
    mapfile -t rows < "$SAMPLES_TSV"

    for (( pass = 1; pass <= PIPELINE_RETRY_PASSES; pass++ )); do
        echo ""
        echo "============================================================"
        echo " Pass ${pass}/${PIPELINE_RETRY_PASSES}"
        echo "============================================================"

        for line in "${rows[@]}"; do
            # `_` takes the metadata columns, which would otherwise land in $layout.
            IFS=$'\t' read -r srr species layout _ <<< "$line"
            [[ "$srr" == "SRR" || -z "$srr" ]] && continue

            if tracker_is_complete "$srr"; then
                log_step "$srr" "SKIP" "Already done."
                continue
            fi

            echo ""
            echo "--- ${srr} | ${species} | ${layout} ---"
            process_sample "$srr" "$species" "$layout"
        done
    done
}
