# SPDX-License-Identifier: GPL-2.0-or-later
"""The pins of a build, derived from the Dockerfile and the stage locks (nothing else
holds them):

    pins(dockerfile, over)             ARG defaults with overrides, and the firmware checksums
    stages(dockerfile)                 every FROM ... AS stage: its parent and the stages it reads
    chain(dockerfile, target, over)    the stage chain of a target's base, in build order
    locked(names, stages_dir)          the stages of names that have stages/<stage>/lock
    locks_digest(names, stages_dir)    the base manifest's locks value

Used by kernel-check and materialize. Imported from the scripts directory:
sys.path.insert(0, <scripts>).
"""
import hashlib, os, re

# The last stage of the root file system's chain: the tree a base is made from.
BASE_STAGE = 'base-export'


def read(path):
    with open(path, 'rb') as f:
        return f.read()


def _text(dockerfile):
    return read(dockerfile).decode().replace('\\\n', ' ')


def pins(dockerfile, over=None):
    """ARG defaults (with overrides, applied before ${X} in a default is expanded, as
    docker does) and ADD --checksum lines from the Dockerfile."""
    text = _text(dockerfile)
    args = dict(re.findall(r'^ARG (\w+)=(\S+)', text, re.M))
    args.update(over or {})
    for k, v in list(args.items()):     # one level of ${X} in a default
        args[k] = re.sub(r'\$\{(\w+)\}', lambda m: args.get(m.group(1), m.group(0)), v)
    args['KERNEL_BUILD'] = f"{args.get('KERNEL_BUILD_IMAGE', '')}@{args.get('KERNEL_BUILD_DIGEST', '')}"
    fw = {}
    for csum, dest in re.findall(r'^ADD --checksum=sha256:([0-9a-f]{64})\s+\$\{LINUX_FIRMWARE\}\S*\s+(\S+)', text, re.M):
        fw[dest.lstrip('/')] = csum
    return args, fw


def build_args(dockerfile, over=None):
    """Every build argument in effect: each ARG with a default, plus each override, by
    name (the pins view without the derived KERNEL_BUILD)."""
    args, _ = pins(dockerfile, over)
    args.pop('KERNEL_BUILD', None)
    if 'KERNEL_BUILD' in (over or {}):
        args['KERNEL_BUILD'] = over['KERNEL_BUILD']
    return dict(sorted(args.items()))


def _expand(word, args):
    return re.sub(r'\$\{(\w+)\}', lambda m: args.get(m.group(1), m.group(0)), word)


def stages(dockerfile, args=None):
    """{name: (parent, [stages read by --mount from= and COPY --from=])}, in file order.
    ${X} in names is expanded with args."""
    args = args or {}
    out = {}
    cur = None
    for line in _text(dockerfile).splitlines():
        m = re.match(r'\s*FROM\s+(?:--\S+\s+)*(\S+)\s+AS\s+(\S+)\s*$', line, re.I)
        if m:
            cur = _expand(m.group(2), args)
            out[cur] = (_expand(m.group(1), args), [])
            continue
        if cur is None:
            continue
        for ref in re.findall(r'(?:--mount=\S*?\bfrom=|COPY\s+(?:--\S+\s+)*--from=)([^,\s]+)', line):
            out[cur][1].append(_expand(ref, args))
    return out


def chain(dockerfile, target, over=None):
    """The base's stage chain for target, in build order: from BASE_STAGE up its FROM
    parents (DEVICE = target) to the first parent that isn't a stage."""
    over = dict(over or {})
    over['DEVICE'] = target
    args, _ = pins(dockerfile, over)
    st = stages(dockerfile, args)
    if BASE_STAGE not in st:
        raise ValueError(f'{dockerfile}: no stage {BASE_STAGE}')
    seq, name = [], BASE_STAGE
    while name in st:
        if name in seq:
            raise ValueError(f'{dockerfile}: FROM loop at {name}')
        seq.append(name)
        name = st[name][0]
    return list(reversed(seq))


def reachable(dockerfile, roots, over=None):
    """Every stage roots depend on (FROM parents, mounts, COPY --from), in file order."""
    args, _ = pins(dockerfile, over)
    st = stages(dockerfile, args)
    seen, todo = set(), [r for r in roots if r in st]
    while todo:
        n = todo.pop()
        if n in seen or n not in st:
            continue
        seen.add(n)
        parent, reads = st[n]
        todo += [parent] + reads
    return [n for n in st if n in seen]


def locked(names, stages_dir):
    """The stages of names (order kept) that have a lock file."""
    return [n for n in names if os.path.isfile(os.path.join(stages_dir, n, 'lock'))]


def locks_digest(names, stages_dir):
    """GlassineOS/boot's base manifest locks: sha256 of, for each stage in names (build
    order), the stage's name, a newline and its lock file's bytes."""
    h = hashlib.sha256()
    for n in names:
        h.update(n.encode() + b'\n' + read(os.path.join(stages_dir, n, 'lock')))
    return h.hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()
