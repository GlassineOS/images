#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The boot initramfs, to GlassineOS/boot's docs/kernel-artifacts.md. Runs in the
# initramfs stage (arm64 Alpine with stages/initramfs/packages), with GlassineOS/boot at
# the pinned commit on /src/boot (read-only). Writes
# /out/boot/initramfs/<commit12>@<sha256-16>.cpio.gz and its .manifest: named by boot's
# commit and the file's content, since the bytes also depend on the locked tools.
# No board.conf goes in: the packer adds the device's own as a second archive, so one
# initramfs serves every device. No kernel modules.
set -eu
B=/src/boot
die() { echo "initramfs.sh: $*" >&2; exit 1; }
# boot-src checked out exactly COMMIT; this stage has no git
[ -f $B/build-initramfs.sh ] && [ -n "${COMMIT:-}" ] || die "no GlassineOS/boot at /src/boot, or no COMMIT"
c12=$(printf '%.12s' "$COMMIT")
o=/out/boot/initramfs
mkdir -p $o /tmp/b
# build-initramfs.sh reads its own directory only; a copy keeps the checkout untouched
cp -R $B/. /tmp/b/
SOURCE_DATE_EPOCH=0 sh /tmp/b/build-initramfs.sh /tmp/initramfs.cpio.gz >&2
sha=$(sha256sum /tmp/initramfs.cpio.gz | cut -c1-64)
id=$c12@$(printf '%.16s' "$sha")
mv /tmp/initramfs.cpio.gz "$o/$id.cpio.gz"
rm -rf /tmp/b
fmt=$(sed -n 's/^GS_FORMAT_SUPPORTED=\([0-9]*\).*/\1/p' $B/lib/glassine-state.sh)
[ -n "$fmt" ] || die "no GS_FORMAT_SUPPORTED in lib/glassine-state.sh"
# needs and features: GlassineOS/boot has no conf/kernel-features yet
printf 'format=1\ncommit=%s\nsha256=%s\nstate_format=%s\nneeds=\nfeatures=\n' \
	"$COMMIT" "$sha" "$fmt" > "$o/$id.manifest"
chmod 644 $o/*; find /out -exec touch -h -d @0 {} +
cat "$o/$id.manifest"
