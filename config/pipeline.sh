#!/usr/bin/env bash
# shellcheck disable=SC2034  # read by the modules that source this file

THREADS_DOWNLOAD=8
THREADS_FASTQC=8
THREADS_TRIM=8
THREADS_STAR=8
THREADS_RSEM=8
MAX_MEMORY_GB=32
MAX_SRA_SIZE="100G"
DISK_WARN_GB=20

REFERENCES_DIR="references"
LOG_DIR="logs"
TMP_DIR="tmp"
RESULTS_DIR="results"
SAMPLES_TSV="${RESULTS_DIR}/samples.tsv"

# Species key for RunTable rows with an empty Organism; empty disables it.
SPECIES_FALLBACK=""

TEST_MODE=false
TEST_READS=100000
PIPELINE_RETRY_PASSES=3
PREFETCH_RETRIES=5
PREFETCH_RETRY_SLEEP=30

# Used by run.sh --example.
EXAMPLE_SPECIES="Helicoverpa_armigera"
EXAMPLE_READS=25000

# Rows of the expression matrix printed at the end of a run.
ENABLE_PREVIEW=true
PREVIEW_LINES=10

STAR_OVERHANG=99
STAR_SA_INDEX_NBASES=12
# Below this % of uniquely mapped reads a sample fails (e.g. small-RNA libraries).
MIN_UNIQUE_MAPPED_PCT=10

BBDUK_QTRIM="rl"
BBDUK_TRIMQ=10
BBDUK_MINLEN=36
# Adapter FASTA; empty skips adapter clipping.
BBDUK_REF=""
BBDUK_KTRIM=""
BBDUK_K=""
BBDUK_MINK=""
BBDUK_HDIST=""

CLEAN_SRA_AFTER_FASTQ=true
CLEAN_RAW_FASTQ_AFTER_RSEM=true
CLEAN_FASTQ_AFTER_RSEM=true
