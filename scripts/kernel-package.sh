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
# starts it as an EFI application), an empty firmware/ and kernel.manifest.
#
# What differs from a kernel compiled here (scripts/kernel.sh): the release is the
# package's own (`uname -r`, e.g. 6.18.63-0-lts; Alpine's pkgrel is part of it, so two
# builds of the package don't share one), not <version>-<flavor>.<cfg6>-g<commit12>;
# source names the package and its version (source=alpine:<package>=<version>); the
# manifest has no builder, layout or config_sha256 (nothing here configures or
# compiles), and scripts/kernel-check, which checks a compiled arm64 kernel, doesn't
# apply. image_sha256, modules_sha256 (over the same lines as kernel.sh's, the image
# left out), firmware (empty), provides and features (empty) are as kernel.sh writes
# them.
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
[ -z "$(find "$o" ! -type f ! -type d)" ] \
	|| die "modules/$rel has entries that are neither files nor directories: $(find "$o" ! -type f ! -type d | head -n 3)"
ms=$(cd "$o" && find . -path ./firmware -prune -o -type f ! -path ./vmlinuz -print \
	| sed 's|^\./||' | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(sha "$f")"; done \
	| sha256sum | cut -c1-64)
cat > "$o/kernel.manifest" <<EOF
format=1
release=$rel
source=alpine:$pkg=$ver
image=vmlinuz
image_sha256=$(sha "$o/vmlinuz")
modules_sha256=$ms
firmware=
provides=
features=
EOF
chmod -R u+rwX,go+rX,go-w /out
find /out -exec touch -h -d @0 {} +
echo "kernel-package.sh: $rel: $(find "$o" -name '*.ko*' | wc -l) modules, vmlinuz $(stat -c %s "$o/vmlinuz") bytes"
cat "$o/kernel.manifest"
