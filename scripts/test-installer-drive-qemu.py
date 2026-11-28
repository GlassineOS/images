#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The guest half of scripts/test-installer-drive-qemu.sh, run in its container: the
installer drive (specs/004-installer-drive, FR-011) on a virtual PC (QEMU q35, OVMF).

    test-installer-drive-qemu.py --installer DIR --drive FILE --work DIR

It reuses the installer's QEMU harness (DIR/tests/qemu/run.py: the machine, its disks
and firmware) and the PC release test's steps (scripts/test-pc-release-qemu.py: the
console on an installed set, a start of it, the disk's checks):

  1. the drive's session: set.rec of the drive's one recovery image gets the serial
     console and the test hook glassine.drive.test=install:glassine-ci-0 (its check line
     made again; the loader compares no sum for a recovery it finds by itself). The
     machine: the drive as a removable USB stick, a blank 32 GiB NVMe disk (serial
     glassine-ci-0), no network. The firmware starts the drive's loader from its
     removable-media path, the loader the session, and the session's hook checks that the
     installer runs from the drive and refuses a plan onto it, installs on the NVMe disk
     and powers off;
  2. the drive afterwards: its boot partition byte for byte as before the start (the
     loader wrote no record), the pool image unchanged, the installation record in
     records/ on its data partition;
  3. the machine from the NVMe disk alone: the firmware's new entry, the release's
     loader, the installed set (with the console added, console_on); boot 1 is the first
     start (grows the pool, formats userdata, selects the first deployment, reboots),
     boot 2 boots that deployment, which the boot-success step accepts before the power
     button is pressed.

Every result is a line "QTEST ok|FAIL ..."; exit 0 when none failed.
"""
import argparse, hashlib, importlib.util, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

GIB = 1 << 30
TEST_SERIAL = 'glassine-ci-0'


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def range_sha(p, off, size):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        f.seek(off)
        left = size
        while left:
            b = f.read(min(left, 4 << 20))
            if not b:
                break
            h.update(b)
            left -= len(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    for a in ('installer', 'drive', 'work'):
        ap.add_argument('--' + a, type=Path, required=True)
    ap.add_argument('--boot-timeout', type=int, default=900)
    ap.add_argument('--session-timeout', type=int, default=int(os.environ.get('QTEST_SESSION_TIMEOUT', 5400)))
    ap.add_argument('--accept-wait', type=int, default=int(os.environ.get('QTEST_ACCEPT_WAIT', 240)))
    args = ap.parse_args()
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(args.installer / 'tests' / 'qemu'))
    import run as R  # the installer's harness
    T = load(Path(__file__).with_name('test-pc-release-qemu.py'), 'pctest')
    res = T.res
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

    # 1. the drive, with the console and the hook in its session's set.rec
    drive = cw / 'drive.img'
    R.run('cp', '--sparse=always', args.drive, drive)
    # a stick is larger than the image: its backup GPT header then isn't at the disk's end
    os.truncate(drive, max(os.path.getsize(drive), 8 * GIB))
    by = {e[6]: e for e in R.gpt(drive)}
    if not res(sorted(by) == ['glassine-drive-data', 'glassine-drive-esp'], f'the drive\'s partitions: {sorted(by)}'):
        return finish(T)
    espp, datap = by['glassine-drive-esp'], by['glassine-drive-data']
    eoff, esize = espp[4] * 512, (espp[5] - espp[4] + 1) * 512
    img = f'{drive}@@{eoff}'
    res(T.fat_get(cw, img, 'glassine/loader.a') is None and T.fat_get(cw, img, 'glassine/loader.b') is None,
        'the drive\'s boot partition has no loader record')
    res(T.fat_get(cw, img, 'EFI/BOOT/BOOTX64.EFI') is not None, 'the loader at the removable-media path')
    ls = subprocess.run(['mdir', '-b', '-i', img, '::/glassine/recovery'], capture_output=True, text=True).stdout.split()
    ids = [Path(x).name for x in ls if Path(x).name not in ('.', '..')]
    if not res(len(ids) == 1, f'one recovery image, the session: {ids}'):
        return finish(T)
    sid = ids[0]
    old = T.fat_get(cw, img, f'glassine/recovery/{sid}/set.rec')
    lines = T.record_lines(old)
    cmd0 = dict(lines)['cmdline']
    res('glassine.drive.test=' not in cmd0, 'the drive as made carries no test hook')
    res(f'glassine.img={sid}' in cmd0.split() and 'glassine.system=PARTUUID=00000000-0000-0000-0000-000000000000' in cmd0.split(),
        f'the session\'s command line: {cmd0}')
    hook = T.with_console(cmd0) + f' glassine.drive.test=install:{TEST_SERIAL}'
    (cw / 'set.rec').write_bytes(T.record_text([(k, hook if k == 'cmdline' else v) for k, v in lines]))
    R.run('mcopy', '-o', '-i', img, cw / 'set.rec', f'::/glassine/recovery/{sid}/set.rec')
    esp_before = range_sha(drive, eoff, esize)

    disk = cw / 'disk0.img'
    R.make_blank(disk, 32 * GIB)
    vars_fd = cw / 'OVMF_VARS.fd'
    shutil.copyfile(args.ovmf_vars, vars_fd)
    cmd = R.qemu_cmd(args, None, None, vars_fd, [('nvme', disk)], drive, None)
    cmd[cmd.index('-m') + 1] = '3072'
    # OVMF under KVM sometimes finds no file system on the emulated USB stick at its
    # first look ("failed to load ... Not Found", then "No bootable option"): a start
    # that ends there is tried again, the last time with the stick not removable; the
    # try that started the loader is reported.
    t0 = time.monotonic()
    tries = [('removable', cmd)] * 2 + [('not removable', [a.replace('removable=on', 'removable=off') for a in cmd])]
    for n, (how, c) in enumerate(tries, 1):
        log = cw / ('session.log' if n == 1 else f'session-{n}.log')
        g = R.Guest(c, log)
        try:
            got = g.until(('test hook: install on disk', 'test hook: no single disk', 'not a test disk',
                           "the session can't start", 'NOTHING_STARTED', 'Kernel panic',
                           'No bootable option or device was found'), args.session_timeout)
            if 'No bootable option' in got[-1]:
                g.p.kill()
                g.p.wait()
                print(f'    start {n} (the stick {how}): the firmware found nothing to start', flush=True)
                continue
            g.stop(300)
        except RuntimeError as e:
            print(f'  the session: {e}', flush=True)
            g.p.kill()
            g.p.wait()
        break
    time.sleep(1)
    print(f'QTEST info the session started on try {n} of {len(tries)} (the stick {how})', flush=True)
    text = log.read_text(errors='replace')
    for x in text.splitlines():
        if any(k in x for k in ('LOADER_START', 'START recovery', 'NOTHING_STARTED', 'no loader record', 'glassine-drive:', 'efi: EFI v')):
            print('    ' + x.strip(), flush=True)
    print(f'    the session ran {int(time.monotonic() - t0)} s', flush=True)
    res('no loader record: the recovery' in text and f'START recovery {sid}' in text,
        f'the firmware started the drive\'s loader, which started the session {sid} as the recovery found by itself')
    res('glassine-drive: session: release ' in text, 'the session\'s root assembled (base read-only, upper layer in memory)')
    res('test hook: root: overlay overlay rw' in text, 'the session\'s root is the writable overlay (its changes in memory)')
    failed = sorted(set(re.findall(r'ERROR: (\S+) failed to start', text)))
    print(f'QTEST info services that failed to start in the session: {failed or "none"}', flush=True)
    res(not {'machine-id', 'dbus', 'bootmisc'} & set(failed), f'the session\'s machine id, dbus and bootmisc started ({failed})')
    res('test hook: the first console\'s inittab line: yes' in text, 'the first console logs in to the drive\'s shell (inittab)')
    m0 = re.search(r'test hook: a shell on the first console: (\S+) \(cursor (\S*)\)', text)
    res(m0 is not None and m0.group(1) != 'none' and m0.group(2) == '1', f'a shell on the first console, the cursor on ({m0.group(0) if m0 else "none"})')
    mw = re.search(r'test hook: welcome: exit (\d+): (\d+) line', text)
    res(mw is not None and mw.group(1) == '0' and mw.group(2) != '0', f'the greeting names the release ({mw.group(0) if mw else "none"})')
    mp = re.search(r'test hook: glassine-drive plan onto disk (\d+): exit (\d+)', text)
    res(mp is not None and mp.group(2) == '0', f'glassine-drive plan onto the NVMe disk ({mp.group(0) if mp else "none"})')
    m = re.search(r'test hook: the installer runs from disk: (\d+) (\S+)', text)
    res(m is not None and m.group(2) == 'executable', f'the installer names the drive as the disk it runs from ({m.group(0) if m else "none"})')
    m2 = re.search(r'test hook: a plan onto the drive: exit (\d+): (.*)', text)
    res(m2 is not None and m2.group(1) != '0' and 'runs from' in m2.group(2), f'a plan onto the drive is refused ({m2.group(0) if m2 else "none"})')
    m3 = re.search(r'test hook: install on disk (\d+): exit (\d+)', text)
    res(m3 is not None and m3.group(2) == '0', f'the session installed on the NVMe disk ({m3.group(0) if m3 else "no install"})')

    # 2. the drive afterwards
    res(range_sha(drive, eoff, esize) == esp_before, 'the drive\'s boot partition is byte for byte as before the start')
    l = T.loop(drive, datap)
    try:
        os.makedirs('/d', exist_ok=True)
        T.sh('mount', '-t', 'ext4', '-o', 'ro,noload', l, '/d')
        try:
            rels = list(Path('/d/release').iterdir())
            doc = json.loads((rels[0] / 'release.json').read_text())
            b = doc['artifacts']['base']
            res(T.sha(rels[0] / b['file']) == b['sha256'], 'the drive\'s pool image is unchanged')
            recs = sorted(Path('/d/records').glob('*/record.json'))
            res(len(recs) == 1, f'the installation record on the drive: {[str(r.relative_to("/d")) for r in recs]}')
        finally:
            T.sh('umount', '/d')
    finally:
        T.sh('losetup', '-d', l)
    if m3 is None or m3.group(2) != '0':
        return finish(T)

    # 3. the installed disk alone
    t = R.gpt(disk)
    dby = {e[6]: e for e in t}
    if not res(all(p in dby for p in ('glassine-boot', 'glassine-system', 'glassine-userdata')), f'the installed partitions: {[e[6] for e in t]}'):
        return finish(T)
    bootp = dby['glassine-boot']
    lr = T.loader_record(cw, disk, bootp)
    kid = lr.get('default', '')
    n = T.console_on(R, cw, disk, bootp, f'glassine/sets/{kid}', 'default')
    res(n >= 1, f'the console on the installed set {kid}, the loader record made again in {n} slot(s)')
    arts = doc['artifacts']
    krel, base_id = arts['kernel'].get('release', ''), arts['base']['base']
    rc, text = T.boot_set(args, cw, 1, disk, None, None, '', vars_fd)
    res(f'START_KERNEL {kid} ' in text, f'boot 1: from the disk alone, the loader started the installed set {kid}')
    res('first deployment' in text and 'selected' in text, 'boot 1: the first start selected the first deployment')
    res(rc == 0, f'boot 1: rebooted by itself (qemu exit {rc})')
    dep = T.disk_check(1, disk, dby, base_id, krel, None)
    rc, text = T.boot_set(args, cw, 2, disk, None, None, '', vars_fd, until='glassine-deploy-accept: checking', then=args.accept_wait)
    res(f'deployment {dep}' in text and 'switch_root' in text, f'boot 2: the initramfs started deployment {dep}')
    res(rc == 0, f'boot 2: powered off by its power button (qemu exit {rc})')
    T.disk_check(2, disk, dby, base_id, krel, dep)
    return finish(T)


def finish(T):
    for p in Path(sys.argv[sys.argv.index('--work') + 1]).glob('*.img'):
        p.unlink()
    print(f'test-installer-drive-qemu: {len(T.FAILS)} failed' + ''.join(f'\n  {f}' for f in T.FAILS), flush=True)
    sys.exit(1 if T.FAILS else 0)


if __name__ == '__main__':
    main()
