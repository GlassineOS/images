#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds the RAM environment's initramfs (docs/ramenv.md) in the ramenv stage (arm64
# Alpine with stages/ramenv/packages): busybox (static), glassine-ramread (static, built
# here), the init, and the device's ramenv.conf as /etc/glassine/ramenv.conf. No kernel
# modules: the kernel has USB gadget, FunctionFS, the eMMC and the watchdog built in.
#
# With --recovery, the recovery's initramfs (docs/recovery.md) in the recovery stage
# (stages/recovery/packages): the same, with glassine-ramread built for protocol
# version 3, plus glassine-rcall, the recovery's tools (ramenv/recovery/), and
# GlassineOS/boot's glassine-deploy at BOOT (a checkout of COMMIT, the commit the boot
# initramfs is built from) with what it runs: e2fsprogs' e2fsck, debugfs and dumpe2fs,
# and btrfs (dynamic, with their libraries).
#
#   build.sh [--recovery BOOT COMMIT] SRC CONF DEVICE OUTDIR
#
# Writes OUTDIR/<device>@<sha256-16>.cpio.gz and its .manifest. Reproducible: sorted
# entries, owner 0:0, mtime 0, gzip -n.
set -eu
die() { echo "ramenv/build.sh: $*" >&2; exit 1; }
BOOT='' COMMIT=''
if [ "${1:-}" = --recovery ]; then
	[ $# -ge 3 ] || die "usage: build.sh [--recovery BOOT COMMIT] SRC CONF DEVICE OUTDIR"
	BOOT=$2 COMMIT=$3; shift 3
	[ -f "$BOOT/sbin/glassine-deploy" ] || die "$BOOT has no sbin/glassine-deploy"
	echo "$COMMIT" | grep -qx '[0-9a-f]\{40\}' || die "COMMIT is not a commit id: $COMMIT"
fi
[ $# = 4 ] || die "usage: build.sh [--recovery BOOT COMMIT] SRC CONF DEVICE OUTDIR"
SRC=$1 CONF=$2 DEVICE=$3 OUT=$4
[ -f "$SRC/init" ] && [ -f "$SRC/glassine-ramread.c" ] || die "$SRC is not the ramenv directory"
[ -f "$CONF" ] || die "no $CONF: the device has no ramenv/targets/<device>.conf"
grep -q '^RAMENV_DISKS=' "$CONF" || die "$CONF sets no RAMENV_DISKS"
I=$(mktemp -d)
trap 'rm -rf "$I"' EXIT
mkdir -p "$I/bin" "$I/dev" "$I/proc" "$I/sys" "$I/run" "$I/tmp" "$I/etc/glassine" "$OUT"
mknod -m 600 "$I/dev/console" c 5 1
mknod -m 666 "$I/dev/null" c 1 3
cp /bin/busybox.static "$I/bin/busybox"
applets="sh mount mkdir ls head sleep kill reboot cat"
# glassine-deploy and the recovery's tools
[ -z "$BOOT" ] || applets="$applets awk sed tr stat readlink mountpoint blkid flock du date find sync dd cp mv rm
	ln chown chmod cut grep sort uniq tail wc xargs tar gzip sha256sum mktemp setsid dmesg umount touch od
	printf test expr env id basename dirname rmdir cmp"
for a in $applets; do
	"$I/bin/busybox" --list | grep -qx "$a" || die "busybox.static lacks $a"
done
DEF=''
[ -z "$BOOT" ] || DEF=-DGLASSINE_RECOVERY
# shellcheck disable=SC2086
gcc -static -Os -Wall -Wextra -Werror $DEF -pthread -o "$I/bin/glassine-ramread" "$SRC/glassine-ramread.c"
strip "$I/bin/glassine-ramread"
install -m 755 "$SRC/init" "$I/init"
install -m 644 "$CONF" "$I/etc/glassine/ramenv.conf"
if [ -n "$BOOT" ]; then
	gcc -static -Os -Wall -Wextra -Werror -Wno-unused-function -DGLASSINE_RECOVERY -pthread \
		-o "$I/bin/glassine-rcall" "$SRC/recovery/glassine-rcall.c"
	strip "$I/bin/glassine-rcall"
	mkdir -p "$I/lib/glassine-recovery" "$I/sbin" "$I/usr/lib/glassine-boot" "$I/lib" "$I/usr/lib"
	install -m 644 "$SRC/recovery/common.sh" "$I/lib/glassine-recovery/"
	for t in status describe deploy diag menu; do install -m 755 "$SRC/recovery/$t" "$I/lib/glassine-recovery/"; done
	install -m 755 "$BOOT/sbin/glassine-deploy" "$I/sbin/glassine-deploy"
	for l in glassine-state.sh glassine-root.sh glassine-accounts.sh; do
		[ -f "$BOOT/lib/$l" ] || die "$BOOT has no lib/$l"
		install -m 644 "$BOOT/lib/$l" "$I/usr/lib/glassine-boot/$l"
	done
	# dynamic binaries (Alpine has no static e2fsprogs or btrfs-progs) and their libraries
	cp /lib/ld-musl-aarch64.so.1 "$I/lib/"
	ln -s ld-musl-aarch64.so.1 "$I/lib/libc.musl-aarch64.so.1"
	for n in e2fsck debugfs dumpe2fs btrfs; do
		b=$(command -v $n) || die "no $n (e2fsprogs, e2fsprogs-extra, btrfs-progs)"
		cp "$b" "$I/sbin/"
		for l in $(ldd "$b" | sed -n 's/.* => \(\/[^ ]*\) .*/\1/p'); do
			case $l in */ld-musl*|*/libc.musl*) ;; *) cp -L "$l" "$I/usr/lib/" ;; esac
		done
	done
	for t in ext2 ext3 ext4; do ln -s e2fsck "$I/sbin/fsck.$t"; done
	printf 'RECOVERY_BOOT_COMMIT=%s\nRECOVERY_DEVICE=%s\nRECOVERY_BUILD=%s\n' "$COMMIT" "$DEVICE" \
		"$(cat "$SRC/glassine-ramread.c" "$SRC/init" "$SRC"/recovery/* "$CONF" "$BOOT/sbin/glassine-deploy" | sha256sum | cut -c1-16)" \
		> "$I/etc/glassine/recovery.version"
	chmod 644 "$I/etc/glassine/recovery.version"
fi
find "$I" -exec touch -h -d @0 {} +
(cd "$I" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet | gzip -9n) > "$I.cpio.gz"
sha=$(sha256sum "$I.cpio.gz" | cut -c1-64)
id=$DEVICE@$(printf '%.16s' "$sha")
mv "$I.cpio.gz" "$OUT/$id.cpio.gz"
printf 'format=1\ndevice=%s\nsha256=%s\nconf_sha256=%s\nramread_sha256=%s\n' "$DEVICE" "$sha" \
	"$(sha256sum "$CONF" | cut -c1-64)" "$(sha256sum "$I/bin/glassine-ramread" | cut -c1-64)" > "$OUT/$id.manifest"
[ -z "$BOOT" ] || printf 'role=recovery\nboot_commit=%s\nprotocol=3\n' "$COMMIT" >> "$OUT/$id.manifest"
chmod 644 "$OUT"/*
echo "ramenv/build.sh: $id.cpio.gz, $(stat -c %s "$OUT/$id.cpio.gz") bytes${BOOT:+ (the recovery)}"
