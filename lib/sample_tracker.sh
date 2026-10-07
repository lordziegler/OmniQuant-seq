#!/usr/bin/env bash
# Rows are rewritten atomically via tmp + rename.

SUMMARY_FILE="${RESULTS_DIR}/pipeline_sample_summary.tsv"
_SUMMARY_HEADER="sample\tspecies\tlayout\ttest_mode\ttest_reads\tprefetch_status\tfastq_status\ttrimming_status\tstar_status\trsem_status\tgenes_results"

tracker_init() {
    mkdir -p "$(dirname "$SUMMARY_FILE")"
    [[ -f "$SUMMARY_FILE" ]] || printf '%b\n' "$_SUMMARY_HEADER" > "$SUMMARY_FILE"
}

tracker_update() {
    local sample="$1" species="$2" layout="$3" \
          pre="$4" fq="$5" trim="$6" star="$7" rsem="$8" genes="$9"
    local tmp="${SUMMARY_FILE}.tmp"

    awk -F'\t' -v s="$sample" 'NR==1 || $1 != s' "$SUMMARY_FILE" > "$tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sample" "$species" "$layout" "$TEST_MODE" "$TEST_READS" \
        "$pre" "$fq" "$trim" "$star" "$rsem" "$genes" >> "$tmp"
    mv "$tmp" "$SUMMARY_FILE"
}

tracker_is_complete() {
    local srr="$1"
    # Column 10 is rsem_status; OK means the full sample is done
    awk -F'\t' -v s="$srr" 'NR>1 && $1==s && $10=="OK"{found=1} END{exit !found}' \
        "$SUMMARY_FILE" 2>/dev/null
}
