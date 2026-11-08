#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The validation stage: what a base must not carry. Reads only.
set -eu
fail=0
no() { echo "validation: $*" >&2; fail=1; }
# plain names only, so live upgrades and package replay work
grep -q '[<>=~]' /etc/apk/world && no "pinned versions in /etc/apk/world: $(grep '[<>=~]' /etc/apk/world | tr '\n' ' ')"
# the package cache is a build cache mount, never part of the tree
[ -z "$(find /var/cache/apk -mindepth 1 -print -quit 2>/dev/null)" ] || no "package cache in the tree"
# each installation makes its own machine ID (GlassineOS/hub#19)
[ ! -s /etc/machine-id ] || no "/etc/machine-id is filled in"
[ ! -e /var/log/apk.log ] || no "apk's build log in the tree"
# no cache or log the build regenerates on every run (FR-021): the system builds its
# font cache at boot (glassine-font-cache)
[ -z "$(find /var/cache/fontconfig /root/.cache/fontconfig -mindepth 1 -print 2>/dev/null | head -n 1)" ] \
	|| no "a font cache in the tree"
# the package database matches the tree: every file a package installed is there,
# unchanged. apk-tools' own /sbin/apk: the apk on PATH is glassine-deploy's wrapper.
# --system leaves out protected paths (/etc), whose configuration a stage may change.
a=$(/sbin/apk audit --system 2>&1) || no "apk audit failed: $a"
[ -z "$a" ] || no "files that differ from the package database: $(echo "$a" | tr '\n' ' ')"
# and installing the world again changes nothing (from the installed packages alone, no
# index: the tree must satisfy its world on its own)
rc=0; a=$(/sbin/apk add --simulate --no-network --no-progress 2>&1) || rc=$?
o=$(echo "$a" | grep -v -e '^WARNING: opening from cache ' -e '^OK: ' || :)
[ $rc = 0 ] && [ -z "$o" ] || no "installing the world again would change the tree (exit $rc): $(echo "$o" | tr '\n' ' ')"
# kernel modules and firmware updates come with the kernel, outside the base
for d in /lib/modules /lib/firmware/updates; do
	[ -z "$(ls -A "$d" 2>/dev/null)" ] || no "$d isn't empty"
done
# the deployment's / stays a read-only bind (GlassineOS/boot's docs/boot.md,
# "Deployments layout"): fstab lists / with both bind and ro
awk '!/^[ \t]*#/ && $2 == "/" { n = split($4, o, ","); b = r = 0
	for (i = 1; i <= n; i++) { if (o[i] == "bind") b = 1; if (o[i] == "ro") r = 1 }
	if (b && r) f = 1 } END { exit !f }' /etc/fstab 2>/dev/null \
	|| no "/etc/fstab doesn't list / with bind,ro"
# what glassine-deploy receive needs to take in a base
for c in btrfs zstd; do
	command -v $c >/dev/null || no "$c isn't installed"
done
# nothing only a device may supply: waveforms, signed firmware, any firmware
# (scripts/device-files.c, bind-mounted by the Dockerfile; checks by contents)
if [ -x /run/device-files ]; then
	rc=0; /run/device-files / >&2 || rc=$?
	case $rc in
	0) ;;
	1) no "files only a device may supply (listed above)" ;;
	*) no "the device-file check couldn't read the whole tree (exit $rc, listed above)" ;;
	esac
else
	no "the device-file check is missing"
fi
# a device manager scans the hardware at sysinit (coldplug), so drivers built as modules
# load by their device's modalias
for s in udev udev-trigger; do
	[ -e /etc/runlevels/sysinit/$s ] || no "the device manager isn't enabled: no $s in sysinit"
done
# every enabled service has its script
for l in /etc/runlevels/*/*; do
	[ -e "$l" ] || [ ! -L "$l" ] || no "enabled service without a script: $l -> $(readlink "$l")"
done
exit $fail
