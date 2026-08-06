#!/usr/bin/env bash
# Downloads an SRA archive with configurable retry.
# On success sets global: SRA_PATH

# prefetch writes either sra/<acc>/<acc>.sra or sra/<acc>.sra depending on the
# SRA-Toolkit version; accept both. Sets SRA_PATH and returns 0 when found.
_locate_sra() {
    local srr="$1" candidate
    for candidate in "sra/${srr}/${srr}.sra" "sra/${srr}.sra"; do
        if [[ -f "$candidate" ]]; then
            SRA_PATH="$candidate"
            return 0
        fi
    done
    return 1
}

_discard_partial_sra() {
    local srr="$1"
    rm -f "sra/${srr}/${srr}.sra" "sra/${srr}.sra"
    rmdir "sra/${srr}" 2>/dev/null || true
}

step_prefetch() {
    local srr="$1" attempt

    if _locate_sra "$srr"; then
        log_step "$srr" "PREFETCH" "Already present: ${SRA_PATH}"
        return 0
    fi

    for (( attempt = 1; attempt <= PREFETCH_RETRIES; attempt++ )); do
        log_step "$srr" "PREFETCH" "Attempt ${attempt}/${PREFETCH_RETRIES} (max-size ${MAX_SRA_SIZE}) ..."

        prefetch "$srr" \
            --output-directory sra \
            --max-size "$MAX_SRA_SIZE" \
            2>&1 | tee "${LOG_DIR}/${srr}_prefetch_${attempt}.log"

        if _locate_sra "$srr"; then
            log_step "$srr" "PREFETCH" "Done: ${SRA_PATH}"
            return 0
        fi

        # A failed attempt can leave a truncated archive behind; drop it so the
        # next attempt cannot mistake it for a complete download.
        log_step "$srr" "PREFETCH" "Attempt ${attempt} failed."
        _discard_partial_sra "$srr"

        if (( attempt < PREFETCH_RETRIES )); then
            log_step "$srr" "PREFETCH" "Waiting ${PREFETCH_RETRY_SLEEP}s ..."
            sleep "$PREFETCH_RETRY_SLEEP"
        fi
    done

    log_step "$srr" "ERROR" "prefetch failed after ${PREFETCH_RETRIES} attempts."
    return 1
}
