#!/usr/bin/env bash
# setup.sh — interactive configurator for OmniQuant-seq.
#
#   bash pipeline/setup.sh                 resources, then the species menu
#   bash pipeline/setup.sh --resources     compute resources only
#   bash pipeline/setup.sh --species       species menu only
#   bash pipeline/setup.sh --add-species   add one species and fetch its genome
#
# Writes config/pipeline.sh and config/species.sh. Nothing else is modified.

set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_CFG="${PIPELINE_DIR}/config/pipeline.sh"
SPECIES_CFG="${PIPELINE_DIR}/config/species.sh"

source "$PIPELINE_CFG"
source "${PIPELINE_DIR}/lib/utils.sh"
source "${PIPELINE_DIR}/lib/species_config.sh"
source "${PIPELINE_DIR}/steps/build_references.sh"

# =============================================================================
# Prompt helpers
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

# Species keys are Genus_species: they name the references/ subdirectory and
# must match the key parse_runtable.py derives from the RunTable Organism field.
prompt_species_key() {
    local var_name="$1" prompt_text="$2"
    local value
    while true; do
        read -rp "  ${prompt_text}: " value
        value="${value// /_}"
        if [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_]+$ ]]; then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "  Use letters, digits, and underscores only (e.g. Helicoverpa_armigera)."
    done
}

confirm() {
    local answer
    read -rp " $1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# =============================================================================
# Compute resources → config/pipeline.sh
# =============================================================================
configure_resources() {
    local max_cpus avail_ram_gb avail_disk_gb
    local new_t_dl new_t_fqc new_t_trim new_t_star new_mem new_t_rsem \
          new_sra_size new_disk_warn
    max_cpus=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 64)
    avail_ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' \
                  || sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}' \
                  || echo 64)
    avail_disk_gb=$(df -BG . 2>/dev/null | awk 'NR==2{ gsub("G","",$4); print $4 }' || echo 999)

    echo ""
    echo "========================================================"
    echo " Compute resources"
    echo " Detected CPUs  : ${max_cpus}"
    echo " Available RAM  : ${avail_ram_gb} GB"
    echo " Available disk : ${avail_disk_gb} GB"
    echo " Press Enter to keep the current value."
    echo "========================================================"

    echo ""; echo " Download / fasterq-dump"
    prompt_int new_t_dl   "Threads (THREADS_DOWNLOAD)" "$THREADS_DOWNLOAD" 1 "$max_cpus"

    echo ""; echo " FastQC"
    prompt_int new_t_fqc  "Threads (THREADS_FASTQC)"   "$THREADS_FASTQC"   1 "$max_cpus"

    echo ""; echo " BBDuk trimming"
    prompt_int new_t_trim "Threads (THREADS_TRIM)"     "$THREADS_TRIM"     1 "$max_cpus"

    echo ""; echo " STAR alignment"
    prompt_int new_t_star "Threads (THREADS_STAR)"     "$THREADS_STAR"     1 "$max_cpus"
    prompt_int new_mem    "RAM limit GB (MAX_MEMORY_GB — passed as --limitBAMsortRAM)" \
                          "$MAX_MEMORY_GB" 1 "$avail_ram_gb"

    echo ""; echo " RSEM quantification"
    prompt_int new_t_rsem "Threads (THREADS_RSEM)"     "$THREADS_RSEM"     1 "$max_cpus"

    echo ""; echo " Storage"
    prompt_storage new_sra_size  "Max SRA prefetch size (MAX_SRA_SIZE)" "$MAX_SRA_SIZE"
    prompt_int     new_disk_warn "Disk warning threshold GB (DISK_WARN_GB)" "$DISK_WARN_GB" 1 9999

    echo ""
    echo "========================================================"
    echo " Summary — compute resources:"
    printf "  THREADS_DOWNLOAD : %s\n"    "$new_t_dl"
    printf "  THREADS_FASTQC   : %s\n"    "$new_t_fqc"
    printf "  THREADS_TRIM     : %s\n"    "$new_t_trim"
    printf "  THREADS_STAR     : %s\n"    "$new_t_star"
    printf "  MAX_MEMORY_GB    : %s GB\n" "$new_mem"
    printf "  THREADS_RSEM     : %s\n"    "$new_t_rsem"
    printf "  MAX_SRA_SIZE     : %s\n"    "$new_sra_size"
    printf "  DISK_WARN_GB     : %s GB\n" "$new_disk_warn"
    echo "========================================================"

    if ! confirm "Write these values to config/pipeline.sh?"; then
        echo " Skipped — config/pipeline.sh unchanged."
        return 0
    fi

    sed -i \
        -e "s|^THREADS_DOWNLOAD=.*|THREADS_DOWNLOAD=${new_t_dl}|" \
        -e "s|^THREADS_FASTQC=.*|THREADS_FASTQC=${new_t_fqc}|" \
        -e "s|^THREADS_TRIM=.*|THREADS_TRIM=${new_t_trim}|" \
        -e "s|^THREADS_STAR=.*|THREADS_STAR=${new_t_star}|" \
        -e "s|^MAX_MEMORY_GB=.*|MAX_MEMORY_GB=${new_mem}|" \
        -e "s|^THREADS_RSEM=.*|THREADS_RSEM=${new_t_rsem}|" \
        -e "s|^MAX_SRA_SIZE=.*|MAX_SRA_SIZE=\"${new_sra_size}\"|" \
        -e "s|^DISK_WARN_GB=.*|DISK_WARN_GB=${new_disk_warn}|" \
        "$PIPELINE_CFG"
    echo " config/pipeline.sh updated."
}

# =============================================================================
# Species table → config/species.sh
# =============================================================================
show_species() {
    local i status
    echo ""
    echo "  #   Status  Species"
    echo "  -   ------  -------"
    for i in "${!SP_KEYS[@]}"; do
        status="[OFF]"
        [[ "${SP_ACTIVE[$i]}" == "true" ]] && status="[ON] "
        printf "  %d   %s  %s\n" "$(( i + 1 ))" "$status" "${SP_KEYS[$i]}"
    done
    echo ""
}

# Read a comma-separated list of menu numbers into the named array, as indices.
read_species_indices() {
    local -n out_ref="$1"
    local input="$2"
    local numbers=() n
    out_ref=()
    IFS=',' read -ra numbers <<< "$input"
    for n in "${numbers[@]}"; do
        n="${n// /}"
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#SP_KEYS[@]} )); then
            out_ref+=( "$(( n - 1 ))" )
        else
            echo "  Skipping invalid number: ${n}"
        fi
    done
}

configure_species() {
    species_config_load "$SPECIES_CFG"

    echo ""
    echo "========================================================"
    echo " Species configuration"
    echo "========================================================"
    show_species

    echo " Enter the numbers of species to toggle ON/OFF (comma-separated),"
    echo " or press Enter to keep the current status."
    local toggle_input idx
    read -rp " Toggle: " toggle_input
    if [[ -n "$toggle_input" ]]; then
        local to_toggle=()
        read_species_indices to_toggle "$toggle_input"
        for idx in "${to_toggle[@]}"; do
            if [[ "${SP_ACTIVE[$idx]}" == "true" ]]; then
                SP_ACTIVE[$idx]="false"; echo "  → ${SP_KEYS[$idx]} set to OFF"
            else
                SP_ACTIVE[$idx]="true";  echo "  → ${SP_KEYS[$idx]} set to ON"
            fi
        done
    fi

    echo ""
    echo " Enter the numbers of species to DELETE permanently (comma-separated),"
    echo " or press Enter to skip."
    local delete_input
    read -rp " Delete: " delete_input
    if [[ -n "$delete_input" ]]; then
        local to_delete=()
        read_species_indices to_delete "$delete_input"
        local -A drop=()
        for idx in "${to_delete[@]}"; do
            drop[$idx]=1
            echo "  → Removing: ${SP_KEYS[$idx]}"
        done
        local keys=() fna=() gtf=() active=() i
        for i in "${!SP_KEYS[@]}"; do
            [[ -n "${drop[$i]+x}" ]] && continue
            keys+=( "${SP_KEYS[$i]}" ); fna+=( "${SP_FNA[$i]}" )
            gtf+=( "${SP_GTF[$i]}" );   active+=( "${SP_ACTIVE[$i]}" )
        done
        SP_KEYS=( "${keys[@]}" ); SP_FNA=( "${fna[@]}" )
        SP_GTF=( "${gtf[@]}" );   SP_ACTIVE=( "${active[@]}" )
    fi

    local new_key new_fna new_gtf new_active
    while confirm "Add a new species?"; do
        prompt_species_key new_key "Insert the name of the species (e.g. Helicoverpa_armigera)"
        prompt_url         new_fna "Genome FASTA URL (.fna.gz)"
        prompt_url         new_gtf "Annotation GTF URL (.gtf.gz)"
        new_active="true"
        confirm "Include in the next run?" || new_active="false"
        species_config_upsert "$new_key" "$new_fna" "$new_gtf" "$new_active"
        echo "  ${SPECIES_CONFIG_LAST_ACTION}: ${new_key} [${new_active}]"
    done

    echo ""
    echo "========================================================"
    echo " Final species list:"
    show_species
    echo "========================================================"
    if confirm "Write this to config/species.sh?"; then
        species_config_save "$SPECIES_CFG" || die "Could not write ${SPECIES_CFG}"
        echo " config/species.sh updated."
    else
        echo " Skipped — config/species.sh unchanged."
    fi
}

# =============================================================================
# Add one species and fetch its reference files
# =============================================================================
add_species() {
    local key fna_url gtf_url

    echo ""
    echo "========================================================"
    echo " Add a species"
    echo " The genome and annotation are downloaded into"
    echo " ${REFERENCES_DIR}/<species_key>/ and the entry is written to"
    echo " config/species.sh."
    echo "========================================================"

    prompt_species_key key     "Insert the name of the species (e.g. Helicoverpa_armigera)"
    prompt_url         fna_url "Genome FASTA URL (.fna.gz)"
    prompt_url         gtf_url "Annotation GTF URL (.gtf.gz)"

    echo ""
    species_config_load "$SPECIES_CFG"
    species_config_upsert "$key" "$fna_url" "$gtf_url" "true"
    species_config_save "$SPECIES_CFG" \
        || die "Could not write ${SPECIES_CFG} — check file permissions."
    echo "[OK] Entry ${SPECIES_CONFIG_LAST_ACTION} in config/species.sh: ${key}"

    echo ""
    echo "[INFO] Fetching reference files for ${key} ..."
    if ! fetch_species_references "$key" "$fna_url" "$gtf_url"; then
        echo "[ERROR] Could not obtain the reference files for ${key}." >&2
        echo "        The entry is kept in config/species.sh; check the URLs" >&2
        echo "        and free space, then re-run: bash pipeline/setup.sh --add-species" >&2
        return 1
    fi

    local sp_dir="${REFERENCES_DIR}/${key}"
    echo ""
    echo "========================================================"
    echo " ${key} is ready."
    echo "   Genome     : ${sp_dir}/genome.fa"
    echo "   Annotation : ${sp_dir}/genes.gtf"
    echo ""
    echo " Build the STAR and RSEM indexes with:"
    echo "   bash pipeline/run.sh --build-refs"
    echo "========================================================"
}

# =============================================================================
# CLI
# =============================================================================
usage() {
    cat <<'EOF'
OmniQuant-seq setup — writes config/pipeline.sh and config/species.sh.

Usage: bash pipeline/setup.sh [MODE]

Modes:
  (none)          Compute resources, then the species menu.
  --resources     Compute resources only (threads, RAM, storage).
  --species       Species menu only (toggle, delete, add entries).
  --add-species   Add or update one species: prompts for the species key and
                  the genome FASTA / annotation GTF URLs, writes the entry to
                  config/species.sh, then downloads and decompresses both files
                  into references/<species_key>/. Exits non-zero if any step
                  fails.
  -h, --help      Show this message.
EOF
}

main() {
    case "${1:-}" in
        "")            configure_resources; configure_species ;;
        --resources)   configure_resources ;;
        --species)     configure_species ;;
        --add-species) add_species; return ;;
        -h|--help)     usage; return 0 ;;
        *)
            echo "[ABORT] Unknown argument: $1" >&2
            echo "" >&2
            usage >&2
            return 1 ;;
    esac

    echo ""
    echo "========================================================"
    echo " Setup complete. Next steps:"
    echo "   bash pipeline/run.sh --build-refs   # build genome indexes (once)"
    echo "   bash pipeline/run.sh --example      # small demo run"
    echo "   bash pipeline/run.sh --test         # smoke test on your samples"
    echo "   bash pipeline/run.sh --full         # full run"
    echo "========================================================"
}

main "$@"
