#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""tree-manifest.py ROOT: the content manifest of a tree, one line per entry.

    <path> <type> <uid>:<gid> <mode> <size> <what>[ =<first>][ <xattr>=<hex>]...

  path   relative to ROOT, "." for ROOT itself
  type   the first letter of ls -l: - d l c b p s
  mode   the permission bits in octal, setuid, setgid and sticky included (4 digits)
  size   bytes for a regular file, 0 for anything else
  what   a regular file's sha256, "-> <target>" for a symlink (dangling ones too),
         "dev <major>,<minor>" for a device node, "-" otherwise
  first  for an entry with more than one hard link: the first path of its group, in
         manifest order (the group's first entry names itself)
  xattr  every extended attribute, read from the kernel (security.capability and
         user.* included), sorted by name, the value in hex

No timestamps. Lines are sorted by the bytes of the path. Paths and link targets are
written with every byte outside 0x21..0x7e and the backslash as \\xHH, so any name fits
on one line. The same tree gives the same bytes on any file system that keeps these
properties; two trees are the same tree when their manifests are byte-identical.
"""
import hashlib, os, stat, sys


def esc(b):
    return ''.join(chr(c) if 0x21 <= c <= 0x7e and c != 0x5c else '\\x%02x' % c for c in b)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def entry(root, rel):
    p = os.path.join(root, rel) if rel != b'.' else root
    st = os.lstat(p)
    m = st.st_mode
    size = 0
    if stat.S_ISREG(m):
        what, size = sha256(p), st.st_size
    elif stat.S_ISLNK(m):
        what = '-> ' + esc(os.readlink(p))
    elif stat.S_ISCHR(m) or stat.S_ISBLK(m):
        what = 'dev %d,%d' % (os.major(st.st_rdev), os.minor(st.st_rdev))
    else:
        what = '-'
    xa = ''.join(' %s=%s' % (esc(n), os.getxattr(p, n, follow_symlinks=False).hex())
                 for n in sorted(os.listxattr(p, follow_symlinks=False), key=os.fsencode))
    key = (st.st_dev, st.st_ino) if not stat.S_ISDIR(m) and st.st_nlink > 1 else None
    head = '%s %s %d:%d %04o %d %s' % (esc(rel), stat.filemode(m)[0], st.st_uid, st.st_gid,
                                         stat.S_IMODE(m), size, what)
    return rel, head, xa, key


def manifest(root):
    root = os.fsencode(root)
    rels = [b'.']
    for dirpath, dirs, files in os.walk(root):
        for name in dirs + files:
            rels.append(os.path.relpath(os.path.join(dirpath, name), root))
    entries = sorted((entry(root, r) for r in rels), key=lambda e: e[0])
    first = {}
    lines = []
    for rel, head, xa, key in entries:
        link = ' =' + esc(first.setdefault(key, rel)) if key else ''
        lines.append(head + link + xa + '\n')
    return ''.join(lines)


if __name__ == '__main__':
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.exit(__doc__)
    sys.stdout.write(manifest(sys.argv[1]))
