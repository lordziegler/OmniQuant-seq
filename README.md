# RNA-seq TPM/FPKM Quantification Pipeline (v2.1)

Modular, reproducible pipeline that turns a public NCBI SRA RunTable into a
per-gene expression matrix (TPM and FPKM) from a single entry point. It works
for **any organism** that has a reference genome (FASTA) and annotation (GTF):
the target species are declared in a config file, not hardcoded in the code.

The repository ships preconfigured for a set of Lepidoptera species (used as the
worked example throughout this document), but nothing in the pipeline is tied to
that taxon — see [Adapting to another organism](#adapting-to-another-organism).

**Institution:** Universidad de Nariño
**PI:** Juan Sebastián Zambrano

---

## Pipeline at a glance

```
prefetch → fastq-dump/fasterq-dump → FastQC (raw) → BBDuk
→ FastQC (clean) → MultiQC → STAR → RSEM → expression + QC matrices
```

| Stage        | Tool        | Output                                    |
|:-------------|:------------|:------------------------------------------|
| Download     | SRA-Toolkit | `.sra` → FASTQ                            |
| Quality      | FastQC      | Per-sample QC (before and after trimming) |
| Trimming     | BBDuk       | Quality-trimmed FASTQ                     |
| Alignment    | STAR        | Genome BAM + transcriptome BAM            |
| Quantification | RSEM      | `genes.results` / `isoforms.results`      |
| Aggregation  | Python      | Expression matrix + STAR/BBDuk QC matrices|

---

## Preconfigured species

These are the entries shipped in `config/species.sh`. The `active` flag selects
which ones a run processes; toggling it (or adding/removing species) requires no
code changes — use `setup.sh` or edit the file directly.

| Species                  | Key in pipeline          | Active by default |
|:-------------------------|:-------------------------|:------------------|
| *Helicoverpa armigera*   | `Helicoverpa_armigera`   | yes               |
| *Spodoptera frugiperda*  | `Spodoptera_frugiperda`  | yes               |
| *Plutella xylostella*    | `Plutella_xylostella`    | yes               |
| *Bombyx mori*            | `Bombyx_mori`            | no                |
| *Diatraea saccharalis*   | `Diatraea_saccharalis`   | no                |

---

## Repository structure

```
pipeline/
├── run.sh                          # Single entry point — orchestrates all steps
├── setup.sh                        # Interactive configurator (resources + species)
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

| Tool        | Version   | Role                                        |
|:------------|:----------|:--------------------------------------------|
| SRA-Toolkit | 3.0.0     | `prefetch`, `fasterq-dump` (SRA download)   |
| FastQC      | 0.12.1    | Per-sample quality control                  |
| MultiQC     | 1.14      | Per-sample and global aggregated QC report  |
| BBDuk (BBMap) | unpinned| Adapter removal, quality trimming           |
| STAR        | 2.7.10a   | Splice-aware alignment (ENCODE protocol)    |
| RSEM        | 1.3.3     | TPM/FPKM quantification from BAM            |
| Python      | ≥ 3.9     | `helpers/parse_runtable.py`, `build_matrix.py` |
| openpyxl    | ≥ 3.0     | SRA RunTable parsing from `.xlsx`           |

---

## Quick start

```bash
# 1. Configure resources and species (interactive)
bash pipeline/setup.sh

#    ...or edit the two config files directly:
#    config/pipeline.sh — thread counts, storage paths, run flags
#    config/species.sh  — species keys + genome/GTF URLs, active flag

# 2. Build references once per active species
bash pipeline/run.sh --build-refs

# 3. Smoke test (limited reads per sample)
bash pipeline/run.sh --test

# 4. Full production run
bash pipeline/run.sh --full
```

Run from the **project root** (the directory that contains the genome FASTA,
GTF, and SRA RunTable, when using local inputs). Outputs are written under
`pipeline/results/` and `pipeline/logs/`.

---

## Execution — step by step

### Step 0 — Configure compute resources

Run `bash pipeline/setup.sh`, or edit `config/pipeline.sh` directly. The
defaults are conservative:

```bash
# config/pipeline.sh (defaults)
THREADS_DOWNLOAD=8
THREADS_FASTQC=8
THREADS_TRIM=8
THREADS_STAR=8
THREADS_RSEM=8
MAX_MEMORY_GB=32
```

Key run flags:

| Variable | Default | Effect |
|:---------|:--------|:-------|
| `TEST_MODE` | `false` | When `true`, limits `fastq-dump` to `TEST_READS` reads (also set by `--test`) |
| `TEST_READS` | `100000` | Reads per sample in test mode |
| `PIPELINE_RETRY_PASSES` | `3` | Full passes over `samples.tsv` on partial failure |
| `PREFETCH_RETRIES` | `5` | Download attempts per sample before marking failed |
| `MAX_SRA_SIZE` | `100G` | Maximum SRA download size (`prefetch --max-size`) |
| `DISK_WARN_GB` | `20` | Free-space threshold for a non-fatal disk warning |

### Step 1 — Build genome references *(run once per species)*

```bash
bash pipeline/run.sh --build-refs
```

For each species with `active=true` in `config/species.sh`, the pipeline:

1. Uses a local genome FASTA and GTF if present, otherwise downloads them from
   the URLs in `SPECIES_CONFIG`.
2. Decompresses both files into `references/<species>/`.
3. Builds the STAR genome index (`STAR --runMode genomeGenerate`).
4. Prepares the RSEM reference (`rsem-prepare-reference`).

Skips any species whose index already exists. Safe to re-run.

> **Index size** depends on genome size (typically several GB per species). The
> genome FASTA and GTF are retained under `references/<species>/` for potential
> re-indexing.

### Step 2 — Prepare the sample list *(automatic on first run)*

`parse_samples.sh` calls `helpers/parse_runtable.py` automatically when
`run.sh` starts, passing the active species from `config/species.sh` so that
only organisms you have references for reach `samples.tsv`. To run it in
isolation:

```bash
python3 pipeline/helpers/parse_runtable.py \
    --input   SraRunTable.csv \
    --output  samples.tsv \
    --species Helicoverpa_armigera,Spodoptera_frugiperda
```

Accepts `.csv` or `.xlsx`. The parser:

- keeps `RNA-Seq` records whose `LibrarySource` is `TRANSCRIPTOMIC` or
  `GENOMIC` (if none pass, it falls back to all RNA-Seq rows and warns);
- derives a `Genus_species` key from the `Organism` field
  (`Helicoverpa armigera` → `Helicoverpa_armigera`);
- with `--species`, keeps only the listed keys; without it, keeps every
  organism found;
- deduplicates by accession and validates it against `^[SED]RR\d+$`;
- writes `samples.tsv` with three columns: `SRR`, `SPECIES`, `LAYOUT`.

Use `--fallback Genus_species` (or `SPECIES_FALLBACK` in `config/pipeline.sh`)
for datasets whose `Organism` field is empty or unreliable.

Review `samples.tsv` before a full run.

### Step 3 — Run the quantification loop

```bash
bash pipeline/run.sh --test    # fast validation with limited reads
bash pipeline/run.sh --full    # full production run
```

Per-sample steps for each `SRR` in `samples.tsv`:

```
prefetch → fastq-dump/fasterq-dump → FastQC (raw) → BBDuk
→ FastQC (clean) → MultiQC (per sample) → STAR → RSEM → cleanup
```

The loop is **idempotent**: completed samples are skipped based on the
`pipeline_sample_summary.tsv` tracker, not just the presence of output files.
Interrupted runs resume from the last incomplete sample.

**Retry logic:** if a sample fails, it is retried on the next pass (up to
`PIPELINE_RETRY_PASSES` complete passes over `samples.tsv`).

### Step 4 — Post-processing *(automatic at end of run)*

`postprocess_all` runs automatically after the sample loop. To run it manually:

```bash
python3 pipeline/helpers/build_matrix.py \
    --rsem-dir   pipeline/results/rsem \
    --output     pipeline/results/tables/gene_expression_matrix.tsv \
    --star-logs  pipeline/logs/ \
    --bbduk-logs pipeline/logs/ \
    --star-out   pipeline/results/tables/STAR_mapping_QC_matrix.tsv \
    --bbduk-out  pipeline/results/tables/BBDUK_preprocessing_QC_matrix.tsv
```

---

## Adapting to another organism

The pipeline is not tied to Lepidoptera. To process a different taxon:

1. **Declare the species.** Run `bash pipeline/setup.sh` and add an entry, or
   edit `config/species.sh` directly. Each entry is:

   ```
   "species_key|genome_fna_gz_url|genome_gtf_gz_url|active"
   ```

   - `species_key` is `Genus_species` (underscore-separated) and must match the
     subdirectory name under `references/`.
   - The FASTA and GTF URLs point to gzip-compressed NCBI files (`.fna.gz`,
     `.gtf.gz`). A local FASTA/GTF in the project root is used if present.

2. **Match the RunTable.** `parse_runtable.py` derives the same `Genus_species`
   key from the RunTable's `Organism` column automatically, so as long as the
   `species_key` equals the scientific name with an underscore, samples are
   routed correctly. No Python editing is required.

3. **Handle missing organism metadata.** For single-species datasets, or when
   the `Organism` field is empty or ambiguous, set `SPECIES_FALLBACK` in
   `config/pipeline.sh` (or pass `--fallback Genus_species`).

4. **Tune organism-specific parameters.** In particular `STAR_OVERHANG`
   (`read length − 1`) and `STAR_SA_INDEX_NBASES`
   (`min(14, log2(genome length)/2 − 1)` for small genomes). See
   [Configuration reference](#configuration-reference).

---

## Output files

```
pipeline/results/
├── rsem/
│   └── <species>/
│       ├── <SRR>.genes.results       # TPM, FPKM, expected_count (gene level)
│       └── <SRR>.isoforms.results    # TPM, FPKM, expected_count (isoform level)
├── qc/
│   └── multiqc/
│       ├── <SRR>/                    # Per-sample MultiQC report (clean reads)
│       └── global/                   # Global MultiQC (raw + clean) across samples
├── tables/
│   ├── gene_expression_matrix.tsv    # Inner join of all genes.results (TPM + FPKM columns)
│   ├── STAR_mapping_QC_matrix.tsv    # STAR Log.final.out metrics × samples
│   └── BBDUK_preprocessing_QC_matrix.tsv  # BBDuk stats × samples
├── samples.tsv                       # Parsed sample list (SRR, SPECIES, LAYOUT)
└── pipeline_sample_summary.tsv       # Per-sample status tracker

pipeline/logs/
├── <SRR>.log                         # Per-sample cumulative log (all steps)
├── <SRR>_prefetch.log
├── <SRR>_bbduk.log
├── <SRR>_star.log
├── <SRR>_STAR_Log.final.out
└── <SRR>_rsem.log

fastqc_out/                           # FastQC HTML + ZIP (working dir at project root)
```

`run.sh` also creates the working directories `sra/`, `fastq/`, and
`clean_fastq/` at the project root for intermediate data; these are emptied by
the cleanup steps as each sample completes.

`gene_expression_matrix.tsv` contains all samples as columns and only genes
present in every sample (inner join). Its leading `expected_count` and
`effective_length` columns are copied from the first file in which each gene
appears and should not be read as any single sample's values; for per-sample
counts use the individual `genes.results` files.

---

## Sample tracker

`pipeline_sample_summary.tsv` records the status of each pipeline stage per
sample. Columns (as written by `lib/sample_tracker.sh`):

| Column | Values |
|:-------|:-------|
| `sample` | Run accession |
| `species` | Species key |
| `layout` | `PAIRED` or `SINGLE` |
| `test_mode` | `true` or `false` |
| `test_reads` | Number of reads in test mode |
| `prefetch_status` | `OK`, `FAILED`, `PENDING` |
| `fastq_status` | `OK`, `FAILED`, `PENDING` |
| `trimming_status` | `OK`, `FAILED`, `PENDING` |
| `star_status` | `OK`, `FAILED`, `PENDING` |
| `rsem_status` | `OK`, `FAILED`, `PENDING` |
| `genes_results` | Absolute path or `NA` |

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

Cleanup is controlled by flags in `config/pipeline.sh`:

```bash
CLEAN_SRA_AFTER_FASTQ=true
CLEAN_RAW_FASTQ_AFTER_RSEM=true
CLEAN_FASTQ_AFTER_RSEM=true
```

Set any flag to `false` to retain intermediate files for debugging.

> `cleanup_on_error` is defined in `lib/cleanup.sh` but is **not** currently
> wired into `run.sh`: partial outputs from a failed sample are left in place
> for inspection rather than deleted automatically.

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
- `parse_runtable.py` — row count, SRR value, layout, species-key derivation,
  generic (non-Lepidoptera) organism, `--species` filtering, `--fallback`
- `parse_samples` — restriction to active `SPECIES_CONFIG` species

No external bioinformatics tools required. All tests complete in under 2 seconds.

Expected output:

```
Results: 24 passed, 0 failed.
```

---

## Configuration reference

### `config/pipeline.sh`

| Variable | Default | Description |
|:---------|:--------|:------------|
| `THREADS_DOWNLOAD` | `8` | `fasterq-dump` threads |
| `THREADS_FASTQC` | `8` | FastQC threads |
| `THREADS_TRIM` | `8` | BBDuk threads |
| `THREADS_STAR` | `8` | STAR alignment threads |
| `THREADS_RSEM` | `8` | RSEM quantification threads |
| `MAX_MEMORY_GB` | `32` | Passed to STAR as `--limitBAMsortRAM` (bytes) |
| `MAX_SRA_SIZE` | `100G` | Maximum SRA download size |
| `DISK_WARN_GB` | `20` | Free-space warning threshold (GB) |
| `SPECIES_FALLBACK` | `""` | Species key for rows with an empty/unresolvable Organism field |
| `TEST_MODE` | `false` | Enable test mode (limited reads) |
| `TEST_READS` | `100000` | Reads per sample in test mode |
| `PREFETCH_RETRIES` | `5` | Download retry attempts |
| `PREFETCH_RETRY_SLEEP` | `30` | Seconds between retry attempts |
| `PIPELINE_RETRY_PASSES` | `3` | Full retry passes over sample list |
| `STAR_OVERHANG` | `99` | `sjdbOverhang` (read length − 1) |
| `STAR_SA_INDEX_NBASES` | `12` | `genomeSAindexNbases` (reduce for small genomes) |
| `BBDUK_QTRIM` | `rl` | Quality trimming direction |
| `BBDUK_TRIMQ` | `10` | Quality trimming threshold |
| `BBDUK_MINLEN` | `36` | Minimum read length after trimming |
| `BBDUK_REF` | `""` | Adapter FASTA — empty disables adapter clipping |

### `config/species.sh`

Each entry in `SPECIES_CONFIG` follows the format:

```
"species_key|genome_fna_gz_url|genome_gtf_gz_url|active"
```

- `species_key` must match the subdirectory name under `references/` and the
  `Genus_species` key derived from the RunTable `Organism` field.
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
