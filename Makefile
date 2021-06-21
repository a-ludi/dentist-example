REMOTE_DATA=https://bds.mpi-cbg.de/hillerlab/DENTIST/data
DATADIR=data
ASSEMBLY_REFERENCE=$(DATADIR)/d_melanogaster/assembly-reference.dam
ASSEMBLY_REFERENCE_ALL=$(ASSEMBLY_REFERENCE) $(addprefix $(dir $(ASSEMBLY_REFERENCE)).$(notdir $(basename $(ASSEMBLY_REFERENCE))).,bps hdr idx)
ASSEMBLY_TEST=$(DATADIR)/d_melanogaster/assembly-test.fasta
SIMULATED_READS_SEED=19339
EXAMPLE_ASSEMBLY_REFERENCE=$(DATADIR)/assembly-reference
EXAMPLE_ASSEMBLY_TEST=$(DATADIR)/assembly-test
EXAMPLE_READS=$(DATADIR)/reads
EXAMPLE_READ_MAPPING=$(DATADIR)/reads.mapping.csv

DOC_FILES=README.md
DIST_SOURCE_FILES=cluster.yml dentist.json profile-slurm.drmaa.yml profile-slurm.submit-async.yml profile-slurm.submit-sync.yml Snakefile snakemake.yml
SOURCE_FILES=Makefile $(DIST_SOURCE_FILES)
DENTIST_VERSION=v2.0.0
DENTIST_CONTAINER=dentist_$(DENTIST_VERSION).sif
DOCKER_IMAGE=aludi/dentist
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

$(DATADIR)/scaffold_id: $(ASSEMBLY_REFERENCE_ALL) | $(DATADIR)
	@echo "-- selecting largest contig of ground-truth assembly corresponding to the largest scaffold in the test assembly ..."
	DBdump -rh $< | awk '($$1 == "R") { cid = $$2 } ($$1 == "L") {if ($$4 - $$3 > maxlen) { maxlen = $$4 - $$3; max_cid = cid } } END { print max_cid }' > $@
	@echo "-- selected contig $$(< $@) i.e. scaffold $$(< $@) of the test assembly"

$(EXAMPLE_ASSEMBLY_REFERENCE).fasta $(EXAMPLE_ASSEMBLY_REFERENCE).dam &: $(ASSEMBLY_REFERENCE_ALL) $(DATADIR)/scaffold_id | $(DATADIR)
	@echo "-- building example ground-truth assembly ..."
	DBshow $< $$(< $(DATADIR)/scaffold_id) | tee $@ | fasta2DAM -i $(EXAMPLE_ASSEMBLY_REFERENCE).dam

$(EXAMPLE_ASSEMBLY_TEST).fasta: $(ASSEMBLY_TEST) $(DATADIR)/scaffold_id | $(DATADIR)
	@echo "-- building example assembly ..."
	seqkit grep -p "translocated_gaps_$$(< $(DATADIR)/scaffold_id)" $< > $@

$(EXAMPLE_READS).fasta $(EXAMPLE_READ_MAPPING): $(EXAMPLE_ASSEMBLY_REFERENCE).dam | $(DATADIR)
	@echo "-- simulating reads ..."
	simulator -m25000 -s12500 -e.13 -c20 -r$(SIMULATED_READS_SEED) -M$(EXAMPLE_READ_MAPPING) $< > $@

.PHONY: fetch-data
fetch-data: $(ASSEMBLY_REFERENCE_ALL) $(ASSEMBLY_TEST)

$(ASSEMBLY_REFERENCE_ALL) $(ASSEMBLY_TEST) &: | $(DATADIR)
	wget --timestamping --no-directories --directory-prefix=$(@D) $(patsubst $(DATADIR)/%,$(REMOTE_DATA)/%,$(ASSEMBLY_REFERENCE).tar.gz $(ASSEMBLY_TEST).gz)
	cd $(@D) && tar -xzf $(notdir $(ASSEMBLY_REFERENCE).tar.gz)
	cd $(@D) && gunzip --force --keep $(notdir $(ASSEMBLY_TEST).gz)

checksum.md5: result-files.lst $(DIST_SOURCE_FILES) $(MAIN_OUTPUTS)
	md5sum $$(< $<) > $@

$(BINDIR)/%: dentist_$(DENTIST_VERSION).sif | $(BINDIR)
	singularity run -B./bin:/app/bin $< install -t /app/bin "\$$(which $*)"

.PHONY: binaries
binaries: $(BINARIES)

dentist_%.sif:
	singularity build $(patsubst B,--force,$(findstring B,$(MAKEFLAGS))) $@ docker-daemon://$(DOCKER_IMAGE):$*

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

.PHONY: clean-workflow
clean-workflow:
	rm -rf .snakemake gap-closed.{agp,fasta,closed-gaps.bed} logs workdir

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
