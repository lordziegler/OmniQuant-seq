#!/usr/bin/env bash
# RSEM quantification from the STAR transcriptome BAM.

step_rsem() {
    local srr="$1" layout="$2" species_out="$3"
    mkdir -p "$species_out"

    log_step "$srr" "RSEM" "Quantifying (${layout}) ..."
    disk_usage "pre-RSEM [${srr}]"

    local rsem_tmp="${TMP_DIR}/${srr}_rsem_tmp"
    mkdir -p "$rsem_tmp"

    local base_args=(
        rsem-calculate-expression
        --alignments
        --num-threads      "$THREADS_RSEM"
        --temporary-folder "$rsem_tmp"
        --forward-prob     "${FORWARD_PROB:-0.5}"
    )
    [[ "$layout" == "PAIRED" ]] && base_args+=( --paired-end )

    "${base_args[@]}" \
        "$BAM_PATH" \
        "$RSEM_REF" \
        "${species_out}/${srr}" \
        > "${LOG_DIR}/${srr}_rsem.log" 2>&1

    if [[ ! -f "${species_out}/${srr}.genes.results" ]]; then
        log_step "$srr" "ERROR" "RSEM produced no genes.results. See: ${LOG_DIR}/${srr}_rsem.log"
        return 1
    fi

    log_step "$srr" "RSEM" "genes.results confirmed: ${species_out}/${srr}.genes.results"
}
