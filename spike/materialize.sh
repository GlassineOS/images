#!/bin/sh
# materialize.sh DIR ID [PARENT_ID]: turn DIR/base-ID.tar (a BuildKit tar export)
# into a read-only bases/ID subvolume and its send streams, on the host
# (privileged container, loop devices in a tmpfs; nothing touches a device).
#
#   1. extract the tar into bases/ID on a fresh btrfs. With PARENT_ID, receive
#      DIR/base-PARENT_ID.btrfs.zst first, snapshot it to bases/ID and sync the
#      new tree in by content, so unchanged files stay shared with the parent
#   2. check the tree for build leftovers (resolv.conf, hosts)
#   3. full stream DIR/base-ID.btrfs.zst; with a parent, also the delta
#      DIR/base-ID.from-PARENT_ID.btrfs.zst (send -p)
#   4. receive on a second btrfs (parent + delta, or the full stream), and the
#      full stream on a third; every tree must have the same manifest as the
#      tar extracted onto a plain directory (tree-manifest.py)
#   5. timings, sizes, and how much of the new base is shared with its parent
#
# NORMALIZE_MTIME=EPOCH sets every mtime to EPOCH before the sync (step 1).
set -eu
D=$(cd "${1:?usage: materialize.sh DIR ID [PARENT_ID]}" && pwd)
ID=${2:?ID}; PID=${3:-}
[ -r "$D/base-$ID.tar" ] || { echo "materialize.sh: no $D/base-$ID.tar" >&2; exit 1; }
[ -z "$PID" ] || [ -r "$D/base-$PID.btrfs.zst" ] || { echo "materialize.sh: no $D/base-$PID.btrfs.zst" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
docker run --rm --privileged -e ID="$ID" -e PID="$PID" -e HOST_UID="$(id -u)" \
    -e NORMALIZE_MTIME="${NORMALIZE_MTIME:-}" \
    -v "$D":/d -v "$HERE/tree-manifest.py":/m.py:ro alpine:3.24 sh -ec '
    apk add -q btrfs-progs tar zstd rsync python3 >/dev/null
    for i in 0 1 2 3 4 5 6 7; do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
    W=/w; mkdir -p $W && mount -t tmpfs -o size=12g tmpfs $W
    now() { python3 -c "import time; print(time.time())"; }; t0=0; tick() { t0=$(now); }
    tock() { printf "time %-28s %6.1f s\n" "$1" "$(echo "$(now) - $t0" | bc)"; }
    apk add -q bc >/dev/null
    mkfs1() { truncate -s 6442450944 $W/$1.img; mkfs.btrfs -q $W/$1.img; mkdir -p $W/$1; mount -o loop,noatime,compress=zstd $W/$1.img $W/$1; mkdir -p $W/$1/bases; }
    untar() { tar -C "$1" --numeric-owner --xattrs --xattrs-include="*" -xpf /d/base-$ID.tar; }
    norm() { [ -z "$NORMALIZE_MTIME" ] || find "$1" -exec touch -h -d "@$NORMALIZE_MTIME" {} +; }
    man() { python3 -I /m.py "$1" > "$2"; }

    # the reference: the tar on a plain directory
    mkdir $W/ref; tick; untar $W/ref; norm $W/ref; tock "extract (reference)"
    man $W/ref $W/ref.man
    echo "entries: $(wc -l < $W/ref.man)"
    for f in etc/resolv.conf etc/hosts etc/hostname; do
        if [ -e $W/ref/$f ]; then echo "present $f: $(tr "\n" " " < $W/ref/$f | cut -c1-80)"; else echo "absent $f"; fi
    done
    [ ! -e $W/ref/etc/resolv.conf ] || { echo "FAIL: /etc/resolv.conf from the build is in the base"; exit 1; }

    mkfs1 a
    if [ -n "$PID" ]; then
        tick; zstd -dc /d/base-$PID.btrfs.zst | btrfs -q receive $W/a/bases; tock "receive parent"
        tick; btrfs -q subvolume snapshot $W/a/bases/$PID $W/a/bases/$ID
        # by content: a rebuilt file with the same bytes stays shared
        rsync -aHAX --numeric-ids --delete --force --checksum $W/ref/ $W/a/bases/$ID/
        tock "snapshot + sync"
    else
        tick; btrfs -q subvolume create $W/a/bases/$ID; untar $W/a/bases/$ID; norm $W/a/bases/$ID; tock "extract into subvolume"
    fi
    btrfs property set -ts $W/a/bases/$ID ro true
    sync; btrfs filesystem sync $W/a
    man $W/a/bases/$ID $W/a.man; cmp -s $W/ref.man $W/a.man || { echo "FAIL: bases/$ID differs from the tar"; diff $W/ref.man $W/a.man | head; exit 1; }
    echo "bases/$ID == tar"

    tick; btrfs -q send $W/a/bases/$ID | zstd -qf -T0 -3 -o /d/base-$ID.btrfs.zst; tock "full stream"
    RAWF=$(btrfs -q send $W/a/bases/$ID | wc -c)
    if [ -n "$PID" ]; then
        tick; btrfs -q send -p $W/a/bases/$PID $W/a/bases/$ID | zstd -qf -T0 -3 -o /d/base-$ID.from-$PID.btrfs.zst; tock "delta stream"
        btrfs -q send -p $W/a/bases/$PID $W/a/bases/$ID > $W/delta.raw
        RAWD=$(wc -c < $W/delta.raw)
        echo "== delta commands"; btrfs receive --dump < $W/delta.raw | awk "{print \$1}" | sort | uniq -c | sort -rn | head -12
        echo "== delta: files written"; btrfs receive --dump < $W/delta.raw | awk "\$1==\"write\"{print \$2}" | sort -u | sed "s|^\./[^/]*/||" | head -40
    fi

    mkfs1 b
    if [ -n "$PID" ]; then
        tick; zstd -dc /d/base-$PID.btrfs.zst | btrfs -q receive $W/b/bases
        zstd -dc /d/base-$ID.from-$PID.btrfs.zst | btrfs -q receive $W/b/bases; tock "receive parent + delta"
    else
        tick; zstd -dc /d/base-$ID.btrfs.zst | btrfs -q receive $W/b/bases; tock "receive full"
    fi
    man $W/b/bases/$ID $W/b.man; cmp -s $W/ref.man $W/b.man || { echo "FAIL: received base differs"; diff $W/ref.man $W/b.man | head; exit 1; }
    [ "$(btrfs property get -ts $W/b/bases/$ID ro)" = ro=true ] || { echo "FAIL: received base not read-only"; exit 1; }
    echo "received bases/$ID == tar"
    ruuid() { btrfs subvolume show $1 | sed -n "s/^[[:space:]]*Received UUID:[[:space:]]*//p"; }
    if [ -n "$PID" ]; then
        mkfs1 c; zstd -dc /d/base-$ID.btrfs.zst | btrfs -q receive $W/c/bases
        man $W/c/bases/$ID $W/c.man; cmp -s $W/b.man $W/c.man || { echo "FAIL: full stream and parent + delta differ"; exit 1; }
        [ "$(ruuid $W/b/bases/$ID)" = "$(ruuid $W/c/bases/$ID)" ] || { echo "FAIL: Received UUIDs differ"; exit 1; }
        echo "full stream == parent + delta (Received UUID $(ruuid $W/c/bases/$ID))"
        echo "== sharing on the receiving btrfs"; btrfs filesystem du -s $W/b/bases/*
        umount $W/c
    fi
    echo "files with security.capability: $(grep -c " security.capability=" $W/ref.man || :)"
    echo "files with other xattrs: $(grep " [a-z]*\.[a-z_.]*=" $W/ref.man | grep -vc " security.capability=" || :)"
    echo "== sizes"
    echo "tar:                 $(du -h /d/base-$ID.tar | cut -f1)"
    echo "full stream:         $((RAWF / 1048576)) MiB raw, $(du -h /d/base-$ID.btrfs.zst | cut -f1) zstd"
    [ -z "$PID" ] || echo "delta from $PID: $((RAWD / 1024)) KiB raw, $(du -k /d/base-$ID.from-$PID.btrfs.zst | cut -f1) KiB zstd"
    cp $W/ref.man /d/base-$ID.manifest
    chown "$HOST_UID" /d/base-$ID.* 2>/dev/null || :
    umount $W/a $W/b; umount $W'
