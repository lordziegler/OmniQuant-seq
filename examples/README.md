# Example dataset

`SraRunTable.example.csv` is the RunTable used by `bash pipeline/run.sh --example`.

| Field | Value |
|:--|:--|
| Run | `SRR29271587` |
| Organism | *Helicoverpa armigera* |
| BioProject | [PRJNA1119665](https://www.ncbi.nlm.nih.gov/bioproject/PRJNA1119665) |
| Layout | PAIRED |
| Platform | BGISEQ-500 |
| Spots | 10,463,542 (~1.59 Gbase) |
| SRA archive | ~620 MB |

The example run reads only the first 25,000 spots (`fastq-dump -X`), but
`prefetch` still downloads the whole SRA archive, so budget ~1 GB of transfer
plus the *H. armigera* reference index (~10 GB) the first time.

This RunTable has the same column names as an NCBI SRA Run Selector export, so
it also works as a template for your own dataset.
