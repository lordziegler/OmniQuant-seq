#!/usr/bin/env bash
# Turns the SRA RunTable into samples.tsv via helpers/parse_runtable.py.

parse_samples() {
    echo "[INFO] Parsing RunTable: ${RUN_TABLE}"
    mkdir -p "$(dirname "$SAMPLES_TSV")"

    # Restrict parsing to the species active in config/species.sh, so only
    # organisms with a built reference reach samples.tsv. With none active the
    # parser stays unrestricted and keeps every organism it finds.
    local active_keys
    active_keys="$(species_config_active_keys | paste -sd, -)"

    local args=( --input "$RUN_TABLE" --output "$SAMPLES_TSV" )
    [[ -n "$active_keys" ]] && args+=( --species "$active_keys" )
    [[ -n "${SPECIES_FALLBACK:-}" ]] && args+=( --fallback "$SPECIES_FALLBACK" )

    python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" "${args[@]}"

    require_file "$SAMPLES_TSV" "parse_runtable.py failed to produce samples.tsv."
    echo "[DONE] samples.tsv: ${SAMPLES_TSV}"
}
