# SPDX-License-Identifier: GPL-2.0-or-later
"""The registry's side of a build (specs/003-kernel-outputs-registry, docs/registry.md):
where each export is published, whether it is published under its key, pulling it,
publishing it, and the build contexts that let an export built here take in a pulled
one. Only docker buildx talks to the registry.

    package(export)                          <prefix>/images-<name>, the export's package
    cache_ref(export)                        <prefix>/images-cache:<export>, its layer cache
    lookup(export, key, run)                 published under key? digest and annotations
    pull(export, ref, dest, platform, ...)   the export's files at ref (pinned by digest) into dest
    publish(export, key, src, ...)           push src's files as <package>:<key>
    contexts(export, keys, pulled)           --build-context flags for the pulled exports it reads
    plan(keys, use_registry)                 per export: pull <ref>@<digest>, or build here and why
    git_fetch(gitdir, url, commit, step)     a fetch of a git input with a time limit and tries

The prefix is GLASSINE_REGISTRY (default ghcr.io/glassineos). Every function that runs
a command takes run(cmd, timeout) -> (returncode, output as str), so a caller can log.
"""
import hashlib, json, os, re, shutil, subprocess, time

DEFAULT_PREFIX = 'ghcr.io/glassineos'
SOURCE = 'https://github.com/GlassineOS/images'
ANNOTATION = 'org.glassine.'
FORMAT = '1'
LOOKUP_TIMEOUT = 30
PULL_TIMEOUT = 900
PULL_TRIES = 3


def prefix():
    return os.environ.get('GLASSINE_REGISTRY', DEFAULT_PREFIX).rstrip('/')


def package(export):
    """The export's package: kernel-export -> <prefix>/images-kernel."""
    name = export[:-len('-export')] if export.endswith('-export') else export
    return f'{prefix()}/images-{name}'


def cache_ref(export):
    return f'{prefix()}/images-cache:{export}'


def simple_run(cmd, timeout, stdin=None):
    """(returncode, stdout + stderr as text); 124 on timeout, 127 when cmd can't start."""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout, input=stdin)
        return p.returncode, (p.stdout + p.stderr).decode(errors='replace')
    except subprocess.TimeoutExpired:
        return 124, f'timed out after {timeout} s'
    except OSError as e:
        return 127, str(e)


def _last(text):
    lines = [x.strip() for x in text.strip().splitlines() if x.strip()]
    return lines[-1] if lines else ''


def lookup(export, key, timeout=LOOKUP_TIMEOUT):
    """Whether <package>:<key> is published, read anonymously when the package is public.
    {'state': 'published', 'ref', 'digest', 'annotations'} or {'state': 'missing' |
    'error', 'why'}. 'missing' is an answer from the registry (no such tag, or a package
    that isn't public); 'error' is no answer. The digest is the sha256 of the manifest's
    bytes as the registry gives them, so the pull that names it gets those bytes."""
    ref = f'{package(export)}:{key}'
    try:
        p = subprocess.run(['docker', 'buildx', 'imagetools', 'inspect', '--raw', ref],
                           capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {'state': 'error', 'why': f'registry unreachable: no answer in {timeout} s'}
    except OSError as e:
        return {'state': 'error', 'why': f'registry unreachable: {e}'}
    err = p.stderr.decode(errors='replace')
    if p.returncode != 0:
        low = err.lower()
        if re.search(r'not found|manifest unknown|name unknown|404', low):
            return {'state': 'missing', 'why': 'not published'}
        if re.search(r'unauthorized|denied|forbidden|401|403', low):
            return {'state': 'missing', 'why': 'not published, or not public (the registry refused to read it)'}
        return {'state': 'error', 'why': f'registry unreachable: {_last(err) or "exit " + str(p.returncode)}'}
    raw = p.stdout
    try:
        man = json.loads(raw)
    except ValueError:
        return {'state': 'error', 'why': 'the registry gave no manifest'}
    if 'layers' not in man:
        return {'state': 'error', 'why': f'not a single image manifest ({man.get("mediaType", "?")})'}
    ann = {k[len(ANNOTATION):]: v for k, v in (man.get('annotations') or {}).items()
           if k.startswith(ANNOTATION)}
    if ann.get('export') != export or ann.get('key') != key:
        return {'state': 'error', 'why': f'its annotations name export {ann.get("export")!r}, '
                                          f'key {ann.get("key")!r}'}
    digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
    return {'state': 'published', 'ref': f'{package(export)}@{digest}', 'digest': digest, 'annotations': ann}


def trees(annotations):
    """{<commit ARG in upper case>: tree} from a published export's annotations (the
    registry may give annotation names in lower case)."""
    return {k[len('tree.'):].upper(): v for k, v in annotations.items() if k.startswith('tree.')}


def plan(keys, use_registry=True, timeout=LOOKUP_TIMEOUT, look=None):
    """{export: {'key', 'pull': <ref>@<digest> or None, 'why', 'trees'}}: an export is
    pulled when it is published under its key. look(export, key) answers (lookup by
    default); the lookups run side by side."""
    import concurrent.futures
    look = look or (lambda e, k: lookup(e, k, timeout))
    out = {}
    if not use_registry:
        return {e: {'key': v['key'], 'pull': None, 'why': 'the registry is not used (--no-registry)',
                    'trees': {}, 'state': 'off'} for e, v in keys.items()}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(keys) or 1) as ex:
        fut = {e: ex.submit(look, e, v['key']) for e, v in keys.items()}
        for e, v in keys.items():
            r = fut[e].result()
            if r['state'] == 'published':
                out[e] = {'key': v['key'], 'pull': r['ref'], 'why': 'published', 'trees': trees(r['annotations']),
                          'state': 'published'}
            else:
                out[e] = {'key': v['key'], 'pull': None, 'why': r['why'], 'trees': {}, 'state': r['state']}
    return out


def contexts(export, keys, pulled):
    """--build-context flags for building export here: each pulled export (pulled =
    {export: <ref>@<digest>}) that export reads, directly or through other exports built
    here, stands in for its stage."""
    flags, seen, todo = [], set(), list(keys[export]['takes'])
    while todo:
        t = todo.pop()
        if t in seen:
            continue
        seen.add(t)
        if t in pulled:
            flags += ['--build-context', f'{t}=docker-image://{pulled[t]}']
        else:
            todo += keys[t]['takes']
    return flags


def settle(root):
    """Every entry's mtime to 0, as the export stages leave them: the trip through an
    image keeps file times but not always those of directories."""
    for d, dirs, files in os.walk(root, topdown=False):
        for n in dirs + files:
            os.utime(os.path.join(d, n), (0, 0), follow_symlinks=False)


def pull(export, ref, dest, platform, work, run=simple_run, timeout=PULL_TIMEOUT, tries=PULL_TRIES,
         log=print):
    """The files of ref (<package>@sha256:...) into dest: a one-line build FROM ref,
    exported as a local directory, so BuildKit checks every blob against the digest.
    Failures are tried again after 10, 20 ... seconds. Returns None, or why it failed."""
    if not re.fullmatch(r'\S+@sha256:[0-9a-f]{64}', ref):
        return f'{ref}: not pinned by digest'
    os.makedirs(work, exist_ok=True)
    df = os.path.join(work, f'pull-{export}.Dockerfile')
    empty = os.path.join(work, f'pull-{export}.context')
    os.makedirs(empty, exist_ok=True)
    with open(df, 'w') as f:
        f.write(f'FROM {ref}\n')
    why, pause = '', 10
    for n in range(1, tries + 1):
        shutil.rmtree(dest, ignore_errors=True)
        rc, out = run(['docker', 'buildx', 'build', '--progress=plain', '--platform', platform,
                       '-f', df, '-o', f'type=local,dest={dest}', empty], timeout)
        if rc == 0:
            settle(dest)
            return None
        why = f'exit {rc}{" (timeout)" if rc == 124 else ""}: {_last(out)}'
        if n < tries:
            log(f'registry: pulling {export} ({ref}) failed, try {n} of {tries} ({why}); again in {pause} s')
            time.sleep(pause)
            pause *= 2
    shutil.rmtree(dest, ignore_errors=True)
    return f'pulling {export} from {ref} failed after {tries} tries: {why}'


def publish(export, key, src, platform, work, annotations=None, run=simple_run, timeout=1800):
    """Push the files of src as <package>:<key>, unless that key is published already
    (it is never published again). One layer, the files as they are in src (modes,
    times), no provenance or SBOM, so the tag is a single manifest. annotations go on
    the manifest beside format, export and key. Returns ('published' | 'present',
    <ref>@<digest>), or raises RuntimeError."""
    have = lookup(export, key)
    if have['state'] == 'published':
        return 'present', have['ref']
    if have['state'] == 'error':
        raise RuntimeError(f'can\'t tell whether {export} is published: {have["why"]}')
    os.makedirs(work, exist_ok=True)
    df = os.path.join(work, f'publish-{export}.Dockerfile')
    with open(df, 'w') as f:
        f.write('FROM scratch\nCOPY . /\n')
    ann = {'format': FORMAT, 'export': export, 'key': key, **(annotations or {})}
    out = [f'type=image,name={package(export)}:{key},push=true,oci-mediatypes=true',
           f'annotation.org.opencontainers.image.source={SOURCE}']
    out += [f'annotation.{ANNOTATION}{k}={v}' for k, v in sorted(ann.items())]
    rc, log = run(['docker', 'buildx', 'build', '--progress=plain', '--no-cache', '--platform', platform,
                   '--provenance=false', '--sbom=false', '--label', f'org.opencontainers.image.source={SOURCE}',
                   '-f', df, '-o', ','.join(out), src], timeout)
    if rc != 0:
        raise RuntimeError(f'pushing {export} as {package(export)}:{key} failed (exit {rc}): {_last(log)}')
    got = lookup(export, key)
    if got['state'] != 'published':
        raise RuntimeError(f'{export} pushed, but the registry doesn\'t give it back: {got.get("why")}')
    return 'published', got['ref']


# ---- git inputs -------------------------------------------------------------------------

# What a fetch that failed for a network reason says (git, curl, ssh).
NETWORK = re.compile(r'could not resolve|timed out|timeout|connection|connect to|rpc failed|early eof'
                     r'|unexpected disconnect|hung up|transfer closed|ssl|tls|gnutls'
                     r'|returned error: (5\d\d|429)|too slow|empty reply|recv failure|send failure', re.I)


def git_fetch(gitdir, url, commit, step, args=None, timeout=None, tries=None, log=print):
    """git -C gitdir fetch ARGS url [commit] with a time limit (GIT_TIMEOUT seconds,
    default 30), stopped when it moves less than 1 KiB/s for that long, and tried again
    when it timed out or failed for a network reason, up to GIT_TRIES tries (default 3)
    after 5, 10 ... seconds. args default to a shallow, treeless fetch of commit.
    Returns (0, '', '') or (returncode, why: git's error, a message naming the step, the
    repository and the commit, then why)."""
    timeout = timeout or int(os.environ.get('GIT_TIMEOUT', '30'))
    tries = tries or int(os.environ.get('GIT_TRIES', '3'))
    args = args if args is not None else ['--depth=1', '--filter=tree:0', url, commit]
    cmd = ['git', '-C', gitdir, '-c', 'protocol.version=2', '-c', 'http.lowSpeedLimit=1024',
           '-c', f'http.lowSpeedTime={timeout}', 'fetch', '-q'] + args
    env = {**os.environ, 'GIT_TERMINAL_PROMPT': '0'}
    pause = 5
    for n in range(1, tries + 1):
        try:
            p = subprocess.run(cmd, capture_output=True, timeout=timeout, env=env)
            rc, err = p.returncode, p.stderr.decode(errors='replace')
        except subprocess.TimeoutExpired:
            rc, err = 124, f'timed out after {timeout} s'
        except OSError as e:
            rc, err = 127, str(e)
        if rc == 0:
            return 0, '', ''
        fatal = [x.strip() for x in err.splitlines() if x.strip().startswith(('fatal:', 'error:'))]
        why = fatal[0] if fatal else (_last(err) or f'exit {rc}')
        if rc != 124 and not NETWORK.search(err):
            return rc, why, f'{step}: fetching {commit} from {url} failed: {why}'
        if n == tries:
            why = f'{why} ({tries} tries)'
            return rc, why, f'{step}: fetching {commit} from {url} failed: {why}'
        log(f'{step}: fetching {commit} from {url}: try {n} of {tries} failed ({why}); again in {pause} s')
        time.sleep(pause)
        pause *= 2
