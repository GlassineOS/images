#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The container half of scripts/test-first-start-qemu.sh (Alpine, as root; never on
# the host). Mounts: /o (the test's work folder), /r (the release folder, ro), /t (the
# target's board.conf, ro). Modes:
#
#   files    arm64 container: Alpine's virt kernel (/o/Image) and its modules
#            (/o/modules.tar, /o/krel); the initramfs the guest boots (/o/initramfs.cpio.gz)
#            = the images initramfs export (/o/ird.cpio.gz) + the board archive the
#            device's packer appends (/t/board.conf as etc/glassine-boot/board.conf) +
#            a shim archive that loads the virt kernel's disk and file system modules,
#            then runs the real /init
#   disk     privileged, native: /o/disk.img, a GPT with `userdata` (an ext4 of
#            another system with a file in it, USERDATA_RESERVE_KIB at its end left as
#            that system's footer: random bytes) and `system_b` (SYS_BYTES; the pool
#            image written to it as bytes, as the installer does). What it made goes
#            to /o/disk.info
#   check N  privileged, native, read-only: the disk after boot N (1: the first
#            start's reboot; 2: the first deployment's power-off). QTEST lines
# Environment: POOL (the pool image, under /r), SYS_BYTES, UD_BYTES, RESERVE_KIB,
# BASE (the base id), KREL (check).
set -eu
MIB=1048576
say() { echo "QTEST $*"; }
res() { if [ "$1" = 0 ]; then say "ok $2"; else say "FAIL $2"; fi; }
v() { sed -n "s/^$1=//p" "$2" | head -n 1; }

loops() { for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done; }
# part N [ro]: a loop device over partition N of the disk
part() {
	s=$(sgdisk -i "$1" /o/disk.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
	e=$(sgdisk -i "$1" /o/disk.img | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
	losetup -f --show ${2:+-r} -o $((s * 512)) --sizelimit $(((e - s + 1) * 512)) /o/disk.img
}

case ${1:-} in
files)
	apk add -q --no-progress linux-virt kmod cpio gzip zstd >/dev/null
	KREL=$(ls /lib/modules | head -n 1)
	cp /boot/vmlinuz-virt /o/Image
	W=/tmp/f; mkdir -p $W/b/etc/glassine-boot $W/s/lib/qtest $W/i
	# the board archive, as GlassineOS/boot's packer appends it
	cp /t/board.conf $W/b/etc/glassine-boot/board.conf
	(cd $W/b && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > $W/board.cpio.gz
	# the shim: PID 1 for a moment, loads the modules, then the real init (exec keeps PID 1)
	# crc32c: btrfs's soft dependency (its checksums), which --show-depends leaves out
	for m in virtio_blk ext4 crc32c btrfs overlay; do
		modprobe -S "$KREL" --show-depends $m | sed -n 's/^insmod \([^ ]*\).*/\1/p'
	done | awk '!seen[$0]++' | while read -r k; do
		b=${k##*/}; b=${b%.gz}; b=${b%.zst}
		case $k in *.gz) gzip -dc "$k" ;; *.zst) zstd -qdc "$k" ;; *) cat "$k" ;; esac > $W/s/lib/qtest/$b
		echo "$b" >> $W/s/lib/qtest/load.list
	done
	(cd $W/i && zcat /o/ird.cpio.gz | cpio -id --quiet init)
	cp $W/i/init $W/s/init.glassine
	cat > $W/s/init <<'EOF'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc 2>/dev/null
while read -r m; do /bin/busybox insmod /lib/qtest/$m; done < /lib/qtest/load.list
/bin/busybox umount /proc
exec /init.glassine
EOF
	chmod 755 $W/s/init $W/s/init.glassine
	(cd $W/s && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > $W/shim.cpio.gz
	cat /o/ird.cpio.gz $W/board.cpio.gz $W/shim.cpio.gz > /o/initramfs.cpio.gz
	tar -C /lib/modules/"$KREL" -cf /o/modules.tar .
	echo "$KREL" > /o/krel
	echo "files: kernel $KREL; initramfs = images' export + board.conf + shim ($(wc -l < $W/s/lib/qtest/load.list) modules)"
	;;

disk)
	apk add -q --no-progress btrfs-progs e2fsprogs e2fsprogs-extra sgdisk losetup >/dev/null
	loops
	rm -f /o/disk.img
	truncate -s $((MIB + UD_BYTES + SYS_BYTES + MIB)) /o/disk.img
	# userdata first, system_b after it, as on the Note Air (by name; no number is assumed)
	sgdisk -o -n 1:2048:+$((UD_BYTES / 1024))K -c 1:userdata -n 2:0:+$((SYS_BYTES / 1024))K -c 2:system_b \
		/o/disk.img >/dev/null
	# userdata: another system's ext4, short of the partition by the footer it keeps there
	l=$(part 1)
	ud=$(blockdev --getsize64 "$l")
	[ "$ud" = "$UD_BYTES" ] || { echo "disk: userdata is $ud bytes, not $UD_BYTES" >&2; exit 1; }
	mke2fs -F -q -t ext4 -b 4096 -O ^orphan_file,^metadata_csum -L userdata "$l" $(((ud / 1024 - RESERVE_KIB) / 4))
	mkdir -p /m && mount -t ext4 "$l" /m
	mkdir -p /m/qtest-stock/data && head -c 1048576 /dev/urandom > /m/qtest-stock/data/file
	echo stock > /m/qtest-stock/marker
	umount /m
	head -c $((RESERVE_KIB * 1024)) /dev/urandom | dd of="$l" bs=1024 seek=$((ud / 1024 - RESERVE_KIB)) conv=notrunc status=none
	{
		echo "ud_uuid=$(dumpe2fs -h "$l" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p')"
		echo "ud_footer=$(tail -c $((RESERVE_KIB * 1024)) "$l" | sha256sum | cut -c1-64)"
	} > /o/disk.info
	losetup -d "$l"
	# system_b: the pool image as bytes
	l=$(part 2)
	sb=$(blockdev --getsize64 "$l")
	[ "$sb" = "$SYS_BYTES" ] || { echo "disk: system_b is $sb bytes, not $SYS_BYTES" >&2; exit 1; }
	dd if="/r/$POOL" of="$l" bs=1M conv=notrunc,fsync status=none
	losetup -d "$l"
	echo "sys_bytes=$SYS_BYTES" >> /o/disk.info
	echo "ud_bytes=$UD_BYTES" >> /o/disk.info
	echo "disk: userdata $((UD_BYTES / MIB)) MiB (another system's ext4, $RESERVE_KIB KiB footer), system_b $((SYS_BYTES / MIB)) MiB (pool image $(($(stat -c %s "/r/$POOL") / MIB)) MiB)"
	sed 's/^/disk: /' /o/disk.info
	;;

check)
	N=$2
	apk add -q --no-progress btrfs-progs e2fsprogs e2fsprogs-extra sgdisk losetup >/dev/null
	loops
	I=/o/disk.info
	# --- system_b
	l=$(part 2 ro)
	tb=$(btrfs inspect-internal dump-super "$l" | awk '$1 == "total_bytes" { print $2; exit }')
	db=$(btrfs inspect-internal dump-super "$l" | awk '$1 == "dev_item.total_bytes" { print $2; exit }')
	[ "$tb" = "$(v sys_bytes $I)" ] && [ "$db" = "$tb" ]; res $? "after boot $N: the pool fills system_b (total_bytes $tb, device $db, partition $(v sys_bytes $I))"
	if btrfs check --readonly "$l" > /tmp/c 2>&1; then say "ok after boot $N: system_b (btrfs) clean"
	else sed 's/^/    /' /tmp/c; say "FAIL after boot $N: system_b (btrfs) clean"; fi
	mkdir -p /s && mount -t btrfs -o ro "$l" /s
	[ ! -e /s/state/install ]; res $? "after boot $N: the install marker state/install is gone"
	cand=$(v candidate /s/state/deploy) cur=$(v current /s/state/deploy) tries=$(v tries /s/state/deploy)
	echo "    state/deploy: $(tr '\n' ' ' < /s/state/deploy)"
	echo "    state/kernel: $(tr '\n' ' ' < /s/state/kernel 2>/dev/null)"
	[ "$(v current /s/state/kernel)" = "$KREL" ]; res $? "after boot $N: state/kernel current= the running kernel ($KREL)"
	[ "$(ls /s/bases)" = "$BASE" ]; res $? "after boot $N: bases/ holds the release's base only"
	if [ "$N" = 1 ]; then
		[ -n "$cand" ] && [ -z "$cur" ] && [ "$tries" = 2 ]; res $? "after boot 1: a candidate deployment ($cand) with 2 tries, no current"
		dep=$cand
	else
		[ -n "$cur" ] && [ -z "$cand" ] && [ "$cur" = "$(v dep /o/check1.info)" ]; res $? "after boot 2: the first deployment ($cur) is current, no candidate"
		dep=$cur
	fi
	umount /s; losetup -d "$l"
	# --- userdata
	l=$(part 1 ro)
	ud=$(blockdev --getsize64 "$l")
	h=$(dumpe2fs -h "$l" 2>/dev/null)
	f() { echo "$h" | sed -n "s/^$1: *//p" | head -n 1; }
	echo "    userdata: block size $(f 'Block size'), block count $(f 'Block count'), features $(f 'Filesystem features')"
	[ "$(f 'Filesystem UUID')" != "$(v ud_uuid $I)" ]; res $? "after boot $N: userdata is a new file system (UUID $(f 'Filesystem UUID'), the other system's $(v ud_uuid $I))"
	[ "$(f 'Block size')" = 4096 ]; res $? "after boot $N: userdata is ext4 with 4096-byte blocks"
	want=$(((ud / 1024 - RESERVE_KIB) / 4))
	[ "$(f 'Block count')" = "$want" ]; res $? "after boot $N: userdata ends $RESERVE_KIB KiB before the partition's end ($(f 'Block count') blocks, $want wanted)"
	! echo " $(f 'Filesystem features') " | grep -q ' orphan_file '; res $? "after boot $N: userdata has no orphan_file"
	[ "$(tail -c $((RESERVE_KIB * 1024)) "$l" | sha256sum | cut -c1-64)" = "$(v ud_footer $I)" ]; res $? "after boot $N: the $RESERVE_KIB KiB at userdata's end are untouched"
	if echo "$h" | grep -q '^Filesystem features:.*needs_recovery'; then say "FAIL after boot $N: userdata (ext4) clean: the journal needs a replay"
	elif e2fsck -fn "$l" > /tmp/c 2>&1; then say "ok after boot $N: userdata (ext4) clean"
	else sed 's/^/    /' /tmp/c; say "FAIL after boot $N: userdata (ext4) clean (e2fsck -fn)"; fi
	mkdir -p /u && mount -t ext4 -o ro,noload "$l" /u
	[ ! -e /u/qtest-stock ]; res $? "after boot $N: nothing of the other system on userdata"
	m=/u/media/glassine/deployments/$dep/meta
	[ "$(v kind "$m")" = install ] && [ "$(v base "$m")" = "$BASE" ]; res $? "after boot $N: deployment $dep: kind=install on base $BASE ($(tr '\n' ' ' < "$m" 2>/dev/null))"
	umount /u; losetup -d "$l"
	[ "$N" != 1 ] || echo "dep=$dep" > /o/check1.info
	;;
*)
	echo "usage: $0 files|disk|check N" >&2; exit 2 ;;
esac
