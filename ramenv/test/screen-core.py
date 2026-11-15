#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A stand-in for the recovery's core on its local socket, for the screen's headless
run (test/screen-headless.sh): protocol version 3 as glassine-ramread answers it
(LIST, STATUS, DEPLOY with status 9 and a token, DIAG, REBOOT), over a made-up device.
The texts of DEPLOY are those of recovery/describe for that state. It logs every
request and checks, at the end, that every DEPLOY with "confirm" carried the token
this core gave in its last status-9 answer to the same request, and that nothing was
confirmed that wasn't asked first. It is not the core: the QEMU run drives the screen
against the real one.

usage: screen-core.py SOCKET LOG {full|empty} [--hibernated]
Runs until SIGTERM; then prints QTEST lines and exits 0 when all passed.
"""
import gzip, hashlib, io, os, signal, socket, struct, sys, tarfile, threading

REQ, RSP = struct.Struct('<4sHHIIQQ'), struct.Struct('<4sHHIHHQQ32s')
path, logp, kind = sys.argv[1], sys.argv[2], sys.argv[3]
hib = '--hibernated' in sys.argv
log = open(logp, 'w')
fails = []
issued = {}            # the request without its confirm line -> the token given
lock = threading.Lock()

st = {'current': '20261112-0930', 'previous': '20261108-1814', 'candidate': '', 'tries': '0',
      'failed': '20261114-2210'}
deps = {'20261112-0930': ('base-20261110', '2026-11-12T09:30'),
        '20261108-1814': ('base-20261101', '2026-11-08T18:14'),
        '20261101-0702': ('base-20261101', '2026-11-01T07:02'),
        '20261114-2210': ('base-20261114', '2026-11-14T22:10')}
if kind == 'empty':
    st = dict.fromkeys(st, '')
    deps = {}


def state_of(i):
    if i == st['current']: return 'current'
    if i == st['candidate']: return 'candidate'
    if i == st['failed']: return 'failed'
    if i == st['previous']: return 'previous'
    return 'kept'


def status_text():
    s = ['glassine-recovery 3', 'connection local',
         'recovery boot=2b6cb72d5ec555b3713e8ba2b3d53aa5118331fe device=onyx-noteair build=4f1e09c2a7b3d851',
         'kernel 7.3.0-sdm660.4098b5-g2c96773f2662', 'machine Onyx Boox Note Air', 'compatible onyx,noteair',
         'serial unknown', 'emmc-cid 150100444a54443452045a8d2f13a700', 'system /dev/mmcblk0p50',
         'userdata /dev/mmcblk0p48', 'actions select rollback reset reset-full remove']
    if kind == 'empty':
        s += ['status-exit 1', 'glassine-deploy: no system partition (SYSTEM_DEV is empty)', 'list-exit 1',
              'glassine-deploy: no system partition (SYSTEM_DEV is empty)']
        return '\n'.join(s) + '\n'
    s += ['status-exit 0', 'glassine-deploy 1',
          'type=status\tformat=1\tsupported=1\tsystem_fs=btrfs\tmigrated=yes\tcurrent=%s\tprevious=%s\tcandidate=%s\t'
          'staged=\tfailed=%s\ttries=%s\thibernated=%s' % (st['current'], st['previous'], st['candidate'], st['failed'],
                                                            st['tries'], 'yes' if hib else 'no'),
          'list-exit 0', 'glassine-deploy 1']
    for i, (b, c) in sorted(deps.items(), reverse=True):
        s.append('type=deployment\tid=%s\tstate=%s\tbase=%s\tbase_present=yes\tkernel=7.3.0\tcreated=%s\tsize_kib=%d'
                 % (i, state_of(i), b, c, 412000 + len(i)))
    return '\n'.join(s) + '\n'


def describe(act, i, disc):
    cur = st['current']
    if act == 'select':
        if i not in deps: return 1, 'there is no deployment %s' % i
        if i == cur: return 0, '%s is the current deployment: this cancels the candidate; %s starts next.' % (i, i)
        t = ('Start %s next (base %s). It gets 2 tries; if it does not start, %s starts again. Nothing is deleted.'
             % (i, deps[i][0], cur))
    elif act == 'rollback':
        if not st['previous']: return 1, 'there is no previous deployment'
        t = ('Roll back: %s (the previous deployment) starts next, with 2 tries; if it does not start, %s starts '
             'again. A kernel trial is cancelled. Nothing is deleted.' % (st['previous'], cur))
    elif act in ('reset', 'reset-full'):
        if not cur: return 1, 'there is no current deployment to reset'
        b = deps[cur][0]
        if act == 'reset':
            t = ('Reset system: a new deployment on base %s that keeps only the migrate list (accounts, Wi-Fi, '
                 'Bluetooth, settings). Your packages and edits to the system are not in it. Your home and Flatpak '
                 'apps stay.' % b)
        else:
            t = ('Full reset: a new deployment on base %s with nothing carried over (accounts, Wi-Fi, Bluetooth, '
                 'settings, packages). Your home and Flatpak apps stay.' % b)
        t += '\nIt is made now and starts next, with 2 tries; %s stays on the device to go back to.' % cur
    elif act == 'remove':
        if i not in deps: return 1, 'there is no deployment %s' % i
        t = 'Delete deployment %s from userdata: its packages and its changes to the system are lost.' % i
        if i == st['previous']: t += '\nIt is the previous deployment: the rollback to it is lost.'
    else:
        return 64, 'glassine-deploy has no %s operation' % act
    if disc: t += '\nThe hibernated session on userdata is discarded: whatever was open in it is lost.'
    return 0, t + '\n'


def deploy(text):
    kv = {}
    for line in text.decode().splitlines():
        k, _, v = line.partition(' ')
        if k in kv: return 1, b'a key twice'
        kv[k] = v
    act, i, disc = kv.get('action'), kv.get('id', ''), kv.get('discard-hibernation') == 'yes'
    base = '\n'.join('%s %s' % (k, v) for k, v in kv.items() if k != 'confirm')
    rc, t = describe(act, i, disc)
    if rc == 64: return 1, ('not offered: ' + t).encode()
    if rc: return 10, ('exit 1\n' + t + '\n').encode()
    tok = ' '.join([act] + ([i] if i else []) + (['discard-hibernation'] if disc else [])
                   + [hashlib.sha256(t.encode()).hexdigest()[:8]])
    if kv.get('confirm') != tok:
        if 'confirm' in kv and kv['confirm'] != issued.get(base):
            fails.append('a confirm token this core never gave: %r' % kv['confirm'])
        issued[base] = tok
        return 9, ('confirm %s\n%s' % (tok, t)).encode()
    if issued.get(base) != tok:
        fails.append('confirmed without the status-9 answer first: %r' % base)
    log.write('CONFIRMED %s\n' % tok)
    global hib
    if act == 'rollback' and hib and not disc:
        return 10, b'exit 4\nglassine-deploy: userdata holds a hibernated session; --discard-hibernation to go on\n'
    if act == 'remove' and i in (st['current'], st['candidate']):
        return 10, ('exit 1\nglassine-deploy: remove: %s is the current deployment; it is never removed\n' % i).encode()
    if act == 'select':
        st['candidate'], st['tries'] = ('', '0') if i == st['current'] else (i, '2')
        return 0, ('exit 0\nglassine-deploy: %s is the candidate (2 tries)\n' % i).encode()
    if act == 'rollback':
        hib = False
        st['candidate'], st['tries'] = st['previous'], '2'
        return 0, ('exit 0\nglassine-deploy: %s is the candidate (2 tries)\n' % st['previous']).encode()
    if act in ('reset', 'reset-full'):
        n = '20261115-1602'
        deps[n] = (deps[st['current']][0], '2026-11-15T16:02')
        st['candidate'], st['tries'] = n, '2'
        return 0, ('exit 0\nglassine-deploy: staged %s (carry=%s)\nglassine-deploy: switched: %s is the candidate '
                   '(2 tries)\n' % (n, 'none' if act == 'reset-full' else 'migrate', n)).encode()
    if act == 'remove':
        del deps[i]
        if st['previous'] == i: st['previous'] = ''
        if st['failed'] == i: st['failed'] = ''
        return 0, ('exit 0\nglassine-deploy: removed %s\n' % i).encode()
    return 1, b'?'


def diag():
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode='w') as t:
        for n, d in [('identity.txt', status_text()), ('dmesg.txt', '[0.000000] Booting Linux\n'),
                     ('system.txt', 'cmdline ...\n'), ('logs/20261114-2210/messages', 'the failed start\n'),
                     ('SHA256SUMS', '...\n')]:
            data = d.encode()
            i = tarfile.TarInfo(n)
            i.size, i.mtime = len(data), 0
            t.addfile(i, io.BytesIO(data))
    return gzip.compress(b.getvalue(), mtime=0)


def exact(c, n):
    b = b''
    while len(b) < n:
        k = c.recv(n - len(b))
        if not k: raise EOFError
        b += k
    return b


def serve(c):
    try:
        while True:
            magic, ver, op, tag, index, off, length = REQ.unpack(exact(c, REQ.size))
            body = exact(c, length) if op == 9 and length else b''
            with lock:
                log.write('REQ op=%d index=%d %r\n' % (op, index, body))
                log.flush()
                sha = b'\0' * 32
                if op == 1: s, p = 0, b'glassine-ramread 3\n'
                elif op == 8: s, p = 0, status_text().encode()
                elif op == 9: s, p = deploy(body)
                elif op == 10:
                    p = diag(); s = 0; sha = hashlib.sha256(p).digest()
                elif op == 4: s, p = 0, b''
                else: s, p = 2, b'unknown'
                c.sendall(RSP.pack(b'GRRS', ver, op, tag, s, 0, len(p), 0, sha) + p)
    except (EOFError, ConnectionError):
        pass
    c.close()


def end(*_):
    log.close()
    for f in fails: print('QTEST FAIL core: ' + f)
    print('QTEST %s core: every confirmed DEPLOY carried the token of its status-9 answer'
          % ('FAIL' if fails else 'ok  '))
    sys.stdout.flush()
    os._exit(1 if fails else 0)


signal.signal(signal.SIGTERM, end)
if os.path.exists(path): os.unlink(path)
srv = socket.socket(socket.AF_UNIX)
srv.bind(path)
srv.listen(4)
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
