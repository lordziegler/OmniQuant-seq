#!/usr/bin/env bash
# Post-processing: delegates to Python helpers for matrix building,
# then runs global MultiQC.

# Print the head of the merged expression matrix, so every run ends with
# visible evidence that the inner join produced data. Never fatal: a missing
# matrix is reported and the run still finishes.
preview_expression_matrix() {
    local matrix="${RESULTS_DIR}/tables/gene_expression_matrix.tsv"
    local lines="${PREVIEW_LINES:-10}"

    [[ "${ENABLE_PREVIEW:-true}" == true ]] || return 0

    if [[ ! -r "$matrix" ]]; then
        echo "[WARN] ${matrix} not found; no preview available."
        return 0
    fi

    echo ""
    echo "[INFO] Preview of gene_expression_matrix.tsv (inner join of all samples)"
    echo "       Showing first ${lines} lines. Use your editor or tools like head,"
    echo "       tail, awk or visidata for full exploration."
    echo "------------------------------------------------------------"
    head -n "$lines" "$matrix"
    echo "------------------------------------------------------------"
}

postprocess_all() {
    local tables="${RESULTS_DIR}/tables"
    mkdir -p "$tables"

    echo "[INFO] Building gene expression matrix ..."
    python3 "${PIPELINE_DIR}/helpers/build_matrix.py" \
        --rsem-dir   "${RESULTS_DIR}/rsem" \
        --output     "${tables}/gene_expression_matrix.tsv" \
        --star-logs  "$LOG_DIR" \
        --bbduk-logs "$LOG_DIR" \
        --star-out   "${tables}/STAR_mapping_QC_matrix.tsv" \
        --bbduk-out  "${tables}/BBDUK_preprocessing_QC_matrix.tsv"

    echo "[INFO] Running global MultiQC ..."
    step_multiqc_global

    echo ""
    echo "============================================================"
    echo " Pipeline finished."
    echo " Expression matrix : ${tables}/gene_expression_matrix.tsv"
    echo " STAR QC matrix    : ${tables}/STAR_mapping_QC_matrix.tsv"
    echo " BBDuk QC matrix   : ${tables}/BBDUK_preprocessing_QC_matrix.tsv"
    echo " MultiQC reports   : ${RESULTS_DIR}/qc/multiqc/global/"
    echo " Sample summary    : ${RESULTS_DIR}/pipeline_sample_summary.tsv"
    echo "============================================================"

    preview_expression_matrix
}
