DENTIST\: Mini Example
======================

[![standard-readme compliant](https://img.shields.io/badge/readme%20style-standard-brightgreen.svg?style=flat)](https://github.com/RichardLitt/standard-readme)
![License](https://img.shields.io/github/license/a-ludi/dentist)
[![GitHub](https://img.shields.io/badge/GitHub-code-blue?logo=github)][dentist]

> A small example to test DENTIST's workflow

Quickly test [DENTIST][dentist] with this example workflow. It uses part of the
_D. melanogaster_ reference assembly (dm6) and simulated reads to demonstrate
the workflow. The full source code of DENTIST is available at <https://github.com/a-ludi/dentist>.


Table of Contents
-----------------

- [Install](#install)
- [Usage](#usage)
- [Troubleshooting](#troubleshooting)
- [Citation](#citation)
- [Maintainer](#maintainer)
- [Contributing](#contributing)
- [License](#license)


Install
-------

Make sure you have [Snakemake][snakemake] (5.32.1 or later) and [Singularity][singularity] 3.5.x or later installed.

If you do not want to use Singularity, you have to follow the [software setup
of DENTIST][dentist-install]. But that is much more complicated and
error-prone.


[snakemake]: https://snakemake.readthedocs.io/en/v5.11.2/getting_started/installation.html
[singularity]: https://sylabs.io/guides/3.5/user-guide/quick_start.html
[dentist-install]: https://github.com/a-ludi/dentist#install


Usage
-------

First of all download the [test data and workflow][tarball], extract it to
your favorite working directory and switch to the `dentist-example` directory.

```sh
wget https://bds.mpi-cbg.de/hillerlab/DENTIST/dentist-example.v1.0.1.tar.gz
tar -xzf dentist-example.tar.gz
cd dentist-example
```

Execute the entire workflow on your *local machine* using `all` cores:

```sh
# run the workflow
snakemake --configfile=snakemake.yaml --use-singularity --cores=all

# validate the files
md5sum -c checksum.md5
```

Execute the workflow on a *SLURM cluster*:

```sh
mkdir -p "$HOME/.config/snakemake/slurm"
cp -v "profile-slurm.yaml" "$HOME/.config/snakemake/slurm/config.yaml"
snakemake --configfile=snakemake.yaml --use-singularity --profile=slurm

# validate the files
md5sum -c checksum.md5
```

If you want to run with a differnt cluster manager or in the cloud, please
read the advice in [DENTIST's README][dentist-cluster].


[example-tarball-v1.0.1]: https://bds.mpi-cbg.de/hillerlab/DENTIST/dentist-example.v1.0.1.tar.gz
[dentist-install]: https://github.com/a-ludi/dentist#executing-on-a-cluster


Troubleshooting
---------------

When executed on a single machine, `snakemake` will sometimes quit with an
`ProtectedOutputException` ([Snakemake bug report filed][sm-884]). You may try the follow snippet to get `snakemake`
back on track:

```sh
# make sure workdir exists to avoid errors with chmod
mkdir -p workdir
# keep track of the number of retries to avoid an infinite loop
RETRY=0
# try running snakemake as long as the gap-closed assembly was not created
# and we have retries left
while [[ ! -f "gap-closed.fasta" ]] && (( RETRY++ < 3 )); do
    # allow snakemake to overwrite protected output
    chmod -R u+w workdir
    # try snakemake...
    snakemake --configfile=snakemake.yaml --use-singularity --cores=all
done
```

[sm-884]: https://github.com/snakemake/snakemake/issues/884


Citation
--------

> Arne Ludwig, Martin Pippel, Gene Myers, Michael Hiller. DENTIST – using long
> reads to close assembly gaps at high accuracy. _In preparation._


Maintainer
----------

DENTIST is being developed by Arne Ludwig &lt;<ludwig@mpi-cbg.de>&gt; at
the Planck Institute of Molecular Cell Biology and Genetics, Dresden, Germany.


License
-------

This project is licensed under MIT License (see [LICENSE](./LICENSE)).


[dentist]: https://github.com/a-ludi/dentist "Source Code of DENTIST at GitHub"