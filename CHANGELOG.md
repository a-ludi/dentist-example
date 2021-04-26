
# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project DOES NOT adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Instead the version numbers reflect the version of DENTIST.


[standard-readme]: https://github.com/RichardLitt/standard-readme


## [1.0.1-2] - 2021-04-26
### Added
- Include generated data using Git LFS
- Reference to source repo
- Included link to pre-print
- Three example profile for using Snakemake on a SLURM cluster

### Changed
- Renamed YAML files consistenly to `*.yml`
- Updated Snakefile 

### Fixed
- Compiler error and deprecation warnings


## [1.0.1-1] - 2021-02-25
### Added
- Makfile to create data and release tarball
- Release contains everything to run the example except Snakemake and
  Singularity
- Release contains MD5 checksums to validate the result
