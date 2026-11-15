#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The screen's frames (PGM, as glassine-rscreen --shot writes them) as PNG and back,
for its golden images (test/screen-headless.sh). The PNG is 8-bit grey, one IDAT,
filter 0 on every row, zlib level 9: the pixels compare exactly, whatever wrote them.

  screen-png.py png IN.pgm OUT.png
  screen-png.py same A.pgm B.png        exit 0 = the same pixels (a PGM or a PNG each)
"""
import struct, sys, zlib


def read(p):
    d = open(p, 'rb').read()
    if d.startswith(b'P5'):
        parts = d.split(maxsplit=4)
        w, h = int(parts[1]), int(parts[2])
        return w, h, parts[4][:w * h]
    if d[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit('%s: neither PGM nor PNG' % p)
    i, w, h, idat = 8, 0, 0, b''
    while i < len(d):
        n, t = struct.unpack('>I4s', d[i:i + 8])
        c = d[i + 8:i + 8 + n]
        if t == b'IHDR':
            w, h, bits, ct = struct.unpack('>IIBB', c[:10])
            if bits != 8 or ct != 0: raise SystemExit('%s: not 8-bit grey' % p)
        elif t == b'IDAT': idat += c
        i += 12 + n
    raw = zlib.decompress(idat)
    rows = [raw[r * (w + 1):(r + 1) * (w + 1)] for r in range(h)]
    if any(r[0] != 0 for r in rows): raise SystemExit('%s: a row with a filter (not written by this tool)' % p)
    return w, h, b''.join(r[1:] for r in rows)


def chunk(t, c):
    return struct.pack('>I', len(c)) + t + c + struct.pack('>I', zlib.crc32(t + c))


if sys.argv[1] == 'png':
    w, h, px = read(sys.argv[2])
    raw = b''.join(b'\0' + px[r * w:(r + 1) * w] for r in range(h))
    open(sys.argv[3], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 0, 0, 0, 0))
                                  + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
elif sys.argv[1] == 'same':
    a, b = read(sys.argv[2]), read(sys.argv[3])
    if a[:2] != b[:2]: sys.exit(1)
    if a[2] == b[2]: sys.exit(0)
    n = sum(1 for x, y in zip(a[2], b[2]) if x != y)
    if n: print('%d pixels differ' % n)
    sys.exit(1 if n else 0)
else:
    raise SystemExit(__doc__)
