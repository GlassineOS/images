#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Inside the QEMU guest (qemu-inner.sh), next to the production init: once the reader
# is serving, every disk and partition must be read-only in the kernel and a write to
# any of them must fail. In the usb run, client-usb then reads everything over the
# dummy USB host controller and reboots the guest. Prints QTEST lines.
B=/bin/busybox
i=0
while [ ! -e /run/ramread.ready ]; do
	$B sleep 1; i=$((i + 1))
	[ $i -lt 120 ] || { echo "QTEST FAIL the reader never got ready"; exit 1; }
done
echo "QTEST info partitions: $($B awk 'NR > 2 { printf "%s ", $4 }' /proc/partitions)"
# every block device of the disks (whole disks and partitions), from the kernel's list
for x in $($B awk 'NR > 2 && $4 ~ /^vd/ { print $4 }' /proc/partitions); do
	r=$($B blockdev --getro /dev/$x 2>&1)
	if [ "$r" = 1 ]; then echo "QTEST ok   /dev/$x is read-only in the kernel"
	else echo "QTEST FAIL /dev/$x is read-only in the kernel (getro: $r)"; fi
done
for x in vda vda1 vda2 vdb; do
	[ -b /dev/$x ] || { echo "QTEST FAIL no block device /dev/$x"; continue; }
	if $B dd if=/dev/zero of=/dev/$x bs=512 count=1 seek=40 conv=notrunc,fsync 2>/tmp/dd; then
		echo "QTEST FAIL a write to /dev/$x succeeded"
	else echo "QTEST ok   a write to /dev/$x fails ($($B head -n 1 /tmp/dd))"; fi
done
. /etc/glassine/ramenv.conf
[ "$RAMENV_TRANSPORT" = usb ] || exit 0

# the gadget's vendor interface (ff/47/52), as the host side of dummy_hcd sees it
i=0 itf=
while [ -z "$itf" ]; do
	for f in /sys/bus/usb/devices/*:*; do
		[ "$($B cat $f/bInterfaceClass 2>/dev/null)$($B cat $f/bInterfaceSubClass 2>/dev/null)$($B cat $f/bInterfaceProtocol 2>/dev/null)" = ff4752 ] && itf=$f
	done
	[ -n "$itf" ] && break
	$B sleep 1; i=$((i + 1))
	[ $i -lt 60 ] || { echo "QTEST FAIL no USB interface ff/47/52 after 60 s"; exit 1; }
done
dev=${itf%:*}
node=/dev/bus/usb/$($B printf %03d "$($B cat $dev/busnum)")/$($B printf %03d "$($B cat $dev/devnum)")
echo "QTEST ok   the vendor interface ff/47/52 at $node ($($B cat $dev/idVendor):$($B cat $dev/idProduct), $($B cat $dev/speed) Mb/s)"
in= out=
for e in $itf/ep_*; do
	[ "$($B cat $e/type)" = Bulk ] || continue
	case $($B cat $e/direction) in in) in=0x$($B cat $e/bEndpointAddress) ;; out) out=0x$($B cat $e/bEndpointAddress) ;; esac
done
exec /lib/qtest/client-usb "$node" "$($B cat $itf/bInterfaceNumber)" "$in" "$out"
