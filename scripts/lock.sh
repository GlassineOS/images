#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Refresh the locks: rebuild the whole chain from scratch with the comparison off, then
# record what each stage installed in stages/<stage>/lock.
#   scripts/lock.sh [DEVICE]          default: every device-* stage
# Needs docker buildx; builds linux/arm64 (natively on arm64, through QEMU elsewhere).
set -eu
cd "$(dirname "$0")/.."
devices=${1:-$(cd stages && ls -d device-* | sed 's/^device-//')}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
b() { docker buildx build -q --platform linux/arm64 --build-arg LOCK=refresh "$@" . >/dev/null; }
first=1
for d in $devices; do
	# one fresh build per device; the generic stages come from it, so they match
	if [ $first = 1 ]; then b --no-cache --target "device-$d"; first=0
	else b --no-cache-filter "device-$d" --target "device-$d"; fi
	for s in alpine glassine-common eink "device-$d"; do
		b --target "$s" -o "type=tar,dest=$tmp/$s.tar"
		tar -xOf "$tmp/$s.tar" lib/apk/db/installed \
			| awk -F: '/^P:/{p=$2} /^V:/{print p "=" $2}' | LC_ALL=C sort > "stages/$s/lock"
		echo "lock.sh: $s: $(wc -l < "stages/$s/lock") packages" >&2
	done
done
