#!/usr/bin/env bash
# STAR alignment. On success sets global: BAM_PATH.

# ENCODE long-RNA-seq standard flags. Same settings for every organism —
# organism-dependent knobs (STAR_OVERHANG, STAR_SA_INDEX_NBASES) live in
# config/pipeline.sh and are applied at index-build time.
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
    local star_log="${LOG_DIR}/${srr}_star.log"
    mkdir -p "$out_prefix"

    local reads=()
    if [[ "$layout" == "PAIRED" ]]; then
        reads=( "$CLEAN_1" "$CLEAN_2" )
    else
        reads=( "$CLEAN_SE" )
    fi

    # BBDuk writes gzipped output; keep the plain-file path working too.
    local read_files_command="cat"
    [[ "${reads[0]}" == *.gz ]] && read_files_command="zcat"

    log_step "$srr" "STAR" "Aligning (${layout}, ${THREADS_STAR} threads) ..."
    disk_usage "pre-STAR [${srr}]"

    STAR \
        --runThreadN          "$THREADS_STAR" \
        --limitBAMsortRAM     "$(( MAX_MEMORY_GB * 1073741824 ))" \
        --genomeDir           "$STAR_INDEX" \
        --readFilesCommand    "$read_files_command" \
        --outFileNamePrefix   "$out_prefix" \
        --readFilesIn         "${reads[@]}" \
        "${_STAR_FLAGS[@]}" \
        > "$star_log" 2>&1

    BAM_PATH="${out_prefix}Aligned.toTranscriptome.out.bam"
    if [[ ! -f "$BAM_PATH" ]]; then
        log_step "$srr" "ERROR" "STAR produced no transcriptome BAM. See: ${star_log}"
        tail -n 30 "$star_log" >&2 || true
        return 1
    fi

    # Keep the mapping stats where build_matrix.py looks for them.
    if [[ -f "${out_prefix}Log.final.out" ]]; then
        cp "${out_prefix}Log.final.out" "${LOG_DIR}/${srr}_STAR_Log.final.out"
    fi

    log_step "$srr" "STAR" "BAM: ${BAM_PATH}"
}
