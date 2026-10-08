#!/usr/bin/env bash
# Sets globals: BAM_PATH, READ_MAX_NT (longest read, long-read samples only).

# ENCODE long-RNA-seq options.
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

# STARlong, for reads past LONG_READ_NT (PacBio, Nanopore, 454): the STAR
# manual's long-read seeding and filtering, same index and outputs.
LONG_READ_NT=500
_STARLONG_FLAGS=(
    --outSAMtype              BAM Unsorted
    --outSAMunmapped          Within
    --outSAMattributes        NH HI AS NM MD
    --outFilterMultimapScoreRange 20
    --outFilterScoreMinOverLread  0
    --outFilterMatchNminOverLread 0.66
    --outFilterMismatchNmax   1000
    --winAnchorMultimapNmax   200
    --seedSearchLmax          30
    --seedSearchStartLmax     12
    --seedPerReadNmax         100000
    --seedPerWindowNmax       100
    --alignTranscriptsPerReadNmax   100000
    --alignTranscriptsPerWindowNmax 10000
    --alignIntronMax          1000000
    --quantMode               TranscriptomeSAM GeneCounts
)

# Longest read among the first N reads of a FASTQ (default 10,000; 0 = all).
_max_read_len() {
    { zcat -f "$1" | awk -v n="${2:-10000}" 'NR % 4 == 2 && length($0) > m { m = length($0) } n && NR >= 4 * n { exit } END { print m + 0 }'; } 2>/dev/null || true
}

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

    local read_files_command="cat"
    [[ "${reads[0]}" == *.gz ]] && read_files_command="zcat"

    local star=STAR flags=( "${_STAR_FLAGS[@]}" ) threads="$THREADS_STAR" longest
    longest="$(_max_read_len "${reads[0]}")"
    READ_MAX_NT=""
    if (( longest > LONG_READ_NT )); then
        # The whole file, not a sample: RSEM corrupts memory past this length.
        READ_MAX_NT="$(_max_read_len "${reads[0]}" 0)"
        longest="$READ_MAX_NT"
        # ponytail: ~2 GB per STARlong thread (2.1 GB peak, 1 thread, 454 reads);
        # re-measure if the long-read seeding options change.
        star=STARlong flags=( "${_STARLONG_FLAGS[@]}" )
        threads=$(( MAX_MEMORY_GB / 2 < 1 ? 1 : MAX_MEMORY_GB / 2 ))
        (( threads > THREADS_STAR )) && threads="$THREADS_STAR"
    fi

    log_step "$srr" "STAR" "Aligning with ${star} (${layout}, reads up to ${longest} nt, ${threads} threads) ..."
    disk_usage "pre-STAR [${srr}]"

    "$star" \
        --runThreadN          "$threads" \
        --genomeDir           "$STAR_INDEX" \
        --readFilesCommand    "$read_files_command" \
        --outFileNamePrefix   "$out_prefix" \
        --readFilesIn         "${reads[@]}" \
        "${flags[@]}" \
        > "$star_log" 2>&1

    BAM_PATH="${out_prefix}Aligned.toTranscriptome.out.bam"
    if [[ ! -f "$BAM_PATH" ]]; then
        log_step "$srr" "ERROR" "STAR produced no transcriptome BAM. See: ${star_log}"
        tail -n 30 "$star_log" >&2 || true
        return 1
    fi

    # build_matrix.py reads it from LOG_DIR.
    if [[ -f "${out_prefix}Log.final.out" ]]; then
        cp "${out_prefix}Log.final.out" "${LOG_DIR}/${srr}_STAR_Log.final.out"
    fi

    # Small-RNA libraries catalogued as RNA-Seq align almost nothing; keep
    # them out of the matrix instead of reporting them as OK.
    # ponytail: retried like any failed stage; mark it final if retries cost too much.
    local unique min="${MIN_UNIQUE_MAPPED_PCT:-10}"
    unique="$(awk -F'|' '/Uniquely mapped reads %/ {gsub(/[ \t%]/, "", $2); print $2}' \
        "${out_prefix}Log.final.out" 2>/dev/null)"
    if [[ -n "$unique" ]] && awk -v u="$unique" -v m="$min" 'BEGIN { exit !(u < m) }'; then
        log_step "$srr" "ERROR" "Only ${unique}% of reads mapped uniquely (MIN_UNIQUE_MAPPED_PCT=${min}): not an mRNA library? See ${LOG_DIR}/${srr}_STAR_Log.final.out"
        return 1
    fi

    _infer_strandedness "$srr" "${out_prefix}ReadsPerGene.out.tab"

    log_step "$srr" "STAR" "BAM: ${BAM_PATH}"
}

# Sets STRAND_RATIO and FORWARD_PROB (RSEM --forward-prob).
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
