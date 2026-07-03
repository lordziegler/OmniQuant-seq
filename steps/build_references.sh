#!/usr/bin/env bash
# Downloads (or decompresses local) genome FASTA + GTF, then builds
# STAR genome index and RSEM reference for one species entry.
# Idempotent: skips if both indexes already exist.

_decompress_or_download() {
    local url="$1" gz_out="$2" final_out="$3"
    if [[ -f "$final_out" ]]; then
        echo "[SKIP] ${final_out##*/} already exists."
        return 0
    fi

    if [[ ! -f "$gz_out" ]]; then
        local attempt=1
        while [[ "$attempt" -le "$REF_DOWNLOAD_RETRIES" ]]; do
            echo "[DOWNLOAD] ${url##*/} (attempt ${attempt}/${REF_DOWNLOAD_RETRIES}) ..."
            if wget --tries=3 --continue --timeout=60 -q --show-progress -O "$gz_out" "$url" \
                && gzip -t "$gz_out" 2>/dev/null; then
                break
            fi
            echo "[WARN] Download or integrity check failed for ${url##*/}."
            rm -f "$gz_out"
            if [[ "$attempt" -lt "$REF_DOWNLOAD_RETRIES" ]]; then
                echo "[RETRY] Waiting ${REF_DOWNLOAD_RETRY_SLEEP}s ..."
                sleep "$REF_DOWNLOAD_RETRY_SLEEP"
            fi
            attempt=$(( attempt + 1 ))
        done
        if [[ ! -f "$gz_out" ]]; then
            echo "[ABORT] Failed to download a valid ${gz_out##*/} after ${REF_DOWNLOAD_RETRIES} attempts."
            exit 1
        fi
    else
        echo "[DECOMPRESS] ${gz_out##*/}"
        if ! gzip -t "$gz_out" 2>/dev/null; then
            echo "[ABORT] Existing file ${gz_out} is corrupt (failed gzip integrity check). Delete it and re-run."
            exit 1
        fi
    fi

    gunzip -c "$gz_out" > "$final_out"
    rm -f "$gz_out"
}

build_reference() {
    local entry="$1"
    local species fna_url gtf_url active
    IFS='|' read -r species fna_url gtf_url active <<< "$entry"

    [[ "${active,,}" == "false" ]] && { echo "[SKIP] ${species} is inactive."; return 0; }

    local sp_dir="${REFERENCES_DIR}/${species}"
    local star_idx="${sp_dir}/STAR_genome_index"
    local rsem_ref="${sp_dir}/rsem_ref"
    local genome="${sp_dir}/genome.fa"
    local gtf="${sp_dir}/genes.gtf"

    mkdir -p "$sp_dir" "$star_idx"

    if [[ -f "${rsem_ref}.grp" && -f "${star_idx}/SA" ]]; then
        echo "[SKIP] References already built for ${species}."
        return 0
    fi

    echo "--- ${species} ---"

    # Use local FASTA/GTF if already present (detect_inputs found them), else download
    if [[ -n "${FNA_FILE:-}" ]]; then
        _decompress_or_download "" "$FNA_FILE" "$genome"
    else
        _decompress_or_download "$fna_url" "${sp_dir}/genome.fna.gz" "$genome"
    fi

    if [[ -n "${GTF_FILE:-}" ]]; then
        _decompress_or_download "" "$GTF_FILE" "$gtf"
    else
        _decompress_or_download "$gtf_url" "${sp_dir}/genes.gtf.gz" "$gtf"
    fi

    echo "[STAR] Building genome index for ${species} ..."
    STAR \
        --runThreadN          "$THREADS_STAR" \
        --runMode             genomeGenerate \
        --genomeDir           "$star_idx" \
        --genomeFastaFiles    "$genome" \
        --sjdbGTFfile         "$gtf" \
        --sjdbOverhang        "$STAR_OVERHANG" \
        --genomeSAindexNbases "$STAR_SA_INDEX_NBASES" \
        2>&1 | tee "${LOG_DIR}/${species}_star_index.log"

    echo "[RSEM] Preparing reference for ${species} ..."
    rsem-prepare-reference \
        --gtf    "$gtf" \
        "$genome" \
        "$rsem_ref" \
        2>&1 | tee "${LOG_DIR}/${species}_rsem_prepare.log"

    disk_usage "post-index [${species}]"
    echo "[DONE] ${species}"
}

build_all_references() {
    for entry in "${SPECIES_CONFIG[@]}"; do
        build_reference "$entry"
    done
}
