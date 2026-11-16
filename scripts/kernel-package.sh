#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# A distribution kernel, installed as a package by the stage before (apk-stage.sh, at
# its locked version), as the tree kernel-export carries (GlassineOS/boot's
# docs/kernel-artifacts.md, "On the system partition"):
#
#   kernel-package.sh PACKAGE IMAGE      e.g. linux-lts /boot/vmlinuz-lts
#
# writes /out/modules/<release>/: the package's modules and depmod's files (as the
# package installed them), the kernel image as vmlinuz (the x86 EFI stub: firmware
# starts it as an application), firmware/, microcode/ when there is any, and
# kernel.manifest.
#
# firmware/ is what the stage's linux-firmware packages installed in /lib/firmware
# (decision 0016: firmware published for redistribution, as locked packages), with their
# licenses beside it: the files of /run/firmware-licenses (WHENCE and the license files,
# which the packages don't carry). FIRMWARE_TAG names the upstream tag those licenses
# are from; every installed linux-firmware package (and amd-ucode, built from the same
# source) must be that version, or the build fails. They move only with the kernel
# package (the release doesn't name them): scripts/lock.sh holds them otherwise and, when
# the kernel package moves, moves the tag with them (scripts/kernel-lock.sh); and
# scripts/kernel-release-check refuses a tree that differs under a published release.
# A package's symlinks become hard links to their targets
# (a kernel's tree holds only files and directories; hard links keep the size). Without
# firmware in /lib/firmware, firmware/ is empty and no licenses are needed.
# microcode/ holds the early microcode archives the packages installed in /boot
# (*-ucode.img: uncompressed cpio archives the kernel reads only when they come first in
# the initramfs; it loads microcode only early) and their licenses. Nothing puts them in
# front of an initramfs yet: that is the loader's.
#
# What differs from a kernel compiled here (scripts/kernel.sh): the release is the
# package's own (`uname -r`, e.g. 6.18.63-0-lts; Alpine's pkgrel is part of it, so two
# builds of the package don't share one), not <version>-<flavor>.<cfg6>-g<commit12>;
# source names the package and its version (source=alpine:<package>=<version>); the
# manifest has no builder, layout or config_sha256 (nothing here configures or
# compiles), and scripts/kernel-check, which checks a compiled arm64 kernel, doesn't
# apply. image_sha256, modules_sha256 (over the same lines as kernel.sh's, the image
# and firmware/ left out; microcode/ is in it), firmware (each file of firmware/ as
# name@sha256-16, sorted by bytes; a space in a name as %20, a % as %25), provides and features (empty) are as kernel.sh
# writes them.
set -eu
die() { echo "kernel-package.sh: $*" >&2; exit 1; }
[ $# = 2 ] || die "usage: kernel-package.sh PACKAGE IMAGE"
pkg=$1 img=$2
sha() { sha256sum "$1" | cut -c1-64; }
ver=$(apk info -e -v "$pkg" 2>/dev/null) || die "$pkg isn't installed"
ver=${ver#"$pkg"-}
[ -f "$img" ] || die "$pkg installed no $img"
rel=$(ls /lib/modules)
[ "$(echo "$rel" | wc -l)" = 1 ] && [ -n "$rel" ] || die "expected one /lib/modules/<release>, found: $(echo $rel)"
# the image says which release it is (the x86 boot protocol's version string)
grep -aq "$rel " "$img" || die "$img doesn't name the release $rel"
o=/out/modules/$rel
rm -rf /out
mkdir -p "$o/firmware"
cp -a "/lib/modules/$rel/." "$o/"
rm -f "$o/build" "$o/source"
cp "$img" "$o/vmlinuz"
# the firmware, its licenses and the version check
if [ -n "$(find /lib/firmware -mindepth 1 ! -type d 2>/dev/null | head -n 1)" ]; then
	[ -n "${FIRMWARE_TAG:-}" ] || die "/lib/firmware holds firmware, but no FIRMWARE_TAG names its licenses' tag"
	[ -f /run/firmware-licenses/WHENCE ] || die "/lib/firmware holds firmware, but /run/firmware-licenses has no WHENCE"
	bad=$(apk info -e -v $(apk info | grep -e '^linux-firmware-' -e '^amd-ucode$') 2>/dev/null \
		| while read -r pv; do
			v=${pv#"${pv%-*-r*}"-}
			case $v in "$FIRMWARE_TAG"-r*) ;; *) echo "$pv" ;; esac
		done)
	[ -z "$bad" ] || die "linux-firmware packages that aren't version $FIRMWARE_TAG (the licenses' tag; they move only with the kernel package, and scripts/lock.sh moves LINUX_FIRMWARE_TAG and LINUX_FIRMWARE_TAG_COMMIT with them): $(echo $bad)"
	cp -a /lib/firmware/. "$o/firmware/"
	find "$o/firmware" -type l | while IFS= read -r l; do
		t=$(readlink -f "$l") || die "${l#"$o/"}: a symlink that doesn't resolve"
		case $t in "$o/firmware/"*) ;; *) die "${l#"$o/"}: a symlink out of firmware/ ($(readlink "$l"))" ;; esac
		[ -f "$t" ] && [ ! -L "$t" ] || die "${l#"$o/"}: a symlink to no file ($(readlink "$l"))"
		ln -f "$t" "$l"
	done
	for f in /run/firmware-licenses/*; do
		[ ! -e "$o/firmware/${f##*/}" ] || die "a license and a firmware file share the name ${f##*/}"
		cp "$f" "$o/firmware/"
	done
fi
for u in /boot/*-ucode.img; do
	[ -f "$u" ] || continue
	mkdir -p "$o/microcode"
	cp "$u" "$o/microcode/"
	n=${u##*/}; n=${n%.img}
	if [ -f "/usr/share/licenses/$n/LICENSE" ]; then cp "/usr/share/licenses/$n/LICENSE" "$o/microcode/LICENSE.$n"
	elif [ -f "/run/firmware-licenses/LICENSE.$n" ]; then cp "/run/firmware-licenses/LICENSE.$n" "$o/microcode/"
	else die "$u: no license (neither /usr/share/licenses/$n/LICENSE nor a LICENSE.$n among the firmware licenses)"; fi
done
[ -z "$(find "$o" ! -type f ! -type d)" ] \
	|| die "modules/$rel has entries that are neither files nor directories: $(find "$o" ! -type f ! -type d | head -n 3)"
ms=$(cd "$o" && find . -path ./firmware -prune -o -type f ! -path ./vmlinuz -print \
	| sed 's|^\./||' | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(sha "$f")"; done \
	| sha256sum | cut -c1-64)
# firmware this kernel carries, by the names drivers request: name@sha256-16, names
# relative to firmware/, sorted by bytes (as kernel.sh writes it). The list is separated
# by spaces, and a few names have spaces (brcmfmac's board files, named after the
# machine): a space in a name is written %20, a % as %25
tab=$(printf '\t') nl=$(printf '\nx'); nl=${nl%x}
[ -z "$(find "$o/firmware" -name "*$tab*" -o -name "*$nl*")" ] || die "firmware/ has a name with a tab or a newline"
fw=$(cd "$o/firmware" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
	printf '%s@%s\n' "$(printf '%s' "$f" | sed 's/%/%25/g; s/ /%20/g')" "$(sha "$f" | cut -c1-16)"; done \
	| tr '\n' ' ' | sed 's/ $//')
cat > "$o/kernel.manifest" <<EOF
format=1
release=$rel
source=alpine:$pkg=$ver
image=vmlinuz
image_sha256=$(sha "$o/vmlinuz")
modules_sha256=$ms
firmware=$fw
provides=
features=
EOF
chmod -R u+rwX,go+rX,go-w /out
find /out -exec touch -h -d @0 {} +
echo "kernel-package.sh: $rel: $(find "$o" -name '*.ko*' | wc -l) modules, vmlinuz $(stat -c %s "$o/vmlinuz") bytes," \
	"firmware/ $(find "$o/firmware" -type f | wc -l) files, $(du -sm "$o/firmware" | cut -f1) MiB," \
	"microcode/ $(ls "$o/microcode" 2>/dev/null | tr '\n' ' ')"
grep -v '^firmware=' "$o/kernel.manifest"
