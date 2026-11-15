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
# recovery's initramfs (docs/recovery.md) the same way, into /out/recovery/.
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
B=/tmp/board.conf
{ cat $T/board.conf; printf 'CMDLINE="%s"\n' "$cmd"; } > $B
r=$(python3 /src/boot/lib/glassine-bootimg-pack $B "/run/modules/$rel/Image.gz" "$dtb" "$ird" /tmp/ramenv.img \
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
cp "/run/ramenv/$(basename "$ird" .cpio.gz).manifest" "$O/$(basename "$ird" .cpio.gz).initramfs.manifest"
chmod 644 $O/*; find /out -exec touch -h -d @0 {} +
cat "$O/$ID.manifest"
