version 1.0

workflow runNucFreq {

    input {
        File input_bam
        File input_bam_bai
        File regions_bed
        File assembly_fasta
    }

    meta {
        description: "Calls NucFreq to identify regions in assembly with unexpected heterozygosity. See [NucFreq's documentation](https://github.com/mrvollger/NucFreq)"
    }
    
    parameter_meta {
        input_bam: "HiFi or ONT reads for a sample aligned to the sample's diploid assembly with Winnowmap or minimap2"
        input_bam_bai: "Index file for the input_bam"
        assembly_fasta: "Assembly that reads were aligned against. Can be fasta, fasta.gz, fa, or ga.gz. Used for creating genome regions to split."
        regions_bed: "Bed file of regions in which to output NucFreq plots"
    }


    call filter_bam {
        input:
            input_bam      = input_bam,
            input_bam_bai  = input_bam_bai
    }

    ## Call nucreq in just regions_bed to get nucfreq plots
    call nucfreq {
        input:
            input_bam     = filter_bam.nucfreq_filt_bam,
            input_bam_bai = filter_bam.nucfreq_filt_bam_bai,
            regions_bed   = regions_bed
    } 


    call create_genome_bed {
        input:
            inputFasta = assembly_fasta
    }

    ## Call nucfreq using rustybam to get just bed files from large
    ## genomic segments (which cause tradtional nucfreq to crash).
    call nucfreq_bed_only {
        input:
            input_bam     = filter_bam.nucfreq_filt_bam,
            input_bam_bai = filter_bam.nucfreq_filt_bam_bai,
            regions_bed   = create_genome_bed.genome_bed
    }

    call filter_nucfreq {
        input:
            nucfreq_loci_bed = nucfreq_bed_only.nucfreq_bed
    }

    call bedgraph_to_bigwig as first_allele_bw {
        input:
            bedgraph    = nucfreq_bed_only.nucfreq_first_bedgraph,
            chrom_sizes = create_genome_bed.chrom_sizes
    }
     
    call bedgraph_to_bigwig as second_allele_bw {
        input:
            bedgraph    = nucfreq_bed_only.nucfreq_second_bedgraph,
            chrom_sizes = create_genome_bed.chrom_sizes
    }       

    output {
        ## If regions were passed as inputs
        File nucplot_image_tar        = nucfreq.nucplot_images
        File error_clusters_bed       = filter_nucfreq.variant_clusters_bed        
        File first_allele_bigwig      = first_allele_bw.bigwig
        File second_allele_bigwig     = second_allele_bw.bigwig
    }
}

task filter_bam {
    input{
        File input_bam
        File input_bam_bai
        File? regions_bed 
        String sam_omit_flag = "2308"

        Int threadCount    = 8    
        Int memSizeGB      = 48
        Int addldisk       = 64    
        String dockerImage = "quay.io/biocontainers/samtools@sha256:9cd15e719101ae8808e4c3f152cca2bf06f9e1ad8551ed43c1e626cb6afdaa02" # 1.19.2--h50ea8bc_1
    }
    
    String file_prefix = basename(input_bam, ".bam")

    Int bam_size = ceil(size(input_bam, "GB"))
    Int final_disk_dize = 2*bam_size + addldisk

    command <<<

        # exit when a command fails, fail with unset variables, print commands before execution
        set -eux -o pipefail

        if [ ! -f "~{regions_bed}" ]
        then
            REGIONS_ARG=""
        else
            REGIONS_ARG="--regions-file ~{regions_bed}"
        fi

        samtools view \
            -F ~{sam_omit_flag}\
            --bam \
            --with-header \
            $REGIONS_ARG \
            --threads ~{threadCount} \
            -X ~{input_bam} ~{input_bam_bai} \
            -o ~{file_prefix}_nucfreq.bam

        samtools index \
            --threads ~{threadCount} \
            ~{file_prefix}_nucfreq.bam
  >>>  

  output {
    File nucfreq_filt_bam     = "~{file_prefix}_nucfreq.bam"
    File nucfreq_filt_bam_bai = "~{file_prefix}_nucfreq.bam.bai"
  }

  runtime {
    memory: memSizeGB + " GB"
    cpu: threadCount
    disks: "local-disk " + final_disk_dize + " SSD"
    docker: dockerImage
    preemptible: 1
  }
}

task nucfreq {
    input{
        File input_bam
        File input_bam_bai
        File regions_bed 

        String tag = ""
        String otherArgs   = ""

        Int threadCount    = 4   
        Int memSizeGB      = 32
        Int addldisk       = 64    
        String dockerImage = "humanpangenomics/nucfreq@sha256:6f2f981892567f2a8ba52ba20e87f98e6ca770ea3f4d5430bf67a26673c8f176" 
    }

    String file_prefix = basename(input_bam, ".bam")

    Int bam_size = ceil(size(input_bam, "GB"))
    Int final_disk_dize = bam_size + addldisk

    command <<<

        # exit when a command fails, fail with unset variables, print commands before execution
        set -eux -o pipefail

        ## soft link bam and bai to cwd so they are in the same directory
        ln -s ~{input_bam} input.bam
        ln -s ~{input_bam_bai} input.bam.bai

        # Split bed to one file per row. Run on one row at a time
        # Create a directory to store split BED files
        mkdir -p split_beds
        mkdir -p split_beds_out
        mkdir -p output_plots


        ## run nucfreq: find loci with heterozygosity; create plots for each region
        while IFS=$'\t' read -r chrom start end rest; do
            
            FILE_NAME="${chrom}_${start}_${end}.bed"
            echo -e "$chrom\t$start\t$end\t$rest" > "split_beds/$FILE_NAME"

            python /opt/nucfreq/NucPlot.py \
                -t ~{threadCount} \
                --bed "split_beds/$FILE_NAME" \
                --obed "split_beds_out/$FILE_NAME" \
                input.bam \
                "output_plots/~{file_prefix}_${chrom}_${start}_${end}.png" \
                ~{otherArgs}

        done < ~{regions_bed}

        
        # Process the first file fully, including the header
        head -n 1 split_beds_out/$(ls split_beds_out | head -n 1) > "~{file_prefix}_regions_loci.bed"

        # Concatenate the rest of the files without the header and then sort
        for file in split_beds_out/*.bed; do
            tail -n +2 "$file"
        done | sort -k1,1 -k2,2n >> "~{file_prefix}_regions_loci.bed"

        ## tar.gz individual plots 
        tar -czvf "~{file_prefix}_plots.tar.gz" output_plots

  >>>  

  output {
    File nucfreq_loci_bed = "~{file_prefix}_regions_loci.bed"
    File nucplot_images   = "~{file_prefix}_plots.tar.gz"
  }

  runtime {
    memory: memSizeGB + " GB"
    cpu: threadCount
    disks: "local-disk " + final_disk_dize + " SSD"
    docker: dockerImage
    preemptible: 1
  }
}

task define_genome_split_beds {
    input{
        File inputFasta
        
        Int region_size    = 50000000

        Int threadCount    = 2   
        Int memSizeGB      = 16
        Int diskSize       = 32
        String dockerImage = "quay.io/biocontainers/samtools@sha256:9cd15e719101ae8808e4c3f152cca2bf06f9e1ad8551ed43c1e626cb6afdaa02" # 1.19.2--h50ea8bc_1
    }

    command <<<

        # exit when a command fails, fail with unset variables, print commands before execution
        set -eux -o pipefail

        inputFastaFN=$(basename -- "~{inputFasta}")

        ## first check if inputFasta needs to be unzipped
        if [[ $inputFastaFN =~ \.gz$ ]]; then
            cp ~{inputFasta} .
            gunzip -f $inputFastaFN
            inputFastaFN="${inputFastaFN%.gz}"
        else
            ln -s ~{inputFasta}
        fi 

        ## get contig/scaffold sizes from genome assembly
        samtools faidx "$inputFastaFN" 
        cut -f1,2 "${inputFastaFN}.fai" > sizes.genome

        mkdir genomic_windows

        ## split genome into regions; output bed file for each region (to scatter on)
        while IFS=$'\t' read -r CHROM SIZE; do
        
            # find number of windows. Add 1 if there is a remainder.
            NUMWINS=$((SIZE / ~{region_size} + (SIZE % ~{region_size} > 0 ? 1 : 0)))

            for ((i=1; i<=NUMWINS; i++)); do
                START=$(( (i - 1) * ~{region_size} + 1 ))
                END=$(( i * ~{region_size} ))
                END=$(( END < SIZE ? END : SIZE ))

                FILE_NAME="${CHROM}_${START}_${END}.bed"
                echo -e "$CHROM\t$START\t$END\tchrom_split" > "genomic_windows/$FILE_NAME"
            done
        done < sizes.genome


  >>>  

  output {
    Array[File] genomic_windows_beds = glob("genomic_windows/*.bed")
    File chrom_sizes = "sizes.genome"
  }

  runtime {
    memory: memSizeGB + " GB"
    cpu: threadCount
    disks: "local-disk " + diskSize + " SSD"
    docker: dockerImage
    preemptible: 1
  }
}

task create_genome_bed {
    input{
        File inputFasta

        Int threadCount    = 2   
        Int memSizeGB      = 16
        Int diskSize       = 32
        String dockerImage = "quay.io/biocontainers/samtools@sha256:9cd15e719101ae8808e4c3f152cca2bf06f9e1ad8551ed43c1e626cb6afdaa02" # 1.19.2--h50ea8bc_1
    }

    command <<<

        # exit when a command fails, fail with unset variables, print commands before execution
        set -eux -o pipefail

        inputFastaFN=$(basename -- "~{inputFasta}")

        ## first check if inputFasta needs to be unzipped
        if [[ $inputFastaFN =~ \.gz$ ]]; then
            cp ~{inputFasta} .
            gunzip -f $inputFastaFN
            inputFastaFN="${inputFastaFN%.gz}"
        else
            ln -s ~{inputFasta}
        fi 

        ## get contig/scaffold sizes from genome assembly
        samtools faidx "$inputFastaFN" 
        cut -f1,2 "${inputFastaFN}.fai" > sizes.genome

        awk 'BEGIN {OFS="\t"} {print $1, "0", $2}' sizes.genome > genome.bed
  >>>  

  output {
    File genome_bed  = "genome.bed"
    File chrom_sizes = "sizes.genome"
  }

  runtime {
    memory: memSizeGB + " GB"
    cpu: threadCount
    disks: "local-disk " + diskSize + " SSD"
    docker: dockerImage
    preemptible: 1
  }
}

task nucfreq_bed_only {
    input{
        File input_bam
        File input_bam_bai
        File regions_bed

        Int threadCount    = 8   
        Int memSizeGB      = 32
        Int addldisk       = 128    
        String dockerImage = "quay.io/biocontainers/rustybam@sha256:0c31acc94fe676fd7d853da74660187d9a146acbacb4266abd2ec559fd5641a3" # 0.1.33--h756b843_0
    }
    String file_prefix = basename(input_bam, ".bam")

    Int bam_size = ceil(size(input_bam, "GB"))
    Int final_disk_dize = bam_size + addldisk

    command <<<

        # exit when a command fails, fail with unset variables, print commands before execution
        set -eux -o pipefail

        ## soft link bam and bai to cwd so they are in the same directory
        ln -s ~{input_bam} input.bam
        cp ~{input_bam_bai} input.bam.bai ## copy to ensure index is newer than bam


        rustybam nucfreq \
            --bed ~{regions_bed} \
            input.bam \
            > mpileup.txt
        
        awk_prefix="~{file_prefix}"

        ## write nucfreq-style bed and bedgraphs for most frequent and second most frequent bases
        awk -v prefix="$awk_prefix" '{
            max = $4; second_max = 0; 
            for(i=5;i<=7;i++) {
                if($i > max) { second_max = max; max = $i; }
                else if($i > second_max) { second_max = $i; }
            }
            print $1, $2, $3, max             > $prefix"_first_uns.bedGraph";
            print $1, $2, $3, second_max      > $prefix"_second_uns.bedGraph";
            print $1, $2, $3, max, second_max > $prefix"_uns.bed";
        }' < mpileup.txt
        
        
        export LC_ALL=C

        sort -k1,1 -k2,2n ~{file_prefix}_first_uns.bedGraph  > ~{file_prefix}_first.bedGraph &
        sort -k1,1 -k2,2n ~{file_prefix}_second_uns.bedGraph > ~{file_prefix}_second.bedGraph &
        sort -k1,1 -k2,2n ~{file_prefix}_uns.bed             > ~{file_prefix}.bed &

        wait
  >>>

  output {
    File nucfreq_first_bedgraph  = "~{file_prefix}_first.bedGraph"
    File nucfreq_second_bedgraph = "~{file_prefix}_second.bedGraph"
    File nucfreq_bed             = "~{file_prefix}.bed"
  }

  runtime {
    memory: memSizeGB + " GB"
    cpu: threadCount
    disks: "local-disk " + final_disk_dize + " SSD"
    docker: dockerImage
    preemptible: 1
  }
}


task filter_nucfreq {
    input{
        File nucfreq_loci_bed

        String otherArgs   = ""

        Int threadCount    = 4   
        Int memSizeGB      = 16
        Int addldisk       = 32    
        String dockerImage = "rocker/verse@sha256:56e60da5b006e1406967e58ad501daaba567d6836029aee94ed16ba1965554f0" # 4.3.1
    }
    String file_prefix = basename(nucfreq_loci_bed, ".bed")

    Int bed_size = ceil(size(nucfreq_loci_bed, "GB"))
    Int final_disk_dize = bed_size + addldisk

    command <<<

        # exit when a command fails, fail with unset variables, print commands before execution
        set -eux -o pipefail

        wget https://raw.githubusercontent.com/emics57/nucfreqPipeline/21b3395a7f285962aae9e881db2514e03601c5db/nucfreq_filtering_migalab.R

        Rscript nucfreq_filtering_migalab.R \
            ~{nucfreq_loci_bed} \
            ~{file_prefix}_errors.bed \
            ~{otherArgs}
  >>>  

  output {
    File variant_clusters_bed = "~{file_prefix}_errors.bed"
  }

  runtime {
    memory: memSizeGB + " GB"
    cpu: threadCount
    disks: "local-disk " + final_disk_dize + " SSD"
    docker: dockerImage
    preemptible: 1
  }
}

task bedgraph_to_bigwig {
    input{
        File bedgraph
        File chrom_sizes

        Int threadCount    = 4    
        Int memSizeGB      = 12
        Int addldisk       = 64    
        String dockerImage = "quay.io/biocontainers/ucsc-bedgraphtobigwig@sha256:9a5a150acf6af3910d939396e928dc3d9468d974624eef7fc74ab6e450c12466"
    }
    
    String file_prefix = basename(bedgraph, ".bedGraph")

    Int bed_size = ceil(size(bedgraph, "GB"))
    Int final_disk_dize = bed_size + addldisk

    command <<<

        # exit when a command fails, fail with unset variables, print commands before execution
        set -eux -o pipefail

        bedGraphToBigWig ~{bedgraph} ~{chrom_sizes} ~{file_prefix}.bw
  >>>  

  output {
    File bigwig = "~{file_prefix}.bw"
  }

  runtime {
    memory: memSizeGB + " GB"
    cpu: threadCount
    disks: "local-disk " + final_disk_dize + " SSD"
    docker: dockerImage
    preemptible: 1
  }
}
