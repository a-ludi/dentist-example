from snakemake.utils import min_version

min_version("5.32.1")

import base64
import json
from itertools import chain
from math import *
from os import environ
from os.path import basename, exists, join
import re
import shlex
import subprocess


# Declare variables so they are available in functions
# They get populated with proper values later on
workdir_ = None
logdir = None
insertions_batch = None
custom_auxiliary_threads = None
batch_size = None
dentist_container = None
dentist_env = None
singularity_image = None
conda_env = None


#-----------------------------------------------------------------------------
# BEGIN functions
#-----------------------------------------------------------------------------


def prefetch_singularity_image(container_url):
    global singularity_image

    if not workflow.use_singularity or not singularity_image is None:
        return

    from snakemake.deployment.singularity import Image
    from snakemake.persistence import Persistence
    from snakemake.logging import logger

    dag = type('FakeDAG', (object,), dict(
        workflow=type('FakeWorkflow', (object,), dict(
                persistence=Persistence(singularity_prefix=workflow.singularity_prefix)
            ))))

    singularity_image = None
    try:
        singularity_image = Image(container_url, dag, is_containerized=True)
    except TypeError:
        singularity_image = Image(container_url, dag)

    if not exists(singularity_image.path):
        logger.info("Pre-fetching singularity image...")
        singularity_image.pull()


def prefetch_conda_env(env_file):
    global conda_env

    if not workflow.use_conda or not conda_env is None:
        return

    from snakemake.deployment.conda import Env
    from snakemake.persistence import Persistence

    dag = type('FakeDAG', (object,), dict(
        workflow=type('FakeWorkflow', (object,), dict(
                persistence=Persistence(conda_prefix=workflow.conda_prefix),
                conda_frontend=workflow.conda_frontend,
                singularity_args=workflow.singularity_args,
                sourcecache=getattr(workflow, "sourcecache", None)
            ))))

    # This makes older versions of Snakemake work
    dag.workflow.workflow = dag.workflow

    conda_env = Env(
        env_file,
        dag.workflow,
        container_img=singularity_image,
        cleanup=workflow.conda_cleanup_pkgs,
    )
    conda_env.create()


def shellcmd(cmd):
    if workflow.use_singularity:
        from snakemake.deployment import singularity

        return singularity.shellcmd(dentist_container, cmd,
                                    workflow.singularity_args,
                                    container_workdir=workflow.singularity_prefix)
    elif workflow.use_conda:
        from snakemake.deployment.conda import Conda

        conda = None
        if hasattr(workflow, "conda_base_path"):
            conda = Conda(singularity_image, prefix_path=workflow.conda_base_path)
        else:
            conda = Conda(singularity_image)
        conda_cmd = conda.shellcmd(conda_env.path, cmd)

        return conda_cmd
    else:
        return cmd


def rel_to_workdir(path):
    from os.path import relpath

    return relpath(path, workdir_)


def db_stub(db_file):
    from os.path import splitext

    return splitext(db_file)[0]


def db_name(db_file):
    from os.path import basename

    return basename(db_stub(db_file))


def prepend_ext(filename, ext):
    from os.path import splitext

    parts = splitext(filename)

    return parts[0] + ext + parts[1]


def fasta_to_workdb(fasta_file, ext):
    return join(workdir_, "{db}.{ext}".format(db=db_name(fasta_file), ext=ext))


def assembly_marker(db):
    return join(workdir_, ".assembly.{db}".format(db=db_name(db)))


def reads_marker(db):
    return join(workdir_, ".reads.{db}".format(db=db_name(db)))


def fasta2dazz_command(target_db):
    if target_db.endswith(".db"):
        return "fasta2DB"
    else:
        return "fasta2DAM"


def db_files(db):
    from os.path import dirname

    hidden_db_file_suffixes = [".bps", ".idx"]
    hidden_dam_file_suffixes = [".bps", ".hdr", ".idx"]
    root = dirname(db)
    suffixes = hidden_db_file_suffixes if db.endswith(".db") \
                else hidden_dam_file_suffixes

    def __hidden_file(suffix):
        if root:
            return "{}/.{}{}".format(root, db_name(db), suffix)
        else:
            return ".{}{}".format(db_name(db), suffix)

    return [db] + [__hidden_file(suffix)  for suffix in suffixes]


class IgnoreMissingFormat(dict):
    def __missing__(self, key):
        return "{" + key + "}"


def expand_wildcards(string, wildcards, more_attributes={}):
    format_dict = IgnoreMissingFormat(wildcards)

    for key, value in more_attributes.items():
        if not key in format_dict:
            format_dict[key] = value

    return string.format_map(format_dict)


_fast2dam_checkpoint = dict()


def await_db_files(db):
    from os.path import splitext

    def __await_db_files(wildcards):
        expanded_db = expand_wildcards(db, wildcards)

        if expanded_db in _fast2dam_checkpoint:
            _checkpoint = getattr(checkpoints, _fast2dam_checkpoint[expanded_db])
            outputs = _checkpoint.get(workdir=workdir_).output

            if not isinstance(outputs, list):
                raise Exception("checkpoint {} should have a list of string as output, got: {!r}".format(
                    _fast2dam_checkpoint[expanded_db],
                    outputs,
                ))
            elif outputs[0] != expanded_db:
                raise Exception("first output of checkpoint {} should be {} but got {}".format(
                    _fast2dam_checkpoint[expanded_db],
                    expanded_db,
                    outputs[0],
                ))

            return outputs
        else:
            raise Exception("unknown db: {}".format(expanded_db));

    return __await_db_files


def await_pile_ups():
    def __await_pile_ups(wildcards):
        return checkpoints.collect.get().output

    return __await_pile_ups


def alignment_file(db_a, db_b=None, block_a=None, block_b=None):
    if db_b is None:
        db_b = db_a
    db_a = db_name(db_a)
    db_b = db_name(db_b)

    filename = None
    if block_a is None and block_b is None:
        filename = "{}.{}.las".format(db_a, db_b)
    elif block_a is None:
        filename = "{}.{}.{}.las".format(db_a, db_b, block_b)
    elif block_b is None:
        filename = "{}.{}.{}.las".format(db_a, block_a, db_b)
    else:
        filename = "{}.{}.{}.{}.las".format(db_a, block_a, db_b, block_b)

    return join(workdir_, filename)


def shell_esc(string):
    try:
        from shlex import quote
    except ImportError:
        from pipes import quote

    return quote(string)


def make_flags(flags):
    try:
        from shlex import join
    except ImportError:
        try:
            from shlex import quote
        except ImportError:
            from pipes import quote

        def join(split_command):
            return " ".join(quote(cmd)  for cmd in split_command)


    if str(flags) == flags:
        return flags
    else:
        return join(flags)


def append_flags(flags, *new_flags):
    try:
        from shlex import quote
    except ImportError:
        from pipes import quote

    if len(flags) == 0:
        return make_flags(new_flags)
    else:
        return flags + " " + make_flags(new_flags)


def prepare_flags(flags):
    def secondary_expand(wildcards, input=None, output=None, threads=None, resources=None):
        txtflags = flags if not callable(flags) else flags()
        txtflags = deduplicate_flags(txtflags)

        return txtflags.format(wildcards=wildcards,
                            input=input,
                            output=output,
                            threads=threads,
                            resources=resources)

    return secondary_expand


def ensure_threads_flag(flags):
    return ensure_flags(flags, { "-T": "{threads}" })


def ensure_masks(flags, *masks):
    return ensure_flags(flags, { "-m": list(masks) })


def ensure_flags(flags, flags_with_values):
    from shlex import split

    def __keep_flag(flag):
        fname = flag[0:2]
        fvalue = flag[2:]

        if not fname in flags_with_values:
            return True
        elif fname in flags_with_values and not isinstance(flags_with_values[fname], list):
            return False
        elif fname in flags_with_values and isinstance(flags_with_values[fname], list):
            return not fvalue in flags_with_values[fname]

    flags = list(f  for f in split(flags) if __keep_flag(f))

    for flag, value in flags_with_values.items():
        if value is True:
            flags.append(flag)
        elif isinstance(value, list):
            flags.extend((str(flag) + str(v)  for v in value))
        elif value:
            flags.append(flag + str(value))

    return make_flags(flags)


def deduplicate_flags(flags):
    from shlex import split

    present_flags = set()
    deduplicated = list()
    for f in split(flags):
        if not f.startswith("-"):
            deduplicated.append(f)
        elif not f in present_flags:
            present_flags.add(f)
            deduplicated.append(f)

    return make_flags(deduplicated)


def assert_flag(flags, required_flag, message="required flag is missing: {missing_flags}"):
    assert_flags(flags, [required_flag], message)


def assert_flags(flags, required_flags, message="required flag(s) are missing: {missing_flags}"):
    from shlex import split

    present_flags = dict(((f[0:2], True)  for f in split(flags)))

    missing_flags = list()
    for required_flag in required_flags:
        if not present_flags.get(required_flag, False):
            missing_flags.append(required_flag)

    if len(missing_flags) > 0:
        e = AssertionError(message.format(missing_flags=", ".join(missing_flags)))
        e.missing_flags = missing_flags

        raise e


def log_file(step):
    return join(logdir, "{}.log".format(step))


def auxiliary_threads(wildcards, threads):
    if not custom_auxiliary_threads is None:
        return custom_auxiliary_threads
    else:
        return max(1, threads // 4)


def main_threads(wildcards, threads):
    return threads // auxiliary_threads(wildcards, threads=threads)


def dentist_validate_file(config_file):
    validate_cmd = shellcmd("dentist validate-config {}".format(shell_esc(config_file)))
    validate_result = subprocess.run(validate_cmd, shell=True, text=True, check=True,
                                     stderr=subprocess.PIPE, stdout=subprocess.PIPE)


def full_validate_dentist_config(config_file):
    errors = list()
    config = None
    with open(config_file, 'r') as cf:
        config = json.load(cf)

    def prohibit_revert_in_default():
        if "__default__" in config:
            if "revert" in config["__default__"]:
                errors.append("highly discouraged use of `revert` in `__default__`")

    def __get_presence_of_flags(command, *inspect_flags):
        flags = dict()
        if "__default__" in config:
            for flag in inspect_flags:
                flags[flag] = flag in config["__default__"]
        if command in config:
            for flag in inspect_flags:
                flags[flag] = flag in config[command]
            if "revert" in config[command]:
                for flag in inspect_flags:
                    if flag in config[command]["revert"]:
                        flags[flag] = False
        return flags

    def check_presence_of_read_masking_threshold():
        flags = __get_presence_of_flags("mask-repetitive-regions", "read-coverage", "max-coverage-reads")

        if not (flags["read-coverage"] ^ flags["max-coverage-reads"]):
            errors.append("must specify either --read-coverage or --max-coverage-reads for command `mask-repetitive-regions`")

    def check_presence_of_validation_coverage_threshold():
        flags = __get_presence_of_flags("validate-regions", "read-coverage", "ploidy", "min-coverage-reads")

        if not ((flags["read-coverage"] and flags["ploidy"]) ^ flags["min-coverage-reads"]):
            errors.append("must specify either --read-coverage and --ploidy or --min-coverage-reads for command `validate-regions")

    prohibit_revert_in_default()
    check_presence_of_read_masking_threshold()
    check_presence_of_validation_coverage_threshold()

    try:
        dentist_validate_file(config_file);
    except subprocess.CalledProcessError as e:
        errors.append(e.stderr)

    if len(errors) > 0:
        raise Exception("; ".join(errors))

    return config


def is_dentist_testing():
    cmd = shellcmd("dentist --version 2>&1 | grep -qF '+testing'")

    return subprocess.call(cmd, shell=True) == 0


def generate_options_for(alignment_name, config_file, additional_flags=None):
    if not exists(config_file):
        return "false"

    generate_template = "dentist generate --quiet --config={}"
    generate_cmd = shellcmd(generate_template.format(config_file, shell_esc(alignment_name)))
    generate_proc = subprocess.run(generate_cmd,
                                   shell=True,
                                   stderr=subprocess.PIPE,
                                   stdout=subprocess.PIPE)
    commands = generate_proc.stdout.decode().splitlines()

    if generate_proc.returncode != 0 or len(commands) == 0:
        verbose_generate_cmd = generate_cmd.replace("--quiet", "-v -v")
        error = generate_proc.stderr.decode()

        raise Exception("failed to get alignment commands: " + error)

    while not commands[0].startswith("#"):
        commands = commands[1:]

    for comment, command in zip(commands[::2], commands[1::2]):
        if alignment_name in comment:
            command = re.sub(r"<[^>]+>", "", command)
            command = command.rstrip()
            if not additional_flags is None:
                command += " " + additional_flags

            return command

    raise Exception("failed to get alignment command: unknown alignment_name `{}`".format(alignment_name))


def get_num_blocks(db):
    try:
        with open(db, 'r') as db_file:
            for line in db_file:
                if line.startswith("blocks ="):
                    return int(line.rpartition(" ")[2])

        raise EOFError("DB not split: {}".format(db))
    except FileNotFoundError:
        return 1


__num_contigs_regex = re.compile(r"^\+\s+R\s+(?P<num_contigs>\d+)\s*$", re.MULTILINE)


def get_num_contigs(db):
    try:
        cmd = shellcmd("DBdump {}".format(shell_esc(db)))
        dbdump = subprocess.check_output(cmd, shell=True, text=True)
        match = __num_contigs_regex.match(dbdump)

        if not match:
            raise Exception("Could not read number of contigs in {}".format(db))

        return int(match.group("num_contigs"))
    except subprocess.CalledProcessError:
        return 1


FULL_DB = object()


class block_range:
    def __init__(self, batch_size):
        self.batch_size = batch_size


def blocks_for(db, batch_size, block=None):
    def __dbblocks(db, batch_size):
        num_blocks = get_num_blocks(db)
        range_requested = isinstance(batch_size, block_range) or batch_size > 1
        if isinstance(batch_size, block_range):
            batch_size = batch_size.batch_size
        blocks = range(1, num_blocks + 1, batch_size)

        def __range(b):
            return "{}-{}".format(b, min(b + batch_size - 1, num_blocks))

        if range_requested:
            blocks = [__range(b)  for b in blocks]

        return blocks

    def __block_or_range(block):
        if isinstance(block, str):
            parts = block.split("-")

            if len(parts) == 1:
                return [parts[0]]
            elif len(parts) == 2:
                return range(int(parts[0]), int(parts[1]) + 1)
            else:
                raise ValueError("illegal value for block: " + block)
        else:
            return iter(block)

    if block is FULL_DB:
        return None
    elif block is None:
        return __dbblocks(db, batch_size)
    else:
        return __block_or_range(block)


def block_alignments(db_a, db_b=None, block_a=None, block_b=None):
    if db_b is None:
        db_b = db_a

    blocks_a = blocks_for(db_a, 1, block_a)
    blocks_b = blocks_for(db_b, 1, block_b)

    if not blocks_a is None and not blocks_b is None:
        return (alignment_file(db_a, db_b, i, j)  for i in blocks_a for j in blocks_b)
    elif not blocks_b is None:
        return (alignment_file(db_a, db_b, block_b=j)  for j in blocks_b)
    elif not blocks_a is None:
        return (alignment_file(db_a, db_b, block_a=i)  for i in blocks_a)
    else:
        raise Exception("illegal block selection: both block_a and block_b are empty")


def homogenized_mask(mask):
    return mask + "-H"


def block_mask(mask, block):
    return "{}.{}".format(block, mask)


def block_masks(mask, db):
    return [block_mask(mask, b + 1)  for b in range(get_num_blocks(db))]


def pseudo_block_mask(mask, block):
    return "{}-{}B".format(mask, block)


def pseudo_block_masks(mask, db, block=None):
    blocks = blocks_for(db, 1, block)

    return [pseudo_block_mask(mask, b)  for b in blocks]


def mask_files(db, mask, *, block=None, pseudo_block=False):
    from os.path import dirname

    suffixes = ["anno", "data"]
    root = dirname(db)

    if isinstance(pseudo_block, str):
        block = pseudo_block
        pseudo_block = True

    if not block is None:
        if pseudo_block:
            mask = pseudo_block_mask(mask, block)
        else:
            mask = block_mask(mask, block)

    def __mask_files(suffix):
        if root:
            return "{}/.{}.{}.{}".format(root, db_name(db), mask, suffix)
        else:
            return ".{}.{}.{}".format(db_name(db), mask, suffix)

    return (__mask_files(suffix)  for suffix in suffixes)


def batch_range(wildcards, batch_size, num_elements):
    batch_id = int(wildcards.batch_id, base=10)
    from_index = batch_id * batch_size
    to_index = min(from_index + batch_size, num_elements)

    return "{}..{}".format(from_index, to_index)


def insertion_batch_range(wildcards):
    return batch_range(wildcards, batch_size, get_num_pile_ups())


def get_num_pile_ups():
    # emit at least one pile up in order to prevent the DAG from falling apart
    num_pile_ups = 1

    if exists(pile_ups):
        try:
            info_cmd = "dentist show-pile-ups -j {}".format(shell_esc(pile_ups))
            info_cmd = shellcmd(info_cmd)
            pile_ups_info_json = subprocess.check_output(info_cmd, shell=True, stderr=subprocess.DEVNULL)
            pile_ups_info = json.loads(pile_ups_info_json)
            num_pile_ups = pile_ups_info["numPileUps"]
        except subprocess.CalledProcessError as e:
            raise e


    return num_pile_ups


def ceildiv(n, d):
    return (n + d - 1) // d


def insertions_batches():
    num_pile_ups = get_num_pile_ups()
    num_batches = ceildiv(num_pile_ups, batch_size)
    num_digits = int(ceil(log10(num_batches)))
    batch_id_format = "{{:0{}d}}".format(num_digits)

    def get_insertions_batch(batch_id):
        batch_id = batch_id_format.format(batch_id)

        return insertions_batch.format(batch_id=batch_id)

    return [get_insertions_batch(i)  for i in range(num_batches)]


def docstring(string):
    paragraph_sep = re.compile(r"\n\s*\n")
    whitespace = re.compile(r"\s+")

    paragraphs = paragraph_sep.split(string)
    paragraphs = (whitespace.sub(" ", par).strip()  for par in paragraphs)

    return "\n\n".join(paragraphs)


def replace_env(string, envdict=environ):
    import re

    env_re = re.compile(r"\$(?P<var>\$|[a-zA-Z_][a-zA-Z0-9_]*|\{[a-zA-Z_][a-zA-Z0-9_]*\})")

    def fetch_env(match):
        varname = match["var"]

        if varname == "$":
            return "$"
        elif varname.startswith("{"):
            return envdict[varname[1:-1]]
        else:
            return envdict[varname]

    fullmatch = env_re.fullmatch(string)
    if fullmatch:
        return fetch_env(fullmatch)
    else:
        return env_re.sub(lambda m: str(fetch_env(m)), string)


def replace_env_rec(obj, envdict=environ):
    iterable = None

    if isinstance(obj, str):
        return replace_env(obj, envdict)
    elif isinstance(obj, list):
        iterable = enumerate(obj)
    elif isinstance(obj, dict):
        iterable = obj.items()
    else:
        return obj

    for k, v in iterable:
        obj[k] = replace_env_rec(v, envdict)

    return obj


#-----------------------------------------------------------------------------
# END functions
#-----------------------------------------------------------------------------


#-----------------------------------------------------------------------------
# Variables for rules
#-----------------------------------------------------------------------------

augmented_env = replace_env_rec(config.pop("default_env", dict()))

if isinstance(augmented_env, dict):
    for k, v in environ.items():
        augmented_env[k] = v
else:
    raise Exception("expected dictionary for config[default_env] but got: " + type(augmented_env))

override_env = replace_env_rec(config.pop("override_env", dict()))
if isinstance(override_env, dict):
    for k, v in override_env.items():
        augmented_env[k] = v
else:
    raise Exception("expected dictionary for config[override_env] but got: " + type(override_env))

for k, v in augmented_env.items():
    environ[k] = str(v)

config = replace_env_rec(config, augmented_env)

# config shortcuts
inputs = config["inputs"]
outputs = config["outputs"]
workdir_ = config["workdir"]
logdir = config["logdir"]
workflow_ = config.get("workflow", {})
max_threads = config["max_threads"]
custom_auxiliary_threads = config.get("auxiliary_threads", None)
propagate_batch_size = config["propagate_batch_size"]
batch_size = config["batch_size"]
validation_blocks = config["validation_blocks"]
workflow_flags_names = ["full_validation", "no_purge_output"]
workflow_flags = dict(((flag, config.get(flag, False))  for flag in workflow_flags_names))
dentist_container = config.get("dentist_container", "docker://aludi/dentist:stable")
dentist_env = "envs/dentist.yml"

if workflow.use_singularity:
    prefetch_singularity_image(dentist_container)

if workflow.use_conda:
    prefetch_conda_env(dentist_env)


# workflow files
reference_fasta = inputs["reference"]
reads_fasta = inputs["reads"]
gap_closed_fasta = outputs["output_assembly"]
gap_closed_agp = db_stub(gap_closed_fasta) + ".agp"
preliminary_gap_closed_fasta = join(workdir_, db_name(outputs["output_assembly"]) + "-preliminary.fasta")
validation_report = outputs.get("validation_report", join(workdir_, "validation-report.json"))
validation_report_block = join(workdir_, "validation-report.{block_ref}.json")
gap_closed = fasta_to_workdb(gap_closed_fasta, "dam")
preliminary_gap_closed = fasta_to_workdb(preliminary_gap_closed_fasta, "dam")
closed_gaps_mask = workflow_.get("closed_gaps_mask", "closed-gaps")
preliminary_closed_gaps_agp = join(workdir_, "{}.{}.agp".format(db_name(preliminary_gap_closed), closed_gaps_mask))
preliminary_closed_gaps_bed = join(workdir_, "{}.{}.bed".format(db_name(preliminary_gap_closed), closed_gaps_mask))
closed_gaps_bed = "{}.{}.bed".format(db_stub(gap_closed_fasta), closed_gaps_mask)
reference = fasta_to_workdb(reference_fasta, "dam")
reads_db_type = "db" if inputs["reads_type"] == "PACBIO_SMRT" else "dam"
reads = fasta_to_workdb(reads_fasta, reads_db_type)
dentist_config_file = config.get("dentist_config", "dentist.json")
dentist_config = full_validate_dentist_config(dentist_config_file)
dentist_merge_config_file = join(workdir_, workflow_.get("dentist_merge_config_file", "dentist.merge.json"))
skip_gaps = join(workdir_, workflow_.get("skip-gaps", "skip-gaps.txt"))
self_alignment = alignment_file(reference)
tandem_alignment = alignment_file("TAN", reference)
tandem_alignment_block = alignment_file("TAN", reference, block_b="{block}")
ref_vs_reads_alignment = alignment_file(reference, reads)
reads_vs_ref_alignment = alignment_file(reads, reference)
preliminary_gap_closed_vs_reads_alignment = alignment_file(preliminary_gap_closed, reads)
self_mask = workflow_.get("self_mask", "dentist-self")
dust_mask = "dust"
tandem_mask = "tan"
reads_mask = workflow_.get("reads_mask", "dentist-reads")
weak_coverage_mask = workflow_.get("weak_coverage_mask", "dentist-weak-coverage")
masks = [
    self_mask,
    tandem_mask,
    reads_mask,
]
propagate_mask_batch_marker = join(workdir_, ".propagted-mask.{mask}.{blocks_reads}")
pile_ups = join(workdir_, workflow_.get("pile_ups", "pile-ups.db"))
insertions_batch = join(workdir_, workflow_.get("insertions_batch", "insertions/batch.{batch_id}.db"))
insertions = join(workdir_, workflow_.get("insertions", "insertions.db"))

# command-specific
from os import environ
dentist_flags = environ.get("DENTIST_FLAGS", "")
preliminary_output_revert_options = ["scaffolding", "skip-gaps", "skip-gaps-file"]

if is_dentist_testing():
    preliminary_output_revert_options.append("cache-contig-alignments")

additional_reference_dbsplit_options = make_flags(config.get("reference_dbsplit", []))
assert_flag(
    additional_reference_dbsplit_options,
    "-x",
    "DBsplit should have a -x flag; provide at minimum -x20 to avoid errors",
)
additional_reads_dbsplit_options = make_flags(config.get("reads_dbsplit", []))
assert_flag(
    additional_reads_dbsplit_options,
    "-x",
    "DBsplit should have a -x flag; provide at minimum -x20 to avoid errors",
)
additional_tanmask_options = make_flags(config.get("tanmask", []))
additional_tanmask_options = ensure_flags(additional_tanmask_options, {
    "-v": True,
    "-n": tandem_mask,
})

additional_lamerge_options = make_flags(["-v"])

if "TMPDIR" in environ:
    tmpdir_flag = { "-P": environ["TMPDIR"] }
    additional_lamerge_options = ensure_flags(additional_lamerge_options, tmpdir_flag)


def LAmerge(merged="output", parts="input[block_alignments]", dbs="params.dbs", log="log"):
    lamerge_cmd = " ".join([
        "LAmerge",
        "{additional_lamerge_options}",
        "{" + merged + ":q}",
        "{" + parts + ":q}"])

    if log:
        return lamerge_cmd + " &> {" + log + ":q}"
    else:
        return lamerge_cmd


#-----------------------------------------------------------------------------
# BEGIN rules
#-----------------------------------------------------------------------------

localrules:
    ALL,
    validate_dentist_config,
    reference2dam,
    mark_assembly_reference,
    preliminary_gap_closed2dam,
    mark_assembly_preliminary_gap_closed,
    mask_tandem,
    reads2db,
    mark_reads,
    propagate_mask_batch,
    propagate_mask_back_to_reference,
    full_masking,
    make_merge_config,
    merge_insertions,
    split_preliminary_gap_closed_vs_reads_alignment,
    preliminary_closed_gaps_bed2mask,
    validate_regions,
    weak_coverage_mask,
    skip_gaps


wildcard_constraints:
    dam = r"[^/\.]+",
    block_reads = r"[0-9]+",
    block_ref = r"[0-9]+",
    block = r"[0-9]+",
    blocks_reads = r"[0-9]+-[0-9]+",
    blocks_ref = r"[0-9]+-[0-9]+",
    blocks = r"[0-9]+-[0-9]+"


default_targets = [
    gap_closed_fasta,
    closed_gaps_bed,
]

if workflow_flags["full_validation"]:
    default_targets.append([
        validation_report,
        mask_files(preliminary_gap_closed, weak_coverage_mask),
    ])


rule ALL:
    input: default_targets


rule validate_dentist_config:
    input: dentist_config_file
    container: dentist_container
    conda: dentist_env
    script: "scripts/validate_dentist_config.py"


_fast2dam_checkpoint[reference] = "reference2dam"
checkpoint reference2dam:
    input: reference_fasta
    output: *db_files(reference)
    container: dentist_container
    conda: dentist_env
    shell:
        "fasta2DAM {output[0]} {input} && DBsplit {additional_reference_dbsplit_options} {output[0]}"


# _fast2dam_checkpoint[reference] = "reference2dam"
# if reference_fasta.endswith(".dam"):
#     checkpoint reference2dam:
#         input: db_files(reference_fasta)
#         output: *db_files(reference)
#         container: dentist_container
#         conda: dentist_env
#         shell:
#             "fasta2DAM {output[0]} {input} && DBsplit {additional_reference_dbsplit_options} {output[0]}"
# else:
#     checkpoint reference2dam:
#         input: reference_fasta
#         output: *db_files(reference)
#         container: dentist_container
#         conda: dentist_env
#         shell:
#             "fasta2DAM {output[0]} {input} && DBsplit {additional_reference_dbsplit_options} {output[0]}"


rule mark_assembly_reference:
    input: reference_fasta
    output: touch(assembly_marker(reference))


_fast2dam_checkpoint[preliminary_gap_closed] = "preliminary_gap_closed2dam"
checkpoint preliminary_gap_closed2dam:
    input: preliminary_gap_closed_fasta
    output: *db_files(preliminary_gap_closed)
    container: dentist_container
    conda: dentist_env
    shell:
        "fasta2DAM {output[0]} {input} && DBsplit {additional_reference_dbsplit_options} {output[0]}"


rule mark_assembly_preliminary_gap_closed:
    input: preliminary_gap_closed_fasta
    output: touch(assembly_marker(preliminary_gap_closed))


rule mask_dust:
    input:
        await_db_files(join(workdir_, "{dam}.dam")),
        assembly_marker("{dam}.dam")
    output:
        mask_files(join(workdir_, "{dam}.dam"), dust_mask)
    params:
        dustcmd = prepare_flags(lambda : generate_options_for("DBdust reference", dentist_config_file)),
    container: dentist_container
    conda: dentist_env
    shell:
        "{params.dustcmd} {workdir_}/{wildcards.dam}"


rule self_alignment_block:
    input:
        dentist_config_file,
        await_db_files(join(workdir_, "{dam}.dam")),
        assembly_marker("{dam}.dam"),
        mask_files(join(workdir_, "{dam}.dam"), dust_mask),
        mask_files(join(workdir_, "{dam}.dam"), tandem_mask)
    output:
        temp(alignment_file("{dam}", block_a='{block_ref}', block_b='{block_reads}')),
        temp(alignment_file("{dam}", block_b='{block_ref}', block_a='{block_reads}'))
    params:
        aligncmd = prepare_flags(lambda : generate_options_for("self", dentist_config_file, ensure_masks("", dust_mask, tandem_mask))),
        alignment_file_a_vs_b = lambda _, output: basename(output[0]),
        alignment_file_b_vs_a = lambda _, output: basename(output[1])
    threads: max_threads
    log: log_file("self-alignment.{dam}.{block_ref}.{block_reads}")
    container: dentist_container
    conda: dentist_env
    shell:
        """
            {{
                cd {workdir_}
                {params.aligncmd} {wildcards.dam}.{wildcards.block_ref} {wildcards.dam}.{wildcards.block_reads}
            }} &> {log}
        """


rule self_alignment:
    input:
        db = await_db_files(join(workdir_, "{dam}.dam")),
        marker = assembly_marker("{dam}.dam"),
        block_alignments = lambda wildcards: block_alignments(join(workdir_, wildcards.dam + ".dam"))
    output:
        protected(alignment_file("{dam}"))
    params:
        dbs = lambda _, input: input.db[0]
    log: log_file("self-alignment.{dam}")
    container: dentist_container
    conda: dentist_env
    shell: LAmerge()



rule mask_self:
    input:
        dentist_config_file,
        dam = await_db_files(join(workdir_, "{dam}.dam")),
        marker = assembly_marker("{dam}.dam"),
        alignment = alignment_file("{dam}")
    output:
        mask_files(join(workdir_, "{dam}.dam"), self_mask)
    log: log_file("mask-self.{dam}")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist mask --config={dentist_config_file} {dentist_flags} {input.dam[0]} {input.alignment} {self_mask} 2> {log}"


rule tandem_alignment_block:
    input:
        dentist_config_file,
        await_db_files(join(workdir_, "{dam}.dam")),
        assembly_marker("{dam}.dam")
    output:
        temp(alignment_file("TAN", "{dam}", block_b="{block}"))
    params:
        aligncmd = prepare_flags(lambda : generate_options_for("tandem", dentist_config_file)),
        alignment_file = lambda _, output: basename(output[0])
    log: log_file("tandem-alignment.{dam}.{block}")
    threads: max_threads
    container: dentist_container
    conda: dentist_env
    shell:
        """
            {{
                cd {workdir_}
                {params.aligncmd} {wildcards.dam}.{wildcards.block}
            }} &> {log}
        """


rule tandem_alignment:
    input:
        db = await_db_files(join(workdir_, "{dam}.dam")),
        marker = assembly_marker("{dam}.dam"),
        block_alignments = lambda wildcards: block_alignments("TAN", join(workdir_, wildcards.dam + ".dam"), block_a=FULL_DB)
    output:
        protected(alignment_file("TAN", "{dam}"))
    params:
        dbs = lambda _, input: input.db[0]
    log: log_file("tandem-alignment.{dam}")
    container: dentist_container
    conda: dentist_env
    shell: LAmerge()


rule mask_tandem_block:
    input:
        await_db_files(join(workdir_, "{dam}.dam")),
        assembly_marker("{dam}.dam"),
        alignment = alignment_file("TAN", "{dam}", block_b="{block}")
    output:
        temp(mask_files(join(workdir_, "{dam}.dam"), block_mask(tandem_mask, "{block}")))
    params:
        reference_stub = join(workdir_, "{dam}"),
        tanmask_options = prepare_flags(additional_tanmask_options)
    log: log_file("mask-tandem.{dam}.{block}")
    container: dentist_container
    conda: dentist_env
    shell:
        "TANmask {params[tanmask_options]} {params.reference_stub} {input[alignment]} &> {log}"


rule mask_tandem:
    input:
        dentist_config_file,
        db = await_db_files(join(workdir_, "{dam}.dam")),
        marker = assembly_marker("{dam}.dam"),
        mask_files = lambda wildcards: chain(*(mask_files(join(workdir_, "{dam}.dam"), m)  for m in block_masks(tandem_mask, join(workdir_, wildcards.dam + ".dam"))))
    output:
        mask_files(join(workdir_, "{dam}.dam"), tandem_mask)
    log: log_file("mask-tandem.{dam}")
    container: dentist_container
    conda: dentist_env
    shell:
        "Catrack -v {input.db[0]} {tandem_mask} &> {log}"


_fast2dam_checkpoint[reads] = "reads2db"
checkpoint reads2db:
    input: reads_fasta
    output: *db_files(reads)
    params:
        fasta2dazz = fasta2dazz_command(reads)
    container: dentist_container
    conda: dentist_env
    shell:
        "{params.fasta2dazz} {output[0]} {input} && DBsplit {additional_reads_dbsplit_options} {output[0]}"


rule mark_reads:
    input: reads_fasta
    output: touch(reads_marker(reads))


rule ref_vs_reads_alignment_block:
    input:
        dentist_config_file,
        await_db_files(reference),
        await_db_files(reads),
        mask_files(reference, dust_mask),
        mask_files(reference, self_mask),
        mask_files(reference, tandem_mask)
    output:
        alignment_file(reference, reads, block_b='{block_reads}'),
        alignment_file(reads, reference, block_a='{block_reads}')
    params:
        aligncmd = prepare_flags(lambda : generate_options_for("reads", dentist_config_file, ensure_masks("", dust_mask, self_mask, tandem_mask))),
        reference_stub = db_stub(rel_to_workdir(reference)),
        reads_stub = db_stub(rel_to_workdir(reads)),
        alignment_file_a_vs_b = lambda _, output: basename(output[0]),
        alignment_file_b_vs_a = lambda _, output: basename(output[1])
    threads: max_threads
    log: log_file("ref-vs-reads-alignment.{block_reads}")
    container: dentist_container
    conda: dentist_env
    shell:
        """
            {{
                cd {workdir_}
                {params.aligncmd} {params.reference_stub} {params.reads_stub}.{wildcards.block_reads}
            }} &> {log}
        """


rule ref_vs_reads_alignment:
    input:
        refdb = await_db_files(reference),
        readsdb = await_db_files(reads),
        block_alignments = lambda _: block_alignments(reference, reads, block_a=FULL_DB)
    output:
        protected(ref_vs_reads_alignment)
    params:
        dbs = lambda _, input: (input.refdb[0], input.readsdb[0])
    log: log_file("ref-vs-reads-alignment")
    container: dentist_container
    conda: dentist_env
    shell: LAmerge()


rule reads_vs_ref_alignment:
    input:
        refdb = await_db_files(reference),
        readsdb = await_db_files(reads),
        block_alignments = lambda _: block_alignments(reads, reference, block_b=FULL_DB)
    output:
        protected(reads_vs_ref_alignment)
    params:
        dbs = lambda _, input: (input.readsdb[0], input.refdb[0])
    log: log_file("reads-vs-ref-alignment")
    container: dentist_container
    conda: dentist_env
    shell: LAmerge()


rule mask_reads:
    input:
        dentist_config_file,
        await_db_files(reference),
        await_db_files(reads),
        ref_vs_reads_alignment
    output:
        mask_files(reference, reads_mask)
    log: log_file("mask-reads")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist mask --config={dentist_config_file} {dentist_flags} {reference} {reads} {ref_vs_reads_alignment} {reads_mask} 2> {log}"


rule propagate_mask_to_reads_block:
    input:
        dentist_config_file,
        await_db_files(reference),
        await_db_files(reads),
        mask_files(reference, "{mask}"),
        alignment = alignment_file(reference, reads, block_b='{block_reads}')
    output:
        mask_files(reads, "{mask}", pseudo_block="{block_reads}")
    params:
        inmask = "{mask}",
        outmask = pseudo_block_mask("{mask}", "{block_reads}")
    log: log_file("propagate-mask-to-reads.{mask}.{block_reads}")
    group: "propagate_mask"
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist propagate-mask --config={dentist_config_file} {dentist_flags} -m {params[inmask]} {reference} {reads} {input[alignment]} {params[outmask]} 2> {log}"


rule propagate_mask_back_to_reference_block:
    input:
        dentist_config_file,
        await_db_files(reference),
        await_db_files(reads),
        mask_files(reads, "{mask}", pseudo_block="{block_reads}"),
        alignment = alignment_file(reads, reference, block_a='{block_reads}')
    output:
        temp(mask_files(reference, homogenized_mask("{mask}"), pseudo_block="{block_reads}"))
    params:
        inmask = pseudo_block_mask("{mask}", "{block_reads}"),
        outmask = pseudo_block_mask(homogenized_mask("{mask}"), "{block_reads}")
    log: log_file("propagate-mask-back-to-reference-block.{mask}.{block_reads}")
    group: "propagate_mask"
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist propagate-mask --config={dentist_config_file} {dentist_flags} -m {params[inmask]} {reads} {reference} {input[alignment]} {params[outmask]} 2> {log}"


rule propagate_mask_batch:
    input:
        dentist_config_file,
        await_db_files(reference),
        await_db_files(reads),
        lambda wildcards: chain(*(mask_files(reference, m) for m in pseudo_block_masks(homogenized_mask(wildcards.mask), reads, wildcards.blocks_reads)))
    output:
        touch(propagate_mask_batch_marker)
    group: "propagate_mask"


rule propagate_mask_back_to_reference:
    input:
        dentist_config_file,
        await_db_files(reference),
        await_db_files(reads),
        lambda wildcards : [propagate_mask_batch_marker.format(blocks_reads=brange, mask=wildcards.mask) for brange in blocks_for(reads, block_range(propagate_batch_size))],
        mask_files(reference, "{mask}"),
        lambda wildcards : chain(*(mask_files(reference, m) for m in pseudo_block_masks(homogenized_mask(wildcards.mask), reads)))
    output:
        mask_files(reference, homogenized_mask("{mask}"))
    params:
        merged_mask = homogenized_mask("{mask}"),
        block_masks = ["{mask}"] + pseudo_block_masks(homogenized_mask("{mask}"), reads)
    log: log_file("propagate-mask-back-to-reference.{mask}")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist merge-masks --config={dentist_config_file} {dentist_flags} {reference} {params[merged_mask]} {params[block_masks]} 2> {log}"


rule full_masking:
    input:
        *[mask_files(reference, homogenized_mask(m))  for m in masks]


checkpoint collect:
    input:
        *[mask_files(reference, homogenized_mask(m))  for m in masks],
        config = dentist_config_file,
        refdb = await_db_files(reference),
        readsdb = await_db_files(reads),
        alignment = ref_vs_reads_alignment
    output:
        protected(pile_ups)
    params:
        main_threads = main_threads,
        auxiliary_threads = auxiliary_threads,
        masks = ",".join([homogenized_mask(m)  for m in masks])
    threads: max_threads
    log: log_file("collect")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist collect --config={input.config} {dentist_flags} --threads={params.main_threads} --auxiliary-threads={params.auxiliary_threads} --mask={params.masks} {input.refdb[0]} {input.readsdb[0]} {input.alignment} {output} 2> {log}"


rule process:
    input:
        *[mask_files(reference, homogenized_mask(m))  for m in masks],
        config = dentist_config_file,
        refdb = await_db_files(reference),
        readsdb = await_db_files(reads),
        pile_ups = await_pile_ups()
    output:
        temp(insertions_batch)
    params:
        batch_range = insertion_batch_range,
        main_threads = main_threads,
        auxiliary_threads = auxiliary_threads,
        masks = ",".join([homogenized_mask(m)  for m in masks])
    threads: max_threads
    log: log_file("process.{batch_id}")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist process --config={input.config} {dentist_flags} --threads={params.main_threads} --auxiliary-threads={params.auxiliary_threads} --mask={params.masks} --batch={params.batch_range} {input.refdb[0]} {input.readsdb[0]} {input.pile_ups} {output} 2> {log}"

rule make_merge_config:
    input:
        pile_ups = await_pile_ups(),
        insertions_batches = lambda _: insertions_batches()
    output:
        temp(dentist_merge_config_file)
    container: dentist_container
    conda: dentist_env
    script: "scripts/make_merge_config.py"


rule merge_insertions:
    input:
        config = dentist_merge_config_file,
        pile_ups = await_pile_ups(),
        insertions_batches = lambda _: insertions_batches()
    output:
        protected(insertions)
    log: log_file("merge-insertions")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist merge-insertions --config={input.config} {dentist_flags} {output} - 2> {log}"


rule preliminary_output:
    input:
        config = dentist_config_file,
        refdb = await_db_files(reference),
        insertions = insertions
    output:
        fasta = preliminary_gap_closed_fasta,
        agp = preliminary_closed_gaps_agp,
        bed = preliminary_closed_gaps_bed
    params:
        revert_options = "--revert={}".format(",".join(preliminary_output_revert_options))
    log: log_file("preliminary-output")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist output --config={input.config} {dentist_flags} --agp={output[agp]} --closed-gaps-bed={output[bed]} {params.revert_options} {input.refdb[0]} {input.insertions} {output[fasta]} 2> {log}"


rule preliminary_gap_closed_vs_reads_alignment_block:
    input:
        dentist_config_file,
        await_db_files(preliminary_gap_closed),
        await_db_files(reads),
        mask_files(preliminary_gap_closed, dust_mask),
        mask_files(preliminary_gap_closed, self_mask),
        mask_files(preliminary_gap_closed, tandem_mask)
    output:
        alignment_file(preliminary_gap_closed, reads, block_b='{block_reads}'),
        temp(alignment_file(reads, preliminary_gap_closed, block_a='{block_reads}'))
    params:
        aligncmd = prepare_flags(lambda : generate_options_for("reads", dentist_config_file, ensure_masks("", dust_mask, self_mask, tandem_mask))),
        preliminary_gap_closed_stub = db_stub(rel_to_workdir(preliminary_gap_closed)),
        reads_stub = db_stub(rel_to_workdir(reads)),
        alignment_file_a_vs_b = lambda _, output: basename(output[0]),
        alignment_file_b_vs_a = lambda _, output: basename(output[1])
    threads: max_threads
    log: log_file("gap-closed-vs-reads-alignment.{block_reads}")
    container: dentist_container
    conda: dentist_env
    shell:
        """
            {{
                cd {workdir_}
                {params.aligncmd} {params.preliminary_gap_closed_stub} {params.reads_stub}.{wildcards.block_reads}
            }} &> {log}
        """


rule preliminary_gap_closed_vs_reads_alignment:
    input:
        refdb = await_db_files(preliminary_gap_closed),
        readsdb = await_db_files(reads),
        block_alignments = lambda _: block_alignments(preliminary_gap_closed, reads, block_a=FULL_DB)
    output:
        protected(preliminary_gap_closed_vs_reads_alignment)
    params:
        dbs = lambda _, input: (input.refdb[0], input.readsdb[0])
    log: log_file("gap-closed-vs-reads-alignment")
    container: dentist_container
    conda: dentist_env
    shell: LAmerge()


rule split_preliminary_gap_closed_vs_reads_alignment:
    input: preliminary_gap_closed_vs_reads_alignment
    output: expand(alignment_file(preliminary_gap_closed, reads, block_a="{block_ref}"), block_ref=range(1, validation_blocks + 1))
    params:
        split_alignment = alignment_file(preliminary_gap_closed, reads, block_a="@")
    log: log_file("split-gap-closed-vs-reads-alignment")
    container: dentist_container
    conda: dentist_env
    shell:
        "LAsplit {params.split_alignment} {validation_blocks} < {input} &> {log}"


rule preliminary_closed_gaps_bed2mask:
    input:
        db = await_db_files(preliminary_gap_closed),
        bed = preliminary_closed_gaps_bed
    output:
        mask_files(preliminary_gap_closed, closed_gaps_mask)
    log: log_file("closed-gaps-bed2mask")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist bed2mask --config={dentist_config_file} {dentist_flags} --data-comments --bed={input.bed} {input.db[0]} {closed_gaps_mask} 2> {log}"


rule validate_regions_block:
    input:
        refdb = await_db_files(preliminary_gap_closed),
        readsdb = await_db_files(reads),
        mask_files = mask_files(preliminary_gap_closed, closed_gaps_mask),
        alignment = alignment_file(preliminary_gap_closed, reads, block_a="{block_ref}")
    output:
        temp(validation_report_block),
        temp(mask_files(preliminary_gap_closed, block_mask(weak_coverage_mask, "{block_ref}")))
    params:
        block_mask = block_mask(weak_coverage_mask, "{block_ref}")
    threads: max_threads
    log: log_file("validate-regions-block.{block_ref}")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist validate-regions --config={dentist_config_file} --threads={threads} --weak-coverage-mask={params.block_mask} {input.refdb[0]} {input.readsdb[0]} {input.alignment} {closed_gaps_mask} > {output[0]} 2> {log}"


rule validate_regions:
    input:
        block_reports = expand(validation_report_block, block_ref=range(1, validation_blocks + 1))
    output:
        validation_report
    shell:
        "cat {input.block_reports} > {output}"


rule weak_coverage_mask:
    input:
        *expand(mask_files(preliminary_gap_closed, block_mask(weak_coverage_mask, "{block_ref}")), block_ref=range(1, validation_blocks + 1)),
        db = await_db_files(preliminary_gap_closed)
    output:
        mask_files(preliminary_gap_closed, weak_coverage_mask)
    params:
        block_masks = expand(block_mask(weak_coverage_mask, "{block_ref}"), block_ref=range(1, validation_blocks + 1))
    log: log_file("weak-coverage-mask")
    container: dentist_container
    conda: dentist_env
    shell:
        "dentist merge-masks --config={dentist_config_file} {dentist_flags} {input.db[0]} {weak_coverage_mask} {params.block_masks} 2> {log}"


rule skip_gaps:
    input: validation_report
    output: skip_gaps
    container: dentist_container
    conda: dentist_env
    script: "scripts/skip_gaps.py"

if workflow_flags["no_purge_output"]:
    rule unpurged_output:
        input:
            config = dentist_config_file,
            refdb = await_db_files(reference),
            insertions = insertions
        output:
            fasta = gap_closed_fasta,
            bed = closed_gaps_bed,
            agp = gap_closed_agp
        log: log_file("unpurged-output")
        container: dentist_container
        conda: dentist_env
        shell:
            "dentist output --config={input.config} {dentist_flags} --agp={output.agp} --closed-gaps-bed={output.bed} {input.refdb[0]} {input.insertions} {output.fasta} 2> {log}"
else:
    rule purged_output:
        input:
            config = dentist_config_file,
            refdb = await_db_files(reference),
            insertions = insertions,
            skip_gaps = skip_gaps
        output:
            fasta = gap_closed_fasta,
            bed = closed_gaps_bed,
            agp = gap_closed_agp
        log: log_file("purged-output")
        container: dentist_container
        conda: dentist_env
        shell:
            "dentist output --config={input.config} {dentist_flags} --agp={output.agp} --closed-gaps-bed={output.bed} --skip-gaps-file={input.skip_gaps} {input.refdb[0]} {input.insertions} {output.fasta} 2> {log}"


#-----------------------------------------------------------------------------
# END rules
#-----------------------------------------------------------------------------
