#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The recovery's QEMU clients (test/qemu-recovery.sh), from outside the guest.

deploy: over the virtio-serial port, protocol version 3 as the installer would speak
it: LIST, STATUS (the pool's deployments A current, B previous, C kept), DEPLOY select
C (refused without the confirmation, then confirmed), rollback, select A, pin (not
offered), DIAG (its sha256, its SHA256SUMS, A's log from userdata, every block device
read-only in the kernel), a version 1 READ; every disk HASHed before and after: vda and
vdb unchanged, vdc unchanged outside the system partition. Then it says nothing more:
the recovery's idle time must restart it.

console: over the virtio console (hvc0) the menu runs on: roll back (a wrong
confirmation cancels, the right one does it), then a reset, each shown in the
menu's list afterwards; then nothing more (the idle restart).

Prints QTEST lines; exit 0 = all passed.
usage: client-recovery.py deploy SOCKET VDA.IMG VDB.IMG SYS_OFFSET SYS_LENGTH
       client-recovery.py console SOCKET
"""
import hashlib, io, socket, struct, sys, tarfile, time

REQ, RSP = struct.Struct('<4sHHIIQQ'), struct.Struct('<4sHHIHHQQ32s')
LIST, READ, HASH, STATUS, DEPLOY, DIAG = 1, 2, 3, 8, 9, 10
fails = 0
tag = 0


def qt(ok, what):
    global fails
    print(('QTEST ok   ' if ok else 'QTEST FAIL ') + what, flush=True)
    fails += not ok


def connect(path):
    for _ in range(900):
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


def ask(s, op, index=0, off=0, length=0, payload=b'', version=3):
    global tag
    tag += 1
    if payload:
        length = len(payload)
    s.sendall(REQ.pack(b'GRRQ', version, op, tag, index, off, length) + payload)
    magic, ver, rop, rtag, status, _, n, roff, sha = RSP.unpack(exact(s, RSP.size))
    if magic != b'GRRS' or ver != version or rop != op or rtag != tag:
        raise SystemExit(f'QTEST FAIL a response out of step ({magic!r} {ver} {rop} {rtag})')
    return status, sha, exact(s, n)


def records(text, kind):
    out = []
    for l in text.splitlines():
        if l.startswith('type=' + kind + '\t'):
            out.append(dict(f.split('=', 1) for f in l.split('\t')))
    return out


def deploy_run(path, vda, vdb, sys_off, sys_len):
    s = connect(path)
    s.settimeout(600)
    st, _, t = ask(s, LIST)
    t = t.decode()
    qt(st == 0 and t.startswith('glassine-ramread 3\n'), 'LIST under version 3 says glassine-ramread 3')
    disks = {l.split()[2]: (int(l.split()[1]), int(l.split()[3])) for l in t.splitlines() if l.startswith('disk ')}
    qt(set(disks) >= {'vda', 'vdb', 'vdc'}, f'the disks are listed ({" ".join(sorted(disks))})')

    def h(name, off=0, length=None):
        i, size = disks[name]
        length = size - off if length is None else length
        m = hashlib.sha256()
        for o in range(off, off + length, 64 << 20):
            k = min(64 << 20, off + length - o)
            st, sha, _ = ask(s, HASH, i, o, k)
            if st:
                raise SystemExit(f'QTEST FAIL HASH {name} {o}: status {st}')
            m.update(sha)
        return m.hexdigest()
    vdc_size = disks['vdc'][1]
    before = {n: h(n) for n in ('vda', 'vdb')}
    outside = (h('vdc', 0, sys_off), h('vdc', sys_off + sys_len))
    for n, img in (('vda', vda), ('vdb', vdb)):
        data = open(img, 'rb').read()
        st, sha, b = ask(s, READ, disks[n][0], 0, 512, version=1)
        qt(st == 0 and b == data[:512] and sha == hashlib.sha256(b).digest(), f'a version 1 READ of {n} is the image\'s first sector')

    def status():
        st, sha, t = ask(s, STATUS)
        t = t.decode()
        rec = records(t, 'status')
        return st, sha, t, (rec[0] if rec else {}), {d['id']: d for d in records(t, 'deployment')}
    st, sha, t, rec, deps = status()
    qt(st == 0 and t.startswith('glassine-recovery 3\nconnection computer\n') and sha == bytes(32),
       'STATUS: version 3, the connection, a text payload')
    qt('\nrecovery boot=' in t and '\nkernel ' in t and '\nmachine ' in t and '\nemmc-cid ' in t, 'STATUS names the recovery, the kernel and the machine')
    acts = [l for l in t.splitlines() if l.startswith('actions')]
    qt(acts and {'select', 'rollback', 'reset', 'reset-full'} <= set(acts[0].split()[1:]) and 'pin' not in acts[0],
       f'STATUS lists the actions this glassine-deploy offers ({acts[0] if acts else "none"})')
    qt('\nstatus-exit 0\n' in t and '\nlist-exit 0\n' in t, 'glassine-deploy status and list ran (exit 0)')
    qt(rec.get('current') == 'A' and rec.get('previous') == 'B' and rec.get('candidate') == '',
       f'the state: current A, previous B, no candidate ({rec.get("current")}, {rec.get("previous")}, {rec.get("candidate")!r})')
    qt({k: v['state'] for k, v in deps.items()} == {'A': 'current', 'B': 'previous', 'C': 'kept'}
       and all(v.get('base') == 'base1' and v.get('base_present') == 'yes' for v in deps.values()),
       f'the list: A current, B previous, C kept, on base1 ({ {k: v["state"] for k, v in deps.items()} })')

    st, _, t = ask(s, DEPLOY, payload=b'action select\nid C\n')
    t = t.decode()
    qt(st == 9 and t.startswith('confirm select C\n') and 'Start C next' in t,
       f'select C without the confirmation: status 9, the token and what it does ({t.splitlines()[1] if st == 9 else t})')
    st, _, t = ask(s, DEPLOY, payload=b'action select\nid C\nconfirm select B\n')
    qt(st == 9, 'select C with the token of another id: status 9')
    st, _, rec, _ = (lambda r: (r[0], r[1], r[3], r[4]))(status())
    qt(rec.get('candidate') == '', 'nothing changed: still no candidate')
    st, _, t = ask(s, DEPLOY, payload=b'action select\nid C\nconfirm select C\n')
    qt(st == 0 and t.startswith(b'exit 0\n'), f'select C confirmed: done ({t.decode().strip()!r})')
    _, _, _, rec, deps = status()
    qt(rec.get('candidate') == 'C' and rec.get('tries') == '2' and deps['C']['state'] == 'candidate',
       f'STATUS: C is the candidate with 2 tries (candidate {rec.get("candidate")!r}, tries {rec.get("tries")!r})')
    st, _, t = ask(s, DEPLOY, payload=b'action rollback\nconfirm rollback\n')
    qt(st == 0, f'rollback confirmed: done ({t.decode().strip()!r})')
    _, _, _, rec, _ = status()
    qt(rec.get('candidate') == 'B' and rec.get('current') == 'A', f'STATUS: B (the previous one) is the candidate ({rec.get("candidate")!r})')
    st, _, t = ask(s, DEPLOY, payload=b'action select\nid A\nconfirm select A\n')
    _, _, _, rec, _ = status()
    qt(st == 0 and rec.get('candidate') == '' and rec.get('current') == 'A', 'select A (current): the candidate is cancelled')
    st, _, t = ask(s, DEPLOY, payload=b'action pin\nid A\nconfirm pin A\n')
    qt(st == 1 and t.startswith(b'not offered: '), f'pin: not offered ({t.decode().strip()!r})')
    st, _, t = ask(s, DEPLOY, payload=b'action select\nid Z\nconfirm select Z\n')
    qt(st == 10, f'select of a deployment that is not there: the tool refuses (status {st}: {t.decode().strip()!r})')

    st, sha, b = ask(s, DIAG)
    qt(st == 0 and hashlib.sha256(b).digest() == sha and len(b) < 16 << 20, f'DIAG: {len(b)} bytes, the header carries their sha256')
    try:
        tf = tarfile.open(fileobj=io.BytesIO(b))
        files = {m.name.lstrip('./'): tf.extractfile(m).read() for m in tf.getmembers() if m.isfile()}
    except Exception as e:
        files = {}
        qt(False, f'DIAG is a gzip\'ed tar ({e})')
    sums = {}
    for l in files.get('SHA256SUMS', b'').decode().splitlines():
        h_, n = l.split(None, 1)
        sums[n.lstrip('./')] = h_
    qt(sums and all(hashlib.sha256(files[n]).hexdigest() == v for n, v in sums.items())
       and set(sums) == set(files) - {'SHA256SUMS'}, f'DIAG: SHA256SUMS covers every file and matches ({len(sums)} files)')
    qt('identity.txt' in files and b'type=status' in files['identity.txt'] and 'dmesg.txt' in files, 'DIAG holds the identity, the state and the kernel log')
    logs = [n for n in files if n.startswith('logs/A/') and files[n] == b'the last start of A\n']
    qt(bool(logs), f'DIAG holds the current deployment\'s log, read from userdata ({logs or [n for n in files if n.startswith("logs/")]})')
    sysinfo = files.get('system.txt', b'').decode()
    ro = sysinfo.split('read-only (', 1)[-1].split('\n\n', 1)[0].splitlines()[1:]
    flags = dict(l.split() for l in ro if len(l.split()) == 2)
    vd = {k: v for k, v in flags.items() if k.startswith('vd')}
    qt(len(vd) >= 5 and all(v == '1' for v in vd.values()), f'after the operations every disk and partition is read-only in the kernel ({vd})')

    qt(all(h(n) == before[n] for n in ('vda', 'vdb')), 'HASH: vda and vdb unchanged by the operations')
    qt((h('vdc', 0, sys_off), h('vdc', sys_off + sys_len)) == outside,
       'HASH: vdc unchanged outside the system partition (userdata and the table too)')
    s.close()


class Console:
    def __init__(self, path):
        self.s = connect(path)
        self.s.settimeout(1)
        self.buf = b''

    def until(self, what, limit=180):
        t0 = time.time()
        while time.time() - t0 < limit:
            i = self.buf.find(what.encode())
            if i >= 0:
                out, self.buf = self.buf[:i + len(what)], self.buf[i + len(what):]
                return out.decode(errors='replace')
            try:
                k = self.s.recv(65536)
                if not k:
                    break
                self.buf += k
            except socket.timeout:
                pass
        raise SystemExit(f'QTEST FAIL the console never showed {what!r}; it showed:\n{self.buf.decode(errors="replace")[-2000:]}')

    def send(self, line):
        self.s.sendall(line.encode() + b'\r')


def console_run(path):
    c = Console(path)
    c.until('Press Enter.')
    c.send('')
    m = c.until('> ')
    qt('== GlassineOS recovery (boot=' in m and 'A' in m and 'current' in m and 'previous' in m,
       'the menu shows the recovery and the deployments')
    c.send('r')
    t = c.until('anything else to cancel: ')
    qt('Roll back: B' in t and 'Type "rollback"' in t, 'roll back: the menu shows what the core says it does and the token')
    c.send('roll back')
    t = c.until('back to the menu ')
    qt('Cancelled. Nothing changed.' in t, 'a wrong confirmation cancels')
    c.send('')
    m = c.until('> ')
    qt('candidate' not in m, 'nothing changed: no candidate in the list')
    c.send('r')
    c.until('anything else to cancel: ')
    c.send('rollback')
    t = c.until('back to the menu ', 600)
    qt('Done.' in t, 'the confirmed rollback is done')
    c.send('')
    m = c.until('> ')
    qt(any('B' in l and 'candidate' in l for l in m.splitlines()), 'the list shows B as the candidate')
    c.send('x')
    t = c.until('anything else to cancel: ')
    qt('Reset system' in t and 'Type "reset"' in t and 'home and Flatpak apps stay' in t, 'reset: what it keeps and loses, the token')
    c.send('reset')
    t = c.until('back to the menu ', 600)
    qt('Done.' in t, f'the confirmed reset is done{"" if "Done." in t else ": " + t[-800:]}')
    c.send('')
    m = c.until('> ')
    new = [l for l in m.splitlines() if 'candidate' in l]
    qt(len(new) == 1 and ' B ' not in new[0], f'the reset deployment is the candidate ({new[0].strip() if new else "none"})')
    c.send('g')
    t = c.until('back to the menu ', 300)
    qt('Diagnostics: ' in t and 'identity.txt' in t, 'diagnostics from the menu: size, sha256 and the contents')
    c.send('')
    c.until('> ')
    # nothing more: the idle restart


if __name__ == '__main__':
    if len(sys.argv) == 7 and sys.argv[1] == 'deploy':
        deploy_run(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6]))
    elif len(sys.argv) == 3 and sys.argv[1] == 'console':
        console_run(sys.argv[2])
    else:
        raise SystemExit(__doc__)
    sys.exit(1 if fails else 0)
