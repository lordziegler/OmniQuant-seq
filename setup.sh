#!/usr/bin/env bash
# setup.sh — Interactive compute-resource configurator.
# Detects available CPUs, RAM, and disk, prompts for thread/memory/storage
# limits, and writes the values into config/pipeline.sh.
# Run once before the first execution, or whenever server resources change.

set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${PIPELINE_DIR}/config/pipeline.sh"

# --- Helpers -----------------------------------------------------------------
prompt_int() {
    local var_name="$1" prompt_text="$2" current="$3" min="$4" max="$5"
    local value
    while true; do
        read -rp "  ${prompt_text} [current: ${current}, range: ${min}–${max}]: " value
        value="${value:-$current}"
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "  Invalid input. Enter an integer between ${min} and ${max}."
    done
}

prompt_storage() {
    local var_name="$1" prompt_text="$2" current="$3"
    local value
    read -rp "  ${prompt_text} [current: ${current}]: " value
    value="${value:-$current}"
    if [[ "$value" =~ ^[0-9]+(G|T|M)$ ]]; then
        printf -v "$var_name" '%s' "$value"
    else
        echo "  Invalid format (use e.g. 100G, 1T) — keeping current: ${current}"
        printf -v "$var_name" '%s' "$current"
    fi
}

# --- Load current values from config/pipeline.sh as defaults -----------------
source "$CONFIG"

# --- Detect available resources ----------------------------------------------
MAX_CPUS=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 64)
AVAIL_RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}' || echo 64)
AVAIL_DISK_GB=$(df -BG . 2>/dev/null | awk 'NR==2{ gsub("G","",$4); print $4 }' || echo 999)

echo ""
echo "========================================================"
echo " Lepidoptera RNA-seq Pipeline — Compute Resource Setup"
echo " Detected CPUs  : ${MAX_CPUS}"
echo " Available RAM  : ${AVAIL_RAM_GB} GB"
echo " Available disk : ${AVAIL_DISK_GB} GB"
echo " Leave blank to keep the current value."
echo "========================================================"

echo ""
echo " Download / fasterq-dump"
prompt_int  NEW_T_DL    "Threads (THREADS_DOWNLOAD)" "$THREADS_DOWNLOAD" 1 "$MAX_CPUS"

echo ""
echo " FastQC"
prompt_int  NEW_T_FQC   "Threads (THREADS_FASTQC)"   "$THREADS_FASTQC"   1 "$MAX_CPUS"

echo ""
echo " BBDuk trimming"
prompt_int  NEW_T_TRIM  "Threads (THREADS_TRIM)"     "$THREADS_TRIM"     1 "$MAX_CPUS"

echo ""
echo " STAR alignment"
prompt_int  NEW_T_STAR  "Threads (THREADS_STAR)"     "$THREADS_STAR"     1 "$MAX_CPUS"
prompt_int  NEW_MEM     "RAM limit GB (MAX_MEMORY_GB — passed to --limitBAMsortRAM)" \
                        "$MAX_MEMORY_GB" 1 "$AVAIL_RAM_GB"

echo ""
echo " RSEM quantification"
prompt_int  NEW_T_RSEM  "Threads (THREADS_RSEM)"     "$THREADS_RSEM"     1 "$MAX_CPUS"

echo ""
echo " Storage"
prompt_storage NEW_SRA_SIZE "Max SRA prefetch size (MAX_SRA_SIZE)"  "$MAX_SRA_SIZE"
prompt_int  NEW_DISK_WARN   "Disk warning threshold GB (DISK_WARN_GB)" \
                            "$DISK_WARN_GB" 1 9999

echo ""
echo "========================================================"
echo " Summary of new values:"
printf "  THREADS_DOWNLOAD : %s\n"  "$NEW_T_DL"
printf "  THREADS_FASTQC   : %s\n"  "$NEW_T_FQC"
printf "  THREADS_TRIM     : %s\n"  "$NEW_T_TRIM"
printf "  THREADS_STAR     : %s\n"  "$NEW_T_STAR"
printf "  MAX_MEMORY_GB    : %s GB\n" "$NEW_MEM"
printf "  THREADS_RSEM     : %s\n"  "$NEW_T_RSEM"
printf "  MAX_SRA_SIZE     : %s\n"  "$NEW_SRA_SIZE"
printf "  DISK_WARN_GB     : %s GB\n" "$NEW_DISK_WARN"
echo "========================================================"
read -rp " Write these values to config/pipeline.sh? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo " Aborted — config/pipeline.sh unchanged."
    exit 0
fi

sed -i \
    -e "s|^THREADS_DOWNLOAD=.*|THREADS_DOWNLOAD=${NEW_T_DL}|" \
    -e "s|^THREADS_FASTQC=.*|THREADS_FASTQC=${NEW_T_FQC}|" \
    -e "s|^THREADS_TRIM=.*|THREADS_TRIM=${NEW_T_TRIM}|" \
    -e "s|^THREADS_STAR=.*|THREADS_STAR=${NEW_T_STAR}|" \
    -e "s|^MAX_MEMORY_GB=.*|MAX_MEMORY_GB=${NEW_MEM}|" \
    -e "s|^THREADS_RSEM=.*|THREADS_RSEM=${NEW_T_RSEM}|" \
    -e "s|^MAX_SRA_SIZE=.*|MAX_SRA_SIZE=\"${NEW_SRA_SIZE}\"|" \
    -e "s|^DISK_WARN_GB=.*|DISK_WARN_GB=${NEW_DISK_WARN}|" \
    "$CONFIG"

echo " config/pipeline.sh updated."
echo ""
echo " Next steps:"
echo "   bash pipeline/run.sh --build-refs   # build genome indexes (once)"
echo "   bash pipeline/run.sh --test          # smoke test"
echo "   bash pipeline/run.sh --full          # full run"
