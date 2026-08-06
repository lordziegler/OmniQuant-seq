#!/usr/bin/env bash
# Interactive input helpers shared by setup.sh and lib/menu.sh.
# Every helper validates and re-asks until the value is usable, so callers
# never have to check what they read.

# Read an integer in [min, max]; empty input keeps the current value.
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

# Read a storage size such as 100G or 1T; empty input keeps the current value.
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

# Read one of a fixed set of values; empty input keeps the current one.
prompt_choice() {
    local var_name="$1" prompt_text="$2" current="$3"; shift 3
    local options=( "$@" ) value opt
    while true; do
        read -rp "  ${prompt_text} [current: ${current}, options: ${options[*]}]: " value
        value="${value:-$current}"
        for opt in "${options[@]}"; do
            [[ "$value" == "$opt" ]] || continue
            printf -v "$var_name" '%s' "$value"
            return
        done
        echo "  Invalid input. Choose one of: ${options[*]}"
    done
}

# Read a path to an existing file, or "none" to clear it. The value is written
# into config/pipeline.sh through a sed replacement, so | and & are rejected.
prompt_path() {
    local var_name="$1" prompt_text="$2" current="$3"
    local value
    while true; do
        read -rp "  ${prompt_text} [current: ${current:-none}]: " value
        value="${value:-$current}"
        [[ "$value" == "none" ]] && value=""
        if [[ -z "$value" ]] || { [[ -f "$value" ]] && [[ "$value" != *[\|\&]* ]]; }; then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "  Not a readable file, or contains | or &. Enter a path, or 'none' to disable."
    done
}

prompt_url() {
    local var_name="$1" prompt_text="$2"
    local value
    while true; do
        read -rp "  ${prompt_text}: " value
        if [[ "$value" =~ ^https?://[^[:space:]]+$ ]]; then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "  Must be a single URL starting with http:// or https://"
    done
}

# Species keys are Genus_species: they name the references/ subdirectory and
# must match the key parse_runtable.py derives from the RunTable Organism
# field, hence the mandatory underscore.
prompt_species_key() {
    local var_name="$1" prompt_text="$2"
    local value
    while true; do
        read -rp "  ${prompt_text}: " value
        value="${value// /_}"
        if [[ "$value" =~ ^[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+$ ]]; then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "  Use the Genus_species form: letters, digits and at least one"
        echo "  underscore, e.g. Helicoverpa_armigera."
    done
}

confirm() {
    local answer
    read -rp " $1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}
