#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The guest half of scripts/test-pc-release-qemu.sh, run in its container: a PC
release folder installed by GlassineOS/installer on a blank virtual PC (QEMU q35, OVMF),
then the installed disk started.

    test-pc-release-qemu.py --installer DIR --binary FILE --release DIR --work DIR --cache DIR

It reuses the installer's own QEMU harness (DIR/tests/qemu/run.py: its guest, its
stick, its disks, its firmware checks), with the release given here in place of the
harness's made-up one:

  1. the stick: the static glassine-install, the installer's uefi-pc description and the
     release folder, byte for byte. A release without a boot-loader gets the harness's
     placeholder loader as that role on the stick's copy (the installer's own test path);
  2. install --pc on a blank 32 GiB NVMe disk (the description's sizes): it must finish,
     with the partitions, the pool image byte for byte, the kernel set the installer
     assembled from the release's parts, the loader record, the splash, and one new
     firmware boot entry, first;
  3. the machine from its disk alone: the firmware starts that entry, the release's
     loader (GlassineOS/loader: its LOADER_START line with the pinned version), which starts the default set
     (START_KERNEL) from its record. One change to the installed disk, so that Linux
     reaches the serial log: the set's command line gets console=ttyS0 loglevel=7, with
     set.rec's check line and the loader record's default_rec made again (console_on);
     every other byte of the set is the installer's. Boot 1 is the first start: it grows
     the pool, formats glassine-userdata, selects the first deployment and reboots. Boot 2
     boots that deployment, which the boot-success step accepts; then the guest is
     powered off by its power button (ACPI, the base's acpid) --accept-wait seconds
     (default 240, QTEST_ACCEPT_WAIT) after that step's service starts. The disk is
     checked after each boot; after boot 2 the deployment must be current (accepted), no
     candidate, and the loader record names the set it started with unmarked=0: the
     boot-success step's healthy mark (boot's glassine-loader-mark, in the base's
     glassine-deploy) cleared the loader's count, and the power-off's shutdown step
     wrote nothing more.
  5. the loader's limit, end to end (with the release's loader only; QTEST_LIMIT=0
     skips it). A test script in the deployment's upper layer (local.d, written from the
     host and removed after its one run) installs a second kernel set with the running
     system's own glassine-bootimg (the base command line + the console, so its id
     differs) and reboots into its trial: boot 3, an unmarked start that ends in an
     orderly reboot, so the shutdown step takes it out of the count (unmarked 0 again).
     Boot 4: the trial, which glassine-bootimg-promote accepts: default = the new set,
     previous = the installer's. Boots 5 to 7: the new default, stopped (QEMU quit)
     before the boot-success step can accept it: the loader counts 1, 2, 3. Boot 8: at
     3, the loader starts the previous set (started_why=limit); it is accepted, so the
     healthy mark and glassine-bootimg rollback --limit make it the default again:
     default = the installer's set, previous = the failed one, unmarked=0, and
     state/kernel lists the failed kernel. Boot 9: the loader starts the new default
     with started_why=default; powered off before the accept (a real poweroff after an
     unmarked start), the shutdown step takes it out of the count again (unmarked=0).

  Without a release loader, or with --direct-kernel (QTEST_DIRECT_KERNEL=1): step 3 only
  shows the firmware starting the entry, and OVMF then starts the set's vmlinuz with its
  initrd and its set.rec command line directly (-kernel/-initrd; + console=ttyS0
  loglevel=7), as the loader would start it.

Every result is a line "QTEST ok|FAIL ..."; exit 0 when none failed.
"""
import argparse, hashlib, json, os, re, shutil, socket, subprocess, sys, time
from pathlib import Path

MIB, GIB = 1 << 20, 1 << 30
FAILS = []


def res(ok, what):
    print(f'QTEST {"ok" if ok else "FAIL"} {what}', flush=True)
    if not ok:
        FAILS.append(what)
    return ok


def sh(*cmd, **kw):
    return subprocess.run([str(c) for c in cmd], check=True, capture_output=True, text=True, **kw).stdout


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(MIB), b''):
            h.update(b)
    return h.hexdigest()


def stick(R, p: Path, binary: Path, release: Path, installer: Path, cw: Path) -> dict:
    """The installer's stick with the release and the placeholder as its boot-loader."""
    rel = cw / 'release'
    def link(a, b):
        try:
            os.link(a, b)
        except OSError:
            shutil.copyfile(a, b)
    shutil.copytree(release, rel, copy_function=link)
    doc = json.loads((rel / 'release.json').read_text())
    arts = doc['artifacts']
    gap = 'boot-loader' not in arts
    if gap:
        (rel / 'boot-loader').mkdir()
        b = R.placeholder.efi_app()
        (rel / 'boot-loader' / 'placeholder.efi').write_bytes(b)
        arts['boot-loader'] = {'file': 'boot-loader/placeholder.efi', 'sha256': hashlib.sha256(b).hexdigest(),
                               'size': len(b), 'kind': 'efi-application'}
        doc['missing'] = [m for m in doc.get('missing', []) if m != 'boot-loader']
        os.unlink(rel / 'release.json')
        (rel / 'release.json').write_text(json.dumps(doc, indent=2, sort_keys=True) + '\n')
    total = sum(f.stat().st_size for f in rel.rglob('*') if f.is_file())
    R.sparse(p, max(2 * GIB, (total + binary.stat().st_size) // MIB * MIB + 1 * GIB))
    R.run('sgdisk', '-n1:1MiB:0', '-t1:0700', '-c1:GLINSTALL', p)
    off, size = R.part_start(p, 1)
    R.run('mkfs.fat', '-F', '32', '-n', 'GLINSTALL', '--offset', off // 512, p, size // 1024)
    img = f'{p}@@{off}'
    R.run('mcopy', '-i', img, binary, '::/glassine-install')
    R.run('mcopy', '-i', img, installer / 'devices' / 'uefi-pc.toml', '::/uefi-pc.toml')
    R.run('mcopy', '-s', '-i', img, rel, '::/release')
    (cw / 'install-args').write_text('--backup\n/media/stick/backup\n')
    R.run('mcopy', '-i', img, cw / 'install-args', '::/install-args')
    return {'doc': doc, 'dir': rel, 'loader_gap': gap}


def fat_file(cw, bootimg, path):
    out = cw / ('fat-' + path.replace('/', '_'))
    r = subprocess.run(['mcopy', '-n', '-i', str(bootimg), '::/' + path, str(out)], capture_output=True)
    return out if r.returncode == 0 and out.exists() else None


def initrd_of(R, rel: Path, arts: dict) -> bytes:
    """The kernel set's initrd as boot-partition.md assembles it from the release's parts."""
    micro = sorted((Path(a['file']).name, r) for r, a in arts.items() if r == 'microcode' or r.startswith('microcode-'))
    out = b''
    for part in [(rel / arts[r]['file']).read_bytes() for _, r in micro] + [(rel / arts['initramfs']['file']).read_bytes()]:
        out += b'\0' * (-len(out) % 4) + part
    board = (rel / arts['board']['file']).read_bytes()
    out += b'\0' * (-len(out) % 4) + R.newc([('etc', 0o40755, b''), ('etc/glassine-boot', 0o40755, b''),
                                            ('etc/glassine-boot/board.conf', 0o100644, board)])
    if 'boot-modules' in arts:
        out += b'\0' * (-len(out) % 4) + (rel / arts['boot-modules']['file']).read_bytes()
    return out


def loop(disk, part, ro=True):
    return sh('losetup', '-f', '--show', *(['-r'] if ro else []), '-o', part[4] * 512,
              '--sizelimit', (part[5] - part[4] + 1) * 512, disk).strip()


def kv(path):
    try:
        return dict(ln.split('=', 1) for ln in Path(path).read_text().splitlines() if '=' in ln)
    except OSError:
        return {}


def disk_check(n, disk, by, base_id, krel, first_dep):
    """The disk after boot n, read-only: the pool, its state, userdata."""
    sysp, datap = by['glassine-system'], by['glassine-userdata']
    l = loop(disk, sysp)
    try:
        sup = sh('btrfs', 'inspect-internal', 'dump-super', l)
        tb = next(int(x.split()[1]) for x in sup.splitlines() if x.startswith('total_bytes'))
        size = (sysp[5] - sysp[4] + 1) * 512
        res(tb == size, f'after boot {n}: the pool fills glassine-system ({tb} of {size} bytes)')
        c = subprocess.run(['btrfs', 'check', '--readonly', l], capture_output=True, text=True)
        res(c.returncode == 0, f'after boot {n}: glassine-system (btrfs) clean' + ('' if c.returncode == 0 else f': {c.stderr[-500:]}'))
        os.makedirs('/s', exist_ok=True)
        sh('mount', '-t', 'btrfs', '-o', 'ro', l, '/s')
        try:
            res(not os.path.exists('/s/state/install'), f'after boot {n}: the install marker state/install is gone')
            d, k = kv('/s/state/deploy'), kv('/s/state/kernel')
            print(f'    state/deploy: {d}\n    state/kernel: {k}', flush=True)
            res(k.get('current') == krel, f'after boot {n}: state/kernel current= the release\'s kernel {krel}')
            res(sorted(os.listdir('/s/bases')) == [base_id], f'after boot {n}: bases/ holds the release\'s base only')
            if n == 1:
                res(bool(d.get('candidate')) and not d.get('current'), f'after boot 1: a candidate deployment ({d.get("candidate")}), no current')
                dep = d.get('candidate')
            else:
                res(d.get('current') == first_dep and not d.get('candidate'), f'after boot 2: the first deployment ({first_dep}) is current, no candidate')
                dep = d.get('current')
        finally:
            sh('umount', '/s')
    finally:
        sh('losetup', '-d', l)
    l = loop(disk, datap)
    try:
        h = subprocess.run(['dumpe2fs', '-h', l], capture_output=True, text=True).stdout
        f = {ln.split(':', 1)[0]: ln.split(':', 1)[1].strip() for ln in h.splitlines() if ':' in ln}
        res(f.get('Block size') == '4096', f'after boot {n}: glassine-userdata is ext4 with 4096-byte blocks')
        c = subprocess.run(['e2fsck', '-fn', l], capture_output=True, text=True)
        res(c.returncode == 0 and 'needs_recovery' not in f.get('Filesystem features', ''), f'after boot {n}: glassine-userdata (ext4) clean')
        os.makedirs('/u', exist_ok=True)
        sh('mount', '-t', 'ext4', '-o', 'ro,noload', l, '/u')
        try:
            meta = kv(f'/u/media/glassine/deployments/{dep}/meta')
            res(meta.get('kind') == 'install' and meta.get('base') == base_id, f'after boot {n}: deployment {dep}: kind=install on base {base_id} ({meta})')
        finally:
            sh('umount', '/u')
    finally:
        sh('losetup', '-d', l)
    return dep


def fat_get(cw, img, path):
    """A file of the FAT at `img` (mtools' file@@offset), or None."""
    out = cw / 'fat-get'
    out.unlink(missing_ok=True)
    r = subprocess.run(['mcopy', '-n', '-i', img, '::/' + path, str(out)], capture_output=True)
    return out.read_bytes() if r.returncode == 0 and out.exists() else None


def record_text(lines):
    """A record's bytes (boot-partition.md "Records"): the lines and the check line."""
    body = ''.join(f'{k}={v}\n' for k, v in lines).encode()
    return body + b'check=' + hashlib.sha256(body).hexdigest().encode() + b'\n'


def record_lines(b):
    body, sep, last = b.rstrip(b'\n').rpartition(b'\n')
    body += sep
    assert last == b'check=' + hashlib.sha256(body).hexdigest().encode(), 'not a valid record'
    return [tuple(x.split('=', 1)) for x in body.decode().splitlines()]


def console_on(R, cw, disk, bootp, sd, key):
    """The one change this test makes to what the installer wrote: the installed set's
    command line gets console=ttyS0 loglevel=7 (the board's has no console, so nothing
    of Linux would reach the serial log), with set.rec's check line and the sha256 the
    loader record's `<key>_rec` names made again in every slot that names it. The
    loader starts that set unchanged otherwise (its files, sizes and sums)."""
    img = f'{disk}@@{bootp[4] * 512}'
    old = fat_get(cw, img, f'{sd}/set.rec')
    lines = [(k, v + ' console=ttyS0 loglevel=7' if k == 'cmdline' else v) for k, v in record_lines(old)]
    new = record_text(lines)
    (cw / 'set.rec').write_bytes(new)
    R.run('mcopy', '-o', '-i', img, cw / 'set.rec', f'::/{sd}/set.rec')
    old_sha, new_sha = hashlib.sha256(old).hexdigest(), hashlib.sha256(new).hexdigest()
    n = 0
    for slot in ('glassine/loader.a', 'glassine/loader.b'):
        b = fat_get(cw, img, slot)
        if b is None:
            continue
        try:
            sl = record_lines(b)
        except (AssertionError, ValueError):
            continue
        if dict(sl).get(f'{key}_rec') != old_sha:
            continue
        size = len(b)
        b = record_text([(k, new_sha if k == f'{key}_rec' else v) for k, v in sl])
        b += b'\n' * (size - len(b))
        (cw / 'slot').write_bytes(b)
        R.run('mcopy', '-o', '-i', img, cw / 'slot', f'::/{slot}')
        n += 1
    return n


def loader_record(cw, disk, bootp):
    """The loader record in use after a start (the valid slot with the higher seq)."""
    img = f'{disk}@@{bootp[4] * 512}'
    best = None
    for slot in ('glassine/loader.a', 'glassine/loader.b'):
        b = fat_get(cw, img, slot)
        try:
            d = dict(record_lines(b)) if b is not None else None
        except (AssertionError, ValueError):
            d = None
        if d and d.get('seq', '').isdigit() and (best is None or int(d['seq']) > int(best['seq'])):
            best = d
    return best or {}


def boot_set(args, cw, n, disk, vmlinuz, initrd, cmdline, vars_fd, until=None, then=0, quit=False):
    """One start of the kernel set; QEMU ends by itself (-no-reboot), or, `then` seconds
    after `until` is on the console, the guest's power button is pressed (QMP), or with
    `quit` QEMU stops at once (a start that ends without any shutdown).
    `vmlinuz` None: from the disk alone, the firmware's boot entry (the loader), on the
    machine the install ran on (the installer harness's devices, so the entry's device
    path holds); else OVMF starts `vmlinuz` directly (-kernel/-initrd)."""
    qmp = cw / f'qmp{n}.sock'
    if vmlinuz is None:
        cmd = args.R.qemu_cmd(args, None, None, vars_fd, [('nvme', disk)], None, None)
        cmd[cmd.index('-m') + 1] = '2048'
        cmd += ['-qmp', f'unix:{qmp},server=on,wait=off']
    else:
        cmd = ['qemu-system-x86_64', '-machine', 'q35', '-m', '2048', '-smp', '2', '-accel', 'kvm', '-accel', 'tcg',
               '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-no-reboot',
               '-drive', f'if=pflash,format=raw,unit=0,readonly=on,file={args.ovmf_code}',
               '-drive', f'if=pflash,format=raw,unit=1,file={vars_fd}',
               '-kernel', str(vmlinuz), '-initrd', str(initrd), '-append', cmdline + ' console=ttyS0 loglevel=7',
               '-drive', f'if=none,id=d0,format=raw,file={disk}', '-device', 'nvme,drive=d0,serial=glassine-ci-0',
               '-net', 'none', '-qmp', f'unix:{qmp},server=on,wait=off']
    log = cw / f'boot{n}.log'
    R = args.R
    g = R.Guest(cmd, log)
    lines = []
    try:
        if until:
            lines = g.until(until, args.boot_timeout)
            time.sleep(then)
            s = socket.socket(socket.AF_UNIX)
            s.connect(str(qmp))
            for m in ({'execute': 'qmp_capabilities'}, {'execute': 'quit' if quit else 'system_powerdown'}):
                s.sendall(json.dumps(m).encode() + b'\n')
                time.sleep(1)
            s.close()
        g.p.wait(timeout=args.boot_timeout)
    except Exception as e:
        print(f'  boot {n}: {e}', flush=True)
        g.p.kill()
        g.p.wait()
    time.sleep(1)
    text = log.read_text(errors='replace')
    for x in text.splitlines():
        if any(k in x for k in ('glassine-first-start:', 'glassine-deploy-accept:', 'glassine-boot:', 'glassine-switch:',
                                'efi: EFI v', 'boot modules:', 'LOADER_START', 'START_KERNEL', 'SECURE_BOOT',
                                'MESSAGE ', 'PANIC ', 'StartImage', 'glassine-loader-mark:', 'qtest-limit:')):
            print('    ' + x.strip(), flush=True)
    return g.p.returncode, text


QTEST_SCRIPT = r"""#!/bin/sh
# test-pc-release-qemu's limit run: a second kernel set, then the reboot into its trial
# the console, not the kernel log: once the system is up, the kernel log isn't on it
say() { echo "qtest-limit: $*" > /dev/console; }
b=/etc/glassine-bootimg/board.conf
grep -q '^CMDLINE=.*console=ttyS0' "$b" || sed -i 's/^CMDLINE="\(.*\)"$/CMDLINE="\1 console=ttyS0 loglevel=7"/' "$b"
say "board CMDLINE: $(grep '^CMDLINE=' "$b")"
n=0
while :; do
    out=$(glassine-bootimg install "$(uname -r)" 2>&1); rc=$?
    [ $rc = 6 ] && [ $n -lt 120 ] || break
    sleep 2; n=$((n + 2))
done
say "install: exit $rc: $(echo "$out" | tail -n 4 | tr '\n' ' ')"
[ $rc = 0 ] || exit 0
# the reboot after this service's start returned (it hands the reboot to init)
setsid sh -c 'sleep 5; echo "qtest-limit: reboot-test" > /dev/console; out=$(glassine-bootimg reboot-test 2>&1) || echo "qtest-limit: reboot-test failed: $out" > /dev/console' </dev/null >/dev/null 2>&1 &
"""


def upper(disk, datap, dep, put=None, drop=()):
    """Files in deployment `dep`'s live upper layer (switch/) on glassine-userdata, read
    by the overlay at its next mount: put = {path: (bytes, mode) or ('->', target)}."""
    l = loop(disk, datap, ro=False)
    try:
        os.makedirs('/u', exist_ok=True)
        sh('mount', '-t', 'ext4', l, '/u')
        try:
            up = Path(f'/u/media/glassine/deployments/{dep}/switch')
            for rel, v in (put or {}).items():
                f = up / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                if f.is_symlink() or f.exists():
                    f.unlink()
                if v[0] == '->':
                    f.symlink_to(v[1])
                else:
                    f.write_bytes(v[0])
                    f.chmod(v[1])
            for rel in drop:
                (up / rel).unlink(missing_ok=True)
        finally:
            sh('umount', '/u')
    finally:
        sh('losetup', '-d', l)


def pool_put(disk, sysp, put):
    """Files on glassine-system (the pool's top level), written while the guest is off:
    put = {path: bytes}."""
    l = loop(disk, sysp, ro=False)
    try:
        os.makedirs('/s', exist_ok=True)
        sh('mount', '-t', 'btrfs', l, '/s')
        try:
            for rel, b in put.items():
                f = Path('/s') / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_bytes(b)
        finally:
            sh('umount', '/s')
    finally:
        sh('losetup', '-d', l)


def kernel_state(disk, sysp):
    """state/kernel on glassine-system, read-only."""
    l = loop(disk, sysp)
    try:
        os.makedirs('/s', exist_ok=True)
        sh('mount', '-t', 'btrfs', '-o', 'ro', l, '/s')
        try:
            return kv('/s/state/kernel')
        finally:
            sh('umount', '/s')
    finally:
        sh('losetup', '-d', l)


def limit_run(args, cw, disk, bootp, sysp, datap, dep, kid, vars_fd):
    """Step 5: the loader's limit, end to end (see the module's docstring)."""
    def rec(n):
        r = loader_record(cw, disk, bootp)
        print(f'    loader record after boot {n}: seq={r.get("seq")} unmarked={r.get("unmarked")} default={r.get("default")} '
              f'previous={r.get("previous")} started={r.get("started")} started_why={r.get("started_why")} '
              f'request={r.get("request")} trial={r.get("trial")}', flush=True)
        return r

    # glassine-bootimg install takes the initramfs from the pool's boot/initramfs/, which
    # `glassine-deploy receive --boot` fills on a device. A release pool has no boot/
    # files and receive --boot doesn't exist yet, so this test supplies the release's
    # initramfs and its build manifest itself: a fresh install can't do this step alone.
    arts = json.loads((args.release / 'release.json').read_text())['artifacts']
    ird = arts['initramfs']['identity']
    irm = args.initramfs_dir / f'{ird}.manifest' if args.initramfs_dir else None
    if not irm or not irm.is_file():
        res(False, f'step 5: no manifest of initramfs {ird} (--initramfs-dir: the build\'s boot/initramfs/; QTEST_LIMIT=0 skips the step)')
        return
    pool_put(disk, sysp, {f'boot/initramfs/{ird}.cpio.gz': (args.release / arts['initramfs']['file']).read_bytes(),
                          f'boot/initramfs/{ird}.manifest': irm.read_bytes()})
    upper(disk, datap, dep, {'etc/local.d/qtest-limit.start': (QTEST_SCRIPT.encode(), 0o755),
                             'etc/runlevels/default/local': ('->', '/etc/init.d/local')})
    # boot 3: the second set installed, then the reboot into its trial (orderly)
    rc, text = boot_set(args, cw, 3, disk, None, None, '', vars_fd)
    upper(disk, datap, dep, drop=('etc/local.d/qtest-limit.start',))
    res(f'START_KERNEL {kid} ' in text, f'boot 3: the loader started the default set {kid}')
    res('qtest-limit: install: exit 0' in text and 'reboot-test failed' not in text,
        'boot 3: glassine-bootimg installed a second kernel set and rebooted into its trial')
    r = rec(3)
    k2 = r.get('trial', '')
    res(bool(k2) and k2 != kid and r.get('request') == 'trial', f'after boot 3: the record names the new set {k2} as the trial, request=trial')
    # the shutdown step's line (its service's stop writes it on the console)
    res(r.get('unmarked') == '0' and 'this start taken out of the count (unmarked 1 -> 0)' in text,
        f'after boot 3: the unmarked start ended in an orderly reboot, the shutdown step took it out of the count (unmarked={r.get("unmarked")})')
    if not k2:
        return
    # boot 4: the trial, promoted
    rc, text = boot_set(args, cw, 4, disk, None, None, '', vars_fd, until='glassine-deploy-accept: checking', then=args.accept_wait)
    res(f'START_KERNEL {k2} ' in text, f'boot 4: the loader started the trial set {k2}')
    r = rec(4)
    res(r.get('default') == k2 and r.get('previous') == kid and not r.get('trial') and r.get('unmarked') == '0',
        f'after boot 4: the trial promoted: default {r.get("default")}, previous {r.get("previous")}, unmarked={r.get("unmarked")}')
    if r.get('default') != k2:
        return
    # boots 5 to 7: the new default, never accepted (stopped before the boot-success step)
    for n in (5, 6, 7):
        rc, text = boot_set(args, cw, n, disk, None, None, '', vars_fd, until='glassine-deploy-accept: checking', then=5, quit=True)
        r = rec(n)
        res(f'START_KERNEL {k2} ' in text and r.get('started') == k2 and r.get('started_why') == 'default'
            and r.get('unmarked') == str(n - 4),
            f'boot {n}: the default set {k2} started, stopped before its accept: unmarked={r.get("unmarked")} (want {n - 4})')
    # boot 8: the limit: the previous set, accepted, the rollback
    rc, text = boot_set(args, cw, 8, disk, None, None, '', vars_fd, until='glassine-deploy-accept: checking', then=args.accept_wait)
    res(f'START_KERNEL {kid} ' in text, f'boot 8: at the limit the loader started the previous set {kid}')
    r = rec(8)
    res(r.get('started') == kid and r.get('started_why') == 'limit', f'after boot 8: started={r.get("started")} started_why={r.get("started_why")} (limit)')
    res(r.get('default') == kid and r.get('previous') == k2 and r.get('unmarked') == '0',
        f'after boot 8: accepted: default = the previous set {r.get("default")}, previous = the failed {r.get("previous")}, unmarked={r.get("unmarked")}')
    k = kernel_state(disk, sysp)
    print(f'    state/kernel after boot 8: {k}', flush=True)
    res(k.get('current_img') == kid and k.get('previous_img') == k2 and k.get('failed_img') == k2 and not k.get('writing'),
        'after boot 8: state/kernel: the previous kernel current again, the failed one listed as failed')
    # boot 9: the new default, by default; powered off before its accept
    rc, text = boot_set(args, cw, 9, disk, None, None, '', vars_fd, until='glassine-deploy-accept: checking', then=5)
    res(f'START_KERNEL {kid} ' in text, f'boot 9: the loader started the new default set {kid}')
    r = rec(9)
    res(r.get('started') == kid and r.get('started_why') == 'default', f'after boot 9: started={r.get("started")} started_why={r.get("started_why")} (default)')
    res(rc == 0 and r.get('unmarked') == '0' and 'this start taken out of the count (unmarked 1 -> 0)' in text,
        f'after boot 9: a poweroff before the accept: the shutdown step took the start out of the count (unmarked={r.get("unmarked")}, qemu exit {rc})')


def main():
    ap = argparse.ArgumentParser()
    for a in ('installer', 'binary', 'release', 'work', 'cache'):
        ap.add_argument('--' + a, type=Path, required=True)
    ap.add_argument('--initramfs-dir', type=Path, default=None,
                    help="the build's boot/initramfs/ (its manifests): step 5 needs the release initramfs's")
    ap.add_argument('--boot-timeout', type=int, default=900)
    ap.add_argument('--direct-kernel', action='store_true', default=os.environ.get('QTEST_DIRECT_KERNEL') == '1',
                    help='start the kernel set with -kernel/-initrd, not through the release\'s loader')
    ap.add_argument('--run-timeout', type=int, default=1800)
    ap.add_argument('--accept-wait', type=int, default=int(os.environ.get('QTEST_ACCEPT_WAIT', 240)),
                    help='seconds from the boot-success service\'s start to the power button')
    args = ap.parse_args()
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(args.installer / 'tests' / 'qemu'))
    import run as R  # the installer's harness
    args.R = R
    for c, v in R.OVMF_CANDIDATES:
        if Path(c).exists() and Path(v).exists():
            args.ovmf_code, args.ovmf_vars = Path(c), Path(v)
            break
    else:
        sys.exit('no OVMF')
    print('kvm:', 'yes' if os.access('/dev/kvm', os.R_OK | os.W_OK) else 'no (tcg, slow)', flush=True)
    cw = args.work
    cw.mkdir(parents=True, exist_ok=True)
    files = R.fetch(args.cache)
    boot = {'kernel': files['vmlinuz-virt'], 'initrd': R.initramfs(files, cw)}
    release = args.release.resolve()
    rdoc = json.loads((release / 'release.json').read_text())
    arts = rdoc['artifacts']

    # 1, 2: the install
    disk = cw / 'disk0.img'
    R.make_blank(disk, 32 * GIB)
    st = cw / 'stick.img'
    s = stick(R, st, args.binary, release, args.installer, cw)
    if s['loader_gap']:
        print('QTEST info the release has no boot-loader (GlassineOS/loader has no release): '
              'the stick\'s copy carries the installer harness\'s placeholder loader', flush=True)
    vars_fd = cw / 'OVMF_VARS.fd'
    shutil.copyfile(args.ovmf_vars, vars_fd)
    lines = R.run_guest(args, boot, vars_fd, [('nvme', disk)], st, 'install', cw / 'serial-install.log')
    first, after = R.boot_vars(lines, 'before'), R.boot_vars(lines, 'after')
    rec = R.records(lines)
    code, text = rec.get('log-install', (None, ''))
    res(code == 0, f'the installer accepted the release and installed it: exit {code}')
    if code != 0:
        print((text or '')[-4000:])
    for x in (text or '').splitlines():
        if any(w in x for w in ('release', 'artifact', 'role', 'kernel set', 'microcode', 'splash', 'boot-modules')):
            print('    ' + x, flush=True)
    t = R.gpt(disk)
    by = {e[6]: e for e in t}
    if not res(all(p in by for p in ('glassine-boot', 'glassine-system', 'glassine-userdata')),
               f'the three partitions: {[e[6] for e in t]}'):
        return
    bootp, sysp, datap = by['glassine-boot'], by['glassine-system'], by['glassine-userdata']
    res((bootp[5] - bootp[4] + 1) * 512 == 2 * GIB and (sysp[5] - sysp[4] + 1) * 512 == 16 * GIB
        and (datap[5] - datap[4] + 1) * 512 >= 8 * GIB, 'glassine-boot 2 GiB, glassine-system 16 GiB, glassine-userdata >= 8 GiB')
    pool = release / arts['base']['file']
    res(R.range_digest(disk, sysp[4] * 512, arts['base']['size']) == arts['base']['sha256'],
        'glassine-system holds the release\'s pool image byte for byte')
    bootimg = cw / 'boot.img'
    R.run('dd', f'if={disk}', f'of={bootimg}', 'bs=4M', f'skip={bootp[4] * 512}', f'count={(bootp[5] - bootp[4] + 1) * 512}',
          'iflag=skip_bytes,count_bytes', 'conv=sparse', stderr=subprocess.DEVNULL)
    lr = R.record_keys((fat_file(cw, bootimg, 'glassine/loader.a') or Path('/dev/null')).read_bytes())
    kid = lr.get('default', '')
    sd = f'glassine/sets/{kid}'
    vml, ird, srec = (fat_file(cw, bootimg, f'{sd}/{f}') for f in ('vmlinuz', 'initrd', 'set.rec'))
    res(vml is not None and sha(vml) == arts['kernel']['sha256'], 'the kernel set\'s vmlinuz is the release\'s kernel')
    want = initrd_of(R, release, arts)
    res(ird is not None and sha(ird) == hashlib.sha256(want).hexdigest(),
        f'its initrd is the release\'s parts as boot-partition.md assembles them ({len(want)} bytes)')
    sk = R.record_keys(srec.read_bytes() if srec else b'')
    ident = f'glassine.system=PARTUUID={sysp[3]} glassine.userdata=PARTUUID={datap[3]} glassine.img={kid}'
    res(sk.get('cmdline') == f'{arts["kernel"]["cmdline"]} {ident}', f'its command line: the board\'s CMDLINE and the identities: {sk.get("cmdline")}')
    res(sk.get('initramfs') == arts['initramfs'].get('identity'), f'set.rec names the initramfs {sk.get("initramfs")}')
    if 'splash' in arts:
        sp = fat_file(cw, bootimg, 'glassine/splash/default.gspl')
        res(sp is not None and sha(sp) == arts['splash']['sha256'], 'the default splash')
    new = [k for k in after if k not in first]
    res(len(new) == 1 and new[0].startswith('Boot'), f'one new firmware boot entry: {new}')

    cmdline = sk.get('cmdline', '')
    krel, base_id = arts['kernel'].get('release', ''), arts['base']['base']
    direct = s['loader_gap'] or args.direct_kernel
    if direct:
        # 3: the firmware starts the entry (the placeholder, or the release's loader
        # stopped at its first line)
        g = R.Guest(R.qemu_cmd(args, None, None, vars_fd, [('nvme', disk)], None, None), cw / 'serial-firmware.log')
        try:
            marks = (R.placeholder.MARKER, 'LOADER_START', 'Access Denied', 'No bootable')
            out = g.until(marks, args.boot_timeout)
            try:
                g.stop(60 if s['loader_gap'] else 1)
            except RuntimeError:
                pass
        finally:
            g.p.kill()
            g.p.wait()
        mark = R.placeholder.MARKER if s['loader_gap'] else 'LOADER_START'
        res(any(mark in x for x in out), f'the firmware starts the new entry from the disk alone ({mark})')
        # 4: the kernel set, as the loader starts it
        vm, ir = vml, ird
    else:
        # 3, 4: from the disk alone: the firmware starts the entry, the release's loader
        # starts the set (the console added to its command line, console_on)
        n = console_on(R, cw, disk, bootp, sd, 'default')
        res(n >= 1, f'the console on the set\'s command line, the loader record\'s default_rec made again in {n} slot(s)')
        vm, ir = None, None
    rc, text = boot_set(args, cw, 1, disk, vm, ir, cmdline, vars_fd)
    if not direct:
        bl = s['doc']['artifacts']['boot-loader']
        m = re.search(r'/download/v([^/]+)/', bl.get('url', ''))
        want = 'LOADER_START x86-64' + (f' {m.group(1)}' if m else '')
        res(want in text, f'boot 1: the release\'s loader ({bl.get("url") or bl.get("file")}) started from the firmware\'s entry: "{want}"')
        res(f'START_KERNEL {kid} ' in text, f'boot 1: the loader started the default set {kid}')
    res('efi: EFI v' in text, 'boot 1: started by UEFI firmware')
    res('first deployment' in text and 'selected' in text, 'boot 1: the first start selected the first deployment')
    res(rc == 0, f'boot 1: rebooted by itself (qemu exit {rc})')
    dep = disk_check(1, disk, by, base_id, krel, None)
    # the boot-success step runs ACCEPT_AFTER (120 s) after the start and logs to the
    # kernel log only (not the console once the system is up): its result is read from
    # the disk afterwards (state/deploy: the deployment current, no candidate)
    rc, text = boot_set(args, cw, 2, disk, vm, ir, cmdline, vars_fd,
                        until='glassine-deploy-accept: checking', then=args.accept_wait)
    if not direct:
        res(f'START_KERNEL {kid} ' in text, f'boot 2: the loader started the default set {kid}')
    res(f'deployment {dep}' in text and 'switch_root' in text, f'boot 2: the initramfs started deployment {dep}')
    res(rc == 0, f'boot 2: powered off by its power button (qemu exit {rc})')
    disk_check(2, disk, by, base_id, krel, dep)
    if not direct:
        # the unmarked count: the accepted start is marked healthy in the loader record
        # (boot's glassine-loader-mark, 010 FR-023); unmarked, the loader would start
        # the previous set at 3.
        lr2 = loader_record(cw, disk, bootp)
        print(f'QTEST info the loader record after boot 2: seq={lr2.get("seq")} unmarked={lr2.get("unmarked")} '
              f'started={lr2.get("started")} started_why={lr2.get("started_why")}', flush=True)
        res(lr2.get('started') == kid, f'after boot 2: the loader record names the set it started ({lr2.get("started")})')
        res(lr2.get('unmarked') == '0', f'after boot 2: the accepted start marked healthy, unmarked=0 ({lr2.get("unmarked")})')
        if os.environ.get('QTEST_LIMIT', '1') != '0':
            limit_run(args, cw, disk, bootp, sysp, datap, dep, kid, vars_fd)
    for p in cw.glob('*.img'):
        p.unlink()
    print(f'test-pc-release-qemu: {len(FAILS)} failed' + ''.join(f'\n  {f}' for f in FAILS), flush=True)
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
