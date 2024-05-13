version 1.0

workflow RunFCS{
    input {
        File assembly
        
        File blast_div
        File GXI
        File GXS
        File manifest
        File metaJSON
        File seq_info
        File taxa

        String taxon_id="9606"

        Int threadCount
        Int preemptible = 1
        Int diskSizeGBGX  = 500
        Int diskSizeGBAdapter = 32
    }

    meta {
        author: "Hailey Loucks"
        email: "hloucks@ucsc.edu"
        description: "Runs NCBI FCS-GX and FCS-adapter https://doi.org/10.1101/2023.06.02.543519 on given assembly"
    }

    String GxDB = basename(GXI, ".gxi")
    String asm_name=basename(sub(sub(sub(assembly, "\\.gz$", ""), "\\.fasta$", ""), "\\.fa$", ""))

    call FCSGX {
        input:
            assembly=assembly,
            blast_div=blast_div,
            GXI=GXI,
            GXS=GXS,
            manifest=manifest,
            metaJSON=metaJSON,
            seq_info=seq_info,
            taxa=taxa,
            taxon_id=taxon_id,

            GxDB=GxDB,
            asm_name=asm_name,


            preemptible=preemptible,
            threadCount=threadCount,
            diskSizeGB=diskSizeGBGX
    }
    call FCS_adapter{
        input:
            GxCleanFasta = FCSGX.GxCleanFasta,
            asm_name=asm_name,


            preemptible=preemptible,
            threadCount=threadCount,
            diskSizeGB=diskSizeGBAdapter
    }

    output {
        ## GX outputs
        File intermediate_clean_fa = FCSGX.GxCleanFasta
        File contamFasta           = FCSGX.contamFasta
        File fcs_gx_report         = FCSGX.report
        File fcs_taxonomy_report   = FCSGX.taxonomy_report
        
        ## Adapter output
        File adapter_Report        = FCS_adapter.adapter_Report

        ## Final output
        File output_fasta          = FCS_adapter.cleanFasta
    }

    parameter_meta {
        assembly: "Gzipped assembly to be screened for genomic and adapter contamination"
        blast_div: "Required database file - download instructions https://github.com/ncbi/fcs/wiki/FCS-GX before running"
        GXI: "Required database file - download instructions https://github.com/ncbi/fcs/wiki/FCS-GX before running"
        GXS: "Required database file - download instructions https://github.com/ncbi/fcs/wiki/FCS-GX before running"
        manifest: "Required database file - download instructions https://github.com/ncbi/fcs/wiki/FCS-GX before running"
        metaJSON: "Required database file - download instructions https://github.com/ncbi/fcs/wiki/FCS-GX before running"
        seq_info: "Required database file - download instructions https://github.com/ncbi/fcs/wiki/FCS-GX before running"
        taxa: "Required database file - download instructions https://github.com/ncbi/fcs/wiki/FCS-GX before running"
    }


}

task FCSGX {
    input{
        File assembly
        File blast_div
        File GXI
        File GXS
        File manifest
        File metaJSON
        File seq_info
        File taxa
        String taxon_id

        String asm_name
        String GxDB

        Int memSizeGB = 550
        Int preemptible = 1
        Int diskSizeGB
        Int threadCount

    }
    command <<<
        #handle potential errors and quit early
        set -o pipefail
        set -e
        set -u
        set -o xtrace

        ln -s ~{blast_div}
        ln -s ~{GXI}
        ln -s ~{GXS}
        ln -s ~{manifest}
        ln -s ~{metaJSON}
        ln -s ~{seq_info}
        ln -s ~{taxa}

        ln -s ~{assembly}

        python3 /app/bin/run_gx --fasta ~{assembly} --gx-db ~{GxDB} --out-dir . --tax-id ~{taxon_id}
        zcat ~{assembly} | /app/bin/gx clean-genome --action-report *.~{taxon_id}.fcs_gx_report.txt --output ~{asm_name}.GXclean.fasta --contam-fasta-out ~{asm_name}.GXcontam.fasta 

        gzip ~{asm_name}.GXclean.fasta
        gzip ~{asm_name}.GXcontam.fasta
    
    >>>

    output {
        File GxCleanFasta    = "~{asm_name}.GXclean.fasta.gz"
        File contamFasta     = "~{asm_name}.GXcontam.fasta.gz"
        File gx_report       = glob("*.fcs_gx_report.txt")[0]
        File taxonomy_report = glob("*.taxonomy.rpt")[0]
        
    }

    runtime {
        memory: memSizeGB + " GB"
        disks: "local-disk " + diskSizeGB + " SSD"
        preemptible : preemptible
        docker: 'ncbi/fcs-gx:0.5.0'
    }
}

task FCS_adapter {
    input {
        File GxCleanFasta

        String asm_name

        Int memSizeGB = 48
        Int preemptible = 1
        Int diskSizeGB
        Int threadCount
    }
    command <<<

        #handle potential errors and quit early
        set -o pipefail
        set -e
        set -u
        set -o xtrace

        # Run the adapter script 

        /app/fcs/bin/av_screen_x -o . --euk ~{GxCleanFasta}
        mv cleaned_sequences/* ~{asm_name}.clean.fa # the output of FCS adapter is not actually gzipped

        rm -rf cleaned_sequences/

        gzip ~{asm_name}.clean.fa

        
    >>>

    output {
        File cleanFasta = "~{asm_name}.clean.fa.gz"
        File adapter_Report = "fcs_adaptor_report.txt"
    }

    runtime {
        memory: memSizeGB + " GB"
        preemptible : preemptible
        disks: "local-disk " + diskSizeGB + " SSD"
        docker: "ncbi/fcs-adaptor:0.5.0"
    }
}

