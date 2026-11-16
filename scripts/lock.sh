#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Refresh the locks: rebuild the whole chain from scratch with the comparison off, then
# record what each stage installed in its lock file.
#   scripts/lock.sh [--arch ARCH] [DEVICE...]
# ARCH: aarch64 (default; the locks are stages/<stage>/lock, built for linux/arm64) or
# x86_64 (stages/<stage>/lock.x86_64, built for linux/amd64). Each architecture is
# refreshed on its own: a stage built for both has both files.
# DEVICE: default every device-* stage that has this architecture's lock, and, for
# aarch64, every device-* stage with no lock at all (a new device on another
# architecture is named here once). A device's chain is its FROM line back to the Alpine
# image (device-onyx-noteair: alpine, glassine-common, eink, device-onyx-noteair).
# x86_64 also applies the kernel package's rule (scripts/kernel-lock.sh): kernel-lts's
# firmware and microcode keep their locked versions unless linux-lts moves, and when it
# moves, LINUX_FIRMWARE_TAG and LINUX_FIRMWARE_TAG_COMMIT in the Dockerfile follow them.
# Needs docker buildx; builds natively on that architecture, through QEMU elsewhere.
set -eu
cd "$(dirname "$0")/.."
arch=aarch64
[ "${1:-}" != --arch ] || { arch=${2:?lock.sh: --arch needs aarch64 or x86_64}; shift 2; }
case $arch in
aarch64) plat=linux/arm64 lf=lock extra="initramfs ramenv recovery" ;;
x86_64) plat=linux/amd64 lf=lock.x86_64 extra="initramfs kernel-lts" ;;
*) echo "lock.sh: unknown architecture $arch (aarch64, x86_64)" >&2; exit 2 ;;
esac
if [ $# -gt 0 ]; then devices=$*
else
	devices=$(cd stages && for d in device-*; do
		if [ -f "$d/$lf" ]; then echo "${d#device-}"
		elif [ $arch = aarch64 ] && ! ls "$d"/lock* >/dev/null 2>&1; then echo "${d#device-}"; fi
	done)
fi
[ -n "$devices" ] || { echo "lock.sh: no device stage for $arch" >&2; exit 1; }
# chain STAGE: the stages STAGE is built on, first to last (FROM <stage> AS <stage>)
chain() {
	s=$1 c=$1
	while p=$(sed -n "s/^FROM \([^ ]*\) AS $s\$/\1/p" Dockerfile | head -n 1) && [ -n "$p" ] \
		&& grep -q "^FROM [^ ]* AS $p\$" Dockerfile; do
		c="$p $c" s=$p
	done
	echo "$c"
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# the kernel package's lock before the refresh: its firmware and microcode keep their
# versions unless the kernel package moves (scripts/kernel-lock.sh)
kl=stages/kernel-lts/$lf
[ $arch != x86_64 ] || [ ! -f "$kl" ] || cp "$kl" "$tmp/kernel-lts.old"
b() { docker buildx build -q --platform $plat --build-arg LOCK=refresh "$@" . >/dev/null; }
record() {	# record STAGE: its installed set from the tar export into its lock file
	tar -xOf "$tmp/$1.tar" lib/apk/db/installed \
		| awk -F: '/^P:/{p=$2} /^V:/{print p "=" $2}' | LC_ALL=C sort > "stages/$1/$lf"
	echo "lock.sh: $1: $(wc -l < "stages/$1/$lf") packages ($arch)" >&2
}
first=1
for d in $devices; do
	# one fresh build per device; the generic stages come from it, so they match
	if [ $first = 1 ]; then b --no-cache --target "device-$d"; first=0
	else b --no-cache-filter "device-$d" --target "device-$d"; fi
	for s in $(chain "device-$d"); do
		b --target "$s" -o "type=tar,dest=$tmp/$s.tar"
		record "$s"
	done
done
# the stages apart from the device chain, each on its own: the initramfs's tools, the
# RAM environment's and the recovery's (docs/recovery.md; their packages install before
# anything device-specific, so the first device's build stands for all), the kernel
# package
for s in $extra; do
	b --no-cache-filter "$s" --target "$s" -o "type=tar,dest=$tmp/$s.tar"
	record "$s"
done
# x86-64: the kernel package's firmware and microcode move only with it (GlassineOS/boot's
# docs/kernel-artifacts.md, "A distribution's kernel"); when it moves, the licenses' tag
# in the Dockerfile moves with them
if [ $arch = x86_64 ]; then
	sh scripts/kernel-lock.sh hold "$tmp/kernel-lts.old" "$kl" >&2
	sh scripts/kernel-lock.sh tag "$kl" Dockerfile >&2
fi
