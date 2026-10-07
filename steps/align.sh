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
    --quantMode               TranscriptomeSAM GeneCounts
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

    _infer_strandedness "$srr" "${out_prefix}ReadsPerGene.out.tab"

    log_step "$srr" "STAR" "BAM: ${BAM_PATH}"
}

# GeneCounts costs nothing extra — STAR already walks the annotation for
# TranscriptomeSAM — and tells us whether a library is stranded, which the
# pipeline previously had no way to detect. Sets globals: STRAND_RATIO,
# FORWARD_PROB (RSEM's --forward-prob for the upcoming quantify step).
_infer_strandedness() {
    local srr="$1" gene_counts="$2"
    STRAND_RATIO="NA"
    FORWARD_PROB="0.5"

    [[ -f "$gene_counts" ]] || return 0
    cp "$gene_counts" "${LOG_DIR}/${srr}_STAR_ReadsPerGene.out.tab"

    # Columns 3/4 after the 4 summary rows are forward/reverse counts.
    read -r STRAND_RATIO FORWARD_PROB < <(awk 'NR>4 {f+=$3; r+=$4} END {
        if (f + r == 0) { print "NA", 0.5; exit }
        s = sprintf("%.3f", f / (f + r)); x = s + 0
        print s, (x > 0.8 ? 1 : (x < 0.2 ? 0 : 0.5))
    }' "$gene_counts")
    [[ "$STRAND_RATIO" == NA ]] && return 0
    log_step "$srr" "STAR" "Strand ratio fwd/(fwd+rev)=${STRAND_RATIO} -> RSEM --forward-prob ${FORWARD_PROB}"
}
