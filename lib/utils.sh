#!/usr/bin/env bash
# Shared utilities sourced by every pipeline module.
# Nothing here is organism-specific.

CONDA_ENV_NAME="omniquant-seq"

# --- Messaging ---------------------------------------------------------------

# Print an abort message on stderr and stop the script.
die() {
    echo "[ABORT] $*" >&2
    exit 1
}

# Per-sample log line, echoed and appended to pipeline/logs/<sample>.log.
log_step() {
    local srr="$1" tag="$2" msg="$3"
    local ts line
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    line="[${ts}] [${srr}] [${tag}] ${msg}"
    echo "$line"
    mkdir -p "$LOG_DIR"
    echo "$line" >> "${LOG_DIR}/${srr}.log"
}

# --- Environment checks ------------------------------------------------------

check_tools() {
    local tool missing=0
    for tool in "$@"; do
        if command -v "$tool" &>/dev/null; then
            echo "[OK] ${tool}"
        else
            echo "[MISSING] ${tool}"
            (( missing++ )) || true
        fi
    done
    (( missing == 0 )) || die "${missing} required tool(s) not found in PATH.
        Activate the conda environment: conda activate ${CONDA_ENV_NAME}"
}

require_file() {
    local path="$1" hint="${2:-}"
    [[ -f "$path" ]] && return 0
    [[ -n "$hint" ]] && echo "        ${hint}" >&2
    die "Required file missing: ${path}"
}

require_dir() {
    local path="$1" hint="${2:-}"
    [[ -d "$path" ]] && return 0
    [[ -n "$hint" ]] && echo "        ${hint}" >&2
    die "Required directory missing: ${path}"
}

# --- Disk --------------------------------------------------------------------

disk_usage() {
    local label="$1"
    local used avail
    used="$(du -sh . 2>/dev/null | cut -f1)"
    avail="$(df -BG . 2>/dev/null | awk 'NR==2{ gsub("G","",$4); print $4 }')"
    echo "[DISK] ${label} | used: ${used} | free: ${avail}G"
    if [[ -n "$avail" ]] && (( avail < DISK_WARN_GB )); then
        echo "[WARN] Free space (${avail}G) below threshold (${DISK_WARN_GB}G)."
    fi
}

# --- Downloads ---------------------------------------------------------------

# Fetch a URL to $dest via a .part file, so an interrupted transfer is never
# mistaken for a complete one on the next run.
download_file() {
    local url="$1" dest="$2"
    local part="${dest}.part"

    mkdir -p "$(dirname "$dest")"
    rm -f "$part"

    # Progress meters are noise in a log file; keep them only on a terminal.
    local quiet=()
    [[ -t 2 ]] || quiet=( --silent --show-error )

    echo "[DOWNLOAD] ${url##*/}"
    if command -v curl &>/dev/null; then
        curl -fL --retry 3 --retry-delay 5 "${quiet[@]}" -o "$part" "$url" \
            || { rm -f "$part"; return 1; }
    elif command -v wget &>/dev/null; then
        local wget_flags=( -q )
        [[ -t 2 ]] && wget_flags+=( --show-progress )
        wget "${wget_flags[@]}" --tries=3 -O "$part" "$url" \
            || { rm -f "$part"; return 1; }
    else
        echo "[ERROR] Neither curl nor wget is available." >&2
        return 1
    fi

    mv "$part" "$dest"
}

# Produce the decompressed $dest from, in order of preference:
#   1. $dest itself, if it already exists (idempotent re-runs);
#   2. $local_gz, a gzip file already on disk — never deleted, it may be an
#      input the user supplied;
#   3. $url, downloaded next to $dest and removed once decompressed.
fetch_and_decompress() {
    local dest="$1" local_gz="${2:-}" url="${3:-}"

    if [[ -f "$dest" ]]; then
        echo "[SKIP] ${dest##*/} already exists."
        return 0
    fi

    local src="$local_gz"
    if [[ -z "$src" || ! -f "$src" ]]; then
        src="${dest}.gz"
        if [[ ! -f "$src" ]]; then
            download_file "$url" "$src" || {
                echo "[ERROR] Download failed: ${url}" >&2
                return 1
            }
        fi
    fi

    echo "[DECOMPRESS] ${src##*/} -> ${dest##*/}"
    if ! gunzip -c "$src" > "$dest"; then
        rm -f "$dest"
        echo "[ERROR] Decompression failed: ${src}" >&2
        return 1
    fi

    # Only remove archives we placed there ourselves.
    if [[ "$src" != "$local_gz" ]]; then
        rm -f "$src"
    fi
    return 0
}

# --- Parsing -----------------------------------------------------------------

normalize_layout() {
    local raw
    raw="$(echo "$1" | tr '[:lower:]' '[:upper:]' | tr -d '\r' | sed 's/[-_]/ /g' | xargs)"
    case "$raw" in
        PAIRED|"PAIRED END"|PE) echo "PAIRED" ;;
        SINGLE|"SINGLE END"|SE) echo "SINGLE" ;;
        *) echo "[ABORT] Unknown library layout: '${1}'" >&2; return 1 ;;
    esac
}
