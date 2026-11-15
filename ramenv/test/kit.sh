#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The QEMU test's guest kernel (test-ramenv.sh): Debian's arm64 kernel, because it has
# the dummy USB host controller (dummy_hcd), which lets the gadget and a USB client run
# in one guest; the device's own kernel only runs on the device. Runs in an arm64
# debian:trixie container with /out mounted. Writes /out/Image and /out/mods/ (the
# modules the test loads, uncompressed, with load.list in load order).
set -eu
O=/out
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends kmod xz-utils zstd >/dev/null
pkg=$(apt-cache depends linux-image-arm64 | sed -n 's/.*Depends: \(linux-image-[0-9][^ ]*\).*/\1/p' | head -n 1)
[ -n "$pkg" ] || { echo "kit.sh: no linux-image package for linux-image-arm64" >&2; exit 1; }
cd /tmp
apt-get download -qq "$pkg"
dpkg-deb -x ./*.deb /tmp/k
# merged /usr: the modules are under usr/lib/modules; Debian runs depmod at install
[ -d /tmp/k/lib/modules ] || { mkdir -p /tmp/k/lib && ln -s ../usr/lib/modules /tmp/k/lib/modules; }
rel=$(ls /tmp/k/lib/modules)
depmod -b /tmp/k "$rel"
cp /tmp/k/boot/vmlinuz-"$rel" $O/Image
rm -rf $O/mods; mkdir -p $O/mods
# load.list: the RAM environment's runs; load-recovery.list: the recovery's, which also
# need the file systems glassine-deploy mounts, the USB serial function (and the host's
# cdc_acm, to read it inside the guest), a virtio console for the menu, and evdev and
# uinput for the screen run (screen-drive's touchscreen and power key)
mods() {	# mods LIST MODULE...: the modules and what they depend on, in load order
	l=$1; shift
	: > $O/mods/$l
	for m in "$@"; do
		modprobe -d /tmp/k -S "$rel" --show-depends $m | sed -n 's/^insmod \([^ ]*\).*/\1/p'
	done | awk '!seen[$0]++' | while read -r k; do
		b=${k##*/}; b=${b%.xz}; b=${b%.zst}; b=${b%.gz}
		[ -f $O/mods/$b ] || case $k in *.xz) xz -dc "$k" ;; *.zst) zstd -qdc "$k" ;; *.gz) gzip -dc "$k" ;; *) cat "$k" ;; esac > $O/mods/$b
		echo "$b" >> $O/mods/$l
	done
}
base="virtio_blk configfs usbcore udc_core libcomposite dummy_hcd usb_f_fs i6300esb sdhci_pci mmc_block"
mods load.list $base
mods load-recovery.list $base ext4 btrfs overlay usb_f_acm cdc_acm virtio_console evdev uinput
[ -z "${OWNER:-}" ] || chown -R "$OWNER" $O/Image $O/mods
echo "kit.sh: $pkg ($rel), modules: $(tr '\n' ' ' < $O/mods/load.list); recovery: $(tr '\n' ' ' < $O/mods/load-recovery.list)"
