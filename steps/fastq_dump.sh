#!/usr/bin/env bash
# Sets globals: RAW_1, RAW_2, RAW_SE.

step_fastq_dump() {
    local srr="$1" layout="$2"

    RAW_1="fastq/${srr}_1.fastq"
    RAW_2="fastq/${srr}_2.fastq"
    RAW_SE="fastq/${srr}.fastq"

    local expected=( "$RAW_SE" )
    [[ "$layout" == "PAIRED" ]] && expected=( "$RAW_1" "$RAW_2" )

    if _files_present "${expected[@]}"; then
        log_step "$srr" "FASTQ" "Raw FASTQ already present — skipping."
        return 0
    fi

    if [[ "$TEST_MODE" == true ]]; then
        log_step "$srr" "FASTQ-DUMP" "Test mode: ${TEST_READS} reads (${layout}) ..."
        fastq-dump "$SRA_PATH" \
            --outdir fastq \
            --split-3 \
            -X "$TEST_READS" \
            2>&1 | tee "${LOG_DIR}/${srr}_fastq_dump.log"
    else
        log_step "$srr" "FASTERQ-DUMP" "Extracting all reads (${layout}) ..."
        fasterq-dump "$SRA_PATH" \
            --outdir  fastq \
            --temp    "$TMP_DIR" \
            --split-3 \
            --threads "$THREADS_DOWNLOAD" \
            2>&1 | tee "${LOG_DIR}/${srr}_fasterq.log"
    fi

    _files_present "${expected[@]}" && return 0
    log_step "$srr" "ERROR" "${layout} FASTQ missing after extraction."
    return 1
}
