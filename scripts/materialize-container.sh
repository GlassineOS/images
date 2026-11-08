#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The privileged half of scripts/materialize: runs in its container (Alpine, as root),
# never on the host. Every btrfs file system here is a sparse file on a tmpfs, mounted
# through a loop device; no block device of the host is opened.
#
# Mounts: /in/base.tar (the tar export, ro), /k (the kernel and boot exports, ro),
# /a (the artifacts folder), /s (scripts/, ro). Environment, set by materialize:
#   DATE      yyyymmdd (UTC)            TARGET   the target
#   PARENT    parent base id, or empty  RELEASE  the kernel release (modules/<RELEASE>)
#   STAGE     the staging directory under /a, where every output goes
#   MODULES   new = make the modules stream; have = /a/modules/RELEASE.btrfs.zst exists
#   TMPFS     tmpfs size (mount -o size=)   IMG  each btrfs file's size in bytes
#   HOST_UID, HOST_GID  owner of the outputs
# Inputs in STAGE: base.manifest.in (the base manifest without its base= line).
# Outputs in STAGE: tree.manifest, packages, base.btrfs.zst, base.from-PARENT.btrfs.zst,
# modules.btrfs.zst + modules.manifest (MODULES=new), result (key=value). Exit 3 = a
# base with this tree exists (FR-011): result holds exists=<id>.
set -eu
O=/a/$STAGE
W=/w
say() { echo "materialize: $*"; }
die() { echo "materialize: FAIL: $*" >&2; exit 1; }
up() { cut -d' ' -f1 /proc/uptime; }
T0=$(up); t0=$T0
tick() { t0=$(up); }
tock() { awk -v a="$t0" -v b="$(up)" -v n="$1" 'BEGIN { printf "time %-26s %6.2f s\n", n, b - a }' | tee -a $O/times; }
res() { echo "$1=$2" >> $O/result; }

cleanup() {
	set +e
	for m in a b c; do mountpoint -q $W/$m 2>/dev/null && umount $W/$m; done
	mountpoint -q $W && umount $W
	chown -R "$HOST_UID:$HOST_GID" "$O" 2>/dev/null
}
trap cleanup EXIT

tick
apk add -q --no-progress btrfs-progs tar zstd rsync python3 >/dev/null || die "apk add failed"
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
mkdir -p $W && mount -t tmpfs -o size="$TMPFS" tmpfs $W
: > $O/result; : > $O/times
tock "container setup"

man() { python3 -I /s/tree-manifest.py "$1" > "$2"; }
same() {	# same REF.man TREE WHAT
	man "$2" $W/cmp.man
	cmp -s "$1" $W/cmp.man || { diff "$1" $W/cmp.man | head -20 >&2; die "$3 differs from the reference"; }
	say "same content: $3"
}
untar() { tar -C "$1" --numeric-owner --xattrs --xattrs-include='*' -xpf /in/base.tar; }
mkfs1() {
	truncate -s "$IMG" $W/$1.img && mkfs.btrfs -q $W/$1.img
	mkdir -p $W/$1 && mount -o loop,noatime,compress=zstd $W/$1.img $W/$1
	mkdir -p $W/$1/bases $W/$1/modules
}
ruuid() { btrfs subvolume show "$1" | sed -n 's/^[[:space:]]*Received UUID:[[:space:]]*//p'; }
suuid() { btrfs subvolume show "$1" | sed -n 's/^[[:space:]]*UUID:[[:space:]]*//p'; }
is_ro() { [ "$(btrfs property get -ts "$1" ro)" = ro=true ]; }
# receive STREAM DIR NAME: one read-only subvolume with a received UUID, named NAME,
# as glassine-deploy receive keeps it
receive() {
	before=$(ls "$2" | wc -l)
	zstd -dc "$1" | btrfs -q receive "$2" || die "receive $1 failed"
	[ "$(ls "$2" | wc -l)" = $((before + 1)) ] || die "$1: not exactly one subvolume"
	[ -d "$2/$3" ] || die "$1: the subvolume is not named $3"
	is_ro "$2/$3" || die "$1: received $3 is not read-only"
	[ -n "$(ruuid "$2/$3")" ] || die "$1: received $3 has no received UUID"
}
# the base manifest into a tree, the same way into every tree
put_manifest() {
	d=$1/usr/share/glassine
	[ -d "$d" ] || install -d -m 0755 -o 0 -g 0 "$d"
	install -m 0644 -o 0 -g 0 $W/base.manifest "$d/base.manifest"
	touch -h -d @0 "$d/base.manifest"
}

# 1. the reference: the tar on a plain directory
tick; mkdir $W/ref; untar $W/ref; tock "extract (reference)"
python3 -I /s/base_tree.py check $W/ref || die "the export carries build leftovers (FR-019)"
tick; man $W/ref $O/tree.manifest; tock "content manifest"
TREE=$(sha256sum $O/tree.manifest | cut -c1-64)
T16=$(echo "$TREE" | cut -c1-16)
ID=$DATE-$T16
say "entries: $(wc -l < $O/tree.manifest), tree $TREE"
say "id: $ID"
res id "$ID"; res tree "$TREE"

# 2. one tree is materialized once (FR-011)
for d in /a/"$TARGET"/*-"$T16"; do
	[ -d "$d" ] || continue
	res exists "${d##*/}"
	echo "materialize: base ${d##*/} has this tree ($T16); no new base made" >&2
	exit 3
done

# 3. the base manifest, then the comparison reference with it
{ head -n 1 $O/base.manifest.in; echo "base=$ID"; tail -n +2 $O/base.manifest.in; } > $W/base.manifest
put_manifest $W/ref
man $W/ref $W/ref.man
python3 -I /s/base_tree.py packages $W/ref > $O/packages
python3 -I /s/base_tree.py name $W/ref "$ID" || die "base manifest"

# 4. the subvolume: fresh, or a snapshot of the parent with the new tree synced in by
# content (unchanged files stay shared even with new timestamps)
mkfs1 a
if [ -n "$PARENT" ]; then
	tick; receive /a/"$TARGET"/"$PARENT"/base.btrfs.zst $W/a/bases "$PARENT"; tock "receive parent"
	tick
	btrfs -q subvolume snapshot $W/a/bases/"$PARENT" $W/a/bases/"$ID"
	rsync -aHAX --numeric-ids --delete --force --checksum $W/ref/ $W/a/bases/"$ID"/
	tock "snapshot parent + sync"
else
	tick
	btrfs -q subvolume create $W/a/bases/"$ID"
	untar $W/a/bases/"$ID"
	put_manifest $W/a/bases/"$ID"
	tock "extract into subvolume"
fi
python3 -I /s/base_tree.py name $W/a/bases/"$ID" "$ID" || die "base manifest in the subvolume"
btrfs property set -ts $W/a/bases/"$ID" ro true
btrfs filesystem sync $W/a
tick; same $W/ref.man $W/a/bases/"$ID" "subvolume bases/$ID"; tock "compare subvolume"
UUID=$(suuid $W/a/bases/"$ID")
res uuid "$UUID"

# 5. streams
tick; btrfs -q send $W/a/bases/"$ID" | zstd -q -T0 -3 -o $O/base.btrfs.zst; tock "full stream"
if [ -n "$PARENT" ]; then
	tick
	btrfs -q send -p $W/a/bases/"$PARENT" $W/a/bases/"$ID" > $W/delta.raw
	zstd -q -T0 -3 -o $O/base.from-"$PARENT".btrfs.zst $W/delta.raw
	tock "delta stream"
	res delta_raw "$(wc -c < $W/delta.raw)"
	echo "== delta: commands"
	btrfs receive --dump < $W/delta.raw | awk '{ print $1 }' | sort | uniq -c | sort -rn
	echo "== delta: files written"
	btrfs receive --dump < $W/delta.raw | awk '$1 == "write" { print $2 }' | sort -u | sed "s|^\./$ID/||"
	rm $W/delta.raw
fi

# 6. modules/<release>: owned by root, every file 0644 (kernel-check), a subvolume of its own
tick
mkdir $W/modref && cp -a /k/modules/"$RELEASE" $W/modref/m && chown -R 0:0 $W/modref/m
man $W/modref/m $W/modref.man
if [ "$MODULES" = new ]; then
	btrfs -q subvolume create $W/a/modules/"$RELEASE"
	cp -a $W/modref/m/. $W/a/modules/"$RELEASE"/
	btrfs property set -ts $W/a/modules/"$RELEASE" ro true
	same $W/modref.man $W/a/modules/"$RELEASE" "subvolume modules/$RELEASE"
	btrfs -q send $W/a/modules/"$RELEASE" | zstd -q -T0 -3 -o $O/modules.btrfs.zst
	cp $W/modref.man $O/modules.manifest
	tock "modules subvolume + stream"
else
	cmp -s $W/modref.man /a/modules/"$RELEASE".manifest \
		|| die "/a/modules/$RELEASE.btrfs.zst exists with other contents than this kernel export's"
	say "modules/$RELEASE: the artifacts folder has its stream (same contents)"
	tock "modules (existing)"
fi

# 7. receive every stream back on fresh file systems (FR-009)
mkfs1 b
tick; receive $O/base.btrfs.zst $W/b/bases "$ID"; tock "receive full"
same $W/ref.man $W/b/bases/"$ID" "received full stream"
python3 -I /s/base_tree.py name $W/b/bases/"$ID" "$ID" || die "base manifest, full stream"
RUUID=$(ruuid $W/b/bases/"$ID")
[ "$RUUID" = "$UUID" ] || die "received UUID $RUUID is not the subvolume's $UUID"
res received_uuid "$RUUID"
if [ "$MODULES" = new ]; then
	MS=$O/modules.btrfs.zst; else MS=/a/modules/"$RELEASE".btrfs.zst; fi
tick; receive "$MS" $W/b/modules "$RELEASE"; tock "receive modules"
same $W/modref.man $W/b/modules/"$RELEASE" "received modules stream"
if [ -n "$PARENT" ]; then
	mkfs1 c
	tick
	receive /a/"$TARGET"/"$PARENT"/base.btrfs.zst $W/c/bases "$PARENT"
	receive $O/base.from-"$PARENT".btrfs.zst $W/c/bases "$ID"
	tock "receive parent + delta"
	same $W/ref.man $W/c/bases/"$ID" "received parent + delta"
	python3 -I /s/base_tree.py name $W/c/bases/"$ID" "$ID" || die "base manifest, parent + delta"
	[ "$(ruuid $W/c/bases/"$ID")" = "$RUUID" ] || die "parent + delta: received UUID $(ruuid $W/c/bases/"$ID") is not $RUUID"
	say "full stream and parent + delta: received UUID $RUUID"
	echo "== sharing with the parent (receiving file system)"
	btrfs filesystem du -s $W/c/bases/*
fi

res stream_sha256 "$(sha256sum $O/base.btrfs.zst | cut -c1-64)"
[ -z "$PARENT" ] || res delta_sha256 "$(sha256sum $O/base.from-"$PARENT".btrfs.zst | cut -c1-64)"
[ "$MODULES" != new ] || res modules_sha256 "$(sha256sum $O/modules.btrfs.zst | cut -c1-64)"
t0=$T0; tock "materialize (container)"
