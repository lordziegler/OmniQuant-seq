#!/usr/bin/env bash
# Locates the pipeline's inputs in the project root.
# Sets globals: RUN_TABLE (required), FNA_FILE / GTF_FILE (optional overrides).

# Exactly one RunTable must be present, unless the caller already chose one
# (e.g. run.sh --example).
detect_run_table() {
    local search_dir="${1:-.}"

    if [[ -n "${RUN_TABLE:-}" ]]; then
        require_file "$RUN_TABLE" "RUN_TABLE was set explicitly but does not exist."
        echo "[OK] RunTable : ${RUN_TABLE}"
        return 0
    fi

    local tables
    mapfile -t tables < <(find "$search_dir" -maxdepth 1 -type f \
        \( -iname "*RunTable*.csv" -o -iname "*RunTable*.xlsx" \) | sort)

    (( ${#tables[@]} == 1 )) || die \
        "Expected exactly 1 SRA RunTable (*RunTable*.csv/.xlsx) in '${search_dir}', found ${#tables[@]}."

    RUN_TABLE="${tables[0]}"
    echo "[OK] RunTable : ${RUN_TABLE}"
}

# A genome FASTA and GTF in the project root override the download URLs, but
# only when a single species is active — otherwise there is no way to tell
# which species those files belong to, and using them for all of them would
# silently quantify every organism against one genome.
detect_local_references() {
    local search_dir="${1:-.}"
    local fnas gtfs active_count
    FNA_FILE=""
    GTF_FILE=""

    mapfile -t fnas < <(find "$search_dir" -maxdepth 1 -type f \
        \( -name "*.fna.gz" -o -name "*.fa.gz" -o -name "*.fasta.gz" \) | sort)
    mapfile -t gtfs < <(find "$search_dir" -maxdepth 1 -type f -name "*.gtf.gz" | sort)

    if (( ${#fnas[@]} == 0 && ${#gtfs[@]} == 0 )); then
        echo "[INFO] No local genome files; references will be downloaded from SPECIES_CONFIG URLs."
        return 0
    fi

    if (( ${#fnas[@]} != 1 || ${#gtfs[@]} != 1 )); then
        echo "[WARN] Local override needs exactly 1 FASTA and 1 GTF (found ${#fnas[@]} and ${#gtfs[@]})."
        echo "       Ignoring local files; references will be downloaded instead."
        return 0
    fi

    active_count="$(species_config_active_keys | wc -l | tr -d ' ')"
    if (( active_count != 1 )); then
        echo "[WARN] ${active_count} species are active — a single local FASTA/GTF cannot be assigned."
        echo "       Ignoring local files; references will be downloaded per species instead."
        return 0
    fi

    FNA_FILE="${fnas[0]}"
    GTF_FILE="${gtfs[0]}"
    echo "[OK] FASTA    : ${FNA_FILE} (local override)"
    echo "[OK] GTF      : ${GTF_FILE} (local override)"
}
