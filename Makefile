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
DIST_SOURCE_FILES=cluster.yml dentist.json envs/dentist.yml profile-slurm.drmaa.yml profile-slurm.submit-async.yml profile-slurm.submit-sync.yml Snakefile snakemake.yml
SOURCE_FILES=Makefile $(DIST_SOURCE_FILES)
DENTIST_VERSION=v2.0.0
DENTIST_CONTAINER=dentist_$(DENTIST_VERSION).sif
DOCKER_IMAGE=aludi/dentist
CONDA_PREFIX=.conda-env/dentist-core_$(DENTIST_VERSION)
BINDIR=bin
BINARIES=$(addprefix $(BINDIR)/,Catrack computeintrinsicqv daccord daligner DAM2fasta damapper DAScover DASqv datander DB2fasta DBa2b DBb2a DBdump DBdust DBmv DBrm DBshow DBsplit DBstats DBtrim DBwipe dentist dumpLA fasta2DAM fasta2DB LAa2b LAb2a LAcat LAcheck LAdump LAmerge lasfilteralignments LAshow LAsort LAsplit rangen simulator TANmask)
RUNTIME_ENVIRONMENT=$(DENTIST_CONTAINER) $(BINARIES)


SOURCE_TARBALL=dentist-example.source.tar.gz
DIST_TARBALL=dentist-example.tar.gz
TEMP_OUTPUTS=$(EXAMPLE_ASSEMBLY_REFERENCE).dam $(addprefix $(dir $(EXAMPLE_ASSEMBLY_REFERENCE)).$(notdir $(EXAMPLE_ASSEMBLY_REFERENCE)).,bps hdr idx) $(DATADIR)/scaffold_id
MAIN_OUTPUTS=$(EXAMPLE_ASSEMBLY_REFERENCE).fasta $(EXAMPLE_ASSEMBLY_TEST).fasta $(EXAMPLE_READS).fasta $(EXAMPLE_READ_MAPPING)
ALL_OUTPUTS=$(MAIN_OUTPUTS) $(TEMP_OUTPUTS)

snakemake=$(shell command -v snakemake)
conda=conda

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

$(BINDIR)/%: $(CONDA_PREFIX)/.timestamp | $(BINDIR)
	install $(CONDA_PREFIX)/bin/$(@F) $@

$(CONDA_PREFIX)/.timestamp: envs/dentist.yml
	mkdir -p $(CONDA_PREFIX)
	rm -rf $(CONDA_PREFIX)
	$(conda) env create --prefix $(CONDA_PREFIX) --file $<
	touch $@

.PHONY: binaries
binaries: $(BINARIES)

Snakefile: external/dentist/snakemake/Snakefile patches/conda-env.patch
	patch -o $@ $^

snakemake.yml: snakemake.template.yml $(DENTIST_CONTAINER)
	sed 's!{{CONTAINER}}!$(DENTIST_CONTAINER)!' $< > $@

envs/dentist.yml: envs/dentist.template.yml
	sed 's!{{DENTIST_VERSION}}!$(DENTIST_VERSION:v%=%)!' $< > $@

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

# --- Tests ---

SINGULARITY_TESTS=.passed-singularity-dentist-dependency-check \
				  .passed-singularity-snakemake-syntax-check \
				  .passed-singularity-snakemake-workflow


.passed-singularity-dentist-dependency-check: $(DENTIST_CONTAINER)
	singularity exec $(DENTIST_CONTAINER) dentist -d
	touch $@


.passed-singularity-snakemake-syntax-check: $(DENTIST_CONTAINER)
	$(snakemake) --configfile=snakemake.yml --use-singularity --config dentist_container=$(DENTIST_CONTAINER) -nqj1
	touch $@


.passed-singularity-snakemake-workflow: $(MAIN_OUTPUTS) $(DENTIST_CONTAINER)
	$(MAKE) clean-workflow
	$(snakemake) --configfile=snakemake.yml --use-singularity --config dentist_container=$(DENTIST_CONTAINER) -jall
	$(MAKE) check-results
	touch $@


CONDA_TESTS=.passed-conda-dentist-dependency-check \
			.passed-conda-snakemake-syntax-check \
			.passed-conda-snakemake-workflow


.passed-conda-dentist-dependency-check: $(BINARIES) $(CONDA_PREFIX)/.timestamp
	conda run --prefix $(CONDA_PREFIX) dentist -d
	touch $@


.passed-conda-snakemake-syntax-check: $(BINARIES) $(CONDA_PREFIX)/.timestamp
	$(snakemake) --use-conda --conda-frontend=conda --configfile=snakemake.yml -nqj1
	touch $@


.passed-conda-snakemake-workflow: $(MAIN_OUTPUTS) $(BINARIES) $(CONDA_PREFIX)/.timestamp
	$(MAKE) clean-workflow
	PATH="$(PWD)/$(BINDIR):$$PATH" $(snakemake) --use-conda --conda-frontend=conda --configfile=snakemake.yml -jall
	$(MAKE) check-results
	touch $@


PRECOMPILED_BINARIES_TESTS=.passed-precompiled-binaries-dentist-dependency-check \
				           .passed-precompiled-binaries-snakemake-syntax-check \
				           .passed-precompiled-binaries-snakemake-workflow


.passed-precompiled-binaries-dentist-dependency-check: $(BINARIES)
	PATH="$(PWD)/$(BINDIR):$$PATH" dentist -d
	touch $@


.passed-precompiled-binaries-snakemake-syntax-check: $(BINARIES)
	PATH="$(PWD)/$(BINDIR):$$PATH" $(snakemake) --configfile=snakemake.yml -nqj1
	touch $@


.passed-precompiled-binaries-snakemake-workflow: $(MAIN_OUTPUTS) $(BINARIES)
	$(MAKE) clean-workflow
	PATH="$(PWD)/$(BINDIR):$$PATH" $(snakemake) --configfile=snakemake.yml -jall
	$(MAKE) check-results
	touch $@


.PHONY: test-singularity
test-singularity: $(SINGULARITY_TESTS)


.PHONY: test-conda
test-conda: $(CONDA_TESTS)


.PHONY: test-precompiled-binariesaries
test-precompiled-binariesaries: $(PRECOMPILED_BINARIES_TESTS)


.PHONY: test
test: test-singularity test-conda test-precompiled-binariesaries


.PHONY: check-results
check-results:
	./check-results.sh
