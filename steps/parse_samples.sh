#!/usr/bin/env bash

parse_samples() {
    echo "[INFO] Parsing RunTable: ${RUN_TABLE}"
    mkdir -p "$(dirname "$SAMPLES_TSV")"

    # With no active species the parser keeps every organism.
    local active_keys
    active_keys="$(species_config_active_keys | paste -sd, -)"

    local args=( --input "$RUN_TABLE" --output "$SAMPLES_TSV" )
    [[ -n "$active_keys" ]] && args+=( --species "$active_keys" )
    [[ -n "${SPECIES_FALLBACK:-}" ]] && args+=( --fallback "$SPECIES_FALLBACK" )
    [[ -n "${STAR_OVERHANG:-}" ]] && args+=( --star-overhang "$STAR_OVERHANG" )
    [[ -n "${MANUAL_RUNS:-}" ]] && args+=( --runs "$MANUAL_RUNS" )

    python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" "${args[@]}"

    require_file "$SAMPLES_TSV" "parse_runtable.py failed to produce samples.tsv."
    echo "[DONE] samples.tsv: ${SAMPLES_TSV}"
}
