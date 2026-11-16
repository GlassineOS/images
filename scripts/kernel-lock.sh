#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The lock rule of a distribution's kernel (GlassineOS/boot's docs/kernel-artifacts.md,
# "A distribution's kernel"): its firmware and microcode move only together with the
# kernel package, so a tree never changes under one release. scripts/lock.sh runs both
# steps on stages/kernel-lts/lock.x86_64 after a refresh recorded it.
#
#   kernel-lock.sh hold OLD NEW
#       OLD: the lock before the refresh (may be missing: nothing to hold), NEW: the lock
#       the refresh recorded, rewritten in place. When the kernel package's version is
#       the same in both, every firmware and microcode package OLD names keeps OLD's
#       version in NEW. Prints "kernel moved OLD_VER NEW_VER", "kernel new NEW_VER" or
#       "kernel held VER", then per held package "held NAME LOCKED REFRESHED" and per
#       firmware package only one side names "added NAME=VER" / "dropped NAME=VER" (the
#       tree changes; the same-release check, scripts/kernel-release-check, refuses that
#       for a published release).
#   kernel-lock.sh tag LOCK [DOCKERFILE]
#       LOCK's linux-firmware version (every linux-firmware-* and amd-ucode: one
#       version, YYYYMMDD-rN) as the Dockerfile's LINUX_FIRMWARE_TAG and
#       LINUX_FIRMWARE_TAG_COMMIT (the tag's commit, from LINUX_FIRMWARE_GIT), and
#       checks the Raspberry Pi pins (RPI_BLUEZ_FIRMWARE, RPI_FIRMWARE_NONFREE) against
#       the commits Alpine's linux-firmware APKBUILD names. Fails, changing nothing,
#       when the version isn't a tag's form, upstream has no such tag, or a Raspberry Pi
#       pin differs (its URL and checksum need a hand); only warns when the APKBUILD
#       can't be read. DOCKERFILE defaults to ./Dockerfile.
#
# The packages: KERNEL_PACKAGE (linux-lts) and those whose names match FIRMWARE (every
# linux-firmware-*, amd-ucode, intel-ucode; dependencies such as linux-firmware-dell
# included). intel-ucode has a version of its own (Intel's release date), not the tag's.
# Environment for tests: LINUX_FIRMWARE_GIT (default the Dockerfile's), APKBUILD_URL
# (default aports' <branch>-stable main/linux-firmware/APKBUILD, branch from ALPINE).
set -eu
die() { echo "kernel-lock.sh: $*" >&2; exit 1; }
warn() { echo "kernel-lock.sh: warning: $*" >&2; }
KERNEL_PACKAGE=linux-lts
FIRMWARE='^(linux-firmware-.*|amd-ucode|intel-ucode)$'
ver() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1; }

hold() {
	old=$1 new=$2
	[ -f "$new" ] || die "no lock $new"
	kn=$(ver "$KERNEL_PACKAGE" "$new")
	[ -n "$kn" ] || die "$new names no $KERNEL_PACKAGE"
	ko=$(ver "$KERNEL_PACKAGE" "$old")
	if [ -z "$ko" ]; then echo "kernel new $kn"; return 0; fi
	# a new package revision is a move too: the release (uname -r) carries it
	if [ "$ko" != "$kn" ]; then echo "kernel moved $ko $kn"; return 0; fi
	echo "kernel held $kn"
	m=$(mktemp)
	awk -F= -v re="$FIRMWARE" '
		NR == FNR { if ($1 ~ re) o[$1] = $2; next }
		$1 ~ re && ($1 in o) {
			if (o[$1] != $2) print "held", $1, o[$1], $2 > "/dev/stderr"
			print $1 "=" o[$1]; seen[$1] = 1; next }
		$1 ~ re { print "added", $0 > "/dev/stderr" }
		{ print }
		END { for (p in o) if (!(p in seen)) print "dropped", p "=" o[p] > "/dev/stderr" }
	' "$old" "$new" 2> "$m.msg" | LC_ALL=C sort > "$m" || { rm -f "$m" "$m.msg"; die "merging $old and $new failed"; }
	LC_ALL=C sort "$m.msg"
	cat "$m" > "$new"
	rm -f "$m" "$m.msg"
}

tag() {
	lock=$1 df=${2:-Dockerfile}
	[ -f "$lock" ] || die "no lock $lock"
	[ -f "$df" ] || die "no $df"
	vs=$(awk -F= '$1 ~ /^linux-firmware-/ || $1 == "amd-ucode" { print $2 }' "$lock" | LC_ALL=C sort -u)
	[ -n "$vs" ] || { echo "firmware: none in $lock"; return 0; }
	[ "$(echo "$vs" | wc -l)" = 1 ] || die "$lock: the linux-firmware packages aren't one version ($(echo $vs)): they come from one source and move as one"
	echo "$vs" | grep -Eqx '[0-9]{8}-r[0-9]+' || die "$lock: linux-firmware $vs isn't of the form YYYYMMDD-rN (upstream's tag and Alpine's revision); set LINUX_FIRMWARE_TAG and LINUX_FIRMWARE_TAG_COMMIT by hand"
	t=${vs%-r*}
	one() { [ "$(grep -c "^ARG $1=" "$df")" = 1 ] || die "$df: expected one line ARG $1=, found $(grep -c "^ARG $1=" "$df")"; sed -n "s/^ARG $1=//p" "$df"; }
	cur=$(one LINUX_FIRMWARE_TAG) curc=$(one LINUX_FIRMWARE_TAG_COMMIT) git=$(one LINUX_FIRMWARE_GIT)
	git=${LINUX_FIRMWARE_GIT:-$git}
	if [ "$t" = "$cur" ]; then echo "firmware: tag $t (unchanged)"; return 0; fi
	# the tag's commit: an annotated tag's peeled line (^{}) when there is one
	refs=$(timeout 120 git ls-remote "$git" "refs/tags/$t" "refs/tags/$t^{}") \
		|| die "git ls-remote $git failed: can't resolve the tag $t"
	c=$(echo "$refs" | awk -v r="refs/tags/$t^{}" '$2 == r { print $1 }')
	[ -n "$c" ] || c=$(echo "$refs" | awk -v r="refs/tags/$t" '$2 == r { print $1 }')
	echo "$c" | grep -Eqx '[0-9a-f]{40}' \
		|| die "Alpine's linux-firmware $vs maps to no tag $t in $git; set LINUX_FIRMWARE_TAG and LINUX_FIRMWARE_TAG_COMMIT by hand"
	# the Raspberry Pi sources Alpine adds to brcm/ and cypress/, at its APKBUILD's commits
	alp=$(one ALPINE); br=${alp##*:}
	url=${APKBUILD_URL:-https://gitlab.alpinelinux.org/alpine/aports/-/raw/$br-stable/main/linux-firmware/APKBUILD}
	if ab=$(curl -fsS --max-time 60 "$url" 2>/dev/null); then
		apv=$(echo "$ab" | sed -n 's/^pkgver=//p')
		[ "$apv" = "$t" ] || warn "the APKBUILD ($url) is pkgver $apv, the lock $t: its Raspberry Pi commits may be another version's"
		for p in "RPI_BLUEZ_FIRMWARE _rpi_bt" "RPI_FIRMWARE_NONFREE _rpi_brcm"; do
			a=${p% *} v=${p#* }
			want=$(echo "$ab" | sed -n "s/^$v=//p")
			have=$(one "$a"); have=${have##*/}
			[ -n "$want" ] || { warn "the APKBUILD names no $v: check $a by hand"; continue; }
			[ "$want" = "$have" ] || die "linux-firmware $t: Alpine's APKBUILD pins $v=$want, the Dockerfile's $a is at $have; move $a and the checksum of its ADD --checksum line by hand (nothing changed)"
		done
	else
		warn "can't read $url: check RPI_BLUEZ_FIRMWARE and RPI_FIRMWARE_NONFREE against Alpine's linux-firmware APKBUILD by hand"
	fi
	sed -i "s|^ARG LINUX_FIRMWARE_TAG=.*|ARG LINUX_FIRMWARE_TAG=$t|; s|^ARG LINUX_FIRMWARE_TAG_COMMIT=.*|ARG LINUX_FIRMWARE_TAG_COMMIT=$c|" "$df"
	[ "$(one LINUX_FIRMWARE_TAG)" = "$t" ] && [ "$(one LINUX_FIRMWARE_TAG_COMMIT)" = "$c" ] || die "$df: rewriting the tag failed"
	echo "firmware: tag $cur ($curc) -> $t ($c)"
}

case ${1:-} in
hold) [ $# = 3 ] || die "usage: kernel-lock.sh hold OLD NEW"; hold "$2" "$3" ;;
tag) [ $# = 2 ] || [ $# = 3 ] || die "usage: kernel-lock.sh tag LOCK [DOCKERFILE]"; tag "$2" "${3:-Dockerfile}" ;;
*) die "usage: kernel-lock.sh hold OLD NEW | tag LOCK [DOCKERFILE]" ;;
esac
