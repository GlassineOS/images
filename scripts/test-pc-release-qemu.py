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
     release folder. The release has no boot-loader (GlassineOS/loader has no release
     yet), so the stick's copy gets the harness's placeholder loader as that role (the
     installer's own test path); every other role is the release's, byte for byte;
  2. install --pc on a blank 32 GiB NVMe disk (the description's sizes): it must finish,
     with the partitions, the pool image byte for byte, the kernel set the installer
     assembled from the release's parts, the loader record, the splash, and one new
     firmware boot entry, first;
  3. the machine from its disk alone: the firmware starts that entry (the placeholder's
     serial marker);
  4. the kernel set as the loader would start it: OVMF starts the set's vmlinuz with its
     initrd and its set.rec command line (-kernel/-initrd; + console=ttyS0 loglevel=7 to
     see it), the installed disk only. Boot 1 is the first start: it grows the pool,
     formats glassine-userdata, selects the first deployment and reboots. Boot 2 boots
     that deployment, which the boot-success step accepts; then the guest is powered
     off by its power button (ACPI, the base's acpid) --accept-wait seconds (default
     240, QTEST_ACCEPT_WAIT) after that step's service starts. The disk is checked after
     each boot; after boot 2 the deployment must be current (accepted), no candidate.

Every result is a line "QTEST ok|FAIL ..."; exit 0 when none failed.
"""
import argparse, hashlib, json, os, shutil, socket, subprocess, sys, time
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


def boot_set(args, cw, n, disk, vmlinuz, initrd, cmdline, vars_fd, until=None, then=0):
    """One start of the kernel set; QEMU ends by itself (-no-reboot), or, `then` seconds
    after `until` is on the console, the guest's power button is pressed (QMP)."""
    qmp = cw / f'qmp{n}.sock'
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
            for m in ({'execute': 'qmp_capabilities'}, {'execute': 'system_powerdown'}):
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
                                'efi: EFI v', 'boot modules:')):
            print('    ' + x.strip(), flush=True)
    return g.p.returncode, text


def main():
    ap = argparse.ArgumentParser()
    for a in ('installer', 'binary', 'release', 'work', 'cache'):
        ap.add_argument('--' + a, type=Path, required=True)
    ap.add_argument('--boot-timeout', type=int, default=900)
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

    # 3: the firmware starts the entry (the placeholder while the loader has no release)
    g = R.Guest(R.qemu_cmd(args, None, None, vars_fd, [('nvme', disk)], None, None), cw / 'serial-firmware.log')
    try:
        out = g.until((R.placeholder.MARKER, 'Access Denied', 'No bootable'), args.boot_timeout)
        try:
            g.stop(60)
        except RuntimeError:
            pass
    finally:
        g.p.kill()
        g.p.wait()
    res(any(R.placeholder.MARKER in x for x in out) if s['loader_gap'] else True,
        'the firmware starts the new entry from the disk alone (the placeholder loader\'s marker)')

    # 4: the kernel set, as the loader starts it
    cmdline = sk.get('cmdline', '')
    krel, base_id = arts['kernel'].get('release', ''), arts['base']['base']
    rc, text = boot_set(args, cw, 1, disk, vml, ird, cmdline, vars_fd)
    res('efi: EFI v' in text, 'boot 1: started by UEFI firmware')
    res('first deployment' in text and 'selected' in text, 'boot 1: the first start selected the first deployment')
    res(rc == 0, f'boot 1: rebooted by itself (qemu exit {rc})')
    dep = disk_check(1, disk, by, base_id, krel, None)
    # the boot-success step runs ACCEPT_AFTER (120 s) after the start and logs to the
    # kernel log only (not the console once the system is up): its result is read from
    # the disk afterwards (state/deploy: the deployment current, no candidate)
    rc, text = boot_set(args, cw, 2, disk, vml, ird, cmdline, vars_fd,
                        until='glassine-deploy-accept: checking', then=args.accept_wait)
    res(f'deployment {dep}' in text and 'switch_root' in text, f'boot 2: the initramfs started deployment {dep}')
    res(rc == 0, f'boot 2: powered off by its power button (qemu exit {rc})')
    disk_check(2, disk, by, base_id, krel, dep)
    for p in cw.glob('*.img'):
        p.unlink()
    print(f'test-pc-release-qemu: {len(FAILS)} failed' + ''.join(f'\n  {f}' for f in FAILS), flush=True)
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
