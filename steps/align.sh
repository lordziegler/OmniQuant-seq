#!/usr/bin/env bash
# STAR alignment. On success sets global: BAM_PATH.

# ENCODE-standard flags used throughout.
_STAR_FLAGS=(
    --outSAMtype              BAM Unsorted
    --outSAMunmapped          Within
    --outFilterType           BySJout
    --outSAMattributes        NH HI AS NM MD
    --outFilterMultimapNmax   20
    --outFilterMismatchNmax   999
    --outFilterMismatchNoverReadLmax 0.04
    --alignIntronMin          20
    --alignIntronMax          1000000
    --alignMatesGapMax        1000000
    --alignSJoverhangMin      8
    --alignSJDBoverhangMin    1
    --sjdbScore               1
    --quantMode               TranscriptomeSAM
)

step_star() {
    local srr="$1" layout="$2"
    local out_prefix="${TMP_DIR}/${srr}_star/"
    mkdir -p "$out_prefix"

    local rfcmd="cat"
    [[ "${CLEAN_1:-${CLEAN_SE:-}}" == *.gz ]] && rfcmd="zcat"

    log_step "$srr" "STAR" "Aligning (${layout}) ..."
    disk_usage "pre-STAR [${srr}]"

    local ram_bytes=$(( MAX_MEMORY_GB * 1073741824 ))

    if [[ "$layout" == "PAIRED" ]]; then
        STAR \
            --runThreadN          "$THREADS_STAR" \
            --limitBAMsortRAM     "$ram_bytes" \
            --genomeDir           "$STAR_INDEX" \
            --readFilesCommand    "$rfcmd" \
            --outFileNamePrefix   "$out_prefix" \
            --readFilesIn         "$CLEAN_1" "$CLEAN_2" \
            "${_STAR_FLAGS[@]}" \
            > "${LOG_DIR}/${srr}_star.log" 2>&1
    else
        STAR \
            --runThreadN          "$THREADS_STAR" \
            --limitBAMsortRAM     "$ram_bytes" \
            --genomeDir           "$STAR_INDEX" \
            --readFilesCommand    "$rfcmd" \
            --outFileNamePrefix   "$out_prefix" \
            --readFilesIn         "$CLEAN_SE" \
            "${_STAR_FLAGS[@]}" \
            > "${LOG_DIR}/${srr}_star.log" 2>&1
    fi

    BAM_PATH="${out_prefix}Aligned.toTranscriptome.out.bam"
    if [[ ! -f "$BAM_PATH" ]]; then
        log_step "$srr" "ERROR" "STAR produced no transcriptome BAM. See: ${LOG_DIR}/${srr}_star.log"
        tail -n 30 "${LOG_DIR}/${srr}_star.log" >&2 || true
        return 1
    fi

    # Copy mapping stats for the QC matrix
    [[ -f "${out_prefix}Log.final.out" ]] && \
        cp "${out_prefix}Log.final.out" "${LOG_DIR}/${srr}_STAR_Log.final.out"

    log_step "$srr" "STAR" "BAM: ${BAM_PATH}"
}

resolve_reference_paths() {
    local species="$1"
    STAR_INDEX="${REFERENCES_DIR}/${species}/STAR_genome_index"
    RSEM_REF="${REFERENCES_DIR}/${species}/rsem_ref"
    require_dir  "$STAR_INDEX"     "Run: bash pipeline/run.sh --build-refs"
    require_file "${RSEM_REF}.grp" "Run: bash pipeline/run.sh --build-refs"
}
