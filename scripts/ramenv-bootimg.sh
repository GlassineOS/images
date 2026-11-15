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
# recovery's initramfs (docs/recovery.md) the same way, into /out/recovery/, with the
# recovery's own kernel at /run/modules (the flavor RECOVERY_KERNEL names, everything
# built in, no modules).
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
[ "$(val DEVICE $T/board.conf)" = "$DEVICE" ] || die "board.conf DEVICE is not $DEVICE"
C=/run/ramenv.conf
[ -f $C ] || die "no ramenv/targets/$DEVICE.conf"
# the kernel: the RAM environment's is the system's (the target's kernel-<kernel>), the
# recovery's its own (RECOVERY_KERNEL, a flavor without modules, everything built in)
x=${rel%-g*}; x=${x%.*}; flavor=${x##*-}
if [ "$ROLE" = recovery ]; then
	want=$(val RECOVERY_KERNEL $C)
	[ -n "$want" ] || die "ramenv.conf has no RECOVERY_KERNEL (the recovery kernel's flavor)"
	[ "$flavor" = "$want" ] || die "kernel $rel is not the recovery's kernel-$want"
	[ -z "$(find "/run/modules/$rel" -name '*.ko*' | head -n 1)" ] || die "kernel $rel has modules; the recovery's has none"
	[ -f "/run/modules/$rel/modules.builtin" ] || die "kernel $rel has no modules.builtin"
else
	[ "$flavor" = "$(val kernel $T/target)" ] || die "kernel $rel is not the target's kernel-$(val kernel $T/target)"
fi
cmd=$(val RAMENV_CMDLINE $C); cmd=${cmd#\"}; cmd=${cmd%\"}
[ -n "$cmd" ] || die "ramenv.conf has no RAMENV_CMDLINE"
case $cmd in *[!A-Za-z0-9._=,:/+@\ -]*) die "RAMENV_CMDLINE: only letters, digits, spaces and ._=,:/+@- (is: $cmd)" ;; esac
max=$(val RAMENV_IMAGE_MAX $C)
echo "$max" | grep -qx '[0-9]\{1,\}' || die "ramenv.conf has no RAMENV_IMAGE_MAX (the boot loader's download limit, bytes)"
rec=$(val RAMENV_RECOVERY_SIZE $C)
echo "$rec" | grep -qx '[0-9]\{1,\}' || die "ramenv.conf has no RAMENV_RECOVERY_SIZE (the recovery partition, bytes)"
[ -z "$(tail -c 1 $T/board.conf)" ] || die "board.conf doesn't end with a newline"
# the recovery's screen (docs/recovery.md, "The screen"): its device data seed is the
# board's DEVICE_PART
if [ "$ROLE" = recovery ] && [ "$(val RECOVERY_SCREEN $C)" = epd ]; then
	dl=$(val RECOVERY_DEVICE_LABEL $C); bp=$(val DEVICE_PART $T/board.conf)
	[ "$dl" = "$bp" ] || die "RECOVERY_DEVICE_LABEL ($dl) is not board.conf's DEVICE_PART ($bp)"
fi
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
