configfile: "config.yaml"

rule all:
    input:
        expand(config["data_folder"]+"/{cancer_type}/phased_vcf/chr{chr}.vcf.gz", cancer_type = config["cancer_types"], variant_type = config["variant_types"], chr = range(1,23))
        

# Filter variants botg in the SNP and INDEL vcf files, only keeping variants with a recalibrated variant quality score
# above 99.9
rule filter:
    input:
        config["input_vcf"]
    output:
        temp(config["data_folder"]+"/{cancer_type}/temp/filtered_vcf/{cancer_type}.{variant_type}.vcf")
    shell:
        r"""
            bcftools view -i 'FILTER="PASS" || FILTER="VQSRTrancheINDEL99.90to99.95" || FILTER="VQSRTrancheINDEL99.95to100.00"' {input} > {output} ||
            bcftools view -i 'FILTER="PASS" || FILTER="VQSRTrancheSNP99.90to99.95" || FILTER="VQSRTrancheSNP99.95to100.00"' {input} > {output}
        """


# Sort all vcf files and compress them
rule sort_and_compress:
    input:
        rules.filter.output
    output:
        temp(config["data_folder"]+"/{cancer_type}/temp/sorted_compressed_vcf/{cancer_type}.{variant_type}.vcf.gz")
    shell:
        # Each execution of bcftools should have his own separate tempdir, to avoid collision between temp files with the same
        # name belonging to different jobs
        "bcftools sort --temp-dir "+config["data_folder"]+"/temp/$(echo '{input}' | awk -F '/' '{{print $NF}}') {input} -Oz -o {output}"


# Create index of vcf files for improved handling
rule index:
    input:
        rules.sort_and_compress.output
    output: 
        temp(config["data_folder"]+"/{cancer_type}/temp/sorted_compressed_vcf/{cancer_type}.{variant_type}.vcf.gz.tbi")
    shell: 
        "bcftools index  -t {input}"


# Put togheter SNPs and INDELs in a multisample vcf files
rule concat:
    input: 
        vcf = expand(config["data_folder"]+"/{{cancer_type}}/temp/sorted_compressed_vcf/{{cancer_type}}.{variant_type}.vcf.gz", variant_type = config["variant_types"]),
        index = expand(config["data_folder"]+"/{{cancer_type}}/temp/sorted_compressed_vcf/{{cancer_type}}.{variant_type}.vcf.gz.tbi", variant_type = config["variant_types"])
    output: 
        temp(config["data_folder"]+"/{cancer_type}/temp/concatenated_vcf/{cancer_type}.snp.indel.vcf.gz")
    shell: 
        "bcftools concat -a {input.vcf} -Oz -o {output}"


# Create index of concatenate vcf file
rule index_concatenated_vcf:
    input:
        rules.concat.output
    output:
        temp(config["data_folder"]+"/{cancer_type}/temp/concatenated_vcf/{cancer_type}.snp.indel.vcf.gz.tbi")
    shell:
        "bcftools index  -t {input}"


# Merge all sample from all tumors together to improve accuracy of phasing  
rule merge_tumors:
    input:
        vcf = expand(config["data_folder"]+"/{cancer_type}/temp/concatenated_vcf/{cancer_type}.snp.indel.vcf.gz", cancer_type = config["cancer_types"]),
        index = expand(config["data_folder"]+"/{cancer_type}/temp/concatenated_vcf/{cancer_type}.snp.indel.vcf.gz.tbi", cancer_type = config["cancer_types"])
    output:
        temp(config["data_folder"]+"/temp/merged_vcf/all_samples_all_cancers.vcf.gz")
    threads: config["threads"]
    shell:
        "bcftools merge {input.vcf} -Oz -o {output}"


rule index_merged_tumors:
    input:
        rules.merge_tumors.output
    output:
        temp(config["data_folder"]+"/temp/merged_vcf/all_samples_all_cancers.vcf.gz.tbi")
    threads: config["threads"]
    shell:
        "bcftools index -t {input}"

# Split vcf file per chromosomes to allow for parallelization of following steps
rule split_chromosomes:
    input:
        vcf = config["data_folder"]+"/temp/merged_vcf/all_samples_all_cancers.vcf.gz",
        index = config["data_folder"]+"/temp/merged_vcf/all_samples_all_cancers.vcf.gz.tbi"
    output:
        temp(config["data_folder"]+"/temp/vcf_per_chromosome/chr{chr}.vcf.gz")
    shell:
        "bcftools view --regions chr{wildcards.chr} {input.vcf} -Oz -o {output}"


# Index chromosome-split vcf
rule index_chromosome_vcf:
    input:
        rules.split_chromosomes.output
    output:
        temp(config["data_folder"]+"/temp/vcf_per_chromosome/chr{chr}.vcf.gz.tbi")
    shell:
        "bcftools  index -t {input}"


# vcf files are ready to be phased. To do this, the tool shapeit5 will be used
rule phasing:
    input:
        vcf = config["data_folder"]+"/temp/vcf_per_chromosome/chr{chr}.vcf.gz",
        map = config["recombination_maps"] + "/chr{chr}.b38.gmap.gz",
        indexes = rules.index_chromosome_vcf.output
    output:
        temp(config["data_folder"]+"/temp/phased_vcf/chr{chr}.phased.bcf")
    threads:5
    shell:
        # Maps name MUST be in the format "chr#.[genome_version].gmap.gz (i.e. "chr2.b38.gmap.gz")"
        config["shapeit5"] + " --input {input.vcf} --region $(echo '{input.map}' | cut -d '.' -f 1 | awk -F '/' '{{print $NF}}') --map {input.map} --filter-maf 0.001 --output {output} --thread {threads}"


# Sample lists are needed to split back vcf files per cancer type
rule get_sample_lists_per_cancer_type:
    input:
        rules.concat.output
    output:
        temp(config["data_folder"]+"/temp/{cancer_type}_list.txt")
    shell:
        "bcftools query -l {input} > {output}"


# Split back vcf files per cancer type
rule split_cancer_types:
    input:
        vcf = config["data_folder"]+"/temp/phased_vcf/chr{chr}.phased.bcf",
        sample_list = config["data_folder"]+"/temp/{cancer_type}_list.txt"
    output:
        config["data_folder"]+"/{cancer_type}/phased_vcf/chr{chr}.vcf.gz"
    shell:
        "bcftools view --samples {wildcards.cancer_type}_list.txt {input.vcf} -Oz -o {output}"