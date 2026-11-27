#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# How many earlier deployments a device keeps (GlassineOS/boot spec 007), read from its
# GlassineOS/installer description, for a device whose deploy.conf no package derives
# (the UEFI PC: the installer's glassine-device-files writes no deploy.conf.device for
# it). FR-002: the value comes from the description, never by hand.
#
#   keep-updates.sh DESCRIPTION                print the value
#   keep-updates.sh DESCRIPTION DEPLOY_CONF    append it to DEPLOY_CONF as KEEP_UPDATES
#
# The value is [data_partition] keep_updates, by the installer's rules (spec 002, format
# 5): absent is 1; anything but a whole number of 1 or more fails. It fails too when the
# description is older than format 5 (no keep_updates there: a pin to an older
# installer), names no [data_partition], or writes keep_updates in any form this reader
# doesn't take (a dotted key, an inline table, a string), and when DEPLOY_CONF already
# sets KEEP_UPDATES (the derived line is the only one). busybox awk: the build stage
# installs nothing for it.
set -eu
[ $# = 1 ] || [ $# = 2 ] || { echo "usage: keep-updates.sh DESCRIPTION [DEPLOY_CONF]" >&2; exit 2; }
desc=$1
die() { echo "keep-updates: $*" >&2; exit 1; }
[ -r "$desc" ] || die "$desc: can't read it"
keep=$(awk '
	function fail(m) { print FILENAME ":" NR ": " m > "/dev/stderr"; bad = 1; exit 1 }
	{ line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
	line ~ /^\[/ {
		h = line; sub(/[ \t]*#.*$/, "", h)
		if (h ~ /^\[[ \t]*data_partition[ \t]*\]$/) { if (seen) fail("[data_partition] twice"); seen = 1; in_dp = 1 }
		else in_dp = 0
		started = 1
		next
	}
	!started && line ~ /^format[ \t]*=/ {
		v = line; sub(/^format[ \t]*=[ \t]*/, "", v); sub(/[ \t]*#.*$/, "", v)
		if (v !~ /^[0-9]+$/) fail("format " v ": not a whole number")
		format = v + 0
		next
	}
	line ~ /^([A-Za-z0-9_."-]+[ \t]*\.[ \t]*)?"?keep_updates"?[ \t]*=/ {
		if (!in_dp || line !~ /^keep_updates[ \t]*=/) fail("keep_updates not as a plain key of [data_partition]: " line)
		v = line; sub(/^keep_updates[ \t]*=[ \t]*/, "", v); sub(/[ \t]*#.*$/, "", v)
		if (v !~ /^[1-9][0-9]*$/) fail("keep_updates " v ": not a whole number of 1 or more")
		if (keep != "") fail("keep_updates twice")
		keep = v
	}
	END {
		if (bad) exit 1
		if (format == "") { print FILENAME ": no format" > "/dev/stderr"; exit 1 }
		if (format < 5) { print FILENAME ": format " format ": older than 5, which brings keep_updates" > "/dev/stderr"; exit 1 }
		if (!seen) { print FILENAME ": no [data_partition]" > "/dev/stderr"; exit 1 }
		print (keep == "" ? 1 : keep)
	}' "$desc") || die "$desc: no keep_updates derived"
if [ $# = 1 ]; then
	echo "$keep"
	exit 0
fi
conf=$2
[ -w "$conf" ] || die "$conf: can't write it"
! grep -q '^[[:space:]]*KEEP_UPDATES=' "$conf" || die "$conf: already sets KEEP_UPDATES (the derived line is the only one)"
{
	echo "# how many earlier deployments the clean-up keeps (GlassineOS/boot spec 007): the"
	echo "# description's [data_partition] keep_updates, derived at the build from"
	echo "# GlassineOS/installer's $(basename "$desc") (scripts/keep-updates.sh): change the"
	echo "# description, never this line"
	echo "KEEP_UPDATES=$keep"
} >> "$conf"
echo "keep-updates: KEEP_UPDATES=$keep from $desc"
