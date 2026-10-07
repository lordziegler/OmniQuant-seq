#!/usr/bin/env bash
# setup.sh — interactive configurator for OmniQuant-seq.
#
#   bash setup.sh                 interactive menu
#   bash setup.sh --resources     compute resources only
#   bash setup.sh --analysis      analysis parameters only
#   bash setup.sh --species       species menu only
#   bash setup.sh --add-species   add one species and fetch its genome
#
# Writes config/pipeline.sh and config/species.sh. Nothing else is modified.

set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_CFG="${PIPELINE_DIR}/config/pipeline.sh"
SPECIES_CFG="${PIPELINE_DIR}/config/species.sh"

# shellcheck source=config/pipeline.sh
source "$PIPELINE_CFG"
source "${PIPELINE_DIR}/lib/utils.sh"
source "${PIPELINE_DIR}/lib/prompt.sh"
source "${PIPELINE_DIR}/lib/menu.sh"
source "${PIPELINE_DIR}/lib/species_config.sh"
source "${PIPELINE_DIR}/steps/build_references.sh"

# =============================================================================
# config/pipeline.sh knobs
# =============================================================================
# One row per variable: name|kind|constraint|prompt. kind is int (constraint
# is "min max"), choice (constraint lists the accepted values), storage or
# path. Adding a knob to a table is the whole change; _configure_params
# prompts, validates and writes it.
_ANALYSIS_PARAMS=(
    "TEST_MODE|choice|true false|Limit runs to TEST_READS reads (TEST_MODE)"
    "TEST_READS|int|1 1000000000|Reads per sample in test mode (TEST_READS)"
    "PIPELINE_RETRY_PASSES|int|1 10|Passes over the sample list (PIPELINE_RETRY_PASSES)"
    "PREFETCH_RETRIES|int|1 20|Download attempts per sample (PREFETCH_RETRIES)"
    "PREFETCH_RETRY_SLEEP|int|0 3600|Seconds between attempts (PREFETCH_RETRY_SLEEP)"
    "STAR_OVERHANG|int|1 500|sjdbOverhang, read length - 1 (STAR_OVERHANG)"
    "STAR_SA_INDEX_NBASES|int|1 14|genomeSAindexNbases (STAR_SA_INDEX_NBASES)"
    "BBDUK_QTRIM|choice|rl r l f|Trimming side (BBDUK_QTRIM)"
    "BBDUK_TRIMQ|int|0 40|Quality threshold (BBDUK_TRIMQ)"
    "BBDUK_MINLEN|int|1 1000|Minimum length after trimming (BBDUK_MINLEN)"
    "BBDUK_REF|path||Adapter FASTA, none to skip clipping (BBDUK_REF)"
)

# Prompt for every table row given, summarise, and write the answers to
# config/pipeline.sh once confirmed: _configure_params TITLE ROW...
_configure_params() {
    local title="$1"; shift
    # Not named `value`: the prompt_* helpers use that name for their own
    # local, and printf -v would then write to theirs instead of ours.
    local entry name kind constraint text current new_value quoted
    local sed_args=() summary=()

    echo ""
    echo "========================================================"
    echo " ${title}"
    echo " Press Enter to keep the current value."
    echo "========================================================"
    echo ""

    for entry in "$@"; do
        IFS='|' read -r name kind constraint text <<< "$entry"
        current="${!name}"
        # shellcheck disable=SC2086  # constraint is a deliberate word list
        case "$kind" in
            int)     prompt_int     new_value "$text" "$current" $constraint ;;
            choice)  prompt_choice  new_value "$text" "$current" $constraint ;;
            storage) prompt_storage new_value "$text" "$current" ;;
            path)    prompt_path    new_value "$text" "$current" ;;
            *)       die "Unknown parameter kind '${kind}' for ${name}." ;;
        esac

        # Only ints are written bare; everything else may be empty or a word.
        quoted="$new_value"
        [[ "$kind" == int ]] || quoted="\"${new_value}\""
        sed_args+=( -e "s|^${name}=.*|${name}=${quoted}|" )
        summary+=( "$(printf '  %-22s : %s' "$name" "${new_value:-<empty>}")" )
    done

    echo ""
    echo "========================================================"
    echo " Summary — ${title,,}:"
    printf '%s\n' "${summary[@]}"
    echo "========================================================"

    if ! confirm "Write these values to config/pipeline.sh?"; then
        echo " Skipped — config/pipeline.sh unchanged."
        return 0
    fi

    sed -i "${sed_args[@]}" "$PIPELINE_CFG"
    echo " config/pipeline.sh updated."
}

configure_resources() {
    local cpus ram disk
    cpus=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 64)
    ram=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' \
          || sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}' \
          || echo 64)
    disk=$(df -BG . 2>/dev/null | awk 'NR==2{ gsub("G","",$4); print $4 }' || echo 999)

    echo ""
    echo " Detected: ${cpus} CPUs, ${ram} GB RAM, ${disk} GB free disk."
    _configure_params "Compute resources" \
        "THREADS_DOWNLOAD|int|1 ${cpus}|fasterq-dump threads (THREADS_DOWNLOAD)" \
        "THREADS_FASTQC|int|1 ${cpus}|FastQC threads (THREADS_FASTQC)" \
        "THREADS_TRIM|int|1 ${cpus}|BBDuk threads (THREADS_TRIM)" \
        "THREADS_STAR|int|1 ${cpus}|STAR threads (THREADS_STAR)" \
        "MAX_MEMORY_GB|int|1 ${ram}|RAM limit GB for the STAR index build (MAX_MEMORY_GB)" \
        "THREADS_RSEM|int|1 ${cpus}|RSEM threads (THREADS_RSEM)" \
        "MAX_SRA_SIZE|storage||Max SRA prefetch size (MAX_SRA_SIZE)" \
        "DISK_WARN_GB|int|1 9999|Disk warning threshold GB (DISK_WARN_GB)"
}

configure_analysis() {
    _configure_params "Analysis parameters" "${_ANALYSIS_PARAMS[@]}"
}

# =============================================================================
# Species table → config/species.sh
# =============================================================================

# The species key is not a free-form label: it names a directory and routes
# samples to references, so explain the format before asking for it.
explain_species_key() {
    cat <<'EOF'

  Insert the name of the species (e.g. Helicoverpa_armigera). This key will be
  used as the directory name and to route samples to references, so it must be
  written as Genus_species — the same form parse_runtable.py derives from the
  RunTable "Organism" column.
EOF
}

# Ask for one species entry. Sets SPECIES_NEW_KEY / _FNA / _GTF; the caller
# decides the active flag and when to upsert.
prompt_new_species() {
    explain_species_key
    prompt_species_key SPECIES_NEW_KEY "Species key"
    prompt_url         SPECIES_NEW_FNA "Genome FASTA URL (.fna.gz)"
    prompt_url         SPECIES_NEW_GTF "Annotation GTF URL (.gtf.gz)"
}

# Download + decompress the references of one species and report the outcome.
# Shared by --add-species and the species menu, so both give the same messages.
fetch_and_report() {
    local key="$1" fna_url="$2" gtf_url="$3"
    local sp_dir="${REFERENCES_DIR}/${key}"

    echo ""
    echo "[INFO] Fetching reference files for ${key} into ${sp_dir}/ ..."
    if ! fetch_species_references "$key" "$fna_url" "$gtf_url"; then
        echo "[ERROR] Could not obtain the reference files for ${key}." >&2
        echo "        Check the two URLs, the free disk space, and write access" >&2
        echo "        to ${sp_dir}/, then re-run:" >&2
        echo "          bash setup.sh --add-species" >&2
        return 1
    fi

    echo ""
    echo "========================================================"
    echo " Species ${key} configured successfully."
    echo " Files downloaded to ${sp_dir}/ and ready for STAR/RSEM"
    echo " index building:"
    echo "   Genome     : ${sp_dir}/genome.fa"
    echo "   Annotation : ${sp_dir}/genes.gtf"
    echo ""
    echo " Build the indexes with:"
    echo "   bash run.sh --build-refs"
    echo "========================================================"
}

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
    read -rp " Toggle: " toggle_input || toggle_input=""
    if [[ -n "$toggle_input" ]]; then
        local to_toggle=()
        read_species_indices to_toggle "$toggle_input"
        for idx in "${to_toggle[@]}"; do
            if [[ "${SP_ACTIVE[$idx]}" == "true" ]]; then
                SP_ACTIVE[idx]="false"; echo "  → ${SP_KEYS[$idx]} set to OFF"
            else
                SP_ACTIVE[idx]="true";  echo "  → ${SP_KEYS[$idx]} set to ON"
            fi
        done
    fi

    echo ""
    echo " Enter the numbers of species to DELETE permanently (comma-separated),"
    echo " or press Enter to skip."
    local delete_input
    read -rp " Delete: " delete_input || delete_input=""
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

    # Entries added here are downloaded only after the config file is written,
    # so an aborted session never leaves genomes on disk with no entry.
    local pending=() new_active
    while confirm "Add a new species?"; do
        prompt_new_species
        new_active="true"
        confirm "Include in the next run?" || new_active="false"
        species_config_upsert "$SPECIES_NEW_KEY" "$SPECIES_NEW_FNA" \
                              "$SPECIES_NEW_GTF" "$new_active"
        echo "  ${SPECIES_CONFIG_LAST_ACTION}: ${SPECIES_NEW_KEY} [${new_active}]"
        pending+=( "${SPECIES_NEW_KEY}|${SPECIES_NEW_FNA}|${SPECIES_NEW_GTF}" )
    done

    echo ""
    echo "========================================================"
    echo " Final species list:"
    show_species
    echo "========================================================"
    if ! confirm "Write this to config/species.sh?"; then
        echo " Skipped — config/species.sh unchanged."
        return 0
    fi
    species_config_save "$SPECIES_CFG" || die "Could not write ${SPECIES_CFG}"
    echo " config/species.sh updated."

    (( ${#pending[@]} > 0 )) || return 0
    echo ""
    if ! confirm "Download the genome and annotation of the new species now?"; then
        echo " Skipped — fetch them later with: bash run.sh --build-refs"
        return 0
    fi

    local entry key fna gtf failed=0
    for entry in "${pending[@]}"; do
        IFS='|' read -r key fna gtf <<< "$entry"
        fetch_and_report "$key" "$fna" "$gtf" || failed=1
    done
    return "$failed"
}

# =============================================================================
# Add one species and fetch its reference files
# =============================================================================
add_species() {
    echo ""
    echo "========================================================"
    echo " Add a species"
    echo " The genome and annotation are downloaded into"
    echo " ${REFERENCES_DIR}/<species_key>/ and the entry is written to"
    echo " config/species.sh as:"
    echo "   \"species_key|genome_fna_gz_url|genome_gtf_gz_url|active\""
    echo "========================================================"

    prompt_new_species

    echo ""
    species_config_load "$SPECIES_CFG"
    species_config_upsert "$SPECIES_NEW_KEY" "$SPECIES_NEW_FNA" "$SPECIES_NEW_GTF" "true"
    species_config_save "$SPECIES_CFG" \
        || die "Could not write ${SPECIES_CFG} — check file permissions."
    echo "[OK] Entry ${SPECIES_CONFIG_LAST_ACTION} in config/species.sh: ${SPECIES_NEW_KEY}"

    if ! fetch_and_report "$SPECIES_NEW_KEY" "$SPECIES_NEW_FNA" "$SPECIES_NEW_GTF"; then
        echo "        The entry is kept in config/species.sh, so only the URLs" >&2
        echo "        need fixing." >&2
        return 1
    fi
}

# =============================================================================
# CLI
# =============================================================================
usage() {
    cat <<'EOF'
OmniQuant-seq setup — writes config/pipeline.sh and config/species.sh.

Usage:
  bash setup.sh            Interactive menu
  bash setup.sh [MODE]     Go straight to one step

Modes:
  --resources     Compute resources only (threads, RAM, storage).
  --analysis      Analysis parameters: test mode, retries, STAR index and
                  BBDuk trimming settings.
  --species       Species menu only: toggle, delete or add entries, with an
                  optional genome download for the entries just added.
  --add-species   Add or update one species: prompts for the species key and
                  the genome FASTA / annotation GTF URLs, writes the entry to
                  config/species.sh, then downloads and decompresses both files
                  into references/<species_key>/. Exits non-zero if any step
                  fails.

Options:
  -i, --interactive  Show the menu even when other arguments are given.
  -h, --help         Show this message.

Examples:
  bash setup.sh                  # menu: resources, species, runs
  bash setup.sh --resources      # only threads / RAM / storage
  bash setup.sh --analysis       # trimming, STAR index and retry settings
  bash setup.sh --add-species    # add one organism + fetch its genome

A species key is a Genus_species identifier (e.g. Helicoverpa_armigera): it
names the references/<species_key>/ directory and routes each sample to its
reference, so it must match the RunTable "Organism" column.
EOF
}

main() {
    # The closing message is what tells the user how to recover from a failed
    # step, so it must print before the non-zero status propagates.
    local status=0
    case "${1:-}" in
        "")               menu_main; return 0 ;;
        -i|--interactive) menu_main; return 0 ;;
        --resources)      configure_resources ;;
        --analysis)       configure_analysis ;;
        --species)        configure_species || status=$? ;;
        --add-species)    add_species; return ;;
        -h|--help)        usage; return 0 ;;
        *)
            echo "[ABORT] Unknown argument: $1" >&2
            echo "" >&2
            usage >&2
            return 1 ;;
    esac

    echo ""
    echo "========================================================"
    echo " Setup complete. Next steps:"
    echo "   bash run.sh --build-refs   # build genome indexes (once)"
    echo "   bash run.sh --example      # small demo run"
    echo "   bash run.sh --test         # smoke test on your samples"
    echo "   bash run.sh --full         # full run"
    echo "========================================================"
    return "$status"
}

main "$@"
