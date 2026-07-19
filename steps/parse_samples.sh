#!/usr/bin/env bash
# Calls the Python helper to parse the SRA RunTable and write samples.tsv.

parse_samples() {
    echo "[INFO] Parsing RunTable: ${RUN_TABLE}"
    mkdir -p "$(dirname "$SAMPLES_TSV")"

    # Restrict parsing to the species that are active in config/species.sh, so
    # only organisms with a built reference reach samples.tsv. If none are
    # active, leave the parser unrestricted (it keeps every organism found).
    local active=()
    for entry in "${SPECIES_CONFIG[@]}"; do
        local name fna_url gtf_url active_flag
        IFS='|' read -r name fna_url gtf_url active_flag <<< "$entry"
        [[ "${active_flag,,}" == "true" ]] && active+=( "$name" )
    done

    local args=( --input "$RUN_TABLE" --output "$SAMPLES_TSV" )
    if (( ${#active[@]} > 0 )); then
        local joined; printf -v joined '%s,' "${active[@]}"
        args+=( --species "${joined%,}" )
    fi
    [[ -n "${SPECIES_FALLBACK:-}" ]] && args+=( --fallback "$SPECIES_FALLBACK" )

    python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" "${args[@]}"

    require_file "$SAMPLES_TSV" "parse_runtable.py failed to produce samples.tsv."
    echo "[DONE] samples.tsv: ${SAMPLES_TSV}"
}
