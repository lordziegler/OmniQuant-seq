#!/usr/bin/env bash
# Materializes genome FASTA + GTF for a species, then builds the STAR genome
# index and the RSEM reference. Idempotent: skips species already built.
#
# Layout produced per species:
#   references/<species_key>/genome.fa
#   references/<species_key>/genes.gtf
#   references/<species_key>/STAR_genome_index/
#   references/<species_key>/rsem_ref.*

# Download and decompress the FASTA + GTF of one species into
# references/<species_key>/. Used both by --build-refs and by
# `setup.sh --add-species`.
fetch_species_references() {
    local species="$1" fna_url="$2" gtf_url="$3"
    local sp_dir="${REFERENCES_DIR}/${species}"

    mkdir -p "$sp_dir" || return 1
    fetch_and_decompress "${sp_dir}/genome.fa" "${FNA_FILE:-}" "$fna_url" || return 1
    fetch_and_decompress "${sp_dir}/genes.gtf" "${GTF_FILE:-}" "$gtf_url" || return 1
}

build_reference() {
    local entry="$1"
    local species fna_url gtf_url active
    species_entry_split "$entry" species fna_url gtf_url active

    if [[ "${active,,}" != "true" ]]; then
        echo "[SKIP] ${species} is inactive."
        return 0
    fi

    local sp_dir="${REFERENCES_DIR}/${species}"
    local star_idx="${sp_dir}/STAR_genome_index"
    local rsem_ref="${sp_dir}/rsem_ref"
    local genome="${sp_dir}/genome.fa"
    local gtf="${sp_dir}/genes.gtf"

    if [[ -f "${rsem_ref}.grp" && -f "${star_idx}/SA" ]]; then
        echo "[SKIP] References already built for ${species}."
        return 0
    fi

    echo "--- ${species} ---"
    mkdir -p "$star_idx"
    fetch_species_references "$species" "$fna_url" "$gtf_url" \
        || die "Could not obtain reference files for ${species}."

    echo "[STAR] Building genome index for ${species} (sjdbOverhang=${STAR_OVERHANG}, genomeSAindexNbases=${STAR_SA_INDEX_NBASES}) ..."
    STAR \
        --runThreadN          "$THREADS_STAR" \
        --runMode             genomeGenerate \
        --genomeDir           "$star_idx" \
        --genomeFastaFiles    "$genome" \
        --sjdbGTFfile         "$gtf" \
        --sjdbOverhang        "$STAR_OVERHANG" \
        --genomeSAindexNbases "$STAR_SA_INDEX_NBASES" \
        2>&1 | tee "${LOG_DIR}/${species}_star_index.log"
    require_file "${star_idx}/SA" "STAR genomeGenerate failed — see ${LOG_DIR}/${species}_star_index.log"

    echo "[RSEM] Preparing reference for ${species} ..."
    rsem-prepare-reference \
        --gtf    "$gtf" \
        "$genome" \
        "$rsem_ref" \
        2>&1 | tee "${LOG_DIR}/${species}_rsem_prepare.log"
    require_file "${rsem_ref}.grp" "rsem-prepare-reference failed — see ${LOG_DIR}/${species}_rsem_prepare.log"

    disk_usage "post-index [${species}]"
    echo "[DONE] ${species}"
}

build_all_references() {
    local entry
    for entry in "${SPECIES_CONFIG[@]}"; do
        build_reference "$entry"
    done
}

# STAR index + RSEM reference paths for one species. Sets: STAR_INDEX, RSEM_REF.
resolve_reference_paths() {
    local species="$1"
    STAR_INDEX="${REFERENCES_DIR}/${species}/STAR_genome_index"
    RSEM_REF="${REFERENCES_DIR}/${species}/rsem_ref"
    require_dir  "$STAR_INDEX"     "Run: bash pipeline/run.sh --build-refs"
    require_file "${RSEM_REF}.grp" "Run: bash pipeline/run.sh --build-refs"
}
