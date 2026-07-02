#!/usr/bin/env bash
# Central configuration — edit this file before each run.

# --- Compute resources -------------------------------------------------------
THREADS_DOWNLOAD=8
THREADS_FASTQC=8
THREADS_TRIM=8
THREADS_STAR=8
THREADS_RSEM=8
MAX_MEMORY_GB=32
MAX_SRA_SIZE="100G"
DISK_WARN_GB=20

# --- Paths -------------------------------------------------------------------
REFERENCES_DIR="references"
SAMPLES_TSV="pipeline/results/samples.tsv"
LOG_DIR="pipeline/logs"
TMP_DIR="pipeline/tmp"
RESULTS_DIR="pipeline/results"

# --- Run behaviour -----------------------------------------------------------
TEST_MODE=false
TEST_READS=100000
PIPELINE_RETRY_PASSES=3
PREFETCH_RETRIES=5
PREFETCH_RETRY_SLEEP=30

# --- STAR --------------------------------------------------------------------
STAR_OVERHANG=99
STAR_SA_INDEX_NBASES=12

# --- BBDuk -------------------------------------------------------------------
BBDUK_QTRIM="rl"
BBDUK_TRIMQ=10
BBDUK_MINLEN=36
BBDUK_REF=""       # adapter FASTA — leave empty to skip adapter clipping
BBDUK_KTRIM=""
BBDUK_K=""
BBDUK_MINK=""
BBDUK_HDIST=""

# --- Cleanup -----------------------------------------------------------------
CLEAN_SRA_AFTER_FASTQ=true
CLEAN_RAW_FASTQ_AFTER_RSEM=true
CLEAN_FASTQ_AFTER_RSEM=true
