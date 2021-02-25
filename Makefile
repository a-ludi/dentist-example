# get the data at PBGAPS=https://bds.mpi-cbg.de/hillerlab/DENTIST/
# be sure to copy the hidden files .assembly-reference.{bps,hdr,idx}
ASSEMBLY_REFERENCE=$(PBGAPS)/data/d_melanogaster/assembly-reference.dam
ASSEMBLY_TEST=$(PBGAPS)/data/d_melanogaster/assembly-test.fasta
READ_MAPPING=$(PBGAPS)/data/d_melanogaster/reads-simulated-pb.mapping.csv

DATADIR=data
SIMULATED_READS_SEED=19339
EXAMPLE_ASSEMBLY_REFERENCE=$(DATADIR)/assembly-reference
EXAMPLE_ASSEMBLY_TEST=$(DATADIR)/assembly-test
EXAMPLE_READS=$(DATADIR)/reads
EXAMPLE_READ_MAPPING=$(DATADIR)/reads.mapping.csv

DOC_FILES=README.md
DIST_SOURCE_FILES=cluster.yaml dentist.json profile-slurm.yaml Snakefile snakemake.yaml
SOURCE_FILES=Makefile $(DIST_SOURCE_FILES)

SOURCE_TARBALL=dentist-example.source.tar.gz
DIST_TARBALL=dentist-example.tar.gz
TEMP_OUTPUTS=$(EXAMPLE_ASSEMBLY_REFERENCE).dam $(addprefix $(dir $(EXAMPLE_ASSEMBLY_REFERENCE)).$(notdir $(EXAMPLE_ASSEMBLY_REFERENCE)).,bps hdr idx) $(DATADIR)/scaffold_id
MAIN_OUTPUTS=$(EXAMPLE_ASSEMBLY_REFERENCE).fasta $(EXAMPLE_ASSEMBLY_TEST).fasta $(EXAMPLE_READS).fasta $(EXAMPLE_READ_MAPPING)
ALL_OUTPUTS=$(MAIN_OUTPUTS) $(TEMP_OUTPUTS)

snakemake=`command -v snakemake`

.PHONY: all
all: $(MAIN_OUTPUTS)

$(DATADIR)/scaffold_id: $(ASSEMBLY_REFERENCE) | $(DATADIR)
	@echo "-- selecting largest contig of ground-truth assembly corresponding to the largest scaffold in the test assembly ..."
	DBdump -rh $(ASSEMBLY_REFERENCE) | awk '($$1 == "R") { cid = $$2 } ($$1 == "L") {if ($$4 - $$3 > maxlen) { maxlen = $$4 - $$3; max_cid = cid } } END { print max_cid }' > $@
	@echo "-- selected contig $$(< $@) i.e. scaffold $$(< $@) of the test assembly"

$(EXAMPLE_ASSEMBLY_REFERENCE).fasta $(EXAMPLE_ASSEMBLY_REFERENCE).dam &: $(ASSEMBLY_REFERENCE) $(DATADIR)/scaffold_id | $(DATADIR)
	@echo "-- building example ground-truth assembly ..."
	DBshow $< $$(< $(DATADIR)/scaffold_id) | tee $@ | fasta2DAM -i $(EXAMPLE_ASSEMBLY_REFERENCE).dam

$(EXAMPLE_ASSEMBLY_TEST).fasta: $(ASSEMBLY_TEST) $(DATADIR)/scaffold_id | $(DATADIR)
	@echo "-- building example assembly ..."
	seqkit grep -p "translocated_gaps_$$(< $(DATADIR)/scaffold_id)" $< > $@

$(EXAMPLE_READS).fasta $(EXAMPLE_READ_MAPPING): $(EXAMPLE_ASSEMBLY_REFERENCE).dam | $(DATADIR)
	@echo "-- simulating reads ..."
	simulator -m25000 -s12500 -e.13 -c20 -r$(SIMULATED_READS_SEED) -M$(EXAMPLE_READ_MAPPING) $< > $@

checksum.md5: result-files.lst $(DIST_SOURCE_FILES)
	md5sum $$(< $<) > $@

$(DATADIR):
	mkdir -p $@

$(SOURCE_TARBALL): $(DOC_FILES) $(SOURCE_FILES) checksum.md5
	tar --transform='s|^|dentist-example/|' -czf $@ $^

$(DIST_TARBALL): $(DOC_FILES) $(DIST_SOURCE_FILES) $(MAIN_OUTPUTS) checksum.md5
	tar --transform='s|^|dentist-example/|' -czf $@ $^

.PHONY: clean
clean:
	rm -f $(ALL_OUTPUTS)

.PHONY: tempclean
tempclean:
	rm -f $(TEMP_OUTPUTS)

.PHONY: dist
dist: $(DIST_TARBALL)

.PHONY: tar
tar: $(SOURCE_TARBALL)

.PHONY: test
test: $(MAIN_OUTPUTS)
	$(snakemake) --configfile=snakemake.yaml -nq
	$(snakemake) --configfile=snakemake.yaml -j1 extend_dentist_config
