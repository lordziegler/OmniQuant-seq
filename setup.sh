#!/usr/bin/env bash
# setup.sh — Interactive configurator for compute resources and species.
# Section 1: threads, RAM, storage  → writes config/pipeline.sh
# Section 2: species names + genome URLs → writes config/species.sh
# Run once before the first execution, or whenever resources or species change.

set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_CFG="${PIPELINE_DIR}/config/pipeline.sh"
SPECIES_CFG="${PIPELINE_DIR}/config/species.sh"

# =============================================================================
# Helpers
# =============================================================================
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

prompt_url() {
    local var_name="$1" prompt_text="$2"
    local value
    while true; do
        read -rp "  ${prompt_text}: " value
        if [[ "$value" =~ ^https?:// ]]; then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "  Must start with http:// or https://"
    done
}

prompt_name() {
    local var_name="$1" prompt_text="$2"
    local value
    while true; do
        read -rp "  ${prompt_text} (e.g. Spodoptera_frugiperda): " value
        value="${value// /_}"
        if [[ -n "$value" && "$value" =~ ^[A-Za-z][A-Za-z0-9_]+$ ]]; then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "  Use letters, digits, and underscores only."
    done
}

# =============================================================================
# Phase 1 — Compute resources
# =============================================================================
source "$PIPELINE_CFG"

MAX_CPUS=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 64)
AVAIL_RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' \
              || sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}' \
              || echo 64)
AVAIL_DISK_GB=$(df -BG . 2>/dev/null | awk 'NR==2{ gsub("G","",$4); print $4 }' || echo 999)

echo ""
echo "========================================================"
echo " Compute resources"
echo " Detected CPUs  : ${MAX_CPUS}"
echo " Available RAM  : ${AVAIL_RAM_GB} GB"
echo " Available disk : ${AVAIL_DISK_GB} GB"
echo " Press Enter to keep current value."
echo "========================================================"

echo ""
echo " Download / fasterq-dump"
prompt_int NEW_T_DL   "Threads (THREADS_DOWNLOAD)" "$THREADS_DOWNLOAD" 1 "$MAX_CPUS"

echo ""
echo " FastQC"
prompt_int NEW_T_FQC  "Threads (THREADS_FASTQC)"   "$THREADS_FASTQC"   1 "$MAX_CPUS"

echo ""
echo " BBDuk trimming"
prompt_int NEW_T_TRIM "Threads (THREADS_TRIM)"     "$THREADS_TRIM"     1 "$MAX_CPUS"

echo ""
echo " STAR alignment"
prompt_int NEW_T_STAR "Threads (THREADS_STAR)"     "$THREADS_STAR"     1 "$MAX_CPUS"
prompt_int NEW_MEM    "RAM limit GB (MAX_MEMORY_GB — passed as --limitBAMsortRAM)" \
                      "$MAX_MEMORY_GB" 1 "$AVAIL_RAM_GB"

echo ""
echo " RSEM quantification"
prompt_int NEW_T_RSEM "Threads (THREADS_RSEM)"     "$THREADS_RSEM"     1 "$MAX_CPUS"

echo ""
echo " Storage"
prompt_storage NEW_SRA_SIZE  "Max SRA prefetch size (MAX_SRA_SIZE)" "$MAX_SRA_SIZE"
prompt_int     NEW_DISK_WARN "Disk warning threshold GB (DISK_WARN_GB)" \
                             "$DISK_WARN_GB" 1 9999

echo ""
echo "========================================================"
echo " Summary — compute resources:"
printf "  THREADS_DOWNLOAD : %s\n"    "$NEW_T_DL"
printf "  THREADS_FASTQC   : %s\n"    "$NEW_T_FQC"
printf "  THREADS_TRIM     : %s\n"    "$NEW_T_TRIM"
printf "  THREADS_STAR     : %s\n"    "$NEW_T_STAR"
printf "  MAX_MEMORY_GB    : %s GB\n" "$NEW_MEM"
printf "  THREADS_RSEM     : %s\n"    "$NEW_T_RSEM"
printf "  MAX_SRA_SIZE     : %s\n"    "$NEW_SRA_SIZE"
printf "  DISK_WARN_GB     : %s GB\n" "$NEW_DISK_WARN"
echo "========================================================"
read -rp " Write these values to config/pipeline.sh? [y/N]: " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    sed -i \
        -e "s|^THREADS_DOWNLOAD=.*|THREADS_DOWNLOAD=${NEW_T_DL}|" \
        -e "s|^THREADS_FASTQC=.*|THREADS_FASTQC=${NEW_T_FQC}|" \
        -e "s|^THREADS_TRIM=.*|THREADS_TRIM=${NEW_T_TRIM}|" \
        -e "s|^THREADS_STAR=.*|THREADS_STAR=${NEW_T_STAR}|" \
        -e "s|^MAX_MEMORY_GB=.*|MAX_MEMORY_GB=${NEW_MEM}|" \
        -e "s|^THREADS_RSEM=.*|THREADS_RSEM=${NEW_T_RSEM}|" \
        -e "s|^MAX_SRA_SIZE=.*|MAX_SRA_SIZE=\"${NEW_SRA_SIZE}\"|" \
        -e "s|^DISK_WARN_GB=.*|DISK_WARN_GB=${NEW_DISK_WARN}|" \
        "$PIPELINE_CFG"
    echo " config/pipeline.sh updated."
else
    echo " Skipped — config/pipeline.sh unchanged."
fi

# =============================================================================
# Species configuration
# =============================================================================

# Parse existing species entries into parallel arrays.
# Each entry in SPECIES_CONFIG: "name|fna_url|gtf_url|active"
source "$SPECIES_CFG"

sp_names=()
sp_fna=()
sp_gtf=()
sp_active=()

for entry in "${SPECIES_CONFIG[@]}"; do
    IFS='|' read -r _name _fna _gtf _active <<< "$entry"
    # strip leading/trailing whitespace and backslash-continuations
    _name="${_name//[$'\t\r\n\\']/}"
    _name="${_name#"${_name%%[! ]*}"}"
    _fna="${_fna//[$'\t\r\n\\']/}"
    _fna="${_fna#"${_fna%%[! ]*}"}"
    _gtf="${_gtf//[$'\t\r\n\\']/}"
    _gtf="${_gtf#"${_gtf%%[! ]*}"}"
    _active="${_active//[$'\t\r\n\\']/}"
    _active="${_active#"${_active%%[! ]*}"}"
    [[ -z "$_name" ]] && continue
    sp_names+=( "$_name" )
    sp_fna+=( "$_fna" )
    sp_gtf+=( "$_gtf" )
    sp_active+=( "$_active" )
done

echo ""
echo "========================================================"
echo " Species configuration"
echo "========================================================"

_show_species() {
    echo ""
    echo "  #   Status  Species"
    echo "  -   ------  -------"
    for i in "${!sp_names[@]}"; do
        local status="[OFF]"
        [[ "${sp_active[$i]}" == "true" ]] && status="[ON] "
        printf "  %d   %s  %s\n" "$(( i + 1 ))" "$status" "${sp_names[$i]}"
    done
    echo ""
}

_show_species

# --- Toggle existing species -------------------------------------------------
echo " Enter the numbers of species to toggle ON/OFF (comma-separated),"
echo " or press Enter to keep current status."
read -rp " Toggle: " toggle_input

if [[ -n "$toggle_input" ]]; then
    IFS=',' read -ra toggle_nums <<< "$toggle_input"
    for n in "${toggle_nums[@]}"; do
        n="${n// /}"
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#sp_names[@]} )); then
            idx=$(( n - 1 ))
            if [[ "${sp_active[$idx]}" == "true" ]]; then
                sp_active[$idx]="false"
                echo "  → ${sp_names[$idx]} set to OFF"
            else
                sp_active[$idx]="true"
                echo "  → ${sp_names[$idx]} set to ON"
            fi
        else
            echo "  Skipping invalid number: ${n}"
        fi
    done
fi

# --- Delete species ----------------------------------------------------------
echo ""
echo " Enter the numbers of species to DELETE permanently (comma-separated),"
echo " or press Enter to skip."
read -rp " Delete: " delete_input

if [[ -n "$delete_input" ]]; then
    declare -A _del_set
    IFS=',' read -ra del_nums <<< "$delete_input"
    for n in "${del_nums[@]}"; do
        n="${n// /}"
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#sp_names[@]} )); then
            _del_set[$(( n - 1 ))]=1
            echo "  → Removing: ${sp_names[$(( n - 1 ))]}"
        else
            echo "  Skipping invalid number: ${n}"
        fi
    done
    # Rebuild arrays without the deleted indices
    _new_names=(); _new_fna=(); _new_gtf=(); _new_active=()
    for i in "${!sp_names[@]}"; do
        [[ -n "${_del_set[$i]+x}" ]] && continue
        _new_names+=( "${sp_names[$i]}" )
        _new_fna+=(   "${sp_fna[$i]}" )
        _new_gtf+=(   "${sp_gtf[$i]}" )
        _new_active+=( "${sp_active[$i]}" )
    done
    sp_names=( "${_new_names[@]}" )
    sp_fna=(   "${_new_fna[@]}" )
    sp_gtf=(   "${_new_gtf[@]}" )
    sp_active=( "${_new_active[@]}" )
    unset _del_set _new_names _new_fna _new_gtf _new_active
fi

# --- Add new species ---------------------------------------------------------
while true; do
    echo ""
    read -rp " Add a new species? [y/N]: " add_more
    [[ ! "$add_more" =~ ^[Yy]$ ]] && break

    prompt_name NEW_SP_NAME "Species name"
    prompt_url  NEW_SP_FNA  "Genome FASTA URL (.fna.gz from NCBI RefSeq)"
    prompt_url  NEW_SP_GTF  "Annotation GTF URL (.gtf.gz from NCBI RefSeq)"
    read -rp "  Include in this run? [Y/n]: " sp_on
    NEW_SP_ACTIVE="true"
    [[ "$sp_on" =~ ^[Nn]$ ]] && NEW_SP_ACTIVE="false"

    sp_names+=( "$NEW_SP_NAME" )
    sp_fna+=(   "$NEW_SP_FNA" )
    sp_gtf+=(   "$NEW_SP_GTF" )
    sp_active+=( "$NEW_SP_ACTIVE" )
    echo "  Added: ${NEW_SP_NAME} [${NEW_SP_ACTIVE}]"
done

# --- Show final list and confirm ---------------------------------------------
echo ""
echo "========================================================"
echo " Final species list:"
_show_species
echo "========================================================"
read -rp " Write this to config/species.sh? [y/N]: " confirm2
if [[ ! "$confirm2" =~ ^[Yy]$ ]]; then
    echo " Skipped — config/species.sh unchanged."
else
    {
        echo '#!/usr/bin/env bash'
        echo '# Species reference table — generated by setup.sh'
        echo '# Format per entry: "name|fna_url|gtf_url|active"'
        echo '# Set active=false to skip a species without removing the entry.'
        echo ''
        echo 'declare -a SPECIES_CONFIG=('
        for i in "${!sp_names[@]}"; do
            echo ''
            printf '    "%s|\\\n' "${sp_names[$i]}"
            printf '%s|\\\n'       "${sp_fna[$i]}"
            printf '%s|\\\n'       "${sp_gtf[$i]}"
            printf '%s"\n'         "${sp_active[$i]}"
        done
        echo ')'
    } > "$SPECIES_CFG"
    echo " config/species.sh updated."
fi

# =============================================================================
echo ""
echo "========================================================"
echo " Setup complete. Next steps:"
echo "   bash pipeline/run.sh --build-refs   # build genome indexes (once)"
echo "   bash pipeline/run.sh --test          # smoke test"
echo "   bash pipeline/run.sh --full          # full run"
echo "========================================================"
