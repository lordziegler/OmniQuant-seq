#!/usr/bin/env bash
# Cluster overrides for the CENA/USP Bioinformatics cluster (SGE).
#
# This file is sourced LAST by config/pipeline.sh — only when the environment
# variable CLUSTER_CONFIG points to it (the submit/*.sge scripts export it).
# Any variable set here overrides the default from config/pipeline.sh. Local
# runs never touch this file.

# --- Compute resources -------------------------------------------------------
# The heavy stages (STAR, RSEM) get 20 threads. All stages are tied to $NSLOTS
# so that what the job actually uses matches what it reserved via `-pe smp`
# (the cluster policy requires reserved == used). Outside SGE, $NSLOTS is unset
# and the values fall back to 20, keeping standalone runs sensible.
THREADS_DOWNLOAD="${NSLOTS:-20}"
THREADS_FASTQC="${NSLOTS:-20}"
THREADS_TRIM="${NSLOTS:-20}"
THREADS_STAR="${NSLOTS:-20}"
THREADS_RSEM="${NSLOTS:-20}"

# RAM ceiling for the heaviest steps (e.g. STAR BAM sorting in steps/align.sh).
MAX_MEMORY_GB=20

# --- Paths -------------------------------------------------------------------
# All data MUST live on /Storage/data1 or /Storage/data2, never on /home and
# never on the frontend. BASE_DIR defaults to the directory qsub was launched
# from (`#$ -cwd`); the submit scripts export it explicitly. Every derived path
# stays under BASE_DIR so nothing is written outside the Storage partition.
BASE_DIR="${BASE_DIR:-$PWD}"
REFERENCES_DIR="${BASE_DIR}/references"
RESULTS_DIR="${BASE_DIR}/results"
LOG_DIR="${BASE_DIR}/logs"
TMP_DIR="${BASE_DIR}/tmp"
SAMPLES_TSV="${RESULTS_DIR}/samples.tsv"
