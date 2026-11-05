#!/usr/bin/env python3
"""tree-manifest.py ROOT [--mtime]: one sorted line per entry of ROOT.

Each line: path, type, uid:gid, mode, size, content hash or link target or
device numbers, the first path of its hardlink group, and every xattr (read
from the kernel, so security.* is included). Two trees are the same base when
their manifests are byte-identical. --mtime adds modification times.
"""
import hashlib, os, stat, sys

def main():
    root = sys.argv[1]
    with_mtime = "--mtime" in sys.argv[2:]
    first = {}
    out = []
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(dirs + files):
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, root)
            st = os.lstat(p)
            m = st.st_mode
            kind = stat.filemode(m)[0]
            if stat.S_ISREG(m):
                h = hashlib.sha256()
                with open(p, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                what = h.hexdigest()
            elif stat.S_ISLNK(m):
                what = "-> " + os.readlink(p)
            elif stat.S_ISCHR(m) or stat.S_ISBLK(m):
                what = "dev %d,%d" % (os.major(st.st_rdev), os.minor(st.st_rdev))
            else:
                what = "-"
            link = ""
            if not stat.S_ISDIR(m) and st.st_nlink > 1:
                key = (st.st_dev, st.st_ino)
                link = " =" + first.setdefault(key, rel)
            try:
                names = sorted(os.listxattr(p, follow_symlinks=False))
            except OSError:
                names = []
            xa = "".join(" %s=%s" % (n, os.getxattr(p, n, follow_symlinks=False).hex()) for n in names)
            size = st.st_size if stat.S_ISREG(m) else 0
            mt = " t%d" % st.st_mtime_ns if with_mtime else ""
            out.append("%s %s %d:%d %o %d %s%s%s%s" % (rel, kind, st.st_uid, st.st_gid,
                       stat.S_IMODE(m), size, what, link, xa, mt))
    sys.stdout.write("\n".join(out) + "\n")

main()
