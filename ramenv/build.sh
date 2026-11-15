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
# and btrfs (dynamic, with their libraries). With RECOVERY_SCREEN=epd in CONF, also its
# screen (docs/recovery.md, "The screen"): glassine-rscreen (static, built here, its type
# rasterized here from the GlassineOS shell's IBM Plex), glassine-epdd (the package's
# static daemon), the start script, and the panel's adapter /etc/glassine/epd.conf, taken
# from the device package RECOVERY_SCREEN_ADAPTER (fetched, not installed: its version
# and the file's sha256 go into the manifest).
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
# the screen: the recovery's only (the RAM environment reads the same CONF and has none)
SCREEN=$(sed -n 's/^RECOVERY_SCREEN=//p' "$CONF" | tail -n 1 | tr -d '"')
ADAPTER=$(sed -n 's/^RECOVERY_SCREEN_ADAPTER=//p' "$CONF" | tail -n 1 | tr -d '"')
[ -n "$BOOT" ] || SCREEN=''
case $SCREEN in
'') ;;
epd)
	[ -n "$ADAPTER" ] || die "RECOVERY_SCREEN=epd without RECOVERY_SCREEN_ADAPTER (the device package with epd.conf)"
	applets="$applets insmod uname" ;;
*) die "RECOVERY_SCREEN: epd or empty (is: $SCREEN)" ;;
esac
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
		"$( (cat "$SRC/glassine-ramread.c" "$SRC/init"; find "$SRC/recovery" -type f | LC_ALL=C sort | xargs cat; cat "$CONF" "$BOOT/sbin/glassine-deploy") | sha256sum | cut -c1-16)" \
		> "$I/etc/glassine/recovery.version"
	chmod 644 "$I/etc/glassine/recovery.version"
fi
SCREEN_INFO=''
if [ "$SCREEN" = epd ]; then
	F=/usr/share/fonts/glassine
	for f in $F/IBMPlexSans-VF.ttf $F/IBMPlexMono-Medium.ttf /usr/sbin/glassine-epdd /usr/include/glassine/glassine-epd-proto.h; do
		[ -f "$f" ] || die "no $f (glassine-shell-fonts, glassine-epdd, glassine-epdd-dev, freetype-dev)"
	done
	B=$(mktemp -d)
	# shellcheck disable=SC2046
	gcc -O2 -Wall -Wextra -Werror -o "$B/font-gen" "$SRC/recovery/screen/font-gen.c" $(pkg-config --cflags --libs freetype2)
	"$B/font-gen" "$B/rs-font.h" title $F/IBMPlexSans-VF.ttf 600 64 body $F/IBMPlexSans-VF.ttf 400 40 \
		bold $F/IBMPlexSans-VF.ttf 600 40 small $F/IBMPlexSans-VF.ttf 400 32 label $F/IBMPlexMono-Medium.ttf 0 28
	gcc -static -O2 -Wall -Wextra -Werror -Wno-unused-function -DGLASSINE_RECOVERY -pthread -I"$B" \
		-o "$I/bin/glassine-rscreen" "$SRC/recovery/screen/glassine-rscreen.c"
	strip "$I/bin/glassine-rscreen"
	install -m 755 /usr/sbin/glassine-epdd "$I/sbin/glassine-epdd"
	install -m 755 "$SRC/recovery/screen/start" "$I/lib/glassine-recovery/screen"
	apk fetch -q --stdout "$ADAPTER" > "$B/adapter.apk" || die "cannot fetch $ADAPTER"
	tar -xzOf "$B/adapter.apk" etc/glassine/epd.conf > "$I/etc/glassine/epd.conf" 2>/dev/null \
		|| die "$ADAPTER has no etc/glassine/epd.conf"
	chmod 644 "$I/etc/glassine/epd.conf"
	av=$(tar -xzOf "$B/adapter.apk" .PKGINFO | sed -n 's/^pkgver = //p')
	ev=$(apk info -e -v glassine-epdd 2>/dev/null || echo glassine-epdd)
	SCREEN_INFO=$(printf 'screen=epd\nscreen_adapter=%s-%s\nepd_conf_sha256=%s\nepdd=%s\nepdd_sha256=%s\nrscreen_sha256=%s\n' \
		"$ADAPTER" "$av" "$(sha256sum "$I/etc/glassine/epd.conf" | cut -c1-64)" "$ev" \
		"$(sha256sum "$I/sbin/glassine-epdd" | cut -c1-64)" "$(sha256sum "$I/bin/glassine-rscreen" | cut -c1-64)")
	rm -rf "$B"
fi
find "$I" -exec touch -h -d @0 {} +
(cd "$I" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet | gzip -9n) > "$I.cpio.gz"
sha=$(sha256sum "$I.cpio.gz" | cut -c1-64)
id=$DEVICE@$(printf '%.16s' "$sha")
mv "$I.cpio.gz" "$OUT/$id.cpio.gz"
printf 'format=1\ndevice=%s\nsha256=%s\nconf_sha256=%s\nramread_sha256=%s\n' "$DEVICE" "$sha" \
	"$(sha256sum "$CONF" | cut -c1-64)" "$(sha256sum "$I/bin/glassine-ramread" | cut -c1-64)" > "$OUT/$id.manifest"
[ -z "$BOOT" ] || printf 'role=recovery\nboot_commit=%s\nprotocol=3\n' "$COMMIT" >> "$OUT/$id.manifest"
[ -z "$SCREEN_INFO" ] || printf '%s\n' "$SCREEN_INFO" >> "$OUT/$id.manifest"
chmod 644 "$OUT"/*
echo "ramenv/build.sh: $id.cpio.gz, $(stat -c %s "$OUT/$id.cpio.gz") bytes${BOOT:+ (the recovery)}"
