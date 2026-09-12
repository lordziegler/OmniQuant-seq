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

# Per-sample log line, echoed and appended to ${LOG_DIR}/<sample>.log.
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
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < DISK_WARN_GB )); then
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

# Best-effort integrity check against NCBI's md5checksums.txt, published in
# the same FTP directory as the reference file. Sources that do not publish
# one (a non-NCBI URL) are not blocked — gzip -t below still catches
# truncation; this only adds protection against a truncated-but-valid-gzip or
# silently wrong file (M9).
_verify_md5() {
    local src="$1" url="$2"
    local base="${url%/*}" fname="${url##*/}"
    local sums
    sums="$(dirname "$src")/md5checksums.txt"

    download_file "${base}/md5checksums.txt" "$sums" 2>/dev/null || {
        echo "[WARN] No md5checksums.txt at ${base} — skipping checksum verification."
        return 0
    }

    local expected
    expected="$(grep -E "[[:space:]]\.?/?${fname}\$" "$sums" | awk '{print $1}' | head -1)"
    if [[ -z "$expected" ]]; then
        echo "[WARN] ${fname} not listed in md5checksums.txt — skipping checksum verification."
        return 0
    fi

    local actual
    actual="$(md5sum "$src" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "[ERROR] Checksum mismatch for ${fname}: expected ${expected}, got ${actual}." >&2
        return 1
    fi
    echo "[OK] Checksum verified: ${fname}"
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

    local src="$local_gz" downloaded=false
    if [[ -z "$src" || ! -f "$src" ]]; then
        src="${dest}.gz"
        if [[ ! -f "$src" ]]; then
            download_file "$url" "$src" || {
                echo "[ERROR] Download failed: ${url}" >&2
                return 1
            }
            downloaded=true
        fi
    fi

    # Checksum verification only applies to files this run downloaded — a
    # user-supplied local_gz is trusted as-is, and requiring internet access
    # to use one would break offline/manual-reference usage.
    if [[ "$downloaded" == true && -n "$url" ]]; then
        _verify_md5 "$src" "$url" || { rm -f "$src"; return 1; }
    fi

    # A truncated archive decompresses into a silently incomplete genome, so it
    # is verified before use — whether we downloaded it or the user supplied it.
    if ! gzip -t "$src" 2>/dev/null; then
        [[ "$src" == "$local_gz" ]] || rm -f "$src"
        echo "[ERROR] Corrupt gzip archive: ${src}" >&2
        return 1
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
