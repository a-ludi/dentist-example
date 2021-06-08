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
DIST_SOURCE_FILES=cluster.yml dentist.json profile-slurm.drmaa.yml profile-slurm.submit-async.yml profile-slurm.submit-sync.yml Snakefile snakemake.yml
SOURCE_FILES=Makefile $(DIST_SOURCE_FILES)
DENTIST_VERSION=1.0.2
DENTIST_CONTAINER=dentist_$(DENTIST_VERSION).sif
BINDIR=bin
BINARIES=$(addprefix $(BINDIR)/,Catrack computeintrinsicqv daccord daligner DAM2fasta damapper DAScover DASqv datander DB2fasta DBa2b DBb2a DBdump DBdust DBmv DBrm DBshow DBsplit DBstats DBtrim DBwipe dentist dumpLA fasta2DAM fasta2DB LAa2b LAb2a LAcat LAcheck LAdump LAmerge lasfilteralignments LAshow LAsort LAsplit rangen simulator TANmask)
RUNTIME_ENVIRONMENT=$(DENTIST_CONTAINER) $(BINARIES)


SOURCE_TARBALL=dentist-example.source.tar.gz
DIST_TARBALL=dentist-example.tar.gz
TEMP_OUTPUTS=$(EXAMPLE_ASSEMBLY_REFERENCE).dam $(addprefix $(dir $(EXAMPLE_ASSEMBLY_REFERENCE)).$(notdir $(EXAMPLE_ASSEMBLY_REFERENCE)).,bps hdr idx) $(DATADIR)/scaffold_id
MAIN_OUTPUTS=$(EXAMPLE_ASSEMBLY_REFERENCE).fasta $(EXAMPLE_ASSEMBLY_TEST).fasta $(EXAMPLE_READS).fasta $(EXAMPLE_READ_MAPPING)
ALL_OUTPUTS=$(MAIN_OUTPUTS) $(TEMP_OUTPUTS)

snakemake=$(shell command -v snakemake)

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

$(BINDIR)/%: | $(BINDIR)
	id=$$(docker create dentist:$(DENTIST_VERSION)) && \
	trap 'docker rm $$id' exit && \
	docker cp "$$id:$$(docker run dentist:ubuntu which $*)" $@

.PHONY: binaries
binaries: $(BINARIES)

dentist_%.sif:
	singularity build $@ docker-daemon://dentist:$*

$(DATADIR) $(BINDIR):
	mkdir -p $@

$(SOURCE_TARBALL): $(DOC_FILES) $(SOURCE_FILES) checksum.md5
	tar --transform='s|^|dentist-example/|' --dereference -czf $@ $^

$(DIST_TARBALL): $(DOC_FILES) $(DIST_SOURCE_FILES) $(MAIN_OUTPUTS) $(RUNTIME_ENVIRONMENT) checksum.md5
	tar --transform='s|^|dentist-example/|' --dereference -czf $@ $^

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
	#singularity exec $(DENTIST_CONTAINER) dentist -d
	PATH="$(BINDIR)" dentist -d
	$(snakemake) --configfile=snakemake.yml -nq
	$(snakemake) --configfile=snakemake.yml --use-singularity -j1 -f validate_dentist_config
	PATH="$(BINDIR):$$PATH" $(snakemake) --configfile=snakemake.yml -j1 -f validate_dentist_config
