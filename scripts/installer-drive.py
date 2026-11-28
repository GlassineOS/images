#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The container half of scripts/installer-drive: the installer drive's image
(specs/004-installer-drive) from a PC release folder, the static glassine-install and its
uefi-pc description. Runs as root in a privileged Alpine container (it mounts the pool
image and the data file system through loop devices).

    installer-drive.py --release DIR --name NAME --installer FILE --description FILE
                       --commit HEX --drive DIR --out DIR

Every result line starts with "installer-drive: "; the last names the image.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile, uuid
from pathlib import Path

MIB = 1 << 20
GIB = 1 << 30
ESP_MIB, RESERVE = 128, 1 * GIB
NIL = '00000000-0000-0000-0000-000000000000'
# partition type GUIDs: EFI system, Linux file system
T_ESP, T_LINUX = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B', '0FC63DAF-8483-4772-8E79-3D69D8477DE4'


def say(*a):
    print('installer-drive:', *a, flush=True)


def die(msg):
    print(f'installer-drive: {msg}', file=sys.stderr, flush=True)
    sys.exit(1)


def run(*cmd, **kw):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)
    if r.returncode != 0:
        die(f'{" ".join(map(str, cmd))}: exit {r.returncode}: {r.stderr.strip()[-800:]}')
    return r.stdout


def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(4 * MIB), b''):
            h.update(b)
    return h.hexdigest()


def newc(entries):
    """An uncompressed newc cpio archive, fixed fields (boot-partition.md's board-archive
    rules: owner 0:0, time 0, one link, inode by position)."""
    out = b''
    for i, (name, mode, data) in enumerate(entries + [('TRAILER!!!', 0, b'')], 1):
        nb = name.encode() + b'\0'
        hdr = '070701' + ''.join(f'{x:08X}' for x in (i, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0))
        out += hdr.encode() + nb
        out += b'\0' * (-len(out) % 4) + data
        out += b'\0' * (-len(out) % 4)
    return out


def record(lines):
    body = ''.join(f'{k}={v}\n' for k, v in lines).encode()
    return body + b'check=' + hashlib.sha256(body).hexdigest().encode() + b'\n'


def board_cmdline(text):
    """CMDLINE of board.conf by boot-partition.md's rule: one line, quoted or a bare word."""
    found = [ln for ln in text.splitlines() if ln.startswith('CMDLINE=')]
    if len(found) != 1:
        die(f'board.conf: {len(found)} CMDLINE lines (one wanted)')
    m = re.fullmatch(r'CMDLINE=(?:"([^"\\$`]*)"|([^"\\$` ]*))', found[0])
    if not m:
        die(f'board.conf: CMDLINE in a form a kernel set refuses: {found[0]}')
    c = m.group(1) if m.group(1) is not None else m.group(2)
    if c != ' '.join(c.split()) or any(w.startswith(('glassine.system=', 'glassine.userdata=', 'glassine.img=', 'glassine.deploy.once='))
                                       for w in c.split()):
        die(f'board.conf: CMDLINE refused for a kernel set: "{c}"')
    return c


def ident(seed, what):
    """An identity derived from the release (FR-003): a version-4-shaped UUID."""
    h = bytearray(hashlib.sha256(seed + b'\n' + what.encode()).digest()[:16])
    h[6] = (h[6] & 0x0F) | 0x40
    h[8] = (h[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(h)))


def fat(path, mib, label, volid, kind):
    path.unlink(missing_ok=True)
    with open(path, 'wb') as f:
        f.truncate(mib * MIB)
    run('mkfs.fat', *(['-F', '32'] if kind == 32 else []), '-S', '512', '-n', label, '-i', volid, path)


def mput(img, src, dst):
    run('mcopy', '-o', '-i', img, src, '::' + dst)


def main():
    ap = argparse.ArgumentParser()
    for a in ('release', 'installer', 'description', 'drive', 'out'):
        ap.add_argument('--' + a, type=Path, required=True)
    ap.add_argument('--commit', required=True)
    ap.add_argument('--name', required=True, help='the release folder\'s name')
    a = ap.parse_args()
    rel, out = a.release, a.out
    raw = (rel / 'release.json').read_bytes()
    doc = json.loads(raw)
    arts = doc['artifacts']

    # FR-001: every file the release names, checked
    for role, x in sorted(arts.items()):
        f = rel / x['file']
        if not f.is_file() or f.stat().st_size != x['size'] or sha(f) != x['sha256']:
            die(f'{role}: {x["file"]} is not the file release.json names')
    for role, kind in (('kernel', 'efi-kernel'), ('initramfs', 'initramfs'), ('board', 'board-conf'),
                       ('boot-loader', 'efi-application'), ('base', 'btrfs-pool-image'), ('boot-modules', 'cpio-gz')):
        if arts.get(role, {}).get('kind') != kind:
            die(f'the release has no {role} of kind {kind}: not a PC release the drive can carry')
    base_id, krel = arts['base']['base'], arts['kernel']['release']
    say(f'release {a.name}: base {base_id}, kernel {krel}, checked')

    w = Path(tempfile.mkdtemp(prefix='drive.', dir=out))
    try:
        build(a, rel, doc, raw, arts, base_id, krel, w)
    finally:
        for m in (w / 'pool', w / 'data'):
            subprocess.run(['umount', str(m)], capture_output=True)
        shutil.rmtree(w, ignore_errors=True)


def build(a, rel, doc, raw, arts, base_id, krel, w):
    out = a.out
    seed = hashlib.sha256(raw).digest()
    data_uuid = ident(seed, 'data file system')

    # loop.ko from the pool's modules (the boot-modules archive has no loop driver)
    (w / 'pool').mkdir()
    run('mount', '-o', 'ro,loop', rel / arts['base']['file'], w / 'pool')
    mdir = w / 'pool' / 'modules' / krel
    dep = (mdir / 'modules.dep').read_text().splitlines()
    line = [ln for ln in dep if re.match(r'(kernel/)?drivers/block/loop\.ko(\.[a-z]+)?:', ln)]
    if not line:
        die(f'the pool\'s modules for {krel} have no loop module, and the session needs one')
    path, deps = line[0].split(':', 1)
    if deps.strip():
        die(f'loop.ko depends on {deps.strip()}: the drive carries loop alone')
    src = mdir / path
    dec = {'.gz': ['gzip', '-dc'], '.xz': ['xz', '-dc'], '.zst': ['zstd', '-dc']}.get(src.suffix)
    loop_ko = subprocess.run(dec + [str(src)], capture_output=True, check=True).stdout if dec else src.read_bytes()
    run('umount', w / 'pool')

    # the start archive (FR-004, FR-005)
    d = a.drive
    def f(n):
        return (d / n).read_bytes()
    start = newc([('init', 0o100755, f('init')),
                  ('lib', 0o40755, b''), ('lib/glassine-drive', 0o40755, b''),
                  ('lib/glassine-drive/loop.ko', 0o100644, loop_ko),
                  ('lib/glassine-drive/glassine-drive', 0o100755, f('glassine-drive')),
                  ('lib/glassine-drive/glassine-drive.initd', 0o100755, f('glassine-drive.initd')),
                  ('lib/glassine-drive/session-shell', 0o100755, f('session-shell'))])

    # the initrd: microcode (by file name), the initramfs, the boot modules, the start archive
    micro = sorted((Path(x['file']).name, r) for r, x in arts.items() if r == 'microcode' or r.startswith('microcode-'))
    parts = [rel / arts[r]['file'] for _, r in micro] + [rel / arts['initramfs']['file'], rel / arts['boot-modules']['file']]
    initrd = b''
    for p in parts:
        initrd += b'\0' * (-len(initrd) % 4) + p.read_bytes()
    initrd += b'\0' * (-len(initrd) % 4) + start
    (w / 'initrd').write_bytes(initrd)
    ksha, isha = arts['kernel']['sha256'], hashlib.sha256(initrd).hexdigest()
    base = (board_cmdline((rel / arts['board']['file']).read_text()) + f' glassine.drive=UUID={data_uuid}').strip()
    sid = hashlib.sha256(f'{ksha}\n{isha}\n{base}\n'.encode()).hexdigest()[:16]
    cmdline = f'{base} glassine.system=PARTUUID={NIL} glassine.userdata=PARTUUID={NIL} glassine.img={sid}'
    if len(cmdline) > 1920:
        die('the session\'s command line is longer than 1920 bytes')
    (w / 'set.rec').write_bytes(record([
        ('format', '1'), ('id', sid), ('release', krel),
        ('kernel_sha256', ksha), ('kernel_size', str(arts['kernel']['size'])),
        ('initrd_sha256', isha), ('initrd_size', str(len(initrd))),
        ('cmdline', cmdline), ('initramfs', '')]))
    say(f'session {sid}: initrd {len(initrd)} bytes, command line "{cmdline}"')

    # 1. the boot partition (boot-partition.md "Layout"; no loader record)
    esp = w / 'esp.img'
    fat(esp, ESP_MIB, 'GLASSINEOS', ident(seed, 'esp volume')[:8], 32)
    img = str(esp)
    for dd in ('EFI', 'EFI/BOOT', 'glassine', 'glassine/recovery', f'glassine/recovery/{sid}', 'glassine/splash'):
        run('mmd', '-i', img, '::/' + dd)
    mput(img, rel / arts['boot-loader']['file'], '/EFI/BOOT/BOOTX64.EFI')
    mput(img, rel / arts['kernel']['file'], f'/glassine/recovery/{sid}/vmlinuz')
    mput(img, w / 'initrd', f'/glassine/recovery/{sid}/initrd')
    mput(img, w / 'set.rec', f'/glassine/recovery/{sid}/set.rec')
    if 'splash' in arts:
        mput(img, rel / arts['splash']['file'], '/glassine/splash/default.gspl')
    run('fsck.fat', '-n', esp)

    # 2. the data partition: the release folder, the installer, records/
    content = sum(p.stat().st_size for p in rel.rglob('*') if p.is_file()) + a.installer.stat().st_size
    data_mib = -(-(content * 105 // 100 + 128 * MIB + RESERVE) // MIB)
    dimg = w / 'data.img'
    with open(dimg, 'wb') as fh:
        fh.truncate(data_mib * MIB)
    run('mkfs.ext4', '-q', '-L', 'glassine-drive', '-U', data_uuid, '-m', '0', '-E', 'root_owner=0:0,lazy_itable_init=0', dimg)
    (w / 'data').mkdir()
    run('mount', '-o', 'loop', dimg, w / 'data')
    dr = w / 'data' / 'release' / a.name
    shutil.copytree(rel, dr)
    (w / 'data' / 'installer').mkdir()
    shutil.copyfile(a.installer, w / 'data' / 'installer' / 'glassine-install')
    os.chmod(w / 'data' / 'installer' / 'glassine-install', 0o755)
    shutil.copyfile(a.description, w / 'data' / 'installer' / 'uefi-pc.toml')
    (w / 'data' / 'installer' / 'COMMIT').write_text(a.commit + '\n')
    (w / 'data' / 'records').mkdir()
    for p in dr.rglob('*'):
        os.chmod(p, 0o755 if p.is_dir() else 0o644)
    if sha(dr / arts['base']['file']) != arts['base']['sha256']:
        die('the pool image on the data partition differs from the release\'s')
    fs = os.statvfs(w / 'data')
    free = fs.f_bavail * fs.f_frsize
    run('umount', w / 'data')
    run('e2fsck', '-fn', dimg)
    if free < RESERVE:
        die(f'the data partition has {free} bytes free, below its reserve')

    # the disk: GPT, 1 MiB aligned, in the order of FR-002
    name = f'glassine-drive-{base_id}.img'
    disk = out / name
    disk.unlink(missing_ok=True)
    total = (1 + ESP_MIB + data_mib + 1) * MIB
    with open(disk, 'wb') as fh:
        fh.truncate(total)
    run('sgdisk', '-U', ident(seed, 'disk'),
        '-n', f'1:2048:+{ESP_MIB}M', '-t', f'1:{T_ESP}', '-c', '1:glassine-drive-esp', '-u', f'1:{ident(seed, "esp partition")}',
        '-n', f'2:0:+{data_mib}M', '-t', f'2:{T_LINUX}', '-c', '2:glassine-drive-data', '-u', f'2:{ident(seed, "data partition")}',
        disk)
    off = 1 * MIB
    for part in (esp, dimg):
        run('dd', f'if={part}', f'of={disk}', 'bs=4M', f'seek={off}', 'oflag=seek_bytes', 'conv=notrunc,sparse', 'status=none')
        off += part.stat().st_size
    run('sgdisk', '-v', disk)
    s = sha(disk)
    (out / 'SHA256SUMS').write_text(f'{s}  {name}\n')
    say(f'data partition {data_mib} MiB, {free} bytes free; disk {total} bytes, sha256 {s}')
    say(f'image {disk}')


if __name__ == '__main__':
    main()
