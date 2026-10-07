#!/usr/bin/env bash
# shellcheck disable=SC2034  # read by the modules that source this file
# "species_key|genome_fna_gz_url|genome_gtf_gz_url|active". species_key is
# Genus_species, as parse_runtable.py derives it from Organism. Rewritten by setup.sh.

declare -a SPECIES_CONFIG=(

    "Helicoverpa_armigera|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/030/705/265/GCF_030705265.1_ASM3070526v1/GCF_030705265.1_ASM3070526v1_genomic.fna.gz|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/030/705/265/GCF_030705265.1_ASM3070526v1/GCF_030705265.1_ASM3070526v1_genomic.gtf.gz|\
true"
)
