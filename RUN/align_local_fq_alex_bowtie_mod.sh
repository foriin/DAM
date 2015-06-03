#!/bin/bash
###############################################################################
# Ludo Pagie, 22 March, 2012, align_local_fq_LP120405.sh
#
# DESCRIPTION:
#   wrapper around bowtie2, takes as input a single fastq file and an
#   assembly
#
# OUTPUT:
#   sorted bamfile and an index (bai) file. mapped reads are filtered
#   for alignment quality score 25 or higher
#
# VERSIONS:
#   120322: - add an exit code indicating failure/succes
#           - store output in temp files, at end move temp files to proper
#             filesnames
#           - check whether outfiles exist already, if so return succes
#           - add some mapping statistics to BWT_STATS
#   120405: - save unmapped reads in a separate file, counted and sorted
#             along abundance
#           - before mapping clip adapter sequences using cutadapt;
#             first find reads with long adapter (....
#           - remove duplicate reads from inner reads
#           - split mapped reads in 0x, 1x, 2x, 3x or more 
#   120424: - align unmapped reads to the sequence of the inserted
#             transgene (if given)
#   130117: - renamed to align_local_fq.sh for inclusion in git repos
#           - changed bowtie2 version to 2.0.5
#           - added codedir as CLI arg, should pass the directory with
#             all scripts
#   130123: - added some explanatory comments
###############################################################################

		if [ $# -lt 3 ]; then
			echo 1>&2 Usage: align_local_fq.sh input_file.fq.gz assembly_version [model-matrix-file] fast_output_directory
			exit 1
		elif [[ $# == 4 ]]; then
			IN_FQ="$1 $2"
			fq_dir=`echo "$1" | sed -r "s/(.*?).R.{9}(\.fastq\.gz)/\1_paired\2/"`
			paired=True
			assbly=$3
			FASTDIR=$4
		else
			IN_FQ=$1
			fq_dir=$1
			assbly=$2
			FASTDIR=$3
		fi

# set some paths for executables
BOWTIE2=bowtie2
CUTADAPT=cutadapt
FASTX_REVCOM=fastx_reverse_complement
BOWTIE2_INDEXES=~/data/DAM/indexes/
DSCR=~/data/DAM/RUN/damid_description.csv # path to description file which establishes a correspondence between the file name and its human-readable name.

# echo some versioninfo to log:
echo 'using bowtie2 version:'
echo `${BOWTIE2} --version`
echo ''
echo 'using cutadapt version:'
echo `${CUTADAPT} --version`
echo ''
echo 'using fastx_reverse_complement version:'
echo `${FASTX_REVCOM} -h | grep FASTX`
echo ''

#set some parameters
MIN_Q=25
#adaptor sequences used in DamID-seq
ADPTR_SHORT_5="GGTCGCGGCCGAG"
#adaptor sequences used by Illumina
ILLUMINA_5="GCTCTTCCGATCT"
#make reverse complement of adapter sequences 
#(${FASTX_REVCOM} expects fasta input, "awk 'NR > 1'" means print everything beyond line 1)
ADPTR_SHORT_3=`echo -e ">\n${ADPTR_SHORT_5}" | ${FASTX_REVCOM} | awk 'NR > 1'`
ILLUMINA_3=`echo -e ">\n${ILLUMINA_5}" | ${FASTX_REVCOM} | awk 'NR > 1'` #AGATCGGAAGAGC
CSTAT="cutadapt_statistics.csv"

# Start statistic record
if [ ! -f ${CSTAT} ]; then
echo "Data.set;fastq.file;Total.number.of.reads.obtained;Without.GATCs.original.length;With.edge.GATCs;Cutadapt.Trash;Sum;Sum-Total.number.of.reads.obtained;Without.GATCs.original.length.Percentage;With.edge.GATCs.Percentage;Cutadapt.Trash.Percentage" > ${CSTAT}
fi

basef=${FASTDIR}/${fq_dir%.fastq.gz}
stats=${FASTDIR}/${fq_dir%.fastq.gz}/stats
len9=${FASTDIR}/${fq_dir%.fastq.gz}/len9 # folder for cuted reads 
olen=${FASTDIR}/${fq_dir%.fastq.gz}/orig_len # folder for uncuted reads
tmpf="$len9 $olen"

# make folder defined on last step
mkdir ${fq_dir%.fastq.gz} $len9 $olen $stats

# set base filename
case $fq_dir in
*.fq.gz) 
OUT_BAM=$basef/${fq_dir%.fq.gz}_local.bam
CAT=zcat ;;
*.fastq.gz) 
OUT_BAM=$basef/${fq_dir%.fastq.gz}_local.bam
CAT=zcat ;;
*.fastq) 
OUT_BAM=$basef/${fq_dir%.fastq}_local.bam
CAT=cat ;;
*.fq) 
OUT_BAM=$basef/${fq_dir%.fq}_local.bam
CAT=cat ;;
*) 
echo "inputfile (${fq_dir}) should either be gzipped fastq"
echo "(*.fq.gz or fastq.gz) or fastq (*.fq or *.fastq)" 
exit 1 ;;
esac

# set additional output files based on base filename
OUT_BAM_INNER=${OUT_BAM%_local.bam}_inner_local.bam
OUT_BAM_EDGE=${OUT_BAM%_local.bam}_edge_local.bam
OUTx2_BAM=${OUT_BAM%_local.bam}_local_2x.bam
OUTx3_BAM=${OUT_BAM%_local.bam}_local_3x.bam
BWT_STATS=${OUT_BAM%_local.bam}_local.bowtie_stats
UNMAPPED_INNER=${OUT_BAM%_local.bam}_unmappedInnerReads.txt.gz
UNMAPPED_EDGE=${OUT_BAM%_local.bam}_unmappedEdgeReads.txt.gz

# set species and assembly (for read alignment)
case $assbly in
dm3)
ASSEMBLY=dmel_r5.41 ;;
hg18)
ASSEMBLY=hg18 ;;
hg19)
ASSEMBLY=hg19 ;;
mm9)
ASSEMBLY=mm9 ;;
*)
echo "assembly $3 not know, exiting"
exit 1 ;;
esac


################################################
# create temporary output files
################################################
TMP_BAM_INNER=`mktemp $basef/tmp_bam_inner.XXXXXXXXXX`
TMP_BAM_EDGE=`mktemp $basef/tmp_bam_edge.XXXXXXXXXX`
TMP_STATS_INNER=`mktemp $basef/tmp_stats_inner.XXXXXXXXXX`
TMP_STATS_EDGE=`mktemp $basef/tmp_stats_edge.XXXXXXXXXX`

fq_name=`grep -w $1 $DSCR | sed "s/[a-zA-Z0-9_-.]*$//;s/	//"`
if [ "$paired" == "True" ]; then
	fq_stat_name=`echo $fq_name | sed -r "s/(.*\.)(.*\.)(.*)(F|R)(\..*)/\1\2\3paired\5/"`
	header="$1 and $2"
else
	fq_stat_name="$fq_name"
	header="$1"
fi
echo "
	<!DOCTYPE html>
	<html lang=\"en\">
	<head>
	<meta charset=\"utf-8\">
	<title>Report on the work cutadapt program</title>
	<style type=\"text/css\">body{padding-top: 60px; padding-bottom: 40px;}</style>
	<link href=\"http://cellbiol.ru/files/bootstrap/css/bootstrap.css\" rel=\"stylesheet\">
	<link href=\"http://cellbiol.ru/files/bootstrap/css/bootstrap-responsive.css\" rel=\"stylesheet\">
	<script>
	function number_format( number, decimals, dec_point, thousands_sep ) {	// Format a number with grouped thousands
		// 
		// +   original by: Jonas Raoni Soares Silva (http://www.jsfromhell.com)
		// +   improved by: Kevin van Zonneveld (http://kevin.vanzonneveld.net)
		// +	 bugfix by: Michael White (http://crestidg.com)

		var i, j, kw, kd, km;

		// input sanitation & defaults
		if( isNaN(decimals = Math.abs(decimals)) ){
			decimals = 2;
		}
		if( dec_point == undefined ){
			dec_point = \",\";
		}
		if( thousands_sep == undefined ){
			thousands_sep = \".\";
		}

		i = parseInt(number = (+number || 0).toFixed(decimals)) + \"\";

		if( (j = i.length) > 3 ){
			j = j % 3;
		} else{
			j = 0;
		}

		km = (j ? i.substr(0, j) + thousands_sep : \"\");
		kw = i.substr(j).replace(/(\d{3})(?=\d)/g, \"\$1\" + thousands_sep);
		//kd = (decimals ? dec_point + Math.abs(number - i).toFixed(decimals).slice(2) : \"\");
		kd = (decimals ? dec_point + Math.abs(number - i).toFixed(decimals).replace(/-/, 0).slice(2) : \"\");


		return km + kw + kd;
	}</script>
</head>
<body> 
<div class=\"container\">
<div class=\"hero-unit\">
<h1 align=\"center\">DAM ID pipeline report</h1>
</div>
" >> $basef/${fq_stat_name}_report.html



# Cut adapters from reads
for fq_base in ${IN_FQ}; do	
fq_human=`grep -w $fq_base $DSCR | sed "s/[a-zA-Z0-9_-.]*$//;s/	//"` # human-readable name in variable, get by parse $DSCR

if [ "$paired" == "True" ]; then
	fq_tag=`echo $fq_human | sed -r "s/(.*)\.(.*)\.(.*)\.(.*)/\3/;s/.*_(F|R)/\1/"`
	TMP_FQ_EDGE="$basef/tmp_fq_edge.${fq_tag}.fastq"
	TMP_FQ_INNER="$basef/tmp_fq_inner.${fq_tag}.fastq"
else
	TMP_FQ_EDGE=`mktemp $basef/tmp_fq_edge.XXXXXXXXXX`
	TMP_FQ_INNER=`mktemp $basef/tmp_fq_inner.XXXXXXXXXX`
fi



# define function that checks exit code last command
CheckExit()
{
	if [ $1 -ne 0 ]; then
		echo "$2" 1>&2
		exit 1
	fi
}

###################################################
# awk script to split bam file in 4 files:
# unmapped, 1x-mapped, 2x-mapped, 3x-or-more mapped
###################################################
AWKSCRIPT='
BEGIN {
	flag = lshift(1, 8); # bit-8 flag
}
{
	if ( ! and ( flag, $2 ) ) { # if not first alignment of this read
# check whether previous read is unmapped or uniquely mapped
		if ( cnt == 1 ) { if (oldflag == 4) print ID[1] > OUT0; else print ID[1] >> OUT1; }  # print to unmapped or unique mapped
			if ( cnt == 2 ) { print ID[1] >> OUT2; print ID[2] >> OUT2; } # print to 2x mapped file
				if ( cnt >= 3 ) { for (i in ID) print ID[i] >> OUT3; } # print to 3x or more mapped file
					cnt = 1; delete ID; ID[cnt] = $0; oldflag = $2; # reset intermediate variables
	} else {
		cnt++; ID[cnt] = $0; # increase counter for multi mapped reads
	}
}
END {
	if ( cnt == 1 ) { if (oldflag == 4) print ID[1] > OUT0; else print ID[1] >> OUT1; }
	if ( cnt == 2 ) { print ID[1] >> OUT2; print ID[2] >> OUT2; }
	if ( cnt >= 3 ) { for (i in ID) print ID[i] >> OUT3; }
}
'

# check whether outfiles exists already
if [ -f "${OUT_BAM_INNER}" -a -f "${OUT_BAM_EDGE}" -a -f "${BWT_STATS}" -a -f "${BAM_OUT}".bai ]; then
echo "${fq_base} is aligned already, exiting" 1>&2
exit 0
else
# remove if only some exist
rm -f "${OUT_BAM_INNER}" "${OUT_BAM_EDGE}" "${BWT_STATS}" "${BAM_OUT}".bai
fi

##################################################################################
# trim adapter sequences from reads, sort reads by precence GATC site into reads #
##################################################################################
# and write statistic to file 																									 #
##################################################################################

# Main trim reads. Processing cutadapt with the following parameters: 5 '& 3' adapters encountered from 3 or more times, the overlap of the adapter 9 or more bases. Those reads where found adapters write to file out.fastq, where there was no adapters write to file untrim_out.fastq 
cutadapt -g "${ADPTR_SHORT_5}" -g "${ILLUMINA_5}" -a "${ADPTR_SHORT_3}" -a "${ILLUMINA_3}" -e 0.01 -n 3 --overlap 12 --match-read-wildcards --untrimmed-output $basef/untrim_out.fastq ${fq_base} -o $basef/out.fastq > $stats/clip_${fq_base%.fastq.gz}.stats

# Remove reads smaller then 9 bp. Process files with truncated adapters - looking GATC fragments in any position by reads with a minimum length of 9 bases, do not cut off. That there was a goes into file out_wo_adapt_gatcs_len9.fastq, reads with smaller length and / or without GATC goes in the trash 
cutadapt -g "GATC" -a "GATC" -O 4 -m 9 --no-trim --untrimmed-output $basef/out_wo_adapt_wo_gatcs_small_len.fastq $basef/out.fastq -o $basef/out_wo_adapt_gatcs_len9.fastq > $stats/clip_len9_${fq_base%.fastq.gz}.stats

# Sort reads in untrimmed reads by presence GATC's. Process files with reads without adapters - am also looking for GATC fragments. Nothing is cut off. Reads with fragments are sent to a file untrim_out_gatcs_orig_len.fastq, without going into the file fragments TMP_FQ_INNER (untrim_out_wo_gatcs_orig_len.fastq)
cutadapt -g "GATC" -a "GATC" -O 4 --no-trim --untrimmed-output ${TMP_FQ_INNER} $basef/untrim_out.fastq -o $basef/untrim_out_gatcs_orig_len.fastq > $stats/clip_orig_len_${fq_base%.fastq.gz}.stats

#############################
###  Variable for report  ###
#############################
s0_reads=`grep "Processed reads" $stats/clip_${fq_base%.fastq.gz}.stats | sed 's/^[a-zA-Z ^t:]*//'`
s1_trim=`grep "Trimmed reads" $stats/clip_${fq_base%.fastq.gz}.stats | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
s1_untrim=$((${s0_reads} - ${s1_trim}))
	s2_trim_gatcs=`grep "^\+$" $basef/out_wo_adapt_gatcs_len9.fastq | wc -l`
	s2_untrim_trash_gatcs=`grep "^\+$" $basef/out_wo_adapt_wo_gatcs_small_len.fastq | wc -l`
s2_trash_reads=$(($s1_trim-$s2_trim_gatcs))
	s2_untrim_gatc=`grep "Matched reads" $stats/clip_orig_len_${fq_base%.fastq.gz}.stats | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
s2_untrim=$(($s1_untrim-$s2_untrim_gatc))

# Calculate percentages
	s0_reads_pct=`bc <<< "a=$s0_reads; b=$s0_reads; (b/a)*100"`%
	s1_trim_pct=`bc <<< "scale=4; a=$s0_reads; b=$s1_trim; (b/a)*100" | sed 's/[0].$//'`%
	s1_untrim_pct=`bc <<< "scale=4; a=$s0_reads; b=$s1_untrim; (b/a)*100" | sed 's/[0].$//'`%
	s2_trim_gatcs_pct=`bc <<< "scale=4; a=$s0_reads; b=$s2_trim_gatcs; (b/a)*100" | sed 's/[0].$//'`%
	s2_untrim_trash_gatcs_pct=`bc <<< "scale=4; a=$s0_reads; b=$s2_untrim_trash_gatcs; (b/a)*100" | sed 's/[0].$//'`%
	s2_trash_reads_pct=`bc <<< "scale=4; a=$s0_reads; b=$s2_trash_reads; (b/a)*100" | sed 's/[0].$//'`%
	s2_untrim_gatc_pct=`bc <<< "scale=4; a=$s0_reads; b=$s2_untrim_gatc; (b/a)*100" | sed 's/[0].$//'`%
	s2_untrim_pct=`bc <<< "scale=4; a=$s0_reads; b=$s2_untrim; (b/a)*100" | sed 's/[0].$//'`%

#############################

# Starting cycle in which the search for fragments GATC spaced from the edge read at 1, 2, 3 and so on up to 9 bases
	for (( count = 1; count <= 13; count++ )); do # 13 base = length of short adapter 
		ADPTR_SHORT_5="GGTCGCGGCCGAG"
		adptr5=`echo $ADPTR_SHORT_5 | sed -e 's/^.\{'$count'\}//'` # Remove nt from adapter 5' end
		adptr3=`echo $ADPTR_SHORT_3 | sed -e 's/.\{'$count'\}$//'` # Remove nt from adapter 3' end
		adptr_len=${#adptr5} # Calculate adapter length
	# Sort reads by edge and with shift from 1 to 9 bases of adapters. This block of code looking for reads with GATC fragments at the edges and slightly indented from the edge - up to 9 nucleotides from the adapter as a direct and the reverse side. 
		for folder in $tmpf; do
			if [ "$folder" == "$len9" ]; then
					ins="len9"
					sourcef="$basef/out_wo_adapt_gatcs_len9.fastq"
				else
					ins="orig_len"
					sourcef="$basef/untrim_out_gatcs_orig_len.fastq"
				fi
			if (( $count == 1 )); then # Search and cut only 12 base adapters
				cutadapt -g "^${adptr5}" -a "${adptr3}$" -O ${#adptr5} -e 0.01 --untrimmed-output $folder/inner$((13-${count}))-gatcs.fastq $sourcef -o $folder/output$((13-${count}))-gatcs.fastq > $stats/clip_${ins}_gatcs$((13-${count})).stats

			elif (( ($count > 1) && ($count < 12) )); then # Search and cut adapters the length of which exist between 2-12 bases
				cutadapt -g "^${adptr5}" -a "${adptr3}$" -O ${#adptr5} -e 0.01 --untrimmed-output $folder/inner$((13-${count}))-gatcs.fastq $folder/inner$((14-${count}))-gatcs.fastq -o $folder/output$((13-${count}))-gatcs.fastq > $stats/clip_${ins}_gatcs$((13-${count})).stats

			elif (( $count == 12 )); then
				atom="5 3"
				for num in $atom; do
					if (( $num == 5 )); then
						ADAPTER="^${adptr5}GATC"
						opt="g"
						untrimf="$folder/inner$((13-${count}))-gatcs.tmp.fastq"
						inputf="$folder/inner$((14-${count}))-gatcs.fastq"
					else
						ADAPTER="GATC${adptr3}$"
						opt="a"
						untrimf="$folder/inner$((13-${count}))-gatcs.fastq"
						inputf="$folder/inner$((13-${count}))-gatcs.tmp.fastq"
					fi
					cutadapt -${opt} $ADAPTER -O $((4+${#adptr5})) -e 0.01 --no-trim --untrimmed-output $untrimf $inputf -o $folder/output$((13-${count}))-gatcs${num}.fastq > $stats/clip_${ins}_gatcs$((13-${count})).stats${num}
					cat $folder/output$((13-${count}))-gatcs${num}.fastq | sed  "s/"${ADAPTER}"/GATC/" | sed "n;n;n;s/^.\{"${#adptr5}"\}//" >> $folder/output$((13-${count}))-gatcs.fastq
					rm $folder/output$((13-${count}))-gatcs${num}.fastq
				done
			else # Search and SORT reads with edge GATC's
				cutadapt -g "^GATC" -a "GATC$" -O 4 -e 0.01 --no-trim --untrimmed-output $folder/inner$((13-${count}))-gatcs.fastq $folder/inner$((14-${count}))-gatcs.fastq -o $folder/output$((13-${count}))-gatcs.fastq > $stats/clip_${ins}_gatcs$((13-${count})).stats
			fi
			
		done
	#############################
	###  Variable for report  ###
	#############################

		if (( $count <= 11 )); then
			s3_match_trim_reads=`grep "Trimmed reads" $stats/clip_len9_gatcs$((13-${count})).stats | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
			s3_match_untrim_reads=`grep "Trimmed reads" $stats/clip_orig_len_gatcs$((13-${count})).stats | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
			s3_input_trim_reads=`grep "Processed reads" $stats/clip_len9_gatcs$((13-${count})).stats | sed 's/^[a-zA-Z ^t:]*//'`
			s3_input_untrim_reads=`grep "Processed reads" $stats/clip_orig_len_gatcs$((13-${count})).stats | sed 's/^[a-zA-Z ^t:]*//'`
		elif (($count == 12)); then
			s3tmp5=`grep "Matched reads" $stats/clip_len9_gatcs$((13-${count})).stats5 | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
			s3tmp3=`grep "Matched reads" $stats/clip_len9_gatcs$((13-${count})).stats3 | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
			s3_match_trim_reads=$((${s3tmp3} + ${s3tmp5}))
			s3utmp5=`grep "Matched reads" $stats/clip_orig_len_gatcs$((13-${count})).stats5 | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
			s3utmp3=`grep "Matched reads" $stats/clip_orig_len_gatcs$((13-${count})).stats3 | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
			s3_match_untrim_reads=$((${s3utmp3} + ${s3utmp5}))
			s3_input_trim_reads=`grep "Processed reads" $stats/clip_len9_gatcs$((13-${count})).stats5 | sed 's/^[a-zA-Z ^t:]*//'`
			s3_input_untrim_reads=`grep "Processed reads" $stats/clip_orig_len_gatcs$((13-${count})).stats5 | sed 's/^[a-zA-Z ^t:]*//'`

		else
			s3_match_trim_reads=`grep "Matched reads" $stats/clip_len9_gatcs$((13-${count})).stats | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
			s3_match_untrim_reads=`grep "Matched reads" $stats/clip_orig_len_gatcs$((13-${count})).stats | sed 's/^[a-zA-Z ^t:]*//;s/[%()0-9.]*$//;s/[ ^]*$//'`
			s3_input_trim_reads=`grep "Processed reads" $stats/clip_len9_gatcs$((13-${count})).stats | sed 's/^[a-zA-Z ^t:]*//'`
			s3_input_untrim_reads=`grep "Processed reads" $stats/clip_orig_len_gatcs$((13-${count})).stats | sed 's/^[a-zA-Z ^t:]*//'`
		fi

		s3_input_trim_reads_pct=`bc <<< "scale=4; a=$s0_reads; b=$s3_input_trim_reads; (b/a)*100" | sed 's/[0].$//'`%
		s3_match_trim_reads_pct=`bc <<< "scale=4; a=$s0_reads; b=$s3_match_trim_reads; (b/a)*100" | sed 's/[0].$//'`%
		s3_input_untrim_reads_pct=`bc <<< "scale=4; a=$s0_reads; b=$s3_input_untrim_reads; (b/a)*100" | sed 's/[0].$//'`%
		s3_match_untrim_reads_pct=`bc <<< "scale=4; a=$s0_reads; b=$s3_match_untrim_reads; (b/a)*100" | sed 's/[0].$//'`%
	#############################

	# record statistic to temporary file
		echo "<tr><td>${adptr5}GATC</td><td><script>document.write(number_format(${s3_input_trim_reads}, 0, '.', ' '))</script> (${s3_input_trim_reads_pct})</td><td><script>document.write(number_format(${s3_match_trim_reads}, 0, '.', ' '))</script> (${s3_match_trim_reads_pct})</td></tr>" >> $stats/len9_${fq_base}.txt
		echo "<tr><td>${adptr5}GATC</td><td><script>document.write(number_format(${s3_input_untrim_reads}, 0, '.', ' '))</script> (${s3_input_untrim_reads_pct})</td><td><script>document.write(number_format(${s3_match_untrim_reads}, 0, '.', ' '))</script> (${s3_match_untrim_reads_pct})</td></tr>" >> $stats/orig_len_${fq_base}.txt
	done # end of cycle


# Combine all founded reads to one file
	cat $len9/output*-gatcs.fastq $olen/output*-gatcs.fastq > $basef/interim_gatcs_${fq_base}.fastq

# Remove reads with inner GATC's
	cat $basef/interim_gatcs_${fq_base}.fastq | perl -e 'while($h=<>){$s=<>;$t=<>.<>; if($s!~/.+GATC.+/){print $h.$s.$t}}' > ${TMP_FQ_EDGE}

#############################
###  Variable for report  ###
#############################
	s4_interim_gatcs=`grep "^\+$" $basef/interim_gatcs_${fq_base}.fastq | wc -l`
	s4_interim_gatcs_pct=`bc <<< "scale=4; a=$s0_reads; b=$s4_interim_gatcs; (b/a)*100" | sed 's/[0].$//'`%

	s4_interim_trash_reads=$((${s3_input_trim_reads}+${s3_input_untrim_reads}+${s2_trash_reads}-${s3_match_trim_reads}-${s3_match_untrim_reads}))
	s4_interim_trash_reads_pct=`bc <<< "scale=4; a=$s0_reads; b=$s4_interim_trash_reads; (b/a)*100" | sed 's/[0].$//'`%

	s3_html_trim=`cat $stats/len9_${fq_base}.txt`
	s3_html_untrim=`cat $stats/orig_len_${fq_base}.txt`

	s5_summary_gatcs=`grep "^\+$" ${TMP_FQ_EDGE} | wc -l`
	s5_summary_gatcs_pct=`bc <<< "scale=4; a=$s0_reads; b=$s5_summary_gatcs; (b/a)*100" | sed 's/[0].$//'`%

	s5_trash_reads=$((${s4_interim_gatcs}-${s5_summary_gatcs}+${s4_interim_trash_reads}))
	s5_trash_reads_pct=`bc <<< "scale=4; a=$s0_reads; b=$s5_trash_reads; (b/a)*100" | sed 's/[0].$//'`%
#############################

# Make text statistic in csv file
	echo "$fq_human;$fq_base;$s0_reads;$s2_untrim;$s5_summary_gatcs;$s5_trash_reads;$(($s2_untrim+$s5_summary_gatcs+$s5_trash_reads));$(($s0_reads-$(($s2_untrim+$s5_summary_gatcs+$s5_trash_reads))));${s2_untrim_pct%\%};${s5_summary_gatcs_pct%\%};${s5_trash_reads_pct%\%}" >> ${CSTAT}

# Make visual statistic in html file
	echo "<div class=\"page-header\">
<h1>Cutadapt statistic <small>from ${fq_base}</small></h1>
</div>
<div class=\"row\"> 
<div class=\"span12\"> 
<h2 align=\"center\">input: <script>document.write(number_format(${s0_reads}, 0, '.', ' '))</script> reads (${s0_reads_pct})</h2> 
</div>
</div>
<div class=\"row\">
<div class=\"alert\">Removing DamID and Illumina adapters</div>
<div class=\"span6\"> <h3 align=\"center\"><script>document.write(number_format(${s1_untrim}, 0, '.', ' '))</script> reads (${s1_untrim_pct})</h3> 
<p align=\"center\">No adapters &ge;12 bp found</p>
</div>
<div class=\"span6\"> <h3 align=\"center\"><script>document.write(number_format(${s1_trim}, 0, '.', ' '))</script> reads (${s1_trim_pct})</h3>
<p align=\"center\">Adapters &ge;12 bp found and removed</p>
</div>
</div>
<div class=\"row\">
<div class=\"alert\">Looking for GATC motives</div>
<div class=\"span3\">
<h4 align=\"center\"><script>document.write(number_format(${s2_untrim}, 0, '.', ' '))</script> reads (${s2_untrim_pct})</h4>
<p align=\"center\"><ul><li>without GATC(s)</li></ul></p>
</div>
<div class=\"span3\" style=\"background-color: #83a136\">
<h4 align=\"center\"><script>document.write(number_format(${s2_untrim_gatc}, 0, '.', ' '))</script> reads (${s2_untrim_gatc_pct})</h4>
<p align=\"center\"><ul><li>with GATC(s)</li></ul></p>
</div>
<div class=\"span3\" style=\"background-color: #abec00\">
<h4 align=\"center\"><script>document.write(number_format(${s2_trim_gatcs}, 0, '.', ' '))</script> reads (${s2_trim_gatcs_pct})</h4>
<p align=\"center\"><ul><li>with GATC(s)</li></ul></p>
</div>
<div class=\"span3\" style=\"color: #f10026\">
<h4 align=\"center\"><script>document.write(number_format(${s2_trash_reads}, 0, '.', ' '))</script> trash reads (${s2_trash_reads_pct})</h4>
<p align=\"center\"><ul><li>too short (&lt;12 bp) after removal of adapters</li><li>no GATC(s) after removal of adapters</li><ul></p>
</div>
</div>
<div class=\"row\">
<div class=\"alert\">Determing location of GATC motives</div>
<div class=\"span6\" style=\"background-color: #83a136\">
<table class=\"table table-striped\" align=\"center\">
<thead>
<tr><th>Location</th><th>Processed reads</th><th>Matched reads</th></tr></thead>${s3_html_untrim}</table>
</div>
<div class=\"span6\" style=\"background-color: #abec00\">
<table class=\"table table-striped\" align=\"center\">
<thead><tr><th>Location</th><th>Processed reads</th><th>Matched reads</th></tr></thead>${s3_html_trim}</table>
</div>
</div>
<p>&nbsp;</p>
<div class=\"row\">
<div class=\"alert\">Interim report</div>
<div class=\"span4\">
<h4 align=\"center\"><script>document.write(number_format(${s2_untrim}, 0, '.', ' '))</script> inner reads (${s2_untrim_pct})</h4>
<p align=\"center\"><ul><li>original length</li><li>without GATC</li></ul></p>
</div>
<div class=\"span4\" style=\"background-color: #448f30\">
<h4 align=\"center\"><script>document.write(number_format(${s4_interim_gatcs}, 0, '.', ' '))</script> edge reads (${s4_interim_gatcs_pct})</h4>
<p align=\"center\"><ul><li>original length & truncated</li><li>with GATC(s) at the edge(s)</li><li>possibly with inner GATC(s)</li></ul></p>
</div>
<div class=\"span4\" style=\"color: #f10026\">
<h4 align=\"center\"><script>document.write(number_format(${s4_interim_trash_reads}, 0, '.', ' '))</script> trash reads (${s4_interim_trash_reads_pct})</h4>
<p align=\"center\"><ul><li>too short after removal of adapters</li><li>no GATC(s) after removal of adapters</li><li>contain inner GATC(s)</li></ul></p>
</div>
</div>
<p>&nbsp;</p>
<div class=\"row\">
<div class=\"alert\">Removing  reads with inner GATC(s)</div>
<div class=\"span4\">
<h4 align=\"center\"><script>document.write(number_format(${s2_untrim}, 0, '.', ' '))</script> inner reads (${s2_untrim_pct})</h4>
<p align=\"center\"><ul><li>original length</li><li>without GATC</li></ul></p>
</div>
<div class=\"span4\" style=\"background-color: #448f30\">
<h4 align=\"center\"><script>document.write(number_format(${s5_summary_gatcs}, 0, '.', ' '))</script> edge reads (${s5_summary_gatcs_pct})</h4>
<p align=\"center\"><ul><li>original length & truncated</li><li>with GATC(s) at the edge(s)</li></ul></p>
</div>
<div class=\"span4\" style=\"color: #f10026\">
<h4 align=\"center\"><script>document.write(number_format(${s5_trash_reads}, 0, '.', ' '))</script> trash reads (${s5_trash_reads_pct})</h4>
<p align=\"center\"><ul><li>too short after removal of adapters</li><li>no GATC(s) after removal of adapters</li><li>contain inner GATC(s)</li></ul></p>
</div>
</div>
<p>&nbsp;</p>" >> ${basef}/${fq_stat_name}_report.html
# remove intermediate files
rm -R $len9/* $olen/* $stats/* $basef/out*.fastq $basef/untrim_*.fastq $basef/interim_gatcs_${fq_base}.fastq
#mv $basef $OUT # If folder $OUT is defined then to move output data from $DIR to $OUT
done
rm -R $len9 $olen $stats
PairedStat ()
{
	TR=`grep "Total Reads" $1 | sed -r "s/.*[[:space:]]([0-9]+)/\1/"`
	MP=`grep "Matched Pairs" $1 | sed -r "s/.*[[:space:]]([0-9]+)/\1/"`
	SR=`grep "Single Reads" $1 | sed -r "s/.*[[:space:]]([0-9]+)/\1/"`
	echo "
<div class=\"row\">
<div class=\"alert\">Paired match on $2 reads</div>
<div class=\"span4\">
<h4 align=\"center\">Total reads</h4>
<p align=\"center\"><script>document.write(number_format(${TR}, 0, '.', ' '))</script></p>
</div>
<div class=\"span4\">
<h4 align=\"center\">Matched Pairs</h4>
<p align=\"center\"><script>document.write(number_format(${MP}, 0, '.', ' '))</script></p>
</div>
<div class=\"span4\">
<h4 align=\"center\">Single reads</h4>
<p align=\"center\"><script>document.write(number_format(${SR}, 0, '.', ' '))</script></p>
</div>
</div>
<p>&nbsp;</p>" >> ${basef}/${fq_stat_name}_report.html
}
if [ "$paired" == "True" ]; then
	echo "
	<div class=\"page-header\">
	<h1>Paired match statistic <small>for ${header}</small></h1>
	</div>" >> ${basef}/${fq_stat_name}_report.html

	python /usr/local/bin/paired_sequence_match.py -i " " -v --index-in-memory ${basef}/tmp_fq_inner.F.fastq ${basef}/tmp_fq_inner.R.fastq -p ${basef}/inner_F.fastq -p ${basef}/inner_R.fastq -s ${basef}/single_inner_reads.fastq > ${basef}/paired.stat
		PairedStat ${basef}/paired.stat "inner"

	python /usr/local/bin/paired_sequence_match.py -i " " -v --index-in-memory ${basef}/tmp_fq_edge.F.fastq ${basef}/tmp_fq_edge.R.fastq -p ${basef}/tmp_paired_edge_F.fastq -p ${basef}/tmp_paired_edge_R.fastq -s ${basef}/single_edge_reads.fastq > ${basef}/paired.stat
		PairedStat ${basef}/paired.stat  "edge"

	python /usr/local/bin/paired_sequence_match.py -i " " -v --index-in-memory ${basef}/single_edge_reads.fastq ${basef}/single_inner_reads.fastq -p ${basef}/tmp_paired_F.fastq -p ${basef}/tmp_paired_R.fastq -s ${basef}/single_unpaired.fastq > ${basef}/paired.stat
		PairedStat ${basef}/paired.stat "unmatched"

	cat ${basef}/tmp_paired_edge_F.fastq ${basef}/tmp_paired_F.fastq > ${basef}/edge_F.fastq
	cat ${basef}/tmp_paired_edge_R.fastq ${basef}/tmp_paired_R.fastq > ${basef}/edge_R.fastq
fi


###############################################################################
###############################################################################
###############################################################################

#####################################################
# run bowtie on fastq files
#####################################################
echo "
	<div class=\"page-header\">
	<h1>Bowtie statistic <small>for ${header}</small></h1>
	</div>" >> ${basef}/${fq_stat_name}_report.html

FQ_VECTOR="${TMP_FQ_INNER} ${TMP_FQ_EDGE}"

for FQ in ${FQ_VECTOR}; do
	#Get number of CPU Cores
	CORE=`lscpu | grep 'CPU(s):' | sed -n '1p' | rev | cut -c 1`
	#Run Bowtie
	BOWTIE_PAR="-p ${CORE} -t --phred33 --local -x ${BOWTIE2_INDEXES}${ASSEMBLY}"
	SAMTOOLS_PAR="-bhq"
	# Set TMP_BAM and STAT files
	if [ "$FQ" == "${TMP_FQ_INNER}" ]; then
		TMP_BAM="${TMP_BAM_INNER}"
		STAT="${TMP_STATS_INNER}"
		UNMAP="${UNMAPPED_INNER}"
		label="inner"
	else
		TMP_BAM="${TMP_BAM_EDGE}"
		STAT="${TMP_STATS_EDGE}"
		UNMAP="${UNMAPPED_EDGE}"
		label="edge"
	fi
	# SET FQ source files if paired alingment
	if [ "$paired" == "True" ]; then
		FQ_PAIR="-1 ${basef}/${label}_F.fastq -2 ${basef}/${label}_R.fastq"
		(${BOWTIE2} ${BOWTIE_PAR} --no-discordant --no-mixed ${FQ_PAIR} | grep -v "XS:i" | samtools view -bS - -o ${TMP_BAM}) 2> ${STAT}
		SOURCE_Q="${TMP_BAM}"
		CONC="concordantly "
		prefix=""
		CheckExit $? "bowtie2 failed on inner reads"
	# End of option
	else
		cat ${FQ} | (${BOWTIE2} -k 3 ${BOWTIE_PAR} -U - | samtools view -bS - -o ${TMP_BAM}) 2> ${STAT}
		CheckExit $? "bowtie2 failed on inner reads"
			#################################################################################
			# split bamfile in unmapped, uniquely mapped reads, reads mapped twice, and reads
			# mapped 3 times or more
			# awk script above
			# then prepare output samfiles with sam-header, not for OUT0.sam
			if [ "$FQ" == "${TMP_FQ_EDGE}" ]; then
				samtools view -H ${TMP_BAM} > $basef/OUT1.sam
				SOURCE_Q="${TMP_BAM}"
			else
				samtools view -H ${TMP_BAM} > $basef/OUT1.sam
				samtools view -H ${TMP_BAM} > $basef/OUT2.sam
				samtools view -H ${TMP_BAM} > $basef/OUT3.sam
				SOURCE_Q="$basef/OUT1.sam"
				SAMTOOLS_PAR="-Sbhq"
			fi

			# and run the awk script
			samtools view ${TMP_BAM} | awk -vOUT0=$basef/OUT0.sam -vOUT1=$basef/OUT1.sam -vOUT2=$basef/OUT2.sam -vOUT3=$basef/OUT3.sam "$AWKSCRIPT"

			# unmapped reads: sort, unique, count reads only
			cat $basef/OUT0.sam | cut -f 10 | sort | uniq -c | sort -gr | gzip -c  > ${UNMAP}
			rm -f $basef/OUT0.sam
			CONC=""
			prefix="un"
				
	fi
# filter for quality score MIN_Q
	samtools view ${SAMTOOLS_PAR} ${MIN_Q} ${SOURCE_Q} -o $basef/tmp.bam
	CheckExit $? "samtools filter Q failed on reads from ${FQ}"

	# sort bam file
	mv -f $basef/tmp.bam ${TMP_BAM}
	if [ -e $basef/OUT1.sam ]; then rm -f $basef/OUT1.sam; fi
	samtools sort -n -@ $CORE ${TMP_BAM} $basef/srt
	CheckExit $? "samtools sort failed on reads from ${FQ}"

	# index bam file
	mv -f $basef/srt.bam ${TMP_BAM}

	# Write statistics
	total_reads=`grep "were ${prefix}paired" ${STAT} | sed -r "s/[[:space:]]+([0-9]+)(.+[%\)]).*/\1\2/"`
	zero_times=`grep "0 times" ${STAT} | sed -r "s/[[:space:]]+([0-9]+)(.+[%\)]).*/\1\2/"`
	one_times=`grep "exactly 1 time" ${STAT} | sed -r "s/[[:space:]]+([0-9]+)(.+[%\)]).*/\1\2/"`
	many_times=`grep ">1 times" ${STAT} | sed -r "s/[[:space:]]+([0-9]+)(.+[%\)]).*/\1\2/"`
	rate=`grep "overall alignment rate" ${STAT} | sed -r "s/([0-9.%]+).*/\1/"`

	echo "
<div class=\"row\"> 
<div class=\"alert\">Bowtie alingning on ${label} reads</div>
<div class=\"span12\"> 
<h2 align=\"center\">I handled ${total_reads} reads</h2>
<p align=\"center\">Of them:</p>
</div>
</div>
<p>&nbsp;</p>
<div class=\"row\">
<div class=\"span4\">
<h4 align=\"center\">aligned ${CONC}zero times</h4>
<p align=\"center\">${zero_times}</p>
</div>
<div class=\"span4\">
<h4 align=\"center\">aligned ${CONC}one time</h4>
<p align=\"center\">${one_times}</p>
</div>
<div class=\"span4\">
<h4 align=\"center\">aligned ${CONC}more then one time</h4>
<p align=\"center\">${many_times}</p>
</div>
</div>
<p>&nbsp;</p>
<div class=\"row\"> 
<div class=\"span12\"> 
<h2 align=\"center\">Overall alignment rate: ${rate}</h2> 
</div>
</div>
<p>&nbsp;</p>" >> ${basef}/${fq_stat_name}_report.html
done

if [ "$paired" != "True" ]; then
	# compress OUT2.sam and OUT3.sam to bam
	samtools view -S -b $basef/OUT2.sam -o ${OUTx2_BAM}
	rm -f $basef/OUT2.sam
	samtools view -S -b $basef/OUT3.sam -o ${OUTx3_BAM}
	rm -f $basef/OUT3.sam
fi

# merge stat files
cat ${TMP_STATS_INNER} ${TMP_STATS_EDGE} > ${BWT_STATS}
OUT=$?
if [ ${OUT} -ne 0 ]; then
	rm -f ${OUT_BAM_INNER} ${OUT_BAM_EDGE}
	rm -f ${OUT_BAM_EDGE}.bai ${OUT_BAM_EDGE}.bai
	CheckExit ${OUT} "merging stat files failed"
fi
# delete tmp stats files
rm -f ${TMP_STATS_INNER} ${TMP_STATS_EDGE}

#####################################################
#####################################################

#####################################################
# map unmapped reads onto transgene sequence NOT!!!!!
#####################################################
# parse model matrix file; extract filename with transgene

# construct reference sequence file for bowtie
# run bowtie

#####################################################
#####################################################

#####################################################
# collect additional statistics on reads and mapping:
#####################################################
# count reads after ${Q_MIN} filtering
######################################

CNT_INNER=`samtools view -c "${TMP_BAM_INNER}"`
CheckExit $? "samtools count inner after filter Q failed"
echo '7'
CNT_EDGE=`samtools view -c "${TMP_BAM_EDGE}"`
CheckExit $? "samtools count edge after filter Q failed"
echo '8'
echo "inner nreads after Q_filter: ${CNT_INNER}" >> ${BWT_STATS}
echo "edge nreads after Q_filter: ${CNT_EDGE}" >> ${BWT_STATS}
echo '9'
CNT_ALL=`expr ${CNT_INNER} + ${CNT_EDGE}`
CheckExit $? "summing inner and edge reads failed"
echo '10'
echo "all nreads after Q_filter: ${CNT_ALL}" >> ${BWT_STATS}
# removing duplicates from inner reads
samtools rmdup -S ${TMP_BAM_INNER} $basef/tmp.bam
CheckExit $? "samtools rmdup inner reads failed"
echo '12'
######################################
# # reads lost after rmdup
######################################
CNT_INNER_RMDUP=`samtools view -c $basef/tmp.bam`
# CNT=`samtools view -h "${TMP_BAM_INNER}" | \
#      samtools view -S -h -b - -o - | \
#      samtools rmdup -s - - | \
#      samtools view -c -`
CheckExit $? "samtools unique count inner reads failed"
echo "nreads unique inner reads: ${CNT_INNER_RMDUP}" >> ${BWT_STATS}
# replace inner reads with unique reads only
mv -f $basef/tmp.bam ${TMP_BAM_INNER}
CheckExit $? "replacing inner reads with unique reads failed"
echo '13'
# removing duplicates from edge reads
samtools rmdup -s ${TMP_BAM_EDGE} $basef/tmp.bam
CheckExit $? "samtools rmdup edge reads failed"
echo '14'
CNT_EDGE_RMDUP=`samtools view -c $basef/tmp.bam`
CheckExit $? "samtools unique count edge reads failed"
echo "nreads unique edge inner reads: ${CNT_EDGE_RMDUP}" >> ${BWT_STATS}
# don't replace edge reads with unique reads only
rm -f $basef/tmp.bam
echo '15'
######################################
# count mito reads 
######################################
samtools index ${TMP_BAM_EDGE}
CNT_EDGE_MITO=`samtools view -c ${TMP_BAM_EDGE} dmel_mitochondrion_genome`
rm -f ${TMP_BAM_EDGE}.bai
CheckExit $? "count mito reads from edge reads failed"
echo "# mito reads from edge reads: ${CNT_EDGE_MITO}" >> ${BWT_STATS}
echo '16'
samtools index ${TMP_BAM_INNER}
CNT_INNER_MITO=`samtools view -c ${TMP_BAM_INNER} dmel_mitochondrion_genome`
rm -f ${TMP_BAM_INNER}.bai
CheckExit $? "count mito reads from inner reads failed"
echo "# mito reads from inner reads: ${CNT_INNER_MITO}" >> ${BWT_STATS}
echo '17'
if [ "$paired" != "True" ]; then
	samtools sort ${OUTx2_BAM} $basef/tmp
	mv $basef/tmp.bam ${OUTx2_BAM}
	samtools index ${OUTx2_BAM}
	CNT_2X_MITO=`samtools view -c ${OUTx2_BAM} dmel_mitochondrion_genome`
	rm -f ${OUTx2_BAM}.bai
	CheckExit $? "count mito reads from 2xmapped reads failed from ${OUTx2_BAM}"
	echo "# mito reads from 2xmapped reads: ${CNT_2X_MITO=}" >> ${BWT_STATS}
	echo '18'
	samtools sort ${OUTx3_BAM} $basef/tmp
	mv $basef/tmp.bam ${OUTx3_BAM}
	samtools index ${OUTx3_BAM}
	CNT_3X_MITO=`samtools view -c ${OUTx3_BAM} dmel_mitochondrion_genome`
	rm -f ${OUTx3_BAM}.bai
	CheckExit $? "count mito reads from 3xmapped reads failed from ${OUTx3_BAM}"
	echo "# mito reads from 3xmapped reads: ${CNT_3X_MITO=}" >> ${BWT_STATS}
	echo '19'
fi

mv ${TMP_BAM_INNER} ${OUT_BAM_INNER}
mv ${TMP_BAM_EDGE} ${OUT_BAM_EDGE}

# merge temp files to final filenames
# mv ${TMP_BAM} ${OUT_BAM}
#			 samtools merge ${OUT_BAM} ${TMP_BAM_INNER} ${TMP_BAM_EDGE}
#			 CheckExit $? "merging bam files failed"
# delete tmp bam files
#		 rm -f ${TMP_BAM_INNER} ${TMP_BAM_EDGE}
# index merged bam file
OUT_BAM_VECTOR="${OUT_BAM_INNER} ${OUT_BAM_EDGE}"
for BAM in $OUT_BAM_VECTOR; do
	samtools index ${BAM}
	OUT=$?
	if [ ${OUT} -ne 0 ]; then
	rm -f ${BAM}
	CheckExit ${OUT} "samtools index failed"
	fi
done

rm -R -f ${basef}/paired.stat ${basef}/tmp*.fastq ${basef}/single*.fastq ${TMP_FQ_INNER} ${TMP_FQ_EDGE} ${basef}/edge_R.fastq ${basef}/edge_F.fastq ${basef}/inner_R.fastq ${basef}/inner_F.fastq

echo "<hr>
<footer><b><p>&copy; Laboratory of cell division IMCB SB RAS, Novosibirsk, 2014-2015</p></b></footer>
</div>
</body>
</html>" >> $basef/${fq_stat_name}_report.html

# exit succesful
exit 0
