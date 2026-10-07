#!/usr/bin/env bash

cleanup_sra() {
    local srr="$1" sra_path="$2"
    rm -f "$sra_path"
    rmdir "sra/${srr}" 2>/dev/null || true
    log_step "$srr" "CLEANUP" "SRA removed."
    disk_usage "post-sra-cleanup [${srr}]"
}

# cleanup_files SRR LABEL FILE...
cleanup_files() {
    local srr="$1" label="$2"; shift 2
    rm -f "$@"
    log_step "$srr" "CLEANUP" "${label} removed."
}

cleanup_tmp() {
    local srr="$1"
    rm -rf "${TMP_DIR}/${srr}_star" "${TMP_DIR}/${srr}_rsem_tmp"
}

cleanup_rsem_bam() {
    local srr="$1" species_out="$2"
    rm -f "${species_out}/${srr}.transcript.bam" \
          "${species_out}/${srr}.genome.bam" \
          "${species_out}/${srr}.STAR.genome.bam"
    log_step "$srr" "CLEANUP" "RSEM BAM files removed."
    disk_usage "post-bam-cleanup [${srr}]"
}

cleanup_on_error() {
    local srr="$1"; shift
    cleanup_tmp "$srr"
    cleanup_files "$srr" "Partial files" "$@"
}
