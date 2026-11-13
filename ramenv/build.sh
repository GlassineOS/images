#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds the RAM environment's initramfs (docs/ramenv.md) in the ramenv stage (arm64
# Alpine with stages/ramenv/packages): busybox (static), glassine-ramread (static, built
# here), the init, and the device's ramenv.conf as /etc/glassine/ramenv.conf. No kernel
# modules: the kernel has USB gadget, FunctionFS, the eMMC and the watchdog built in.
#
#   build.sh SRC CONF DEVICE OUTDIR
#
# Writes OUTDIR/<device>@<sha256-16>.cpio.gz and its .manifest. Reproducible: sorted
# entries, owner 0:0, mtime 0, gzip -n.
set -eu
die() { echo "ramenv/build.sh: $*" >&2; exit 1; }
[ $# = 4 ] || die "usage: build.sh SRC CONF DEVICE OUTDIR"
SRC=$1 CONF=$2 DEVICE=$3 OUT=$4
[ -f "$SRC/init" ] && [ -f "$SRC/glassine-ramread.c" ] || die "$SRC is not the ramenv directory"
[ -f "$CONF" ] || die "no $CONF: the target has no ramenv.conf"
grep -q '^RAMENV_DISKS=' "$CONF" || die "$CONF sets no RAMENV_DISKS"
I=$(mktemp -d)
trap 'rm -rf "$I"' EXIT
mkdir -p "$I/bin" "$I/dev" "$I/proc" "$I/sys" "$I/run" "$I/tmp" "$I/etc/glassine" "$OUT"
mknod -m 600 "$I/dev/console" c 5 1
mknod -m 666 "$I/dev/null" c 1 3
cp /bin/busybox.static "$I/bin/busybox"
for a in sh mount mkdir ls head sleep kill reboot cat; do
	"$I/bin/busybox" --list | grep -qx "$a" || die "busybox.static lacks $a"
done
gcc -static -Os -Wall -Wextra -Werror -pthread -o "$I/bin/glassine-ramread" "$SRC/glassine-ramread.c"
strip "$I/bin/glassine-ramread"
install -m 755 "$SRC/init" "$I/init"
install -m 644 "$CONF" "$I/etc/glassine/ramenv.conf"
find "$I" -exec touch -h -d @0 {} +
(cd "$I" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet | gzip -9n) > "$I.cpio.gz"
sha=$(sha256sum "$I.cpio.gz" | cut -c1-64)
id=$DEVICE@$(printf '%.16s' "$sha")
mv "$I.cpio.gz" "$OUT/$id.cpio.gz"
printf 'format=1\ndevice=%s\nsha256=%s\nconf_sha256=%s\nramread_sha256=%s\n' "$DEVICE" "$sha" \
	"$(sha256sum "$CONF" | cut -c1-64)" "$(sha256sum "$I/bin/glassine-ramread" | cut -c1-64)" > "$OUT/$id.manifest"
chmod 644 "$OUT"/*
echo "ramenv/build.sh: $id.cpio.gz, $(stat -c %s "$OUT/$id.cpio.gz") bytes"
