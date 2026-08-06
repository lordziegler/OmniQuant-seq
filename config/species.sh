#!/usr/bin/env bash
# Species reference table — the only place organisms are named.
#
# Format per entry: "species_key|genome_fna_gz_url|genome_gtf_gz_url|active"
#   species_key  Genus_species. Names the references/<species_key>/ directory
#                and must match the key parse_runtable.py derives from the
#                RunTable Organism field.
#   *_url        gzip-compressed genome FASTA and annotation GTF.
#   active       false skips the species without removing its entry.
#
# Add entries with `bash pipeline/setup.sh --add-species` (prompts for the key
# and both URLs, then downloads the files), or edit this file directly.
#
# Helicoverpa armigera ships as the reference example — it is the dataset used
# by `run.sh --example` and by the tests. See "Additional species examples" in
# README.md for ready-to-paste entries for other organisms.

declare -a SPECIES_CONFIG=(

    "Helicoverpa_armigera|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/030/705/265/GCF_030705265.1_ASM3070526v1/GCF_030705265.1_ASM3070526v1_genomic.fna.gz|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/030/705/265/GCF_030705265.1_ASM3070526v1/GCF_030705265.1_ASM3070526v1_genomic.gtf.gz|\
true"
)
