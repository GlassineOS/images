#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The QEMU test's stream client (test/qemu-inner.sh): from outside the guest, over
the virtio-serial port's socket, it reads every disk the RAM environment lists, whole,
checks each chunk's sha256 and each disk's sha256 against the image file that backs it,
compares the device's hashes, and checks that an unknown operation is refused. Then it
closes the connection and sends nothing more, so the environment's idle timeout has to
reboot it. Prints QTEST lines; exit 0 = all passed.

usage: client.py SOCKET NAME=IMAGE...
"""
import hashlib, socket, struct, sys, time

REQ, RSP = struct.Struct('<4sHHIIQQ'), struct.Struct('<4sHHIHHQQ32s')
LIST, READ, HASH = 1, 2, 3
fails = 0


def qt(ok, what):
    global fails
    print(('QTEST ok   ' if ok else 'QTEST FAIL ') + what, flush=True)
    fails += not ok


def connect(path):
    for _ in range(600):
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(path)
            return s
        except OSError:
            time.sleep(0.2)
    raise SystemExit(f'QTEST FAIL no socket {path}')


def exact(s, n):
    b = bytearray()
    while len(b) < n:
        k = s.recv(min(n - len(b), 1 << 20))
        if not k:
            raise SystemExit('QTEST FAIL the stream ended')
        b += k
    return bytes(b)


def ask(s, op, tag, index=0, off=0, length=0):
    s.sendall(REQ.pack(b'GRRQ', 1, op, tag, index, off, length))
    magic, ver, rop, rtag, status, _, n, roff, sha = RSP.unpack(exact(s, RSP.size))
    if magic != b'GRRS' or ver != 1 or rop != op or rtag != tag:
        raise SystemExit(f'QTEST FAIL a response out of step ({magic!r} {ver} {rop} {rtag})')
    return status, roff, sha, exact(s, n)


def main():
    path, images = sys.argv[1], dict(a.split('=', 1) for a in sys.argv[2:])
    s = connect(path)
    s.settimeout(120)
    status, _, _, text = ask(s, LIST, 1)
    lines = text.decode().splitlines()
    qt(status == 0 and lines[0] == 'glassine-ramread 1', 'list (stream)')
    limits = dict(l.split(' ', 1) for l in lines[1:4])
    max_read, max_hash = int(limits['max-read']), int(limits['max-hash'])
    disks = [l.split() for l in lines if l.startswith('disk ')]
    qt(sorted(d[2] for d in disks) == sorted(images), f'the disks listed are the images ({" ".join(d[2] for d in disks)})')
    t0, total = time.monotonic(), 0
    for _, idx, name, size, _ in disks:
        idx, size = int(idx), int(size)
        whole, ranges, part, chunks = hashlib.sha256(), [], hashlib.sha256(), True
        for off in range(0, size, max_read):
            n = min(max_read, size - off)
            status, roff, sha, data = ask(s, READ, off // max_read, idx, off, n)
            chunks &= status == 0 and roff == off and len(data) == n and hashlib.sha256(data).digest() == sha
            whole.update(data)
            part.update(data)
            if (off + n) % max_hash == 0 or off + n == size:
                ranges.append(part.digest())
                part = hashlib.sha256()
        total += size
        want = hashlib.sha256(open(images[name], 'rb').read()).hexdigest()
        qt(chunks, f'{name}: every chunk arrived with its own sha256 (stream)')
        qt(whole.hexdigest() == want, f'{name}: the sha256 of the whole read is the image\'s {want[:16]} (stream)')
        same = all(ask(s, HASH, 1000 + k, idx, k * max_hash, min(max_hash, size - k * max_hash))[2] == d
                   for k, d in enumerate(ranges))
        qt(same, f'{name}: the device\'s hashes of {len(ranges)} range(s) match (stream)')
    dt = time.monotonic() - t0
    print(f'QTEST info stream read {total} bytes in {dt:.1f} s ({total / dt / 1e6:.1f} MB/s, emulated)')
    qt(ask(s, 7, 77, 0, 0, 512)[0] == 2, 'an unknown operation is refused (stream)')
    s.close()
    sys.exit(1 if fails else 0)


main()
