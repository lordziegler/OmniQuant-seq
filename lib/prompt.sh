#!/usr/bin/env bash
# Each helper re-asks until valid. On EOF it keeps the current value, or aborts
# when there is none.

prompt_int() {
    local var_name="$1" prompt_text="$2" current="$3" min="$4" max="$5"
    local value
    # Keep a current value above what this host detects.
    (( current > max )) && max="$current"
    while true; do
        read -rp "  ${prompt_text} [current: ${current}, range: ${min}–${max}]: " value \
            || { printf -v "$var_name" '%s' "$current"; return; }
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
    read -rp "  ${prompt_text} [current: ${current}]: " value || value=""
    value="${value:-$current}"
    if [[ "$value" =~ ^[0-9]+(G|T|M)$ ]]; then
        printf -v "$var_name" '%s' "$value"
    else
        echo "  Invalid format (use e.g. 100G, 1T) — keeping current: ${current}"
        printf -v "$var_name" '%s' "$current"
    fi
}

prompt_choice() {
    local var_name="$1" prompt_text="$2" current="$3"; shift 3
    local options=( "$@" ) value opt
    while true; do
        read -rp "  ${prompt_text} [current: ${current}, options: ${options[*]}]: " value \
            || { printf -v "$var_name" '%s' "$current"; return; }
        value="${value:-$current}"
        for opt in "${options[@]}"; do
            [[ "$value" == "$opt" ]] || continue
            printf -v "$var_name" '%s' "$value"
            return
        done
        echo "  Invalid input. Choose one of: ${options[*]}"
    done
}

# | and & are rejected: the value is written through sed.
prompt_path() {
    local var_name="$1" prompt_text="$2" current="$3"
    local value
    while true; do
        read -rp "  ${prompt_text} [current: ${current:-none}]: " value \
            || { printf -v "$var_name" '%s' "$current"; return; }
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
        read -rp "  ${prompt_text}: " value \
            || die "No input available for '${prompt_text}' — stdin is closed."
        if [[ "$value" =~ ^https?://[^[:space:]]+$ ]]; then
            printf -v "$var_name" '%s' "$value"
            return
        fi
        echo "  Must be a single URL starting with http:// or https://"
    done
}

# Must match the key parse_runtable.py derives from Organism.
prompt_species_key() {
    local var_name="$1" prompt_text="$2"
    local value
    while true; do
        read -rp "  ${prompt_text}: " value \
            || die "No input available for '${prompt_text}' — stdin is closed."
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
    read -rp " $1 [y/N]: " answer || answer=""
    [[ "$answer" =~ ^[Yy]$ ]]
}
