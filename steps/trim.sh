#!/usr/bin/env bash
# Quality trimming with BBDuk.
# On success sets globals: CLEAN_1, CLEAN_2, CLEAN_SE (and SINGLETONS for PE).

# BBTools 39.81 launches the JVM with assertions enabled, and its multithreaded
# FASTQ reader — the one it picks from t>=12 on — asserts that the third line of
# every record is a bare "+". Both fastq-dump and fasterq-dump repeat the read
# header there, which is valid FASTQ, so each reader thread dies on its first
# record and BBDuk then blocks forever on an input queue nobody fills: no error,
# no exit code, the run just stops after the BBDUK line. Turning the assertion
# off leaves the parsing itself untouched.
BBDUK_JVM_ARGS=( -da )

# Build the BBDuk key=value arguments into the array BBDUK_ARGS. Adapter
# clipping is only requested when BBDUK_REF names an adapter FASTA; all values
# come from config/pipeline.sh.
_build_bbduk_args() {
    BBDUK_ARGS=()
    [[ -n "${BBDUK_REF:-}"   ]] && BBDUK_ARGS+=( "ref=${BBDUK_REF}" )
    [[ -n "${BBDUK_KTRIM:-}" ]] && BBDUK_ARGS+=( "ktrim=${BBDUK_KTRIM}" )
    [[ -n "${BBDUK_K:-}"     ]] && BBDUK_ARGS+=( "k=${BBDUK_K}" )
    [[ -n "${BBDUK_MINK:-}"  ]] && BBDUK_ARGS+=( "mink=${BBDUK_MINK}" )
    [[ -n "${BBDUK_HDIST:-}" ]] && BBDUK_ARGS+=( "hdist=${BBDUK_HDIST}" )
    BBDUK_ARGS+=( "qtrim=${BBDUK_QTRIM}" "trimq=${BBDUK_TRIMQ}" "minlen=${BBDUK_MINLEN}" )
    return 0
}

# True only when every path given exists.
_files_present() {
    local path
    for path in "$@"; do
        [[ -f "$path" ]] || return 1
    done
}

step_bbduk() {
    local srr="$1" layout="$2"

    CLEAN_1="clean_fastq/${srr}_1_clean.fastq.gz"
    CLEAN_2="clean_fastq/${srr}_2_clean.fastq.gz"
    SINGLETONS="clean_fastq/${srr}_singletons.fastq.gz"
    CLEAN_SE="clean_fastq/${srr}_clean.fastq.gz"

    mkdir -p clean_fastq
    _build_bbduk_args

    # Expected outputs, and the input/output arguments that produce them.
    local expected=() io_args=()
    if [[ "$layout" == "PAIRED" ]]; then
        expected=( "$CLEAN_1" "$CLEAN_2" )
        io_args=( "in1=${RAW_1}" "in2=${RAW_2}"
                  "out1=${CLEAN_1}" "out2=${CLEAN_2}" "outs=${SINGLETONS}" )
    else
        expected=( "$CLEAN_SE" )
        io_args=( "in=${RAW_SE}" "out=${CLEAN_SE}" )
    fi

    if _files_present "${expected[@]}"; then
        log_step "$srr" "BBDUK" "Clean ${layout} FASTQ already present — skipping."
        return 0
    fi

    log_step "$srr" "BBDUK" "Trimming ${layout} reads (qtrim=${BBDUK_QTRIM}, trimq=${BBDUK_TRIMQ}, minlen=${BBDUK_MINLEN}) ..."
    bbduk.sh \
        "${BBDUK_JVM_ARGS[@]}" \
        "${io_args[@]}" \
        "t=${THREADS_TRIM}" \
        "${BBDUK_ARGS[@]}" \
        2>&1 | tee "${LOG_DIR}/${srr}_bbduk.log"
    local status="${PIPESTATUS[0]}"

    # BBDuk opens its gzip outputs before it reads a single record, so finding
    # them on disk does not mean the trimming finished — only the exit status
    # does. Without this check a crashed run hands empty FASTQ to STAR.
    if (( status != 0 )) || ! _files_present "${expected[@]}"; then
        log_step "$srr" "ERROR" "BBDuk failed (exit ${status}). See: ${LOG_DIR}/${srr}_bbduk.log"
        return 1
    fi
}
