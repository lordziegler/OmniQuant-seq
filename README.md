# OmniQuant-seq

**RNA-seq expression pipeline for any organism with a genome and an annotation.**

Give it an NCBI SRA RunTable and it returns a per-gene expression matrix (TPM
and FPKM), going through download, QC, trimming, alignment and quantification
without further input. Target organisms are declared in a config file; adding
one takes two URLs and no code change.

*Helicoverpa armigera* ships as the worked example — it is the species in
`config/species.sh`, the dataset behind `run.sh --example`, and the organism in
the tests. Anything with a genome FASTA and a GTF works the same way.

**Institution:** Universidad de Nariño · **PI:** Juan Sebastián Zambrano

---

## Quick start

```bash
conda env create -f environment.yml
conda activate omniquant-seq

bash run.sh --example    # bundled demo, 1 sample, 25k reads
bash run.sh --help       # every mode, with current defaults
bash run.sh              # interactive menu
```

Everything is relative to the **working directory**: the RunTable is looked up
there, and `sra/`, `fastq/`, `clean_fastq/`, `fastqc_out/`, `references/`,
`results/`, `logs/` and `tmp/` are created there. The commands above assume you
are in the repository root. To keep data out of the checkout, `cd` to your data
directory and call the entry point by path:

```bash
cd ~/my-experiment && bash ~/OmniQuant-seq/run.sh --full
```

For your own dataset: put one RunTable in the working directory, then

```bash
bash setup.sh            # threads, RAM, species  (or edit the two config files)
bash run.sh --build-refs # genome indexes, once per species
bash run.sh --test       # smoke test on limited reads
bash run.sh --full       # production run
```

---

## What it runs

| Stage | Tool | Version | Output |
|:--|:--|:--|:--|
| Download | SRA-Toolkit (`prefetch`, `fastq-dump`, `fasterq-dump`) | 3.0.0 | `.sra` → FASTQ |
| Quality | FastQC | 0.12.1 | Per-sample QC, before and after trimming |
| Trimming | BBDuk (BBMap) | 39.81 | Quality-trimmed FASTQ |
| Alignment | STAR | 2.7.10a | Genome BAM + transcriptome BAM |
| Quantification | RSEM | 1.3.3 | `genes.results`, `isoforms.results` |
| QC report | MultiQC | 1.14 | Per-sample and global reports |
| Aggregation | Python + openpyxl | ≥ 3.9 / ≥ 3.0 | Expression matrix + QC matrices |

All pinned in `environment.yml`. Reference downloads use `curl` or `wget`,
whichever is present. `flock` (util-linux) is used for the run lock when
available; without it a run simply starts unlocked.

STAR runs with the ENCODE long-RNA-seq options, collected in one array at the
top of `steps/align.sh`.

---

## CLI

### `run.sh`

| Mode | What it does |
|:--|:--|
| *(none)* | Menu on a terminal; otherwise a normal run using `TEST_MODE` |
| `--build-refs` | Genome + GTF download and STAR/RSEM indexes, then exit. No RunTable needed |
| `--test` | Every sample, capped at `TEST_READS` reads each |
| `--full` | Every sample, all reads |
| `--example` | Bundled demo, see below |
| `-i`, `--interactive` | Force the menu even with other arguments |
| `--no-preview` | Skip the matrix preview at the end |
| `-h`, `--help` | Usage, current defaults, output locations |

### `setup.sh`

| Mode | What it does |
|:--|:--|
| *(none)* | Menu |
| `--resources` | Threads, RAM, storage |
| `--species` | Toggle, delete or add entries, with an optional download afterwards |
| `--add-species` | Add or update one species and fetch its reference files |

`--add-species` asks for a species key and the two URLs, validates them, writes
the entry to `config/species.sh`, then downloads and decompresses both files
into `references/<species_key>/`. If a download fails it says so and keeps the
config entry, so only the URL needs fixing.

The menu owns no logic of its own: every option shells out to the entry-point
flag that already implements it, so the two can never drift apart.

---

## The `--example` run

```bash
bash run.sh --example
```

One paired-end *H. armigera* run, `SRR29271587`
([PRJNA1119665](https://www.ncbi.nlm.nih.gov/bioproject/PRJNA1119665)), capped
at 25,000 spots, with the species forced regardless of what `config/species.sh`
has active. It goes through every stage and keeps the intermediates, so each
one can be inspected.

```
results/tables/gene_expression_matrix.tsv        TPM + FPKM for SRR29271587
results/tables/STAR_mapping_QC_matrix.tsv        STAR Log.final.out metrics
results/tables/BBDUK_preprocessing_QC_matrix.tsv BBDuk trimming stats
results/rsem/Helicoverpa_armigera/               gene- and isoform-level results
results/qc/multiqc/                              per-sample and global reports
results/pipeline_sample_summary.tsv              one row, all stages OK
logs/SRR29271587.log                             per-stage log
```

> Small, not instant: `prefetch` still pulls the whole ~620 MB archive, and the
> STAR/RSEM index is built first if missing (~10 GB, tens of minutes).

---

## Adding an organism

1. **Declare the species** — `bash setup.sh --add-species`, or append an entry
   to `SPECIES_CONFIG` in `config/species.sh`:

   ```
   "species_key|genome_fna_gz_url|genome_gtf_gz_url|active"
   ```

   `species_key` is `Genus_species`; it names the directory under `references/`
   and must equal the key `parse_runtable.py` derives from the RunTable's
   `Organism` column, which is how samples find their reference. Both URLs must
   point at gzip-compressed NCBI files — take `*_genomic.fna.gz` and
   `*_genomic.gtf.gz` from the assembly's Genomes FTP directory. Set
   `active=false` to skip a species without deleting its entry.

2. **If `Organism` is empty or unreliable** (common in single-species datasets),
   set `SPECIES_FALLBACK` in `config/pipeline.sh`, or pass
   `--fallback Genus_species` to the parser.

3. **Tune the organism-specific knobs** — `STAR_OVERHANG` (read length − 1) and,
   for small genomes, `STAR_SA_INDEX_NBASES` (`min(14, log2(genome length)/2 − 1)`).

4. **Build the indexes** — `bash run.sh --build-refs`. Species already built are
   skipped, so it is safe to re-run.

**Local genome override.** A `*.fna.gz` plus a `*.gtf.gz` in the working
directory replaces the download URLs, but only when exactly one species is
active — one pair of files cannot be assigned to several organisms, and using
them for all would silently quantify every species against one genome. With
more than one active species they are ignored with a warning. Files you supply
are never deleted.

<details>
<summary>Ready-to-paste entries: Lepidoptera (the original use case)</summary>

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

---

## The sample list

`run.sh` calls `helpers/parse_runtable.py` at startup, passing the active
species so only organisms you have references for reach `samples.tsv`. It reads
`.csv` or `.xlsx`, keeps `RNA-Seq` records whose `LibrarySource` is
`TRANSCRIPTOMIC` or `GENOMIC` (falling back to all RNA-Seq rows, with a
warning, if none pass), derives the `Genus_species` key from `Organism`,
deduplicates by accession, validates it against `^[SED]RR\d+$`, and writes
three columns: `SRR`, `SPECIES`, `LAYOUT`.

Worth reviewing before a full run. To produce it on its own:

```bash
python3 helpers/parse_runtable.py \
    --input   SraRunTable.csv \
    --output  samples.tsv \
    --species Helicoverpa_armigera
```

---

## Running, failing and resuming

Per sample:

```
prefetch → fastq-dump/fasterq-dump → FastQC (raw) → BBDuk
→ FastQC (clean) → MultiQC → STAR → RSEM → cleanup
```

The loop is idempotent. Completed samples are skipped based on the
`pipeline_sample_summary.tsv` tracker rather than on the presence of output
files, so an interrupted run resumes where it stopped. A failed sample is
retried on the next of `PIPELINE_RETRY_PASSES` passes over `samples.tsv`; it
records the stage that failed as `FAILED` and `NA` for the stages that never
ran because of it.

Whatever a failed stage half-wrote — truncated FASTQ, partial BAM, incomplete
`genes.results` — is deleted before the retry, so no pass mistakes a partial
file for a complete one. `Ctrl-C` and `SIGTERM` do the same for the sample in
flight, then exit 130.

Only one run at a time per directory: a second `run.sh` aborts on the `flock`
held at `tmp/pipeline.lock` instead of overwriting the first one's
intermediates.

### Disk

Intermediates are deleted as soon as the next step confirms its output:

| `lib/cleanup.sh` | Deletes | Freed per sample |
|:--|:--|:--|
| `cleanup_sra` | `.sra` archive + prefetch directory | 1–5 GB |
| `cleanup_raw_fastq` | Uncompressed raw FASTQ | 2–10 GB |
| `cleanup_clean_fastq` | Trimmed `.fastq.gz` | 1–4 GB |
| `cleanup_star_tmp` | STAR temporary directory | 2–8 GB |
| `cleanup_rsem_bam` | `.transcript.bam` | 10–60 GB |
| `cleanup_rsem_tmp` | RSEM temporary directory | variable |

Set `CLEAN_SRA_AFTER_FASTQ`, `CLEAN_RAW_FASTQ_AFTER_RSEM` or
`CLEAN_FASTQ_AFTER_RSEM` to `false` to keep them; `--example` does this for all
three. `disk_usage` logs free space before each heavy step and warns below
`DISK_WARN_GB` without aborting.

---

## Output

```
results/
├── rsem/<species_key>/
│   ├── <SRR>.genes.results           # TPM, FPKM, expected_count (gene level)
│   └── <SRR>.isoforms.results        # same, isoform level
├── qc/multiqc/
│   ├── <SRR>/                        # per-sample report (clean reads)
│   └── global/                       # raw + clean across all samples
├── tables/
│   ├── gene_expression_matrix.tsv    # inner join of every genes.results
│   ├── STAR_mapping_QC_matrix.tsv    # Log.final.out metrics × samples
│   └── BBDUK_preprocessing_QC_matrix.tsv
├── samples.tsv                       # SRR, SPECIES, LAYOUT
└── pipeline_sample_summary.tsv       # per-sample status tracker

logs/            <SRR>.log plus one log per tool and per attempt
fastqc_out/      FastQC HTML + ZIP
```

`gene_expression_matrix.tsv` has samples as columns and only genes present in
**every** sample. Its leading `expected_count` and `effective_length` columns
come from the first file each gene appears in and are not any one sample's
values — for per-sample counts, read the individual `genes.results`.

The tracker records `sample`, `species`, `layout`, `test_mode`, `test_reads`,
one column per stage (`OK` / `FAILED` / `NA`) and the path to the RSEM gene
table. `NA` means the stage never ran because an earlier one failed. Rows are
rewritten atomically, so an interrupted run cannot corrupt the file.

A run ends by printing the head of the matrix, as evidence the inner join
produced data. `PREVIEW_LINES` controls how much; `ENABLE_PREVIEW=false` or
`--no-preview` turns it off. A missing matrix warns and never aborts.

To rebuild the tables without re-running anything:

```bash
python3 helpers/build_matrix.py \
    --rsem-dir   results/rsem \
    --output     results/tables/gene_expression_matrix.tsv \
    --star-logs  logs/ --bbduk-logs logs/ \
    --star-out   results/tables/STAR_mapping_QC_matrix.tsv \
    --bbduk-out  results/tables/BBDUK_preprocessing_QC_matrix.tsv
```

---

## Configuration

`config/pipeline.sh` — edit directly or through `setup.sh --resources`.

| Variable | Default | Description |
|:--|:--|:--|
| `THREADS_DOWNLOAD` | `8` | `fasterq-dump` threads |
| `THREADS_FASTQC` | `8` | FastQC threads |
| `THREADS_TRIM` | `8` | BBDuk threads |
| `THREADS_STAR` | `8` | STAR threads |
| `THREADS_RSEM` | `8` | RSEM threads |
| `MAX_MEMORY_GB` | `32` | STAR `--limitBAMsortRAM` |
| `MAX_SRA_SIZE` | `100G` | `prefetch --max-size` |
| `DISK_WARN_GB` | `20` | Free-space warning threshold |
| `SPECIES_FALLBACK` | `""` | Key for rows with no usable `Organism` |
| `TEST_MODE` / `TEST_READS` | `false` / `100000` | Test mode and its read cap |
| `PREFETCH_RETRIES` / `PREFETCH_RETRY_SLEEP` | `5` / `30` | Download attempts, seconds between |
| `PIPELINE_RETRY_PASSES` | `3` | Passes over the sample list |
| `STAR_OVERHANG` | `99` | `sjdbOverhang`, read length − 1 |
| `STAR_SA_INDEX_NBASES` | `12` | `genomeSAindexNbases`, lower for small genomes |
| `BBDUK_QTRIM` / `BBDUK_TRIMQ` / `BBDUK_MINLEN` | `rl` / `10` / `36` | Trimming direction, threshold, minimum length |
| `BBDUK_REF` | `""` | Adapter FASTA; empty disables adapter clipping |
| `EXAMPLE_SPECIES` / `EXAMPLE_READS` | `Helicoverpa_armigera` / `25000` | Used by `--example` |
| `ENABLE_PREVIEW` / `PREVIEW_LINES` | `true` / `10` | End-of-run matrix preview |

---

## Repository layout

```
OmniQuant-seq/
├── run.sh                    # entry point: parses the CLI, delegates
├── setup.sh                  # interactive configurator
├── config/
│   ├── pipeline.sh           # resources, paths, flags, retries
│   └── species.sh            # SPECIES_CONFIG[]: genome + GTF URLs per species
├── lib/
│   ├── utils.sh              # die, log_step, check_tools, disk_usage, downloads
│   ├── menu.sh               # interactive menu shared by both entry points
│   ├── prompt.sh             # validated input helpers
│   ├── species_config.sh     # read/modify/write config/species.sh
│   ├── cleanup.sh            # intermediate-file deletion, per step and on failure
│   └── sample_tracker.sh     # atomic per-sample status TSV
├── steps/                    # one stage per file, one step_* function each
│   ├── validate_inputs.sh    # RunTable and local genome override
│   ├── build_references.sh   # genome/GTF → STAR index + RSEM reference
│   ├── parse_samples.sh      # → samples.tsv
│   ├── prefetch.sh           # SRA download with retries
│   ├── fastq_dump.sh         # SRA → FASTQ
│   ├── fastqc.sh             # FastQC + MultiQC
│   ├── trim.sh               # BBDuk
│   ├── align.sh              # STAR (ENCODE options)
│   ├── quantify.sh           # RSEM
│   ├── process_sample.sh     # stage order, failure handling, retry passes
│   └── postprocess.sh        # matrices, global MultiQC, preview
├── helpers/
│   ├── parse_runtable.py     # RunTable (CSV/XLSX) → samples.tsv
│   └── build_matrix.py       # results → expression and QC matrices
├── examples/
│   └── SraRunTable.example.csv
└── tests/
    └── test_pipeline.sh      # 69 unit tests, no external tools, no network
```

`run.sh` parses flags and calls four functions in order: `build_all_references`,
`parse_samples`, `run_sample_loop`, `postprocess_all`. `steps/process_sample.sh`
decides the order stages run in and what happens when one fails; the
cross-cutting concerns — logging, aborts, downloads, disk accounting, cleanup,
tracking — live in `lib/` and are never reimplemented inside a step.

---

## Testing

```bash
bash tests/test_pipeline.sh
# Results: 69 passed, 0 failed.
```

No bioinformatics tool and no network access required. Covers layout
normalisation, the species config module, RunTable and local-genome detection,
`parse_runtable.py` including `--species` and `--fallback`, both `--help`
screens and unknown-flag rejection, the interactive menu, the matrix preview,
the partial-output cleanup on failure, and `bash -n` over every script.

---

## References

- Andrews, S. (2010). *FastQC: a quality control tool for high throughput sequence data*. https://www.bioinformatics.babraham.ac.uk/projects/fastqc/
- Bushnell, B. (2014). *BBMap: a fast, accurate, splice-aware aligner*. LBNL-7065E. https://sourceforge.net/projects/bbmap/
- Dobin, A., Davis, C. A., Schlesinger, F., et al. (2013). STAR: ultrafast universal RNA-seq aligner. *Bioinformatics*, 29(1), 15–21. https://doi.org/10.1093/bioinformatics/bts635
- Ewels, P., Magnusson, M., Lundin, S., & Käller, M. (2016). MultiQC: summarize analysis results for multiple tools and samples in a single report. *Bioinformatics*, 32(19), 3047–3048. https://doi.org/10.1093/bioinformatics/btw354
- Leinonen, R., Sugawara, H., & Shumway, M. (2011). The Sequence Read Archive. *Nucleic Acids Research*, 39(Database issue), D19–D21. https://doi.org/10.1093/nar/gkq1019
- Li, B., & Dewey, C. N. (2011). RSEM: accurate transcript quantification from RNA-Seq data with or without a reference genome. *BMC Bioinformatics*, 12, 323. https://doi.org/10.1186/1471-2105-12-323
- NCBI SRA Toolkit. https://github.com/ncbi/sra-tools
- STAR alignment options follow the ENCODE long-RNA-seq settings documented in the STAR manual (§ *ENCODE options*). https://github.com/alexdobin/STAR

---

## License

MIT — see [LICENSE](LICENSE).
