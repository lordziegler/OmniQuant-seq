#!/usr/bin/env bash
# FastQC and MultiQC wrappers.

step_fastqc() {
    local srr="$1" label="$2"; shift 2
    log_step "$srr" "FASTQC_${label}" "Running FastQC ..."
    fastqc "$@" \
        --outdir  fastqc_out \
        --threads "$THREADS_FASTQC" \
        2>&1 | tee "${LOG_DIR}/${srr}_fastqc_${label,,}.log" || true
}

# Per-sample MultiQC on clean reads immediately after trimming.
step_multiqc_sample() {
    local srr="$1" layout="$2"
    local mqc_out="${RESULTS_DIR}/qc/multiqc/${srr}"
    mkdir -p "$mqc_out"

    local zips=()
    if [[ "$layout" == "PAIRED" ]]; then
        zips=( "fastqc_out/${srr}_1_clean_fastqc.zip" "fastqc_out/${srr}_2_clean_fastqc.zip" )
    else
        zips=( "fastqc_out/${srr}_clean_fastqc.zip" )
    fi

    local missing=false z
    for z in "${zips[@]}"; do [[ ! -f "$z" ]] && missing=true; done
    if [[ "$missing" == true ]]; then
        log_step "$srr" "MULTIQC" "Clean FastQC zips missing — skipping."
        return 0
    fi

    multiqc "${zips[@]}" \
        --outdir   "$mqc_out" \
        --filename "${srr}_clean_multiqc" \
        2>&1 | tee "${LOG_DIR}/${srr}_multiqc.log" || true
}

# Global MultiQC over all samples at the end of the pipeline.
step_multiqc_global() {
    local mqc_out="${RESULTS_DIR}/qc/multiqc/global"
    local raw_zips=() clean_zips=() bbduk_logs=()
    mkdir -p "$mqc_out"

    mapfile -t raw_zips < <(find fastqc_out -maxdepth 1 -name "*_fastqc.zip" \
                             ! -name "*_clean_fastqc.zip" | sort)
    mapfile -t clean_zips < <(find fastqc_out -maxdepth 1 -name "*_clean_fastqc.zip" | sort)
    mapfile -t bbduk_logs < <(find "$LOG_DIR"  -maxdepth 1 -name "*_bbduk.log" | sort)

    if [[ ${#raw_zips[@]} -gt 0 ]]; then
        multiqc "${raw_zips[@]}" \
            --outdir "$mqc_out" --filename "RNAseq_raw_multiqc" --force \
            2>&1 | tee "${LOG_DIR}/multiqc_raw.log" || true
    fi

    if [[ ${#clean_zips[@]} -gt 0 ]]; then
        multiqc "${clean_zips[@]}" "${bbduk_logs[@]}" \
            --outdir "$mqc_out" --filename "RNAseq_clean_multiqc" --force \
            2>&1 | tee "${LOG_DIR}/multiqc_clean.log" || true
    fi
}
