#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Checks and records on a base's tree, run by materialize inside its container:

    base_tree.py check ROOT         the export holds nothing the build environment left
                                    (FR-019): no /etc/resolv.conf, /etc/hosts only as a
                                    package installed it, and no base manifest yet
    base_tree.py name ROOT ID       the base manifest's base equals ID (the subvolume's name)
    base_tree.py packages ROOT      the installed packages, name=version, sorted by bytes
                                    (the format of stages/<stage>/lock)

Exit 0 = pass, 1 = a check failed (each failure on stderr), 2 = usage.
"""
import base64, hashlib, os, sys

BASE_MANIFEST = 'usr/share/glassine/base.manifest'
APK_DB = 'lib/apk/db/installed'


def apk_db(root):
    """[(package, version, {path: checksum})] from apk's installed database."""
    p = os.path.join(root, APK_DB)
    if not os.path.isfile(p):
        return None
    pkgs, cur, d, last = [], None, '', None
    with open(p, encoding='utf-8', errors='surrogateescape') as f:
        for line in f:
            k, _, v = line.rstrip('\n').partition(':')
            if k == 'P':
                cur = [v, '', {}]
                pkgs.append(cur)
                d, last = '', None
            elif cur is None:
                continue
            elif k == 'V':
                cur[1] = v
            elif k == 'F':
                d = v
            elif k == 'R':
                last = f'{d}/{v}' if d else v
                cur[2][last] = ''
            elif k == 'Z' and last is not None:
                cur[2][last] = v
    return pkgs


def apk_sum(path, z):
    """Does the file match apk's checksum (Q1 = sha1, Q2 = sha256, base64)?"""
    alg = {'Q1': hashlib.sha1, 'Q2': hashlib.sha256}.get(z[:2])
    if not alg:
        return False
    with open(path, 'rb') as f:
        return base64.b64encode(alg(f.read()).digest()).decode() == z[2:]


def check(root):
    fails = []
    if os.path.lexists(os.path.join(root, 'etc/resolv.conf')):
        fails.append('/etc/resolv.conf is in the tree (left by the build environment)')
    hosts = os.path.join(root, 'etc/hosts')
    if os.path.lexists(hosts):
        owners = [(n, z) for n, _, files in (apk_db(root) or []) for p, z in files.items()
                  if p == 'etc/hosts']
        if os.path.islink(hosts) or not os.path.isfile(hosts):
            fails.append('/etc/hosts is not a regular file')
        elif not owners:
            fails.append('/etc/hosts belongs to no package (a build host\'s?)')
        elif not any(z and apk_sum(hosts, z) for _, z in owners):
            fails.append(f'/etc/hosts differs from the one {owners[0][0]} installed (a build host\'s?)')
    if os.path.lexists(os.path.join(root, BASE_MANIFEST)):
        fails.append(f'/{BASE_MANIFEST} is in the export (materialize writes it)')
    return fails


def name(root, ident):
    p = os.path.join(root, BASE_MANIFEST)
    if not os.path.isfile(p):
        return [f'/{BASE_MANIFEST} missing']
    with open(p) as f:
        lines = f.read().splitlines()
    rec = dict(line.split('=', 1) for line in lines if '=' in line)
    fails = []
    if not lines or lines[0] != 'format=1':
        fails.append(f'/{BASE_MANIFEST}: first line is not format=1')
    if rec.get('base') != ident:
        fails.append(f'/{BASE_MANIFEST}: base={rec.get("base")} is not the subvolume\'s name {ident}')
    return fails


def packages(root):
    db = apk_db(root)
    lines = sorted((f'{n}={v}\n' for n, v, _ in db or []), key=str.encode)
    sys.stdout.write(''.join(lines))
    return []


def main(argv):
    if len(argv) == 2 and argv[0] in ('check', 'packages'):
        fails = check(argv[1]) if argv[0] == 'check' else packages(argv[1])
    elif len(argv) == 3 and argv[0] == 'name':
        fails = name(argv[1], argv[2])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    for f in fails:
        print(f'FAIL: {f}', file=sys.stderr)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
