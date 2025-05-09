#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    mgenottate
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Github : https://github.com/maxibor/mgenottate
----------------------------------------------------------------------------------------
*/

nextflow.enable.dsl = 2


include { validateParameters; paramsSummaryLog; samplesheetToList } from 'plugin/nf-schema'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES AND SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { INITIALISE             } from './subworkflows/local/initialise'
include { GUNZIP                 } from './modules/nf-core/gunzip/main'
include { BUSCO_BUSCO            } from './modules/nf-core/busco/busco'
include { RESHAPE_DF             } from './modules/local/reshape_df'
include { DREP_DEREPLICATE       } from './modules/local/drep/dereplicate'
include { CONTIG_CONCAT          } from './modules/local/contig_concat'
include { CAT_CAT                } from './modules/nf-core/cat/cat'
include { MMSEQS_CONTIG_TAXONOMY } from './subworkflows/nf-core/mmseqs_contig_taxonomy'
include { MERGE_TABLES           } from './modules/local/merge_tables'
include { GTDBTK_CLASSIFYWF      } from './modules/nf-core/gtdbtk/classifywf/main'  

// Print parameter summary log to screen before running
log.info paramsSummaryLog(workflow)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NAMED WORKFLOW FOR PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow MGENOTTATE {

    ch_versions = Channel.empty()

    INITIALISE()

    ch_busco_db = params.busco_db ? Channel.fromPath(params.busco_db).first() : []

    ch_input = Channel.fromList(samplesheetToList(params.input, "assets/schema_input.json"))

    ch_input
        .map { 
            meta, genome_fa -> 
            def new_meta = meta + ['genome_name': genome_fa.simpleName]
            tuple(new_meta, genome_fa) 
            }
        .set { ch_input }

    ch_input
        .branch {
            compressed:   it[1].toString().tokenize(".")[-1] == 'gz'
            decompressed: it[1].toString().tokenize(".")[-1] != 'gz'
        }
        .set { genomes_fork }
  

    GUNZIP (
        genomes_fork.compressed
    )

    GUNZIP.out.gunzip
        .mix (genomes_fork.decompressed)
        .set { ch_genomes }

    BUSCO_BUSCO (
        ch_genomes,
        params.busco_mode,
        params.busco_lineage,
        ch_busco_db,
        [],
        []
    )

    BUSCO_BUSCO.out.batch_summary
        .splitCsv(skip: 1, sep: '\t')
        .map {meta, busco -> [meta, "${busco[0]},${busco[2]},${busco[4]}"] }
        .collectFile(newLine: true, seed: "genome,completeness,contamination"){
            meta, busco_summary -> 
                ["${meta.id}.busco_summary.tsv", busco_summary]
        }
        .map {
            it -> [['id': it.simpleName], it]
        }
        .set { ch_busco_summaries }
    

    DREP_DEREPLICATE (
        ch_busco_summaries.join(
            ch_genomes.map { 
                meta, genome -> 
                tuple(meta.subMap(['id']), genome)
            }.groupTuple()
        )
    )
    
   // Define mash DB channel safely


// Use the channel in your GTDBTK_CLASSIFYWF process
   GTDBTK_CLASSIFYWF (
    DREP_DEREPLICATE.out.dereplicated_genomes,
    tuple(params.gtdbtk_db_name, file(params.gtdbtk_db_path)),
    params.gtdbtk_use_pplacer_scratch_dir ?: false,
    []
)

    CONTIG_CONCAT (
        DREP_DEREPLICATE.out.dereplicated_genomes.transpose()
    )

    CAT_CAT (
        CONTIG_CONCAT.out.fasta.groupTuple()
    )

    if (params.skip_tax_annotation == false) {
        MMSEQS_CONTIG_TAXONOMY (
            CAT_CAT.out.file_out,
            params.mmseqs2_db_path,
            params.mmseqs2_db_name
        )
        tax_annot = MMSEQS_CONTIG_TAXONOMY.out.taxonomy
    } else {
        tax_annot = CAT_CAT.out.file_out.map { 
            meta, genome -> [meta, []]
        }
    }    

    MERGE_TABLES(
    DREP_DEREPLICATE.out.genomeInfo.join(
        DREP_DEREPLICATE.out.sdb
    ).join(
        DREP_DEREPLICATE.out.cdb
    ).join(
        tax_annot
    ).join(
        GTDBTK_CLASSIFYWF.out.summary
    )
     )
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
workflow {
    MGENOTTATE ()
}
