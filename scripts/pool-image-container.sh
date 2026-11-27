#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The privileged half of scripts/pool-image: runs in its container (Alpine, as root),
# never on the host. The pool is a sparse file on a tmpfs, mounted through a loop
# device; no block device of the host is opened.
#
# Mounts: /a (the artifacts folder, ro), /b (GlassineOS/boot's checkout, ro), /o (the
# staging directory, where every output goes). Environment, set by pool-image:
#   BASE      the base id                   RUUID    its received UUID (the base record)
#   STREAM    its full stream, under /a     RELEASE  the kernel release (modules/<RELEASE>)
#   MSTREAM   the modules stream, under /a  MARGIN   bytes left free beyond what is allocated
#   BOOTFILES the base's boot/ files, paths under /a (boot/dtb/<device>@<id>.dtb, boot/initramfs/
#             <commit12>@<id>.cpio.gz, each with its .manifest), checked by pool-image
#   IMG       the largest pool tried (the first try is the streams' size + 256 MiB)
#   TMPFS     tmpfs size                    HOST_UID, HOST_GID  owner of the outputs
# Outputs in /o: pool.img, result (key=value: size, sha256, used_*, keep_updates,
# min_partition_bytes).
set -eu
W=/w
P=$W/p
say() { echo "pool-image: $*"; }
die() { echo "pool-image: FAIL: $*" >&2; exit 1; }
up() { cut -d' ' -f1 /proc/uptime; }
T0=$(up); t0=$T0
tick() { t0=$(up); }
tock() { awk -v a="$t0" -v b="$(up)" -v n="$1" 'BEGIN { printf "time %-26s %6.2f s\n", n, b - a }'; }
res() { echo "$1=$2" >> /o/result; }
MIB=1048576

cleanup() {
	set +e
	mountpoint -q $P 2>/dev/null && umount $P
	mountpoint -q $W && umount $W
	chown -R "$HOST_UID:$HOST_GID" /o 2>/dev/null
}
trap cleanup EXIT

tick
apk add -q --no-progress btrfs-progs zstd >/dev/null || die "apk add failed"
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
mkdir -p $W && mount -t tmpfs -o size="$TMPFS" tmpfs $W
: > /o/result
tock "container setup"

ruuid() { btrfs subvolume show "$1" | sed -n 's/^[[:space:]]*Received UUID:[[:space:]]*//p'; }
is_ro() { [ "$(btrfs property get -ts "$1" ro)" = ro=true ]; }
# used bytes of the file system (data + metadata, as allocated to extents)
used() { btrfs filesystem sync $P; btrfs filesystem usage -b $P | awk '$1 == "Used:" { print $2; exit }'; }
super() { btrfs inspect-internal dump-super "$1" | awk -v k="$2" '$1 == k { print $2; exit }'; }
# receive STREAM DIR NAME: one read-only subvolume with a received UUID, named NAME
receive() {
	before=$(ls "$2" | wc -l)
	zstd -dc "$1" | btrfs -q receive "$2" || { say "receive $1 failed"; return 1; }
	[ "$(ls "$2" | wc -l)" = $((before + 1)) ] || die "$1: not exactly one subvolume"
	[ -d "$2/$3" ] || die "$1: the subvolume is not named $3"
	is_ro "$2/$3" || die "$1: received $3 is not read-only"
}
# layout_ok: what boot's init lays out, the base and the modules, nothing more in bases/ and modules/
layout_ok() {
	[ "$(ls $P/bases)" = "$BASE" ] || die "bases/ holds $(ls $P/bases | tr '\n' ' '), not only $BASE"
	[ "$(ls $P/modules)" = "$RELEASE" ] || die "modules/ holds $(ls $P/modules | tr '\n' ' '), not only $RELEASE"
	is_ro $P/bases/"$BASE" || die "bases/$BASE is not read-only"
	is_ro $P/modules/"$RELEASE" || die "modules/$RELEASE is not read-only"
	[ "$(ruuid $P/bases/"$BASE")" = "$RUUID" ] || die "bases/$BASE: received UUID $(ruuid $P/bases/"$BASE"), the base record says $RUUID"
	[ -n "$(ruuid $P/modules/"$RELEASE")" ] || die "modules/$RELEASE has no received UUID"
	[ -f $P/state/format ] || die "no state/format"
	[ -e $P/state/install ] || die "no install marker state/install"
	# boot/: exactly the base's boot files, each the build's bytes
	have=$(cd $P && find boot -type f | sort | tr '\n' ' ')
	want=$(printf '%s\n' $BOOTFILES | sort | tr '\n' ' ')
	[ "$have" = "$want" ] || die "boot/ holds $have, not $want"
	for f in $BOOTFILES; do cmp -s "/a/$f" "$P/$f" || die "$f in the pool is not the build's"; done
}

# fill SIZE: a pool of SIZE bytes, laid out by boot's init, with the base and the modules
# received and the base's boot/ files; 1 when they don't fit. btrfs sizes its chunks by the file system's size (a
# tenth of it, up to 1 GiB data / 256 MiB metadata), and a shrink can't make a chunk
# smaller: so the pool starts at about what it holds, not at the partition's size. Never
# mixed block groups: they would stay for good, also after the first start grows it.
fill() {
	mountpoint -q $P && umount $P
	rm -f $W/pool.img
	truncate -s "$1" $W/pool.img
	mkfs.btrfs -q $W/pool.img || die "mkfs.btrfs failed"
	mount -o loop,noatime,compress=zstd $W/pool.img $P || die "mounting the pool failed"
	mountpoint -q $P || die "the pool is not mounted"

	# the layout: boot's own verb, on the empty, mounted pool (docs/artifacts.md, Releases)
	rc=0
	GLASSINE_DEPLOY_LIB=/b/lib/glassine-state.sh GLASSINE_DEPLOY_CONF=$W/deploy.conf \
		sh /b/sbin/glassine-deploy init $P --install-marker || rc=$?
	[ $rc = 0 ] || die "boot's 'glassine-deploy init $P --install-marker' failed (exit $rc): this boot commit has no init verb, or it refused the pool"
	for d in bases modules state; do [ -d $P/$d ] || die "init made no $d/"; done
	[ -f $P/state/format ] || die "init wrote no state/format"
	[ -e $P/state/install ] || die "init wrote no install marker state/install"
	U0=$(used); [ -n "$U0" ] || die "no used bytes from btrfs filesystem usage"

	# the base and the modules, received as glassine-deploy receive keeps them
	receive "/a/$STREAM" $P/bases "$BASE" || return 1; U1=$(used)
	receive "/a/$MSTREAM" $P/modules "$RELEASE" || return 1; U2=$(used)
	[ -n "$U1" ] && [ -n "$U2" ] || die "no used bytes from btrfs filesystem usage"

	# the base's boot/ files, as glassine-deploy receive --boot keeps them (boot's
	# docs/kernel-artifacts.md, "On the system partition"): file and manifest, read back
	for f in $BOOTFILES; do
		mkdir -p "$P/${f%/*}" && cp "/a/$f" "$P/$f.new" && chmod 644 "$P/$f.new" || { say "boot/: $f did not fit"; return 1; }
		sync; cmp -s "/a/$f" "$P/$f.new" || die "$f: the read-back is not the build's"
		mv "$P/$f.new" "$P/$f"
	done
}

tick
[ -f /b/sbin/glassine-deploy ] && [ -f /b/lib/glassine-state.sh ] || die "/b is not a GlassineOS/boot checkout"
printf '# pool-image: no configuration\n' > $W/deploy.conf
mkdir $P
raw=$(( $(zstd -dc "/a/$STREAM" | wc -c) + $(zstd -dc "/a/$MSTREAM" | wc -c) ))
size=$(( (raw + 256 * MIB + MIB - 1) / MIB * MIB ))
say "streams: $raw bytes uncompressed; first try $((size / MIB)) MiB"
until fill $size; do
	say "did not fit in $((size / MIB)) MiB"
	size=$((size * 2))
	[ $size -le "$IMG" ] || die "the base and the modules don't fit in $IMG bytes"
done
say "state/format: $(cat $P/state/format | tr '\n' ' ')"
[ ! -f $P/state/kernel ] || say "state/kernel: $(cat $P/state/kernel | tr '\n' ' ')"
tock "mkfs + init + receive"

layout_ok
say "base $BASE: read-only, received UUID $RUUID; modules/$RELEASE; $(printf '%s ' $BOOTFILES)"

# 4. shrink to what is allocated + MARGIN, a whole MiB (at least 256 MiB); the first start grows it to the partition
tick
alloc=$(btrfs filesystem usage -b $P | awk '$1 == "Device" && $2 == "allocated:" { print $3; exit }')
[ -n "$alloc" ] || die "no device allocation from btrfs filesystem usage"
size=$(( (alloc + MARGIN + MIB - 1) / MIB * MIB ))
[ $size -ge $((256 * MIB)) ] || size=$((256 * MIB))	# the kernel refuses a smaller btrfs
btrfs -q filesystem resize "$size" $P || die "resize to $size failed"
umount $P
[ "$(super $W/pool.img total_bytes)" = "$size" ] || die "total_bytes $(super $W/pool.img total_bytes) after the resize, not $size"
btrfs inspect-internal dump-super $W/pool.img | grep -q MIXED_GROUPS && die "mixed block groups"
truncate -s "$size" $W/pool.img
btrfs check --readonly $W/pool.img > $W/check.log 2>&1 || { tail -20 $W/check.log >&2; die "btrfs check failed"; }
tock "shrink + check"

# keep_updates: how many base updates the device keeps (GlassineOS/boot spec 007), as its
# glassine-deploy reads it: KEEP_UPDATES in the base's /etc/glassine/deploy.conf, which
# the device's package derives from its description's [data_partition] keep_updates
# (installer spec 002 FR-018c; on a PC the device stage derives it from the same
# description, scripts/keep-updates.sh). Read as text, the
# last assignment; missing or not a whole number of 1 or more: 1, as glassine-deploy.
keep_of() {
	_k=$(sed -n 's/^[[:space:]]*KEEP_UPDATES=//p' "$1" 2>/dev/null | tail -n 1 | sed "s/[[:space:]]*\(#.*\)\{0,1\}\$//; s/^[\"']//; s/[\"']\$//")
	case "$_k" in ''|*[!0-9]*|0*) echo 1 ;; *) echo "$_k" ;; esac
}

# 5. read back what the installer writes: mounted read-only, the same layout
tick
mount -o loop,ro $W/pool.img $P
layout_ok
keep=$(keep_of "$P/bases/$BASE/etc/glassine/deploy.conf")
umount $P
tock "read back"
say "the base keeps $keep update(s) (KEEP_UPDATES in its /etc/glassine/deploy.conf, else 1)"

# min_partition_bytes (GlassineOS/installer spec 002, FR-019a): one base as received
# (its used bytes) + 64 MiB for each of keep_updates kept updates + the modules, x 1.25,
# at least 1 GiB, rounded up to a whole MiB; never below the image itself
ub=$((U1 - U0)); um=$((U2 - U1))
min=$(( (ub + keep * 64 * MIB + um) * 5 / 4 ))
[ $min -ge $((1024 * MIB)) ] || min=$((1024 * MIB))
min=$(( (min + MIB - 1) / MIB * MIB ))
[ $min -ge "$size" ] || min=$size
tick
mv $W/pool.img /o/pool.img
res size "$size"
res sha256 "$(sha256sum /o/pool.img | cut -c1-64)"
res used_empty "$U0"; res used_base "$ub"; res used_modules "$um"
res keep_updates "$keep"
res min_partition_bytes "$min"
res fsid "$(super /o/pool.img fsid)"
tock "hash"
say "pool image: $size bytes ($((size / MIB)) MiB), base $ub B, modules $um B used; min partition $min B"
t0=$T0; tock "pool-image (container)"
