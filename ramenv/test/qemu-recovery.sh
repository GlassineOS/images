#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The QEMU part of test-recovery.sh (docs/recovery.md), inside an Alpine container of
# the build computer's own architecture. Mounts: /src the ramenv directory (read-only),
# /out the kit (Image, mods/, client-usb, recovery.cpio.gz: the production initramfs as
# built).
#
# The disks of test-ramenv's runs (vda: 64 MiB, a GPT, two partitions; vdb: 4 MiB; in the
# usb run QEMU's eMMC with two boot areas) and a pool disk made here without privileges
# (pool.img, 512 MiB): a GPT with system_b (btrfs, by mkfs.btrfs --rootdir: bases/base1
# a read-only subvolume, state/ naming A current and B previous) and userdata (ext4, by
# mke2fs -d: media/glassine/deployments/A, B, C, A with a log).
#   usb      the install case: no pool (a table without system_b and userdata), the
#            composite gadget (the vendor interface 0 and the USB serial) on dummy_hcd.
#            The recovery starts without waiting for the labels; the menu answers on
#            the host's /dev/ttyACM0 with no deployment, a DEPLOY is refused before any
#            window; client-usb runs test-ramenv's whole read and write plan (protocol
#            version 2) against the recovery: the installer's install writes unchanged.
#   deploy   the pool on QEMU's eMMC (mmcblk0, its force_ro too), protocol version 3
#            over virtio-serial (client-recovery.py deploy): STATUS, select, rollback,
#            pin, DIAG, disks hashed before and after; then remove.
#   console  the pool as vdc; the menu on a virtio console (client-recovery.py
#            console): rollback with a wrong then the right confirmation, reset,
#            diagnostics.
#   screen   the pool as vdc and a device data seed as vdd (a GPT, vendor_b: ext4 with
#            glassine/manifest and a made-up waveform); the screen with the production
#            start script and client, glassine-epdd replaced by epd-sink (no panel here),
#            driven by screen-drive (uinput: a touchscreen and a power key) through
#            screen/qemu.events: select, rollback and reset confirmed, cancels by touch
#            and by the power key, taps and holds from before a confirmation (ignored),
#            diagnostics, restart cancelled, the idle notice and the restart.
# Each run ends by the recovery's idle restart (deploy, console, screen) or the client's
# reboot (usb). test/check.sh checks in the guest that every disk and partition is read-only.
# Prints ok/FAIL lines.
set -eu
trap 'mkdir -p /out/logs-recovery; cp $W/*.log $W/*.client /out/logs-recovery/ 2>/dev/null; [ -z "${OWNER:-}" ] || chown -R "$OWNER" /out/logs-recovery' EXIT
apk add -q qemu-system-aarch64 python3 sgdisk cpio gzip coreutils btrfs-progs e2fsprogs e2fsprogs-extra >/dev/null
W=/tmp/w; rm -rf $W; mkdir -p $W/prod $W/t
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
sha() { sha256sum "$1" | cut -c1-64; }

# --- test-ramenv's disks and its write plan (the usb run) ---------------------------
head -c 64M /dev/urandom > $W/vda.img
sgdisk -o -n 1:2048:+16M -n 2:0:+16M $W/vda.img > /dev/null
head -c 4M /dev/urandom > $W/vdb.img
head -c 2M /dev/urandom > $W/mmcb.img
head -c 32M /dev/urandom > $W/mmcu.img
sgdisk -o -n 1:2048:+8M $W/mmcu.img > /dev/null
cat $W/mmcb.img $W/mmcu.img > $W/emmc.img
P=$W/w; mkdir -p $P
cp $W/vda.img $W/vda-new.img
sgdisk -n 3:0:+8M -c 3:glassine $W/vda-new.img > /dev/null
VS=$(stat -c %s $W/vda.img); BK=$((VS - 16896))
head -c 17408 $W/vda-new.img > $P/primary.bin
tail -c 16896 $W/vda-new.img > $P/backup.bin
head -c 16M /dev/urandom > $P/data.bin
head -c 1M /dev/urandom > $P/mmc.bin
cat > $P/plan <<EOF
range vda 0 17408
range vda 4194304 16777216
range vda $BK 16896
range mmcblk0 16777216 1048576
write vda $BK /lib/qtest/w/backup.bin
write vda 0 /lib/qtest/w/primary.bin
write vda 4194304 /lib/qtest/w/data.bin
write mmcblk0 16777216 /lib/qtest/w/mmc.bin
EOF
put() { dd if="$2" of="$1" bs=512 seek=$(($3 / 512)) conv=notrunc status=none; }
cp $W/vda.img $W/vda.want
put $W/vda.want $P/backup.bin $BK; put $W/vda.want $P/primary.bin 0; put $W/vda.want $P/data.bin 4194304
cp $W/emmc.img $W/emmc.want
put $W/emmc.want $P/mmc.bin $((2097152 + 16777216))

# --- the pool disk ------------------------------------------------------------------
R=$W/pool
B=$R/sys/bases/base1
mkdir -p $B/etc $B/usr/share/glassine $B/bin $R/sys/modules $R/sys/state
printf 'root:x:0:0:root:/root:/bin/sh\n' > $B/etc/passwd
printf 'root:x:0:root\n' > $B/etc/group
printf 'root:*:20000:0:::::\n' > $B/etc/shadow; chmod 640 $B/etc/shadow
echo base1 > $B/etc/hostname
echo /etc/hostname > $B/usr/share/glassine/migrate.list
printf 'version=1\n' > $R/sys/state/format
printf 'current=A\nprevious=B\ncandidate=\ntries=0\nstaged=\nfailed=\n' > $R/sys/state/deploy
printf 'current=\nprevious=\n' > $R/sys/state/kernel
: > $R/sys/state/.lock
U=$R/ud/media/glassine/deployments
for d in A B C; do
	mkdir -p $U/$d/build $U/$d/switch $U/$d/work
	printf 'base=base1\nkind=install\ncarry=none\nfrom=\ncreated=2026-11-0%s\n' "$(printf %s $d | tr ABC 123)" > $U/$d/meta
done
mkdir -p $U/A/switch/var/log $U/A/switch/etc
echo 'the last start of A' > $U/A/switch/var/log/messages
echo deployment-a > $U/A/switch/etc/hostname
truncate -s 256M $W/sys.img
mkfs.btrfs -q -r $R/sys -u ro:bases/base1 $W/sys.img
truncate -s 64M $W/ud.img
mke2fs -q -t ext4 -d $R/ud $W/ud.img
# a power of 2: QEMU's eMMC wants one
truncate -s 512M $W/pool.img
sgdisk -o -n 1:2048:+256M -c 1:system_b -n 2:0:+64M -c 2:userdata $W/pool.img > /dev/null
S1=$(sgdisk -i 1 $W/pool.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
S2=$(sgdisk -i 2 $W/pool.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
dd if=$W/sys.img of=$W/pool.img bs=512 seek=$S1 conv=notrunc status=none
dd if=$W/ud.img of=$W/pool.img bs=512 seek=$S2 conv=notrunc status=none
SYS_OFF=$((S1 * 512)) SYS_LEN=$((256 * 1048576))
cp $W/pool.img $W/vdc.img
head -c 2M /dev/urandom > $W/pmmcb.img
cat $W/pmmcb.img $W/pool.img > $W/pemmc.img
A0=$(sha $W/vda.img) B0=$(sha $W/vdb.img) C0=$(sha $W/vdc.img)
ok "the pool disk: system_b (btrfs, base1 read-only) at $SYS_OFF, userdata (ext4) at $((S2 * 512))"

# --- the test archive ---------------------------------------------------------------
(cd $W/prod && zcat /out/recovery.cpio.gz | cpio -id --quiet)
[ -x $W/prod/init ] && [ -x $W/prod/bin/glassine-ramread ] && [ -x $W/prod/sbin/glassine-deploy ] \
	&& [ -f $W/prod/etc/glassine/recovery.version ] || { echo "FAIL the production initramfs is not the recovery's"; exit 1; }
testcpio() {	# testcpio RUN CONF-LINES
	T=$W/t/$1; rm -rf $T; mkdir -p $T/lib/qtest $T/etc/glassine
	cp $W/prod/init $T/init.ramenv
	cp /out/mods/* $T/lib/qtest/
	printf '%s\n' "$2" > $T/etc/glassine/ramenv.conf
	cat > $T/init <<'EOF'
#!/bin/busybox sh
B=/bin/busybox
$B mkdir -p /proc /sys /dev /run
$B mount -t proc proc /proc; $B mount -t sysfs sysfs /sys; $B mount -t devtmpfs devtmpfs /dev
for m in $($B cat /lib/qtest/load-recovery.list); do $B insmod /lib/qtest/$m || echo "QTEST FAIL insmod $m"; done
[ -x /lib/qtest/check.sh ] && /lib/qtest/check.sh > /dev/console 2>&1 &
[ -x /lib/qtest/screen-drive ] && /lib/qtest/screen-drive /lib/qtest/screen.events /run/glassine-rscreen.state \
	/etc/glassine/epd.conf > /dev/console 2>&1 &
( for i in $($B seq 60); do
	for p in /sys/class/virtio-ports/*; do
		[ "$($B cat $p/name 2>/dev/null)" = glassine.ramread ] && { $B ln -s ${p##*/} /dev/ramread-stream; exit 0; }
	done
	$B sleep 0.5
done ) &
exec /init.ramenv
EOF
	chmod 755 $T/init
	[ "$1" = usb ] && cp -r $P $T/lib/qtest/w
	cp /out/client-usb /src/test/check.sh $T/lib/qtest/
	chmod 755 $T/lib/qtest/check.sh $T/lib/qtest/client-usb
	(cd $T && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet | gzip -n) > $W/t/$1.cpio.gz
	cat /out/recovery.cpio.gz $W/t/$1.cpio.gz > $W/t/$1.initrd
}
qemu() {	# qemu RUN [extra args]: the guest, its console to $W/RUN.log; vda, vdb, and
	# POOL (an image) as vdc
	r=$1; shift
	set -- -drive file=$W/vda.img,format=raw,if=virtio -drive file=$W/vdb.img,format=raw,if=virtio \
		${POOL:+-drive file=$POOL,format=raw,if=virtio} "$@"
	timeout 1200 qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 2 -m 1024 -nographic -no-reboot \
		-kernel /out/Image -initrd $W/t/$r.initrd \
		-append "console=ttyAMA0 loglevel=6 panic=5 rdinit=/init" \
		-device i6300esb -nic none "$@" > $W/$r.log 2>&1
}
qtest() {
	grep -a '^QTEST info' $W/$1.log | sed 's/\r$//; s/^QTEST //' || :
	grep -a '^QTEST \(ok\|FAIL\)' $W/$1.log | sed 's/\r$//; s/^QTEST //' > $W/$1.q || :
	while read -r l; do case $l in ok*) echo "$l [$1]" ;; *) echo "$l [$1]"; fails=$((fails + 1)) ;; esac; done < $W/$1.q
}
client() {	# client RUN ARGS...: the host client's QTEST lines
	c=0; python3 /src/test/client-recovery.py "$@" > $W/$1.client 2>&1 || c=$?
	sed 's/^QTEST //' $W/$1.client | while read -r l; do echo "$l [$1]"; done
	grep -q '^QTEST FAIL' $W/$1.client && fails=$((fails + 1))
	[ $c = 0 ] || bad "$1: the client exited $c"
}
common='RAMENV_DISKS="vd[a-z]"
RAMENV_WATCHDOG=/dev/watchdog0
RAMENV_WATCHDOG_TIMEOUT=30
RAMENV_DISK_WAIT=30
RECOVERY_SYSTEM_LABEL=system_b
RECOVERY_USERDATA_LABEL=userdata
RECOVERY_USERDATA_PREFIX=media/glassine'

# --- usb: the composite gadget, the install writes of protocol version 2 --------------
testcpio usb "$common
RAMENV_DISKS=\"vd[a-z] mmcblk[0-9] mmcblk[0-9]boot[0-9]\"
RAMENV_TRANSPORT=usb
RAMENV_UDC=dummy_udc.0
RAMENV_UDC_WAIT=30
RECOVERY_IDLE=300
RECOVERY_USB_SERIAL=yes
RECOVERY_TTYS=ttyGS0"
t0=$(date +%s)
POOL=
if qemu usb -device sdhci-pci -drive if=none,id=emmc,file=$W/emmc.img,format=raw \
	-device emmc,drive=emmc,boot-partition-size=1048576; then ok "usb: the guest ended by itself ($(($(date +%s) - t0)) s)"; else bad "usb: qemu exit (timeout or failure)"; fi
qtest usb
grep -aq 'glassine-ramread: the local socket /run/glassine-recovery.sock is open' $W/usb.log && ok "usb: the reader is the recovery's (local socket open)" || bad "usb: the reader is the recovery's"
grep -aq 'glassine-ramread: reboot (normal) asked by the computer' $W/usb.log && ok "usb: the client's reboot ended it" || bad "usb: the client's reboot ended it"
for d in vda:$A0 vdb:$B0; do
	n=${d%%:*} h=${d#*:}
	got=$(sed -n "s/^QTEST disk $n [0-9]* \([0-9a-f]*\).*/\1/p" $W/usb.log | head -n 1)
	[ "$got" = "$h" ] && ok "usb: $n read whole over USB, sha256 = the image's" || bad "usb: $n read over USB has sha256 ${got:-none}, the image $h"
done
cmp -s $W/vda.img $W/vda.want && ok "usb: vda.img = the original plus exactly the planned writes (cmp)" \
	|| bad "usb: vda.img is not the original plus the planned writes ($(cmp $W/vda.img $W/vda.want 2>&1 | head -n 1))"
cmp -s $W/emmc.img $W/emmc.want && ok "usb: emmc.img = the original plus exactly the planned write (cmp)" || bad "usb: emmc.img"
[ "$(sha $W/vdb.img)" = "$B0" ] && ok "usb: vdb.img unchanged" || bad "usb: vdb.img changed"
grep -aq 'glassine-ramenv: system partition: none (system_b), userdata: none (userdata)' $W/usb.log \
	&& ok "usb: no system_b or userdata: the recovery says so and goes on" || bad "usb: the recovery without the labelled partitions"
st=$(sed -n 's/^\[ *\([0-9]*\)\.[0-9]*\] glassine-ramread: the local socket .* is open.*/\1/p' $W/usb.log | head -n 1)
dk=$(sed -n 's/^\[ *\([0-9]*\)\.[0-9]*\] glassine-ramenv: starting.*/\1/p' $W/usb.log | head -n 1)
[ -n "$st" ] && [ -n "$dk" ] && [ $((st - dk)) -le 25 ] && ok "usb: the socket open $((st - dk)) s after the init started (no wait for the labels)" \
	|| bad "usb: the socket open at ${st:-never} s, init at ${dk:-?} s"
sgdisk -v $W/vda.img 2>&1 | grep -q 'No problems found' && ok "usb: vda's new partition table is valid (sgdisk -v)" || bad "usb: vda's new partition table"
A0=$(sha $W/vda.img)

# --- deploy: protocol version 3 over virtio-serial ----------------------------------
testcpio deploy "$common
RAMENV_DISKS=\"vd[a-z] mmcblk[0-9] mmcblk[0-9]boot[0-9]\"
RAMENV_TRANSPORT=stream
RAMENV_STREAM=/dev/ramread-stream
RECOVERY_IDLE=20"
t0=$(date +%s)
POOL=
qemu deploy -device sdhci-pci -drive if=none,id=emmc,file=$W/pemmc.img,format=raw \
	-device emmc,drive=emmc,boot-partition-size=1048576 -device virtio-serial-pci -chardev socket,id=rr,path=$W/rr.sock,server=on,wait=off \
	-device virtserialport,chardev=rr,name=glassine.ramread &
qpid=$!
client deploy $W/rr.sock $W/vda.img $W/vdb.img mmcblk0 $SYS_OFF $SYS_LEN
t1=$(date +%s)
if wait $qpid; then
	t2=$(date +%s)
	[ $((t2 - t1)) -le 90 ] && ok "deploy: restarted by itself $((t2 - t1)) s after the last request (idle 20 s)" || bad "deploy: the idle restart took $((t2 - t1)) s"
else bad "deploy: qemu exit (timeout or failure)"; fi
qtest deploy
grep -aq 'glassine-ramread: no request for [0-9]* s: rebooting' $W/deploy.log && ok "deploy: the idle time restarted it" || bad "deploy: the idle time restarted it"
grep -aq 'glassine-ramread: .*cannot be made writable' $W/deploy.log && bad "deploy: a deploy partition could not be made writable"
grep -aq 'glassine-ramread: deploy: every disk read-only again (FAILED' $W/deploy.log && bad "deploy: a disk stayed writable after an operation" \
	|| { grep -aq 'glassine-ramread: deploy: every disk read-only again' $W/deploy.log && ok "deploy: after each operation the reader checked every disk read-only again"; }
[ "$(sha $W/vda.img)" = "$A0" ] && [ "$(sha $W/vdb.img)" = "$B0" ] && ok "deploy: vda.img and vdb.img unchanged" || bad "deploy: vda.img or vdb.img changed"

# --- window: stand-in deploy tools that misbehave ----------------------------------
# describe and deploy replaced (later archive entries win): deploy mounts system_b or
# userdata and writes on (ignoring SIGTERM, in the background, with its output closed,
# under an overlay and a bind whose mount point has a space), or leaves userdata as
# swap. After each answer the pool image must not change and the window must have
# closed (or, for the swap, say it didn't and refuse what follows).
cp $W/pool.img $W/vdw.img
testcpio window "$common
RAMENV_TRANSPORT=stream
RAMENV_STREAM=/dev/ramread-stream
RECOVERY_IDLE=30
RECOVERY_TOOL_LIMIT=5"
T=$W/t/window; mkdir -p $T/lib/glassine-recovery
cat > $T/lib/glassine-recovery/describe <<'STUB'
#!/bin/sh
echo "stand-in: $*"
STUB
cat > $T/lib/glassine-recovery/deploy <<'STUB'
#!/bin/sh
. /etc/glassine/deploy.conf
B=/bin/busybox
id=$2
writer() { i=0; while :; do i=$((i + 1)); echo $i > "$1/stand-in-$id"; $B sync; $B sleep 0.2; done; }
case $id in
trap) $B mkdir -p /run/w; $B mount -t btrfs "$SYSTEM_DEV" /run/w || exit 3
	trap '' TERM; echo mounted; writer /run/w ;;
bg) $B mkdir -p /run/w; $B mount -t btrfs "$SYSTEM_DEV" /run/w || exit 3
	( writer /run/w ) > /dev/null 2>&1 &
	echo started ;;
closeout) exec > /dev/null 2>&1
	$B mkdir -p /run/w; $B mount -t btrfs "$SYSTEM_DEV" /run/w || exit 3; writer /run/w ;;
overlay) $B mkdir -p /run/u /run/lo "/run/o x" /run/b; $B mount -t ext4 "$USERDATA_DEV" /run/u || exit 3
	$B mkdir -p /run/u/up /run/u/wk
	$B mount -t overlay overlay -o lowerdir=/run/lo,upperdir=/run/u/up,workdir=/run/u/wk "/run/o x" || exit 3
	$B mount --bind "/run/o x" /run/b || exit 3
	( writer /run/b ) > /dev/null 2>&1 &
	echo started ;;
swap) { $B mkswap "$USERDATA_DEV" && $B swapon "$USERDATA_DEV"; } > /dev/null 2>&1 || { echo "no swap here"; exit 3; }
	echo swapping ;;
*) exit 3 ;;
esac
STUB
chmod 755 $T/lib/glassine-recovery/describe $T/lib/glassine-recovery/deploy
(cd $T && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet | gzip -n) > $W/t/window.cpio.gz
cat /out/recovery.cpio.gz $W/t/window.cpio.gz > $W/t/window.initrd
POOL=$W/vdw.img
qemu window -device virtio-serial-pci -chardev socket,id=rr,path=$W/rw.sock,server=on,wait=off \
	-device virtserialport,chardev=rr,name=glassine.ramread &
qpid=$!
client window $W/rw.sock $W/vdw.img $W/window.log
if wait $qpid; then ok "window: the guest ended by itself"; else bad "window: qemu exit (timeout or failure)"; fi
qtest window
grep -aq 'glassine-ramread: deploy: unmounted /run/o x after the tool' $W/window.log && ok "window: the overlay (a mount point with a space) unmounted" \
	|| bad "window: the overlay was not unmounted by its name"
grep -aq 'glassine-ramread: deploy: unmounted /run/b after the tool' $W/window.log && ok "window: the bind unmounted" || bad "window: the bind unmounted"
[ "$(sha $W/vda.img)" = "$A0" ] && [ "$(sha $W/vdb.img)" = "$B0" ] && ok "window: vda.img and vdb.img unchanged" || bad "window: vda.img or vdb.img changed"

# --- console: the menu on hvc0 ------------------------------------------------------
testcpio console "$common
RAMENV_TRANSPORT=stream
RAMENV_STREAM=/dev/ramread-stream
RECOVERY_IDLE=30
RECOVERY_TTYS=hvc0"
POOL=$W/vdc.img
qemu console -device virtio-serial-pci -chardev socket,id=rr,path=$W/rc.sock,server=on,wait=off \
	-device virtserialport,chardev=rr,name=glassine.ramread \
	-chardev socket,id=con,path=$W/con.sock,server=on,wait=off -device virtconsole,chardev=con &
qpid=$!
client console $W/con.sock
t1=$(date +%s)
if wait $qpid; then ok "console: the guest ended by itself ($(($(date +%s) - t1)) s after the last key, idle 30 s)"; else bad "console: qemu exit (timeout or failure)"; fi
qtest console
grep -aq 'glassine-ramread: no request for [0-9]* s: rebooting' $W/console.log && ok "console: the idle time restarted it" || bad "console: the idle time restarted it"
grep -aq 'glassine-ramread: deploy: rollback [0-9a-f]\{8\} confirmed (local connection)' $W/console.log && ok "console: the rollback came over the local connection" || bad "console: the rollback came over the local connection"

# --- screen: the touch client against the core -------------------------------------
# the device data seed: the waveform is made up (its length at offset 4, as the start
# script and epd-sink check); nothing on the device's own seed is used
D=$W/seed; mkdir -p $D/glassine
python3 -c 'import os, struct, sys; b = bytearray(os.urandom(8192)); b[4:8] = struct.pack("<I", len(b)); sys.stdout.buffer.write(b)' > $D/glassine/waveform.wbf
printf 'format=1\nwaveform.wbf test %s\n' "$(sha $D/glassine/waveform.wbf)" > $D/glassine/manifest
truncate -s 16M $W/seed-fs.img
mke2fs -q -t ext4 -d $D $W/seed-fs.img
truncate -s 32M $W/vdd.img
sgdisk -o -n 1:2048:+16M -c 1:vendor_b $W/vdd.img > /dev/null
dd if=$W/seed-fs.img of=$W/vdd.img bs=512 seek=2048 conv=notrunc status=none
cp $W/pool.img $W/vds.img
D0=$(sha $W/vdd.img)
testcpio screen "$common
RAMENV_TRANSPORT=stream
RAMENV_STREAM=/dev/ramread-stream
RECOVERY_IDLE=40
RECOVERY_SCREEN=epd
RECOVERY_DEVICE_LABEL=vendor_b
RECOVERY_SCREEN_STATE=/run/glassine-rscreen.state"
T=$W/t/screen; mkdir -p $T/sbin
cp /out/epd-sink $T/sbin/glassine-epdd
cp /out/screen-drive $T/lib/qtest/screen-drive
cp /src/test/screen/qemu.events $T/lib/qtest/screen.events
chmod 755 $T/sbin/glassine-epdd $T/lib/qtest/screen-drive
(cd $T && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet | gzip -n) > $W/t/screen.cpio.gz
cat /out/recovery.cpio.gz $W/t/screen.cpio.gz > $W/t/screen.initrd
POOL=$W/vds.img
t0=$(date +%s)
if qemu screen -drive file=$W/vdd.img,format=raw,if=virtio -device virtio-serial-pci \
	-chardev socket,id=rr,path=$W/rs.sock,server=on,wait=off -device virtserialport,chardev=rr,name=glassine.ramread
then ok "screen: the guest ended by itself ($(($(date +%s) - t0)) s)"; else bad "screen: qemu exit (timeout or failure)"; fi
qtest screen
grep -aq 'glassine-screen: waveform waveform.wbf from the seed on /dev/vdd1 (8192 bytes)' $W/screen.log \
	&& ok "screen: the start script read the waveform from the seed (debugfs, sha256 checked)" || bad "screen: the waveform from the seed"
grep -aq 'QTEST info screen-drive: the script ended (0 failed)' $W/screen.log && ok "screen: screen-drive ran its whole script" \
	|| bad "screen: screen-drive did not finish its script"
n=$(grep -ac 'glassine-ramread: deploy: .* confirmed (local connection)' $W/screen.log || :)
for a in select rollback reset; do
	grep -aq "glassine-ramread: deploy: $a [^ ]* \?[0-9a-f]\{8\} confirmed (local connection)" $W/screen.log \
		&& ok "screen: $a confirmed on the screen" || bad "screen: no confirmed $a"
done
[ "$n" = 3 ] && ok "screen: exactly 3 operations confirmed (cancels, early taps and holds confirmed nothing)" \
	|| bad "screen: $n operations confirmed, 3 expected"
grep -aq 'glassine-ramread: deploy: reset-full [0-9a-f]\{8\} confirmed' $W/screen.log && bad "screen: the cancelled full reset ran"
grep -aq 'glassine-ramread: no request for [0-9]* s: rebooting' $W/screen.log && ok "screen: the idle time restarted it" || bad "screen: the idle time restarted it"
grep -aq 'glassine-ramread: reboot (' $W/screen.log && bad "screen: a reboot was asked (the restart was cancelled)"
[ "$(sha $W/vdd.img)" = "$D0" ] && ok "screen: the seed disk vdd unchanged" || bad "screen: the seed disk vdd changed"
[ "$(sha $W/vda.img)" = "$A0" ] && [ "$(sha $W/vdb.img)" = "$B0" ] && ok "screen: vda.img and vdb.img unchanged" || bad "screen: vda.img or vdb.img changed"

# --- nothing else changed -----------------------------------------------------------
[ "$(sha $W/vda.img)" = "$A0" ] && [ "$(sha $W/vdb.img)" = "$B0" ] && ok "vda.img and vdb.img unchanged after all runs" || bad "vda.img or vdb.img changed"
grep -aq 'Trying to write to read-only block-device' $W/usb.log $W/deploy.log $W/console.log $W/screen.log && bad "a write reached a read-only block device" || ok "no write reached a read-only block device"
echo "qemu-recovery: $fails failed"
[ $fails = 0 ]
