#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Packs one device's boot image from the kernel, device tree and initramfs stages with
# GlassineOS/boot's lib/glassine-bootimg-pack (the contract's packer, at the pinned boot
# commit) and the board.conf of the device's target description: header values from
# there and nothing else. Mounts: /run/modules (kernel-export's modules/), /run/dtb
# (dtb-export's boot/dtb/), /run/initramfs (boot/initramfs/), /run/target, /src/boot.
# Writes /out/bootimg/<id>.img and <id>.manifest (the boot record of
# docs/kernel-artifacts.md, with release, size and sha256) and /out/select/<device>, the
# device's update: the only place a device tree is paired with a kernel.
# CMDLINE_EXTRA (the build argument, empty or unset by default): words appended to the
# board's CMDLINE for this one image, packed from a copy of board.conf that ends with
# the longer CMDLINE line. The target's board.conf stays as it is; a build that sets it
# is a trial (specs/001-base-build), and boot-check --cmdline-extra checks it.
set -eu
die() { echo "bootimg.sh: $*" >&2; exit 1; }
one() { set -- $1; [ $# = 1 ] && [ -e "$1" ] || die "expected one file, found: $*"; echo "$1"; }
val() { sed -n "s/^$1=//p" "$2" | tail -n 1; }
T=/run/target
rel=$(basename "$(one "$(echo /run/modules/*)")")
dtb=$(one "$(echo /run/dtb/"$DEVICE"@*.dtb)")
ird=$(one "$(echo /run/initramfs/*.cpio.gz)")
# <KERNELVERSION>(-rcN)-<flavor>.<cfg6>-g<commit12>, taken apart from the end (the version may hold a -)
x=${rel%-g*}; x=${x%.*}; flavor=${x##*-}
[ "$flavor" = "$(val kernel $T/target)" ] || die "kernel $rel is not the target's kernel-$(val kernel $T/target)"
grep -q '^format=1$' "/run/modules/$rel/kernel.manifest" || die "kernel.manifest: not format 1"
[ "$(val DEVICE $T/board.conf)" = "$DEVICE" ] || die "board.conf DEVICE is not $DEVICE"
# the board.conf this image is packed from (and carries): the target's, or a copy whose
# last line sets the CMDLINE with the extra words (the last CMDLINE line counts)
B=$T/board.conf
set -f; set -- ${CMDLINE_EXTRA-}; extra=$*; set +f
if [ -n "$extra" ]; then
	case $extra in *[!A-Za-z0-9._=,:/+@\ -]*) die "CMDLINE_EXTRA: only letters, digits, spaces and ._=,:/+@- (is: $extra)" ;; esac
	[ -z "$(tail -c 1 "$T/board.conf")" ] || die "board.conf doesn't end with a newline"
	base=$(val CMDLINE "$T/board.conf"); base=${base#\"}; base=${base%\"}
	B=/tmp/board.conf
	{ cat "$T/board.conf"; printf 'CMDLINE="%s %s"\n' "$base" "$extra"; } > "$B"
	echo "bootimg.sh: CMDLINE_EXTRA: $extra (a trial image)"
fi
dtbid=$(basename "$dtb" .dtb)
irdid=$(basename "$ird" .cpio.gz)
for m in "/run/dtb/$dtbid.manifest" "/run/initramfs/$irdid.manifest"; do
	grep -q '^format=1$' "$m" || die "$m: missing or not format 1"
done
mkdir -p /out/bootimg /out/select
r=$(python3 /src/boot/lib/glassine-bootimg-pack "$B" "/run/modules/$rel/Image.gz" "$dtb" "$ird" \
	/tmp/boot.img --expect-release "$rel") || die "the packer refused (exit $?)"
# the packer prints one line: ID=<id16> SIZE=<bytes> SHA=<sha256>
set -- $r
[ $# = 3 ] || die "the packer printed: $r"
ID=${1#ID=}; SIZE=${2#SIZE=}; SHA=${3#SHA=}
echo "$ID" | grep -qx '[0-9a-f]\{16\}' || die "the packer printed no ID: $r"
echo "$SIZE" | grep -qx '[0-9]\{1,\}' || die "the packer printed no SIZE: $r"
echo "$SHA" | grep -qx '[0-9a-f]\{64\}' || die "the packer printed no SHA: $r"
mv /tmp/boot.img "/out/bootimg/$ID.img"
cmd=$(val CMDLINE "$B"); cmd=${cmd#\"}; cmd=${cmd%\"}
printf 'format=1\nid=%s\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\ncmdline=%s\nboard=%s\nrelease=%s\nsize=%s\nsha256=%s\n' \
	"$ID" "$DEVICE" "$rel" "$dtbid" "$irdid" "$cmd" \
	"$(sha256sum "$B" | cut -c1-64)" "$rel" "$SIZE" "$SHA" > "/out/bootimg/$ID.manifest"
printf 'format=1\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\n' "$DEVICE" "$rel" "$dtbid" "$irdid" \
	> "/out/select/$DEVICE"
chmod 644 /out/bootimg/* /out/select/*; find /out -exec touch -h -d @0 {} +
cat "/out/bootimg/$ID.manifest" "/out/select/$DEVICE"
