# Lepidoptera Catalytic Triad — RNA-seq TPM Pipeline (v2)

Modular, reproducible pipeline for TPM/FPKM quantification across six Lepidoptera
species with contrasting feeding breadth. Targets midgut transcriptomes from
larval and adult stages to support the identification of the serine protease
catalytic triad.

**Institution:** Universidade de Nariño  
**PI:** Juan Sebastián Zambrano

---

## Target species

| Feeding type | Species                  | Key in pipeline            |
|:-------------|:-------------------------|:---------------------------|
| Polyphagous  | *Spodoptera frugiperda*  | `Spodoptera_frugiperda`    |
| Polyphagous  | *Plutella xylostella*    | `Plutella_xylostella`      |
| Polyphagous  | *Diatraea saccharalis*   | `Diatraea_saccharalis`     |
| Monophagous  | *Bombyx mori*            | `Bombyx_mori`              |
| Monophagous  | *Tecia solanivora*       | `Tecia_solanivora`         |
| Monophagous  | *Helicoverpa armigera*   | `Helicoverpa_armigera`     |

Species are enabled or disabled via the `active` flag in `config/species.sh`.
No code changes required to add or exclude a species.

---

## Repository structure

```
pipeline/
├── run.sh                          # Single entry point — orchestrates all steps
├── config/
│   ├── pipeline.sh                 # Compute resources, paths, flags, retry settings
│   └── species.sh                  # SPECIES_CONFIG[]: genome + GTF URLs per species
├── lib/
│   ├── utils.sh                    # log_step, check_tools, disk_usage, require_file/dir
│   ├── cleanup.sh                  # Per-step intermediate file deletion
│   └── sample_tracker.sh           # Atomic per-sample status TSV
├── steps/
│   ├── validate_inputs.sh          # detect_inputs() — validates FASTA + GTF + RunTable
│   ├── build_references.sh         # STAR genomeGenerate + rsem-prepare-reference
│   ├── parse_samples.sh            # Calls helpers/parse_runtable.py → samples.tsv
│   ├── prefetch.sh                 # SRA download with retry loop
│   ├── fastq_dump.sh               # SRA → FASTQ (fastq-dump test / fasterq-dump full)
│   ├── fastqc.sh                   # FastQC per sample + MultiQC per sample and global
│   ├── trim.sh                     # BBDuk quality + adapter trimming
│   ├── align.sh                    # STAR alignment (ENCODE flags) → BAM
│   ├── quantify.sh                 # RSEM quantification → genes.results
│   └── postprocess.sh              # Expression matrix + QC matrices + global MultiQC
├── helpers/
│   ├── parse_runtable.py           # Parse SRA RunTable (CSV or XLSX) → samples.tsv
│   └── build_matrix.py             # Build expression matrix and QC matrices from results
└── tests/
    └── test_pipeline.sh            # 24 unit tests (no external tools required)
```

---

## Software requirements

All tools are pinned in `environment.yml` at the repository root. Install with:

```bash
conda env create -f environment.yml
conda activate lepidoptera-rnaseq
```

| Tool        | Version | Role                                        |
|:------------|:--------|:--------------------------------------------|
| SRA-Toolkit | ≥ 3.0   | `prefetch`, `fasterq-dump` (SRA download)   |
| FastQC      | ≥ 0.12  | Per-sample quality control                  |
| MultiQC     | ≥ 1.14  | Per-sample and global aggregated QC report  |
| BBDuk       | ≥ 39.x  | Adapter removal, quality trimming (BBMap)   |
| STAR        | ≥ 2.7.10| Splice-aware alignment (ENCODE protocol)    |
| RSEM        | ≥ 1.3.3 | TPM/FPKM quantification from BAM           |
| Python      | ≥ 3.9   | `helpers/parse_runtable.py`, `build_matrix.py` |
| openpyxl    | ≥ 3.0   | SRA RunTable parsing from `.xlsx`           |

---

## Quick start

```bash
# 1. Edit config/pipeline.sh — set thread counts and storage paths
# 2. Edit config/species.sh  — set active=true for the species you want

# Build references only
bash pipeline/run.sh --build-refs

# Test run (limited reads per sample, fast validation)
bash pipeline/run.sh --test

# Full production run
bash pipeline/run.sh --full
```

Run from the **project root** (the directory that contains the genome FASTA,
GTF, and SRA RunTable files).

---

## Execution — step by step

### Step 0 — Configure compute resources

Edit `config/pipeline.sh` directly:

```bash
# config/pipeline.sh
THREADS_STAR=30
THREADS_RSEM=30
THREADS_FASTQC=8
THREADS_TRIM=8
DISK_WARN_GB=20
```

Key flags:

| Variable | Default | Effect |
|:---------|:--------|:-------|
| `TEST_MODE` | `true` | Limits `fastq-dump` to `TEST_READS` reads |
| `TEST_READS` | `100000` | Reads per sample in test mode |
| `PIPELINE_RETRY_PASSES` | `3` | Full passes over `samples.tsv` on partial failure |
| `PREFETCH_RETRIES` | `5` | Download attempts per sample before marking failed |
| `REF_DOWNLOAD_RETRIES` | `3` | Genome/GTF download attempts before aborting reference build |
| `DISK_WARN_GB` | `20` | Free-space threshold for non-fatal disk warning |

### Step 1 — Build genome references *(run once per species)*

```bash
bash pipeline/run.sh --build-refs
```

For each species with `active=true` in `config/species.sh`, the pipeline:

1. Downloads the genome FASTA and GTF from the NCBI URL specified in `SPECIES_CONFIG`.
2. Decompresses both files into `references/<species>/`.
3. Builds the STAR genome index (`STAR --runMode genomeGenerate`).
4. Prepares the RSEM reference (`rsem-prepare-reference`).

Skips any species whose index already exists. Safe to re-run.

> **Disk estimate:** ~2–4 GB per species for indexes (genome FASTA and GTF
> retained for potential re-indexing).

### Step 2 — Prepare the sample list *(automatic on first run)*

`parse_samples.sh` calls `helpers/parse_runtable.py` automatically when
`run.sh` starts. To run it in isolation:

```bash
python3 pipeline/helpers/parse_runtable.py \
    --input  SraRunTable.csv \
    --output samples.tsv
```

Accepts `.csv` or `.xlsx`. Filters for RNA-Seq / TRANSCRIPTOMIC records,
maps organism names to species keys, deduplicates by accession, and writes
`samples.tsv` (three columns: `SRR`, `SPECIES`, `LAYOUT`).

Review `samples.tsv` before a full run.

### Step 3 — Run the quantification loop

```bash
# Test mode — fast validation with limited reads
bash pipeline/run.sh --test

# Full production run
bash pipeline/run.sh --full
```

Per-sample steps for each `SRR` in `samples.tsv`:

```
prefetch → fastq-dump/fasterq-dump → FastQC (raw) → BBDuk
→ FastQC (clean) → MultiQC (per sample) → STAR → RSEM → cleanup
```

The loop is **idempotent**: completed samples are skipped based on the
`pipeline_sample_summary.tsv` tracker, not just the presence of output files.
Interrupted runs resume from the last incomplete sample.

**Retry logic:** If a sample fails, it is retried on the next pass (up to
`PIPELINE_RETRY_PASSES` complete passes over `samples.tsv`).

### Step 4 — Post-processing *(automatic at end of run)*

`postprocess_all` runs automatically after the sample loop. To run it manually:

```bash
python3 pipeline/helpers/build_matrix.py \
    --rsem-dir  results/rsem \
    --output    results/tables/gene_expression_matrix.tsv \
    --star-logs logs/ \
    --bbduk-logs logs/ \
    --star-out  results/tables/STAR_mapping_QC_matrix.tsv \
    --bbduk-out results/tables/BBDUK_preprocessing_QC_matrix.tsv
```

---

## Output files

```
results/
├── rsem/
│   └── <species>/
│       ├── <SRR>.genes.results       # TPM, FPKM, expected_count (gene level)
│       └── <SRR>.isoforms.results    # TPM, FPKM, expected_count (isoform level)
├── qc/
│   ├── fastqc/                       # Per-sample FastQC HTML + ZIP
│   └── multiqc/
│       ├── <SRR>/                    # Per-sample MultiQC report (clean reads)
│       └── global/                   # Global MultiQC across all samples
└── tables/
    ├── gene_expression_matrix.tsv    # Inner join of all genes.results (TPM + FPKM columns)
    ├── STAR_mapping_QC_matrix.tsv    # STAR Log.final.out metrics × samples
    └── BBDUK_preprocessing_QC_matrix.tsv  # BBDuk stats × samples

logs/
├── <SRR>.log                         # Per-sample cumulative log (all steps)
├── <SRR>_prefetch.log
├── <SRR>_fastqc_raw.log
├── <SRR>_bbduk.log
├── <SRR>_star.log
├── <SRR>_STAR_Log.final.out
└── <SRR>_rsem.log

pipeline_sample_summary.tsv           # Per-sample status tracker (11 columns)
samples.tsv                           # Parsed sample list (SRR, SPECIES, LAYOUT)
```

The `TPM` column in `*.genes.results` is the primary value for downstream
comparative analyses. `gene_expression_matrix.tsv` contains all samples as
columns and only genes present in every sample (inner join).

---

## Sample tracker

`pipeline_sample_summary.tsv` records the status of each pipeline stage per
sample. Columns:

| Column | Values |
|:-------|:-------|
| `SRR` | Run accession |
| `SPECIES` | Species key |
| `LAYOUT` | `PAIRED` or `SINGLE` |
| `TEST_MODE` | `true` or `false` |
| `TEST_READS` | Number of reads in test mode |
| `prefetch_status` | `OK`, `FAILED`, `PENDING` |
| `fastqdump_status` | `OK`, `FAILED`, `PENDING` |
| `trim_status` | `OK`, `FAILED`, `PENDING` |
| `star_status` | `OK`, `FAILED`, `PENDING` |
| `rsem_status` | `OK`, `FAILED`, `PENDING` |
| `genes_results_path` | Absolute path or `NA` |

Updates are written atomically (`awk > tmp && mv tmp real`) to prevent
corruption on interrupted runs.

---

## Disk management

Intermediate files are deleted immediately after each step confirms its output:

| Function (`lib/cleanup.sh`)  | Files deleted                        | Freed per sample |
|:-----------------------------|:-------------------------------------|:----------------|
| `cleanup_sra`                | `.sra` archive + prefetch directory  | 1–5 GB          |
| `cleanup_raw_fastq`          | Uncompressed raw FASTQ               | 2–10 GB         |
| `cleanup_clean_fastq`        | Trimmed `.fastq.gz`                  | 1–4 GB          |
| `cleanup_star_tmp`           | STAR temporary directory             | 2–8 GB          |
| `cleanup_rsem_bam`           | `.transcript.bam`                    | 10–60 GB        |
| `cleanup_rsem_tmp`           | RSEM temporary directory             | variable        |
| `cleanup_on_error`           | All partial outputs on failure       | prevents stale data |

Cleanup is controlled by flags in `config/pipeline.sh`:

```bash
CLEAN_SRA_AFTER_FASTQ=true
CLEAN_RAW_FASTQ_AFTER_RSEM=true
CLEAN_FASTQ_AFTER_RSEM=true
```

Set any flag to `false` to retain intermediate files for debugging.

`disk_usage` in `lib/utils.sh` logs free space before each heavy step and
emits a non-fatal warning when available space drops below `DISK_WARN_GB`.

---

## Testing

```bash
bash pipeline/tests/test_pipeline.sh
```

24 unit tests covering:

- `normalize_layout` — 8 input variants (PE, SE, Paired-End, etc.)
- `require_file` — missing file abort, existing file pass
- `detect_inputs` — happy path, two-FASTA abort
- `cleanup_on_error` — partial file cleanup and SIGINT trap
- `_decompress_or_download` — corrupt gzip detection and download retry logic
- `parse_runtable.py` — row count, SRR value, layout normalization

No external bioinformatics tools required. All tests complete in < 2 seconds.

Expected output:

```
Results: 24 passed, 0 failed.
```

---

## Configuration reference

### `config/pipeline.sh`

| Variable | Default | Description |
|:---------|:--------|:------------|
| `THREADS_STAR` | `30` | STAR alignment threads |
| `THREADS_RSEM` | `30` | RSEM quantification threads |
| `THREADS_FASTQC` | `8` | FastQC threads |
| `THREADS_TRIM` | `8` | BBDuk threads |
| `MAX_SRA_SIZE` | `200G` | Maximum SRA download size |
| `TEST_MODE` | `true` | Enable test mode |
| `TEST_READS` | `100000` | Reads per sample in test mode |
| `DISK_WARN_GB` | `20` | Free-space warning threshold (GB) |
| `PREFETCH_RETRIES` | `5` | Download retry attempts |
| `PREFETCH_RETRY_SLEEP` | `30` | Seconds between retry attempts |
| `REF_DOWNLOAD_RETRIES` | `3` | Genome/GTF download retry attempts |
| `REF_DOWNLOAD_RETRY_SLEEP` | `15` | Seconds between reference download retries |
| `PIPELINE_RETRY_PASSES` | `3` | Full retry passes over sample list |
| `STAR_OVERHANG` | `149` | `sjdbOverhang` (read length − 1) |
| `STAR_SA_INDEX_NBASES` | `13` | `genomeSAindexNbases` for ~400 Mb genomes |
| `BBDUK_QTRIM` | `rl` | Quality trimming direction |
| `BBDUK_TRIMQ` | `20` | Quality trimming threshold |
| `BBDUK_MINLEN` | `36` | Minimum read length after trimming |

### `config/species.sh`

Each entry in `SPECIES_CONFIG` follows the format:

```
"species_key|genome_fna_gz_url|genome_gtf_gz_url|active"
```

- `species_key` must match the subdirectory name under `references/`.
- Set `active=false` to skip a species without removing its entry.
- URLs must point to gzip-compressed files (`.fna.gz`, `.gtf.gz`).

---

## References

- Andrews, S. (2010). *FastQC*. https://www.bioinformatics.babraham.ac.uk/projects/fastqc/
- Bushnell, B. (2014). *BBMap: A Fast, Accurate, Splice-Aware Aligner*. https://sourceforge.net/projects/bbmap/
- Dobin, A. et al. (2013). STAR: ultrafast universal RNA-seq aligner. *Bioinformatics*, 29(1), 15–21.
- Ewels, P. et al. (2016). MultiQC. *Bioinformatics*, 32(19), 3047–3048.
- Li, B. & Dewey, C. N. (2011). RSEM: accurate transcript quantification from RNA-Seq data. *BMC Bioinformatics*, 12, 323.
- NCBI SRA Toolkit. https://github.com/ncbi/sra-tools
