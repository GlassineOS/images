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
set -eu
die() { echo "bootimg.sh: $*" >&2; exit 1; }
one() { set -- $1; [ $# = 1 ] && [ -e "$1" ] || die "expected one file, found: $*"; echo "$1"; }
val() { sed -n "s/^$1=//p" "$2" | tail -n 1; }
T=/run/target
rel=$(basename "$(one "$(echo /run/modules/*)")")
dtb=$(one "$(echo /run/dtb/"$DEVICE"@*.dtb)")
ird=$(one "$(echo /run/initramfs/*.cpio.gz)")
flavor=${rel#*-}; flavor=${flavor%%.*}
[ "$flavor" = "$(val kernel $T/target)" ] || die "kernel $rel is not the target's kernel-$(val kernel $T/target)"
grep -q '^format=1$' "/run/modules/$rel/kernel.manifest" || die "kernel.manifest: not format 1"
[ "$(val DEVICE $T/board.conf)" = "$DEVICE" ] || die "board.conf DEVICE is not $DEVICE"
dtbid=$(basename "$dtb" .dtb)
irdid=$(basename "$ird" .cpio.gz)
for m in "/run/dtb/$dtbid.manifest" "/run/initramfs/$irdid.manifest"; do
	grep -q '^format=1$' "$m" || die "$m: missing or not format 1"
done
mkdir -p /out/bootimg /out/select
r=$(python3 /src/boot/lib/glassine-bootimg-pack $T/board.conf "/run/modules/$rel/Image.gz" "$dtb" "$ird" \
	/tmp/boot.img --expect-release "$rel") || die "the packer refused (exit $?)"
eval "$r"   # ID SIZE SHA
mv /tmp/boot.img "/out/bootimg/$ID.img"
cmd=$(sed -n 's/^CMDLINE=//p' $T/board.conf | tail -n 1); cmd=${cmd#\"}; cmd=${cmd%\"}
printf 'format=1\nid=%s\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\ncmdline=%s\nboard=%s\nrelease=%s\nsize=%s\nsha256=%s\n' \
	"$ID" "$DEVICE" "$rel" "$dtbid" "$irdid" "$cmd" \
	"$(sha256sum $T/board.conf | cut -c1-64)" "$rel" "$SIZE" "$SHA" > "/out/bootimg/$ID.manifest"
printf 'format=1\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\n' "$DEVICE" "$rel" "$dtbid" "$irdid" \
	> "/out/select/$DEVICE"
chmod 644 /out/bootimg/* /out/select/*; find /out -exec touch -h -d @0 {} +
cat "/out/bootimg/$ID.manifest" "/out/select/$DEVICE"
