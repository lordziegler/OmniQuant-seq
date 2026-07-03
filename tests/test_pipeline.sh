#!/usr/bin/env bash
# Minimal unit tests — no external tools required.
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOG_DIR="/tmp/pipeline_test_logs"
DISK_WARN_GB=5
mkdir -p "$LOG_DIR"

source "${PIPELINE_DIR}/lib/utils.sh"
source "${PIPELINE_DIR}/lib/cleanup.sh"
source "${PIPELINE_DIR}/steps/validate_inputs.sh"

_pass=0
_fail=0

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        echo "PASS: ${desc}"
        (( ++_pass ))
    else
        echo "FAIL: ${desc}  (got='${got}', want='${want}')"
        (( ++_fail )) || true
    fi
}

# A function that calls exit 1 must run in a subshell so it can't kill the test.
assert_fails() {
    local desc="$1"; shift
    if ! ( "$@" 2>/dev/null ); then
        echo "PASS: ${desc} (expected failure)"
        (( ++_pass ))
    else
        echo "FAIL: ${desc} (expected failure, but succeeded)"
        (( ++_fail )) || true
    fi
}

# --- normalize_layout --------------------------------------------------------
assert_eq "PAIRED literal"    "$(normalize_layout PAIRED)"    "PAIRED"
assert_eq "paired lowercase"  "$(normalize_layout paired)"    "PAIRED"
assert_eq "PE"                "$(normalize_layout PE)"        "PAIRED"
assert_eq "Paired-End"        "$(normalize_layout Paired-End)" "PAIRED"
assert_eq "SINGLE literal"    "$(normalize_layout SINGLE)"    "SINGLE"
assert_eq "SE"                "$(normalize_layout SE)"        "SINGLE"
assert_eq "Single-End"        "$(normalize_layout Single-End)" "SINGLE"
assert_fails "unknown layout" normalize_layout UNKNOWN

# --- require_file ------------------------------------------------------------
assert_fails "require_file missing" require_file "/no/such/file" ""

tmpf="$(mktemp)"
assert_eq "require_file exists" "$(require_file "$tmpf" "" && echo ok)" "ok"
rm -f "$tmpf"

# --- detect_inputs -----------------------------------------------------------
tmpd="$(mktemp -d)"
touch "${tmpd}/genome.fna.gz" "${tmpd}/annotation.gtf.gz" "${tmpd}/SraRunTable.csv"
detect_inputs "$tmpd"
assert_eq "FNA_FILE set"   "$FNA_FILE"   "${tmpd}/genome.fna.gz"
assert_eq "GTF_FILE set"   "$GTF_FILE"   "${tmpd}/annotation.gtf.gz"
assert_eq "RUN_TABLE set"  "$RUN_TABLE"  "${tmpd}/SraRunTable.csv"

# Two FASTA files should abort
touch "${tmpd}/extra.fa.gz"
assert_fails "detect_inputs two FASTAs" detect_inputs "$tmpd"
rm -rf "$tmpd"

# --- cleanup_on_error ---------------------------------------------------------
tmpd="$(mktemp -d)"
TMP_DIR="$tmpd"
mkdir -p "${TMP_DIR}/TESTSRR_star" "${TMP_DIR}/TESTSRR_rsem_tmp"
touch "${tmpd}/partial.genes.results" "${tmpd}/partial.isoforms.results"

cleanup_on_error "TESTSRR" "${tmpd}/partial.genes.results" "${tmpd}/partial.isoforms.results"

assert_eq "cleanup_on_error removes extra files" \
    "$([[ -f "${tmpd}/partial.genes.results" ]] && echo present || echo gone)" "gone"
assert_eq "cleanup_on_error removes STAR tmp dir" \
    "$([[ -d "${TMP_DIR}/TESTSRR_star" ]] && echo present || echo gone)" "gone"
assert_eq "cleanup_on_error removes RSEM tmp dir" \
    "$([[ -d "${TMP_DIR}/TESTSRR_rsem_tmp" ]] && echo present || echo gone)" "gone"
rm -rf "$tmpd"

# --- SIGINT triggers cleanup_on_error via trap --------------------------------
tmpd="$(mktemp -d)"
mkdir -p "${tmpd}/TESTSRR_star"

command cat > "${tmpd}/trap_test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
TMP_DIR="TMPD_PLACEHOLDER"
LOG_DIR="TMPD_PLACEHOLDER"
source "PIPELINE_DIR_PLACEHOLDER/lib/utils.sh"
source "PIPELINE_DIR_PLACEHOLDER/lib/cleanup.sh"
CURRENT_SRR="TESTSRR"
trap 'cleanup_on_error "$CURRENT_SRR"; exit 130' SIGINT SIGTERM
sleep 10
EOF

# Replace placeholders in the script
sed -i "s|TMPD_PLACEHOLDER|${tmpd}|g" "${tmpd}/trap_test.sh"
sed -i "s|PIPELINE_DIR_PLACEHOLDER|${PIPELINE_DIR}|g" "${tmpd}/trap_test.sh"
chmod +x "${tmpd}/trap_test.sh"

timeout -s INT 1 "${tmpd}/trap_test.sh" 2>/dev/null || true

assert_eq "SIGINT cleanup removes STAR tmp dir" \
    "$([[ -d "${tmpd}/TESTSRR_star" ]] && echo present || echo gone)" "gone"
rm -rf "$tmpd"

# --- parse_runtable.py -------------------------------------------------------
tmpd="$(mktemp -d)"
cat > "${tmpd}/SraRunTable.csv" <<'CSV'
Run,Assay Type,LibrarySource,LibraryLayout,Organism
SRR123456,RNA-Seq,TRANSCRIPTOMIC,PAIRED,Helicoverpa armigera
SRR999999,WGS,GENOMIC,SINGLE,Helicoverpa armigera
CSV

python3 "${PIPELINE_DIR}/helpers/parse_runtable.py" \
    --input  "${tmpd}/SraRunTable.csv" \
    --output "${tmpd}/samples.tsv"

rows="$(awk 'NR>1' "${tmpd}/samples.tsv" | wc -l | tr -d ' ')"
assert_eq "parse_runtable: 1 RNA-Seq row"  "$rows"  "1"

got_srr="$(awk -F'\t' 'NR==2{print $1}' "${tmpd}/samples.tsv")"
assert_eq "parse_runtable: correct SRR"    "$got_srr"  "SRR123456"

got_layout="$(awk -F'\t' 'NR==2{print $3}' "${tmpd}/samples.tsv")"
assert_eq "parse_runtable: correct layout" "$got_layout" "PAIRED"
rm -rf "$tmpd"

# --- Summary -----------------------------------------------------------------
echo ""
echo "Results: ${_pass} passed, ${_fail} failed."
[[ "$_fail" -eq 0 ]]
