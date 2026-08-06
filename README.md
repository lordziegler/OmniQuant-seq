# OmniQuant-seq

**RNA-seq expression pipeline for any organism with a genome and an annotation.**

Modular, reproducible pipeline that turns a public NCBI SRA RunTable into a
per-gene expression matrix (TPM and FPKM) from a single entry point. Target
organisms are declared in a config file — nothing about the species is
hardcoded, and adding one requires no code change.

*Helicoverpa armigera* ships as the reference example: it is the species in
`config/species.sh`, the dataset behind `run.sh --example`, and the organism
used in the tests. Any other organism with a genome FASTA and a GTF works the
same way — see [Adding an organism](#adding-an-organism).

**Institution:** Universidad de Nariño
**PI:** Juan Sebastián Zambrano

---

## Pipeline at a glance

```
prefetch → fastq-dump/fasterq-dump → FastQC (raw) → BBDuk
→ FastQC (clean) → MultiQC → STAR → RSEM → expression + QC matrices
```

| Stage          | Tool        | Output                                    |
|:---------------|:------------|:------------------------------------------|
| Download       | SRA-Toolkit | `.sra` → FASTQ                            |
| Quality        | FastQC      | Per-sample QC (before and after trimming) |
| Trimming       | BBDuk       | Quality-trimmed FASTQ                     |
| Alignment      | STAR        | Genome BAM + transcriptome BAM            |
| Quantification | RSEM        | `genes.results` / `isoforms.results`      |
| Aggregation    | Python      | Expression matrix + STAR/BBDuk QC matrices|

---

## Quick start

```bash
conda env create -f environment.yml
conda activate omniquant-seq

# Interactive menu — configure, build references, run
bash pipeline/run.sh

# See every mode and what it does
bash pipeline/run.sh --help

# Small self-contained demo (Helicoverpa armigera, 1 run, 25k reads)
bash pipeline/run.sh --example
```

Run with no arguments on a terminal and both entry points open the same menu:

```
============================================================
 OmniQuant-seq — RNA-seq expression pipeline

 Select an option:
   [1] Configure pipeline resources
   [2] Configure species (interactive)
   [3] Build references
   [4] Run test mode
   [5] Run example (Helicoverpa_armigera)
   [6] Run full production
   [7] Exit
============================================================
 Option [1-7]:
```

Every option simply re-enters `run.sh` / `setup.sh` with the matching flag, so
the menu and the scriptable CLI can never diverge. Without a terminal (cron,
cluster job) the menu is skipped and the old non-interactive behaviour applies.

For your own dataset:

```bash
# 1. Configure compute resources and species (interactive menu)
bash pipeline/setup.sh

#    ...or add a single organism, genome download included:
bash pipeline/setup.sh --add-species

#    ...or edit the two config files directly:
#    config/pipeline.sh — thread counts, paths, run flags
#    config/species.sh  — species keys + genome/GTF URLs, active flag

# 2. Build references once per active species
bash pipeline/run.sh --build-refs

# 3. Smoke test on your samples (limited reads)
bash pipeline/run.sh --test

# 4. Full production run
bash pipeline/run.sh --full
```

Run from the **project root** — the directory holding your SRA RunTable.
Outputs are written under `pipeline/results/` and `pipeline/logs/`.

---

## CLI

### `run.sh`

| Mode | What it does |
|:--|:--|
| *(none)* | Interactive menu on a terminal; otherwise a normal run using `TEST_MODE` from `config/pipeline.sh`. |
| `--build-refs` | Downloads the genome + annotation of every active species and builds the STAR and RSEM indexes, then exits. Run once per species; safe to re-run. Does **not** need a RunTable. |
| `--test` | Full pipeline over every sample, limited to `TEST_READS` reads each. |
| `--full` | Full pipeline over all reads. Production run. |
| `--example` | Self-contained demo, see below. |
| `-i`, `--interactive` | Force the menu even when other arguments are given. |
| `--no-preview` | Skip the expression-matrix preview printed at the end of a run. |
| `-h`, `--help` | Usage, current defaults, examples, and output locations. |

### `setup.sh`

| Mode | What it does |
|:--|:--|
| *(none)* | Interactive menu. |
| `--resources` | Compute resources only (threads, RAM, storage). |
| `--species` | Species menu only: toggle, delete, add entries, then optionally download the genomes of the entries just added. |
| `--add-species` | Add or update **one** species and fetch its reference files. |
| `-i`, `--interactive` | Force the menu. |
| `-h`, `--help` | Usage and examples. |

### Adding a species interactively

Both `setup.sh --add-species` and option `[2]` of the menu ask the same three
questions, after explaining what a species key is and why it must be
`Genus_species`:

```
  Insert the name of the species (e.g. Helicoverpa_armigera). This key will be
  used as the directory name and to route samples to references, so it must be
  written as Genus_species — the same form parse_runtable.py derives from the
  RunTable "Organism" column.

  Species key: Danio_rerio
  Genome FASTA URL (.fna.gz): https://ftp.ncbi.nlm.nih.gov/.../GCF_..._genomic.fna.gz
  Annotation GTF URL (.gtf.gz): https://ftp.ncbi.nlm.nih.gov/.../GCF_..._genomic.gtf.gz
```

The key must be non-empty and contain at least one underscore; both URLs must
start with `http://` or `https://`. Invalid answers are rejected and asked
again. Then the flow

1. writes (or updates) the entry in `config/species.sh` as
   `"species_key|genome_fna_gz_url|genome_gtf_gz_url|active"`, with
   `active=true`;
2. creates `references/<species_key>/`;
3. downloads and decompresses both files into
   `references/<species_key>/genome.fa` and `.../genes.gtf`, the layout STAR
   and RSEM expect.

On success it prints
`Species <species_key> configured successfully. Files downloaded to
references/<species_key>/ and ready for STAR/RSEM index building`, both file
paths, and the command to build the indexes. On failure it says which step
failed (download, decompression, config write, directory creation), keeps the
config entry so the URLs can be corrected, and exits non-zero.

---

## The `--example` run

```bash
bash pipeline/run.sh --example
```

A complete, small run that exercises every stage, meant to show the flow
before committing to a real dataset.

| | |
|:--|:--|
| **Dataset** | `examples/SraRunTable.example.csv` — one paired-end *Helicoverpa armigera* run, `SRR29271587` ([PRJNA1119665](https://www.ncbi.nlm.nih.gov/bioproject/PRJNA1119665)) |
| **Species** | Forced to `Helicoverpa_armigera`, whatever `config/species.sh` has active |
| **Reads** | 25,000 spots (`fastq-dump -X`) |
| **Stages** | All of them: prefetch → fastq-dump → FastQC → BBDuk → FastQC → MultiQC → STAR → RSEM → matrices |
| **Cleanup** | Disabled — SRA, raw FASTQ and trimmed FASTQ are kept so each stage is inspectable |

What to expect afterwards:

```
pipeline/results/tables/gene_expression_matrix.tsv        TPM + FPKM columns for SRR29271587
pipeline/results/tables/STAR_mapping_QC_matrix.tsv        STAR Log.final.out metrics
pipeline/results/tables/BBDUK_preprocessing_QC_matrix.tsv BBDuk trimming stats
pipeline/results/rsem/Helicoverpa_armigera/               RSEM gene- and isoform-level results
pipeline/results/qc/multiqc/                              per-sample and global MultiQC reports
pipeline/results/pipeline_sample_summary.tsv              one row, all stages OK
pipeline/logs/SRR29271587.log                             per-stage log for the sample
```

> **Cost.** The example reads 25k spots but `prefetch` still downloads the
> whole ~620 MB SRA archive, and the *H. armigera* STAR/RSEM index is built
> first if missing (~10 GB, tens of minutes). It is a small run, not an
> instant one.

---

## Repository structure

```
pipeline/
├── run.sh                          # Entry point — parses the CLI, delegates to the modules
├── setup.sh                        # Interactive configurator (resources + species)
├── config/
│   ├── pipeline.sh                 # Compute resources, paths, flags, retry settings
│   └── species.sh                  # SPECIES_CONFIG[]: genome + GTF URLs per species
├── lib/
│   ├── utils.sh                    # die, log_step, check_tools, disk_usage, downloads
│   ├── menu.sh                     # Interactive entry menu shared by run.sh and setup.sh
│   ├── prompt.sh                   # Validated input helpers (int, size, URL, species key)
│   ├── species_config.sh           # Read/modify/write config/species.sh
│   ├── cleanup.sh                  # Per-step intermediate file deletion
│   └── sample_tracker.sh           # Atomic per-sample status TSV
├── steps/
│   ├── validate_inputs.sh          # Locates the RunTable and any local genome override
│   ├── build_references.sh         # Fetch genome/GTF, STAR genomeGenerate, rsem-prepare-reference
│   ├── parse_samples.sh            # Calls helpers/parse_runtable.py → samples.tsv
│   ├── prefetch.sh                 # SRA download with retry loop
│   ├── fastq_dump.sh               # SRA → FASTQ (fastq-dump test / fasterq-dump full)
│   ├── fastqc.sh                   # FastQC per sample + MultiQC per sample and global
│   ├── trim.sh                     # BBDuk quality + adapter trimming
│   ├── align.sh                    # STAR alignment (ENCODE flags) → BAM
│   ├── quantify.sh                 # RSEM quantification → genes.results
│   ├── process_sample.sh           # Per-sample stage order, failure handling, retry passes
│   └── postprocess.sh              # Expression matrix + QC matrices + global MultiQC + preview
├── helpers/
│   ├── parse_runtable.py           # Parse SRA RunTable (CSV or XLSX) → samples.tsv
│   └── build_matrix.py             # Build expression matrix and QC matrices from results
├── examples/
│   └── SraRunTable.example.csv     # Dataset used by run.sh --example
└── tests/
    └── test_pipeline.sh            # 65 unit tests (no external tools, no network)
```

**Separation of responsibilities.** `run.sh` parses flags, sources the modules
and calls four things in order: `build_all_references`, `parse_samples`,
`run_sample_loop`, `postprocess_all`. Every `steps/*.sh` file owns one stage
and exposes one `step_*` function; `steps/process_sample.sh` owns the order in
which they run and what happens when one fails. Cross-cutting concerns —
logging, aborts, downloads, disk accounting, cleanup, sample tracking,
prompting — live in `lib/` and are never re-implemented inside a step.
`lib/menu.sh` holds no pipeline logic at all: each option shells out to the
entry point flag that already implements it.

---

## Software requirements

All tools are pinned in `environment.yml`:

```bash
conda env create -f environment.yml
conda activate omniquant-seq
```

| Tool        | Version   | Role                                        |
|:------------|:----------|:--------------------------------------------|
| SRA-Toolkit | 3.0.0     | `prefetch`, `fasterq-dump` (SRA download)   |
| FastQC      | 0.12.1    | Per-sample quality control                  |
| MultiQC     | 1.14      | Per-sample and global aggregated QC report  |
| BBDuk (BBMap) | 39.81   | Adapter removal, quality trimming           |
| STAR        | 2.7.10a   | Splice-aware alignment (ENCODE protocol)    |
| RSEM        | 1.3.3     | TPM/FPKM quantification from BAM            |
| Python      | ≥ 3.9     | `helpers/parse_runtable.py`, `build_matrix.py` |
| openpyxl    | ≥ 3.0     | SRA RunTable parsing from `.xlsx`           |

`curl` or `wget` is used for reference downloads, whichever is available.

---

## Execution — step by step

### Step 0 — Configure compute resources

Run `bash pipeline/setup.sh --resources`, or edit `config/pipeline.sh`
directly. The defaults are conservative:

```bash
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

For each species with `active=true` in `config/species.sh`:

1. Downloads the genome FASTA and GTF from the URLs in `SPECIES_CONFIG`, or
   reuses the local files described below.
2. Decompresses both into `references/<species_key>/`.
3. Builds the STAR genome index (`STAR --runMode genomeGenerate`).
4. Prepares the RSEM reference (`rsem-prepare-reference`).

Species whose indexes already exist are skipped, so this is safe to re-run.
Both STAR and RSEM outputs are verified before the species is marked done.

**Local genome override.** A `*.fna.gz` plus a `*.gtf.gz` in the project root
is used in place of the download URLs — but only when exactly **one** species
is active, since a single pair of files cannot be assigned to several
organisms. With more than one active species the local files are ignored, with
a warning, and each genome is downloaded from its own URL. Files you supply are
never deleted.

> **Index size** depends on genome size (typically several GB per species). The
> genome FASTA and GTF are kept under `references/<species_key>/` for
> re-indexing.

### Step 2 — Prepare the sample list *(automatic)*

`parse_samples.sh` calls `helpers/parse_runtable.py` when `run.sh` starts,
passing the active species from `config/species.sh` so that only organisms you
have references for reach `samples.tsv`. To run it in isolation:

```bash
python3 pipeline/helpers/parse_runtable.py \
    --input   SraRunTable.csv \
    --output  samples.tsv \
    --species Helicoverpa_armigera
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

Per-sample steps for each accession in `samples.tsv`:

```
prefetch → fastq-dump/fasterq-dump → FastQC (raw) → BBDuk
→ FastQC (clean) → MultiQC (per sample) → STAR → RSEM → cleanup
```

The loop is **idempotent**: completed samples are skipped based on the
`pipeline_sample_summary.tsv` tracker, not just on the presence of output
files, so an interrupted run resumes from the last incomplete sample.

**Retry logic:** a failed sample is retried on the next pass, up to
`PIPELINE_RETRY_PASSES` complete passes over `samples.tsv`. A sample that stops
early records the stage that failed (`FAILED`) and `NA` for the stages that
never ran.

**Data safety:** whatever the failed stage half-wrote — truncated FASTQ, partial
BAM, incomplete `genes.results` — is deleted before the retry, so no pass ever
reads a partial file as if it were complete. `Ctrl-C` (SIGINT) and SIGTERM do
the same for the sample in flight, then exit 130. Only one run at a time is
allowed: a second `run.sh` in the same directory aborts on the `flock` held at
`pipeline/tmp/pipeline.lock`, instead of two pipelines overwriting each other's
intermediates.

### Step 4 — Post-processing *(automatic at end of run)*

`postprocess_all` runs after the sample loop. To run it manually:

```bash
python3 pipeline/helpers/build_matrix.py \
    --rsem-dir   pipeline/results/rsem \
    --output     pipeline/results/tables/gene_expression_matrix.tsv \
    --star-logs  pipeline/logs/ \
    --bbduk-logs pipeline/logs/ \
    --star-out   pipeline/results/tables/STAR_mapping_QC_matrix.tsv \
    --bbduk-out  pipeline/results/tables/BBDUK_preprocessing_QC_matrix.tsv
```

### Step 5 — Expression matrix preview *(automatic at end of run)*

`--test`, `--full` and `--example` all end by printing the head of the inner
join, so a run finishes with visible evidence that the matrix has data:

```
[INFO] Preview of gene_expression_matrix.tsv (inner join of all samples)
       Showing first 10 lines. Use your editor or tools like head,
       tail, awk or visidata for full exploration.
------------------------------------------------------------
gene_id  SRR29271587_TPM  SRR29271587_FPKM
...
------------------------------------------------------------
```

Set `PREVIEW_LINES` in `config/pipeline.sh` to change how much is shown, and
`ENABLE_PREVIEW=false` (or `run.sh --no-preview`) to turn it off. A missing
matrix prints a `[WARN]` and never aborts the run.

---

## Adding an organism

Nothing in the pipeline is tied to a taxon. To process a different organism:

1. **Declare the species.** Easiest path — option `[2]` of the menu, or
   directly:

   ```bash
   bash pipeline/setup.sh --add-species
   ```

   or add the entry to `config/species.sh` by hand:

   ```
   "species_key|genome_fna_gz_url|genome_gtf_gz_url|active"
   ```

   - `species_key` is `Genus_species` (underscore-separated) and names the
     subdirectory under `references/`.
   - Both URLs must point to gzip-compressed NCBI files (`.fna.gz`, `.gtf.gz`).

2. **Match the RunTable.** `parse_runtable.py` derives the same
   `Genus_species` key from the RunTable's `Organism` column, so samples are
   routed automatically as long as `species_key` equals the scientific name
   with an underscore. No Python editing.

3. **Handle missing organism metadata.** For single-species datasets, or when
   `Organism` is empty or ambiguous, set `SPECIES_FALLBACK` in
   `config/pipeline.sh` (or pass `--fallback Genus_species`).

4. **Tune organism-specific parameters.** In particular `STAR_OVERHANG`
   (`read length − 1`) and `STAR_SA_INDEX_NBASES`
   (`min(14, log2(genome length)/2 − 1)` for small genomes). See
   [Configuration reference](#configuration-reference).

5. **Build the indexes:** `bash pipeline/run.sh --build-refs`.

### Additional species examples

Ready-to-paste entries for other organisms. Append any of them to
`SPECIES_CONFIG` in `config/species.sh`, or feed the two URLs to
`setup.sh --add-species`.

<details>
<summary>Lepidoptera (the pipeline's original use case)</summary>

```bash
"Spodoptera_frugiperda|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/023/101/765/GCF_023101765.2_AGI-APGP_CSIRO_Sfru_2.0/GCF_023101765.2_AGI-APGP_CSIRO_Sfru_2.0_genomic.fna.gz|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/023/101/765/GCF_023101765.2_AGI-APGP_CSIRO_Sfru_2.0/GCF_023101765.2_AGI-APGP_CSIRO_Sfru_2.0_genomic.gtf.gz|\
true"

"Plutella_xylostella|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/932/276/165/GCF_932276165.2_ilPluXylo3.2/GCF_932276165.2_ilPluXylo3.2_genomic.fna.gz|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/932/276/165/GCF_932276165.2_ilPluXylo3.2/GCF_932276165.2_ilPluXylo3.2_genomic.gtf.gz|\
true"

"Bombyx_mori|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/030/269/925/GCF_030269925.1_ASM3026992v2/GCF_030269925.1_ASM3026992v2_genomic.fna.gz|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/030/269/925/GCF_030269925.1_ASM3026992v2/GCF_030269925.1_ASM3026992v2_genomic.gtf.gz|\
true"

"Diatraea_saccharalis|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/918/026/875/GCA_918026875.4_PGI_DIATSA_v4/GCA_918026875.4_PGI_DIATSA_v4_genomic.fna.gz|\
https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/918/026/875/GCA_918026875.4_PGI_DIATSA_v4/GCA_918026875.4_PGI_DIATSA_v4_genomic.gtf.gz|\
true"
```

</details>

Genome and annotation URLs for any other organism come from the same place:
the NCBI Genomes FTP directory of the assembly you want, taking the
`*_genomic.fna.gz` and `*_genomic.gtf.gz` files.

---

## Output files

```
pipeline/results/
├── rsem/
│   └── <species_key>/
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
├── <SRR>_prefetch_<n>.log
├── <SRR>_bbduk.log
├── <SRR>_star.log
├── <SRR>_STAR_Log.final.out
└── <SRR>_rsem.log

fastqc_out/                           # FastQC HTML + ZIP (project root)
```

`run.sh` also creates `sra/`, `fastq/` and `clean_fastq/` at the project root
for intermediate data; these are emptied by the cleanup steps as each sample
completes.

`gene_expression_matrix.tsv` contains all samples as columns and only genes
present in every sample (inner join). Its leading `expected_count` and
`effective_length` columns are copied from the first file in which each gene
appears and should not be read as any single sample's values; for per-sample
counts use the individual `genes.results` files.

---

## Sample tracker

`pipeline_sample_summary.tsv` records the status of each stage per sample.
Columns (as written by `lib/sample_tracker.sh`):

| Column | Values |
|:-------|:-------|
| `sample` | Run accession |
| `species` | Species key |
| `layout` | `PAIRED` or `SINGLE` |
| `test_mode` | `true` or `false` |
| `test_reads` | Number of reads in test mode |
| `prefetch_status` | `OK`, `FAILED`, `NA` |
| `fastq_status` | `OK`, `FAILED`, `NA` |
| `trimming_status` | `OK`, `FAILED`, `NA` |
| `star_status` | `OK`, `FAILED`, `NA` |
| `rsem_status` | `OK`, `FAILED`, `NA` |
| `genes_results` | Path to the RSEM gene table, or `NA` |

`NA` means the stage never ran because an earlier one failed. Updates are
written atomically (`awk > tmp && mv tmp real`) so an interrupted run cannot
corrupt the file.

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

Set any flag to `false` to retain intermediate files for debugging. `--example`
sets all three to `false` automatically.

> `cleanup_on_error` is defined in `lib/cleanup.sh` but is **not** wired into
> the sample loop: partial outputs from a failed sample are left in place for
> inspection rather than deleted automatically.

`disk_usage` in `lib/utils.sh` logs free space before each heavy step and warns
(non-fatally) when it drops below `DISK_WARN_GB`.

---

## Testing

```bash
bash pipeline/tests/test_pipeline.sh
```

69 unit tests, no bioinformatics tool and no network access required:

- `normalize_layout` — 8 input variants (PE, SE, Paired-End, …)
- `require_file` — missing file aborts, existing file passes
- `species_config` — entry splitting, active-key filtering, upsert
  (add vs. update), save/load round-trip, index lookup
- `detect_inputs` — RunTable detection, local genome override with one active
  species, override *ignored* with several, ambiguous RunTable aborts,
  references optional
- `parse_runtable.py` — row count, accession, layout, species-key derivation,
  non-example organism, `--species` filtering, `--fallback`
- `examples/SraRunTable.example.csv` — parses to exactly one usable sample
- `parse_samples` — restriction to the active `SPECIES_CONFIG` species
- CLI — both `--help` screens document every mode, both scripts reject unknown
  flags
- interactive menu — invalid answers are rejected and re-asked, `[7]` exits,
  closed stdin ends the loop instead of spinning on EOF
- expression matrix preview — header, `PREVIEW_LINES`, `ENABLE_PREVIEW=false`,
  missing matrix warns without aborting
- failure cleanup — a failed stage drops its own partial FASTQ and RSEM output,
  leaves other samples alone, and records the failed stage in the tracker
- `bash -n` over every shell script in the repository

Expected output:

```
Results: 69 passed, 0 failed.
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
| `PIPELINE_RETRY_PASSES` | `3` | Full retry passes over the sample list |
| `STAR_OVERHANG` | `99` | `sjdbOverhang` (read length − 1) |
| `STAR_SA_INDEX_NBASES` | `12` | `genomeSAindexNbases` (reduce for small genomes) |
| `BBDUK_QTRIM` | `rl` | Quality trimming direction |
| `BBDUK_TRIMQ` | `10` | Quality trimming threshold |
| `BBDUK_MINLEN` | `36` | Minimum read length after trimming |
| `BBDUK_REF` | `""` | Adapter FASTA — empty disables adapter clipping |
| `EXAMPLE_SPECIES` | `Helicoverpa_armigera` | Species used by `run.sh --example` |
| `EXAMPLE_READS` | `25000` | Reads per sample in `--example` |
| `ENABLE_PREVIEW` | `true` | Print the expression matrix head when a run ends |
| `PREVIEW_LINES` | `10` | Lines shown by that preview |

STAR alignment flags follow the ENCODE long-RNA-seq protocol and are collected
in one array at the top of `steps/align.sh`.

### `config/species.sh`

Each entry in `SPECIES_CONFIG`:

```
"species_key|genome_fna_gz_url|genome_gtf_gz_url|active"
```

- `species_key` names the subdirectory under `references/` and must equal the
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
