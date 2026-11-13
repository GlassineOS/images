#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The QEMU part of test-ramenv.sh, inside an Alpine container of the build computer's
# own architecture. Mounts: /src the ramenv directory (read-only), /out the kit
# (Image, mods/, client-usb, ramenv.cpio.gz: the production initramfs as built).
#
# Two disk images stand in for the eMMC's user area (vda, 64 MiB with a GPT and two
# partitions) and a boot area (vdb, 4 MiB). The guest boots the production initramfs
# with a test archive appended: a shim that loads the test kernel's modules and then
# runs the production init, and a ramenv.conf for the run.
#   usb     the FunctionFS gadget on dummy_hcd, read inside the guest with client-usb
#           over usbfs; the client's reboot ends the run.
#   stream  the virtio-serial port, read from outside by client.py; the run ends by
#           the environment's own idle timeout.
#   connect nobody connects: the environment reboots after its connect wait.
#   wdreset a hash over a throttled disk outlasts the operation limit: the reader stops
#           petting and the i6300esb resets the guest.
# In both, test/check.sh checks inside the guest that every disk and partition is
# read-only in the kernel and that a write to each fails.
# Afterwards both images must be byte for byte what they were. Prints ok/FAIL lines.
set -eu
trap 'mkdir -p /out/logs; cp $W/*.log $W/stream.client /out/logs/ 2>/dev/null; [ -z "${OWNER:-}" ] || chown -R "$OWNER" /out/logs' EXIT
apk add -q qemu-system-aarch64 python3 sgdisk cpio gzip coreutils >/dev/null
W=/tmp/w; rm -rf $W; mkdir -p $W/prod $W/t
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# --- the disks ----------------------------------------------------------------------
head -c 64M /dev/urandom > $W/vda.img
sgdisk -o -n 1:2048:+16M -n 2:0:+16M $W/vda.img > /dev/null
[ "$(sgdisk -p $W/vda.img | grep -c '^ *[12] ')" = 2 ] || { echo "FAIL the test disk has no two partitions"; exit 1; }
head -c 4M /dev/urandom > $W/vdb.img
A0=$(sha256sum $W/vda.img | cut -c1-64) B0=$(sha256sum $W/vdb.img | cut -c1-64)

# --- the test archive ---------------------------------------------------------------
(cd $W/prod && zcat /out/ramenv.cpio.gz | cpio -id --quiet)
[ -x $W/prod/init ] && [ -x $W/prod/bin/glassine-ramread ] || { echo "FAIL the production initramfs has no init or reader"; exit 1; }
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
for m in $($B cat /lib/qtest/load.list); do $B insmod /lib/qtest/$m || echo "QTEST FAIL insmod $m"; done
[ -x /lib/qtest/check.sh ] && /lib/qtest/check.sh > /dev/console 2>&1 &
# the stream run's port, by its name (no udev here to make /dev/virtio-ports/NAME)
( for i in $($B seq 60); do
	for p in /sys/class/virtio-ports/*; do
		[ "$($B cat $p/name 2>/dev/null)" = glassine.ramread ] && { $B ln -s ${p##*/} /dev/ramread-stream; exit 0; }
	done
	$B sleep 0.5
done ) &
exec /init.ramenv
EOF
	chmod 755 $T/init
	cp /out/client-usb /src/test/check.sh $T/lib/qtest/
	chmod 755 $T/lib/qtest/check.sh $T/lib/qtest/client-usb
	(cd $T && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet | gzip -n) > $W/t/$1.cpio.gz
	cat /out/ramenv.cpio.gz $W/t/$1.cpio.gz > $W/t/$1.initrd
}
qemu() {	# qemu RUN [extra args]: the guest, its console to $W/RUN.log
	r=$1; shift
	timeout 900 qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 2 -m 1024 -nographic -no-reboot \
		-kernel /out/Image -initrd $W/t/$r.initrd \
		-append "console=ttyAMA0 loglevel=6 panic=5 rdinit=/init" \
		-drive file=$W/vda.img,format=raw,if=virtio -drive file=$W/vdb.img,format=raw,if=virtio \
		-device i6300esb -nic none "$@" > $W/$r.log 2>&1
}
qtest() {	# the guest's QTEST lines of a run, as ok/FAIL lines
	grep -a '^QTEST info' $W/$1.log | sed 's/\r$//; s/^QTEST //' || :
	grep -a '^QTEST \(ok\|FAIL\)' $W/$1.log | sed 's/\r$//; s/^QTEST //' > $W/$1.q || :
	while read -r l; do case $l in ok*) echo "$l [$1]" ;; *) echo "$l [$1]"; fails=$((fails + 1)) ;; esac; done < $W/$1.q
}
common='RAMENV_DISKS="vd[a-z]"
RAMENV_WATCHDOG=/dev/watchdog0
RAMENV_WATCHDOG_TIMEOUT=30
RAMENV_DISK_WAIT=30'

# --- usb: FunctionFS over dummy_hcd, read inside the guest --------------------------
testcpio usb "$common
RAMENV_TRANSPORT=usb
RAMENV_UDC=dummy_udc.0
RAMENV_UDC_WAIT=30
RAMENV_IDLE=300"
t0=$(date +%s)
if qemu usb; then ok "usb: the guest ended by itself ($(($(date +%s) - t0)) s)"; else bad "usb: qemu exit $? (timeout or failure)"; fi
qtest usb
grep -aq 'glassine-ramread: watchdog /dev/watchdog0 armed' $W/usb.log && ok "usb: the watchdog was armed" || bad "usb: the watchdog was armed"
grep -aq 'glassine-ramread: reboot (normal) asked by the computer' $W/usb.log && ok "usb: the reboot operation rebooted the guest" || bad "usb: the reboot operation rebooted the guest"
for d in vda:$A0 vdb:$B0; do
	n=${d%%:*} h=${d#*:}
	got=$(sed -n "s/^QTEST disk $n [0-9]* \([0-9a-f]*\).*/\1/p" $W/usb.log | head -n 1)
	[ "$got" = "$h" ] && ok "usb: $n read whole over USB, sha256 = the image's (${h%"${h#????????????????}"})" \
		|| bad "usb: $n read over USB has sha256 ${got:-none}, the image ${h}"
done

# --- stream: virtio-serial, read from outside ---------------------------------------
testcpio stream "$common
RAMENV_TRANSPORT=stream
RAMENV_STREAM=/dev/ramread-stream
RAMENV_IDLE=20"
t0=$(date +%s)
qemu stream -device virtio-serial-pci -chardev socket,id=rr,path=$W/rr.sock,server=on,wait=off \
	-device virtserialport,chardev=rr,name=glassine.ramread &
qpid=$!
c=0; python3 /src/test/client.py $W/rr.sock vda=$W/vda.img vdb=$W/vdb.img > $W/stream.client 2>&1 || c=$?
t1=$(date +%s)
sed 's/^QTEST //' $W/stream.client | while read -r l; do echo "$l [stream]"; done
! grep -q '^QTEST FAIL' $W/stream.client || fails=$((fails + 1))
[ $c = 0 ] || bad "stream: the client exited $c"
if wait $qpid; then
	t2=$(date +%s)
	[ $((t2 - t1)) -le 90 ] && ok "stream: rebooted by itself $((t2 - t1)) s after the last request (idle 20 s)" \
		|| bad "stream: the idle reboot took $((t2 - t1)) s"
else bad "stream: qemu exit (timeout or failure)"; fi
qtest stream
grep -aq 'glassine-ramread: no request for [0-9]* s: rebooting' $W/stream.log && ok "stream: the idle timeout rebooted it" || bad "stream: the idle timeout rebooted it"

# --- connect: nobody connects, the environment reboots after RAMENV_CONNECT_WAIT -----
testcpio connect "$common
RAMENV_TRANSPORT=stream
RAMENV_STREAM=/dev/ramread-stream
RAMENV_CONNECT_WAIT=15"
t0=$(date +%s)
if qemu connect -device virtio-serial-pci -chardev socket,id=rr,path=$W/rc.sock,server=on,wait=off \
	-device virtserialport,chardev=rr,name=glassine.ramread; then
	t1=$(date +%s)
	grep -aq 'glassine-ramread: no request for [0-9]* s: rebooting' $W/connect.log \
		&& ok "connect: with no computer it rebooted by itself ($((t1 - t0)) s after power on, connect wait 15 s)" \
		|| bad "connect: it ended without the connect-wait reboot"
else bad "connect: qemu exit (timeout or failure)"; fi
qtest connect

# --- wdreset: a disk read that hangs; the reader stops petting, the hardware resets ----
# vdb is throttled to 64 KiB/s, so hashing all of it (4 MiB) takes about a minute,
# longer than the operation limit (5 s) plus the watchdog's timeout (5 s). The guest must
# end by the i6300esb's reset, not by the reader's own reboot.
testcpio wdreset "$common
RAMENV_TRANSPORT=stream
RAMENV_STREAM=/dev/ramread-stream
RAMENV_WATCHDOG_TIMEOUT=5
RAMENV_OP_LIMIT=5"
t0=$(date +%s)
timeout 900 qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 2 -m 1024 -nographic -no-reboot \
	-kernel /out/Image -initrd $W/t/wdreset.initrd \
	-append "console=ttyAMA0 loglevel=6 panic=5 rdinit=/init" \
	-drive file=$W/vda.img,format=raw,if=virtio -drive file=$W/vdb.img,format=raw,if=virtio,bps_rd=65536 \
	-device i6300esb -nic none \
	-device virtio-serial-pci -chardev socket,id=rr,path=$W/rw.sock,server=on,wait=off \
	-device virtserialport,chardev=rr,name=glassine.ramread > $W/wdreset.log 2>&1 &
qpid=$!
c=0; python3 /src/test/client.py --hang-hash vdb $W/rw.sock > $W/wdreset.client 2>&1 || c=$?
t1=$(date +%s)
sed 's/^QTEST //' $W/wdreset.client | while read -r l; do echo "$l [wdreset]"; done
if wait $qpid; then
	t2=$(date +%s)
	grep -aq 'glassine-ramread: watchdog /dev/watchdog0 armed, 5 s' $W/wdreset.log && ok "wdreset: the watchdog was armed with 5 s" || bad "wdreset: the watchdog was armed with 5 s"
	grep -aq 'glassine-ramread: a disk operation has run [0-9]* s: no more petting' $W/wdreset.log \
		&& ok "wdreset: the reader stopped petting during the hung hash" || bad "wdreset: the reader stopped petting during the hung hash"
	grep -aq 'glassine-ramread: no request for\|glassine-ramread: reboot (' $W/wdreset.log \
		&& bad "wdreset: the reader rebooted by itself (the watchdog was not what ended it)" \
		|| ok "wdreset: the reader did not reboot by itself"
	[ $((t2 - t0)) -lt 55 ] && ok "wdreset: the hardware watchdog reset the guest mid-hash ($((t2 - t1)) s after the hash was sent, $((t2 - t0)) s after power on)" \
		|| bad "wdreset: the guest ended only after $((t2 - t0)) s (the hash would have finished: no watchdog reset)"
else bad "wdreset: qemu exit (timeout or failure)"; fi
[ $c = 0 ] || bad "wdreset: the client exited $c"
qtest wdreset

# --- nothing changed ----------------------------------------------------------------
[ "$(sha256sum $W/vda.img | cut -c1-64)" = "$A0" ] && ok "vda.img unchanged after all runs" || bad "vda.img changed"
[ "$(sha256sum $W/vdb.img | cut -c1-64)" = "$B0" ] && ok "vdb.img unchanged after all runs" || bad "vdb.img changed"
grep -aq 'Trying to write to read-only block-device' $W/usb.log $W/stream.log $W/connect.log $W/wdreset.log && bad "a write reached the block layer" || ok "no write reached the block layer"
echo "qemu-inner: $fails failed"
[ $fails = 0 ]
