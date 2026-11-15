#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Packs one device's RAM environment boot image (docs/ramenv.md): the kernel and device
# tree of the kernel and dtb exports with the ramenv initramfs, by GlassineOS/boot's
# lib/glassine-bootimg-pack at the pinned boot commit, the way boot images are packed
# (header v0, the device tree appended to Image.gz, the header values of the target's
# board.conf). Only the command line differs: RAMENV_CMDLINE of the device's
# ramenv/targets/<device>.conf, from a copy of board.conf whose last line sets it. Nothing here is a
# boot update: no select record, and the image goes to ramenv/, never to bootimg/.
# The installer writes the image to the device's recovery partition, where the boot
# loader's recovery path starts it (header v0, the device tree appended: what that path
# boots), so it must fit RAMENV_RECOVERY_SIZE as well as the download limit.
# Mounts: /run/modules, /run/dtb, /run/ramenv (the ramenv initramfs), /run/target,
# /run/ramenv.conf,
# /src/boot. Writes /out/ramenv/<id>.img and <id>.manifest. ROLE=recovery packs the
# recovery's initramfs (docs/recovery.md) the same way, into /out/recovery/; with
# RECOVERY_SCREEN=epd it appends the screen's kernel modules (from /run/modules) as a
# second archive and names them in the manifest.
set -eu
die() { echo "ramenv-bootimg.sh: $*" >&2; exit 1; }
one() { set -- $1; [ $# = 1 ] && [ -e "$1" ] || die "expected one file, found: $*"; echo "$1"; }
val() { sed -n "s/^$1=//p" "$2" | tail -n 1; }
T=/run/target
ROLE=${ROLE:-ramenv}
case $ROLE in ramenv|recovery) ;; *) die "ROLE is ramenv or recovery" ;; esac
rel=$(basename "$(one "$(echo /run/modules/*)")")
dtb=$(one "$(echo /run/dtb/"$DEVICE"@*.dtb)")
ird=$(one "$(echo /run/ramenv/"$DEVICE"@*.cpio.gz)")
x=${rel%-g*}; x=${x%.*}; flavor=${x##*-}
[ "$flavor" = "$(val kernel $T/target)" ] || die "kernel $rel is not the target's kernel-$(val kernel $T/target)"
[ "$(val DEVICE $T/board.conf)" = "$DEVICE" ] || die "board.conf DEVICE is not $DEVICE"
C=/run/ramenv.conf
[ -f $C ] || die "no ramenv/targets/$DEVICE.conf"
cmd=$(val RAMENV_CMDLINE $C); cmd=${cmd#\"}; cmd=${cmd%\"}
[ -n "$cmd" ] || die "ramenv.conf has no RAMENV_CMDLINE"
case $cmd in *[!A-Za-z0-9._=,:/+@\ -]*) die "RAMENV_CMDLINE: only letters, digits, spaces and ._=,:/+@- (is: $cmd)" ;; esac
max=$(val RAMENV_IMAGE_MAX $C)
echo "$max" | grep -qx '[0-9]\{1,\}' || die "ramenv.conf has no RAMENV_IMAGE_MAX (the boot loader's download limit, bytes)"
rec=$(val RAMENV_RECOVERY_SIZE $C)
echo "$rec" | grep -qx '[0-9]\{1,\}' || die "ramenv.conf has no RAMENV_RECOVERY_SIZE (the recovery partition, bytes)"
[ -z "$(tail -c 1 $T/board.conf)" ] || die "board.conf doesn't end with a newline"
# the recovery's screen (docs/recovery.md, "The screen"): the modules it needs from this
# kernel (RECOVERY_SCREEN_MODULES, with what they depend on, in load order) as a second
# archive after the initramfs; and its device data seed is the board's DEVICE_PART
mods='' pack=$ird
if [ "$ROLE" = recovery ] && [ "$(val RECOVERY_SCREEN $C)" = epd ]; then
	dl=$(val RECOVERY_DEVICE_LABEL $C); bp=$(val DEVICE_PART $T/board.conf)
	[ "$dl" = "$bp" ] || die "RECOVERY_DEVICE_LABEL ($dl) is not board.conf's DEVICE_PART ($bp)"
	mods=$(val RECOVERY_SCREEN_MODULES $C); mods=${mods#\"}; mods=${mods%\"}
fi
if [ -n "$mods" ]; then
	python3 - "/run/modules/$rel" "$rel" /tmp/screen-mods.cpio $mods <<'PY' || die "the screen's modules"
import os, sys
root, rel, out, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
dep = {}
for line in open(os.path.join(root, 'modules.dep')):
    k, _, v = line.partition(':')
    dep[k] = v.split()
byname = {os.path.basename(k).split('.ko')[0].replace('-', '_'): k for k in dep}
order = []
def add(k, seen=()):
    if k in order: return
    if k in seen: sys.exit('a dependency loop at ' + k)
    for d in reversed(dep[k]): add(d, seen + (k,))
    order.append(k)
for m in want:
    k = byname.get(m.replace('-', '_'))
    if not k: sys.exit('kernel %s has no module %s (built in? then leave it out)' % (rel, m))
    add(k)
for k in order:
    if not k.endswith('.ko'): sys.exit('%s is compressed; the recovery loads plain .ko files' % k)
files = {}
for k in order: files['lib/modules/%s/%s' % (rel, k)] = open(os.path.join(root, k), 'rb').read()
files['lib/modules/%s/recovery-screen.list' % rel] = ''.join(k + '\n' for k in order).encode()
dirs = set()
for p in files:
    d = os.path.dirname(p)
    while d: dirs.add(d); d = os.path.dirname(d)
ents = [(d, 0o40755, b'') for d in dirs] + [(p, 0o100644, b) for p, b in files.items()]
o = bytearray()
def ent(name, mode, data, ino):
    n = name.encode() + b'\0'
    o.extend(b'070701' + b''.join(b'%08X' % v for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(n), 0)) + n)
    o.extend(b'\0' * (-len(o) % 4)); o.extend(data); o.extend(b'\0' * (-len(o) % 4))
for i, (n, m, b) in enumerate(sorted(ents)): ent(n, m, b, i + 1)
ent('TRAILER!!!', 0, b'', 0)
open(out, 'wb').write(o)
print(' '.join(os.path.basename(k) for k in order))
PY
	gzip -9n < /tmp/screen-mods.cpio > /tmp/screen-mods.cpio.gz
	cat "$ird" /tmp/screen-mods.cpio.gz > /tmp/recovery-initrd.cpio.gz
	pack=/tmp/recovery-initrd.cpio.gz
fi
B=/tmp/board.conf
{ cat $T/board.conf; printf 'CMDLINE="%s"\n' "$cmd"; } > $B
r=$(python3 /src/boot/lib/glassine-bootimg-pack $B "/run/modules/$rel/Image.gz" "$dtb" "$pack" /tmp/ramenv.img \
	--expect-release "$rel") || die "the packer refused (exit $?)"
set -- $r
[ $# = 3 ] || die "the packer printed: $r"
ID=${1#ID=}; SIZE=${2#SIZE=}; SHA=${3#SHA=}
echo "$ID" | grep -qx '[0-9a-f]\{16\}' || die "the packer printed no ID: $r"
[ "$SIZE" = "$(stat -c %s /tmp/ramenv.img)" ] || die "the packer's SIZE isn't the file's"
[ "$SIZE" -le "$max" ] || die "the image is $SIZE bytes, above RAMENV_IMAGE_MAX $max"
[ "$SIZE" -le "$rec" ] || die "the image is $SIZE bytes, above RAMENV_RECOVERY_SIZE $rec (the recovery partition)"
O=/out/$ROLE
mkdir -p $O
mv /tmp/ramenv.img "$O/$ID.img"
printf 'format=1\nid=%s\ndevice=%s\nkernel=%s\ndtb=%s\nramenv=%s\ncmdline=%s\nboard=%s\nramenv_conf=%s\nsize=%s\nsha256=%s\n' \
	"$ID" "$DEVICE" "$rel" "$(basename "$dtb" .dtb)" "$(basename "$ird" .cpio.gz)" "$cmd" \
	"$(sha256sum $B | cut -c1-64)" "$(sha256sum $C | cut -c1-64)" "$SIZE" "$SHA" > "$O/$ID.manifest"
[ "$ROLE" = ramenv ] || printf 'role=%s\n' "$ROLE" >> "$O/$ID.manifest"
[ -z "$mods" ] || printf 'screen_modules=%s\nscreen_modules_sha256=%s\n' "$mods" "$(sha256sum /tmp/screen-mods.cpio.gz | cut -c1-64)" >> "$O/$ID.manifest"
cp "/run/ramenv/$(basename "$ird" .cpio.gz).manifest" "$O/$(basename "$ird" .cpio.gz).initramfs.manifest"
chmod 644 $O/*; find /out -exec touch -h -d @0 {} +
cat "$O/$ID.manifest"
