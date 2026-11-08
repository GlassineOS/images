# SPDX-License-Identifier: GPL-2.0-or-later
"""The pins of a build, derived from the Dockerfile and the stage locks (nothing else
holds them):

    pins(dockerfile, over)             ARG defaults with overrides, and the firmware checksums
    branches(dockerfile)               the git inputs: {commit ARG: the branch it follows}
    repos(dockerfile)                  the git inputs: {commit ARG: the ARG naming its repository}
    builders(dockerfile, over)         the builder images pinned by digest: {image: digest}
    platforms(dockerfile)              the constant platforms of FROM --platform=...
    stages(dockerfile)                 every FROM ... AS stage: its parent and the stages it reads
    chain(dockerfile, target, over)    the stage chain of a target's base, in build order
    locked(names, stages_dir)          the stages of names that have stages/<stage>/lock
    locks_digest(names, stages_dir)    the base manifest's locks value
    export_keys(dockerfile, repo, over, arch)   each registry export's key (docs/registry.md)

Used by kernel-check, materialize, build and registry. Imported from the scripts
directory: sys.path.insert(0, <scripts>).
"""
import hashlib, os, re

# The last stage of the root file system's chain: the tree a base is made from.
BASE_STAGE = 'base-export'

# The exports a build takes from the registry when they are published under their key
# (specs/003-kernel-outputs-registry, docs/registry.md), in build order.
REGISTRY_EXPORTS = ['kernel-export', 'dtb-export', 'initramfs-export', 'boot-export']

# Build arguments that never change an export's bytes, left out of its key: name ->
# None (left out of every export's key) or the exports whose key leaves it out.
KEY_IGNORED = {
    # parallel jobs: the same output
    'JOBS': None,
    # the id of the kernel's cache mount: an empty mount gives the same bytes
    'KCACHE': None,
    # check or refresh: whether a stage compares its packages with the lock; a build
    # that passes the check installs exactly the lock, which is in the key
    'LOCK': None,
    # where the firmware is downloaded from: each file is pinned by its checksum, and
    # the checksums are in the stage's text
    'LINUX_FIRMWARE': None,
    # where GlassineOS/boot is fetched from: its commit fixes the content, and no
    # output names the address
    'BOOT': None,
    # the kernel's repository: kernel.manifest names it (source=), a device tree's
    # record doesn't
    'LINUX': {'dtb-export'},
    # the device tree builds from DTB_COMMIT, its own input; the source stage starts at
    # the kernel's commit and moves
    'LINUX_SDM660': {'dtb-export'},
    # the builder's name: its digest fixes the image; only kernel.manifest names it
    # (builder=)
    'KERNEL_BUILD_IMAGE': {'dtb-export', 'boot-export'},
}
KEY_FORMAT = '1'


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


def branches(dockerfile):
    """The git inputs: each ARG whose default line has "# branch: <name>" right above it,
    with that branch, in file order."""
    out, prev = {}, ''
    for line in read(dockerfile).decode().splitlines():
        m = re.match(r'ARG (\w+)=', line)
        b = re.fullmatch(r'#\s*branch:\s*(\S+)\s*', prev)
        if m and b:
            out[m.group(1)] = b.group(1)
        prev = line
    return out


def repos(dockerfile):
    """Each git input's repository: the ARG declared beside it on a stage's ARG line
    whose default is a URL (ARG LINUX LINUX_SDM660, ARG BOOT BOOT_COMMIT). An input with
    no such ARG, or with more than one, is an error."""
    text = _text(dockerfile)
    urls = {k for k, v in re.findall(r'^ARG (\w+)=(\S+)', text, re.M)
            if re.match(r'(https?|git|ssh|file)://', v)}
    out = {}
    for commit in branches(dockerfile):
        found = set()
        for line in re.findall(r'^\s*ARG\s+(.+)$', text, re.M):
            names = [w.split('=', 1)[0] for w in line.split()]
            if commit in names:
                found |= urls & set(names)
        if len(found) != 1:
            raise ValueError(f'{dockerfile}: git input {commit}: no single repository ARG '
                             f'declared beside it (found {sorted(found)})')
        out[commit] = found.pop()
    return out


def builders(dockerfile, over=None):
    """The builder images pinned by digest: each pair of ARGs <X>_IMAGE and <X>_DIGEST
    (overrides applied), as {image: digest}."""
    args, _ = pins(dockerfile, over)
    return {args[k]: args[k[:-6] + '_DIGEST'] for k in sorted(args)
            if k.endswith('_IMAGE') and args.get(k[:-6] + '_DIGEST')}


def platforms(dockerfile):
    """The platforms stages name with a constant FROM --platform= (no ${X}, no
    $BUILDPLATFORM): a build needs them besides the target's own."""
    return sorted(set(re.findall(r'^\s*FROM\s+(?:--\S+\s+)*?--platform=([^\s$]+)\s', _text(dockerfile),
                                 re.M | re.I)))


def stage_platforms(dockerfile, names):
    """The constant platforms (FROM --platform= without $) of the stages in names."""
    out = set()
    for n, lines in stage_lines(dockerfile).items():
        if n in names and lines:
            plat, _ = _from_parts(lines[0])
            if plat and '$' not in plat:
                out.add(plat)
    return sorted(out)


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


def reachable(dockerfile, roots, over=None, stop=()):
    """Every stage roots depend on (FROM parents, mounts, COPY --from), in file order.
    A stage in stop is not entered (its own name is left out too): it comes from
    elsewhere, such as a published export given as a build context."""
    args, _ = pins(dockerfile, over)
    st = stages(dockerfile, args)
    seen, todo = set(), [r for r in roots if r in st and r not in stop]
    while todo:
        n = todo.pop()
        if n in seen or n not in st or n in stop:
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


# ---- registry keys (docs/registry.md) --------------------------------------------------

def stage_lines(dockerfile):
    """{stage: [its instructions]}: from its FROM line to the next FROM, continuation
    lines joined, comments and blank lines left out, runs of white space made one
    space; nothing expanded."""
    out, cur = {}, None
    for line in _text(dockerfile).splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'\s*FROM\s+(?:--\S+\s+)*\S+\s+AS\s+(\S+)\s*$', line, re.I)
        if m:
            cur = m.group(1)
            out[cur] = []
        if cur is not None:
            out[cur].append(' '.join(line.split()))
    return out


def _arg_names(line):
    m = re.match(r'ARG\s+(.+)$', line)
    return [w.split('=', 1)[0] for w in m.group(1).split()] if m else []


def _from_parts(line):
    """(--platform value or None, the image or stage) of a FROM line."""
    m = re.match(r'FROM\s+((?:--\S+\s+)*)(\S+)', line, re.I)
    plat = re.search(r'--platform=(\S+)', m.group(1))
    return (plat.group(1) if plat else None), m.group(2)


def _context_paths(line, args):
    """The build context paths an instruction reads: bind mounts without from=, and the
    sources of COPY and ADD without --from= that aren't URLs."""
    paths = []
    for spec in re.findall(r'--mount=(\S+)', line):
        kv = dict(x.split('=', 1) for x in spec.split(',') if '=' in x)
        if kv.get('type', 'bind') == 'bind' and 'from' not in kv and 'source' in kv:
            paths.append(_expand(kv['source'], args))
    m = re.match(r'(COPY|ADD)\s+(.*)$', line, re.I)
    if m and '--from=' not in m.group(2):
        words = [w for w in m.group(2).split() if not w.startswith('--')]
        for w in words[:-1]:
            w = _expand(w, args)
            if not re.match(r'[a-z]+://', w):
                paths.append(w)
    return paths


def _file_entries(repo, rel):
    """One line per regular file or symlink at or under rel (relative to repo): its
    path, x when the owner may execute it (the mode git keeps; the other bits follow
    the computer's umask), and its sha256, or the link's target. Directories add
    nothing of their own (git keeps no empty ones). Sorted by the bytes of the path."""
    rel = os.path.normpath(rel).lstrip('/')
    root = os.path.join(repo, rel)
    if not os.path.lexists(root):
        return [f'{rel} missing']
    found = []
    if os.path.isdir(root) and not os.path.islink(root):
        for d, dirs, files in os.walk(root):
            dirs.sort()
            for n in dirs + files:
                p = os.path.join(d, n)
                if os.path.islink(p) or not os.path.isdir(p):
                    found.append(p)
    else:
        found.append(root)
    out = []
    for p in found:
        r = os.path.relpath(p, repo)
        if os.path.islink(p):
            out.append((r, f'{r} -> {os.readlink(p)}'))
        else:
            x = 'x' if os.stat(p).st_mode & 0o100 else '-'
            out.append((r, f'{r} {x} {sha256_file(p)}'))
    return [e for _, e in sorted(out, key=lambda t: t[0].encode())]


def export_keys(dockerfile, repo, over=None, arch='arm64'):
    """Each registry export's key and what went into it:
    {export: {'key', 'text', 'stages', 'takes', 'args', 'inputs', 'fetches'}}.

    The key is the sha256 of text, which holds, one per line:
      format=1, export=<name>
      stage=<instruction>        every instruction of the export's own stages (the
                                 stages it is built from, up to the other registry
                                 exports it takes in), in Dockerfile order
      platform=linux/<arch>      when one of those stages runs on the target's
                                 platform (FROM an image without --platform)
      arg.<NAME>=<value>         every build argument those stages declare or name in
                                 FROM, with the overrides applied, except KEY_IGNORED
      file=<path> <x|-> <sha256> every file of the build context those stages read
      in.<export>=<key>          the key of each registry export it takes in
    args: every build argument its own stages declare or name in FROM (also those left
    out of the key); inputs: the git inputs (commit arguments) in the key; fetches: the git inputs
    building the export here fetches (also those left out of its key)."""
    over = dict(over or {})
    args, _ = pins(dockerfile, over)
    st = stages(dockerfile, args)
    lines = stage_lines(dockerfile)
    gits = branches(dockerfile)
    out = {}

    def key(e):
        if e in out:
            return out[e]['key']
        if e not in st:
            raise ValueError(f'{dockerfile}: no stage {e}')
        own, takes, todo = [], set(), [e]
        while todo:
            n = todo.pop()
            if n in own or n not in st:
                continue
            if n != e and n in REGISTRY_EXPORTS:
                takes.add(n)
                continue
            own.append(n)
            todo += [st[n][0]] + st[n][1]
        own = [n for n in st if n in own]
        text = [f'format={KEY_FORMAT}', f'export={e}']
        names, files, target_plat = set(), set(), False
        for n in own:
            for line in lines.get(n, []):
                text.append(f'stage={line}')
                names.update(_arg_names(line))
                if re.match(r'FROM\s', line, re.I):
                    plat, ref = _from_parts(line)
                    names.update(a or b for a, b in re.findall(r'\$\{(\w+)\}|\$(\w+)', ref))
                    ref = _expand(ref, args)
                    if ref != 'scratch' and ref not in st and (plat is None or 'TARGETPLATFORM' in plat):
                        target_plat = True
                for p in _context_paths(line, args):
                    files.update(_file_entries(repo, p))
        if target_plat:
            text.append(f'platform=linux/{arch}')
        kept = sorted(a for a in names
                      if a in args and not (a in KEY_IGNORED and (KEY_IGNORED[a] is None or e in KEY_IGNORED[a])))
        text += [f'arg.{a}={args[a]}' for a in kept]
        text += [f'file={f}' for f in sorted(files, key=lambda x: x.encode())]
        text += [f'in.{t}={key(t)}' for t in sorted(takes)]
        body = ''.join(x + '\n' for x in text)
        out[e] = {'key': hashlib.sha256(body.encode()).hexdigest(), 'text': body, 'stages': own,
                  'takes': sorted(takes), 'args': sorted(names), 'inputs': [i for i in gits if i in kept],
                  'fetches': [i for i in gits if i in names]}
        return out[e]['key']

    for e in REGISTRY_EXPORTS:
        key(e)
    return {e: out[e] for e in REGISTRY_EXPORTS}
