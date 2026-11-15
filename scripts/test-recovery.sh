#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The recovery's tests (docs/recovery.md):
#   1. unit, on this computer: ramenv/test/unit.c built for the recovery (versions 1
#      and 2 unchanged) and ramenv/test/unit-recovery.c (version 3);
#   2. the recovery stage as the Dockerfile builds it (--target recovery, locks
#      checked): the production initramfs;
#   3. QEMU (arm64 virt, emulated), test-ramenv's guest kernel: the usb, deploy and
#      console runs of ramenv/test/qemu-recovery.sh.
# The device's own kernel, its USB controller, the boot loader's recovery path and the
# screen are not part of this test.
#
#   scripts/test-recovery.sh [--unit-only]      exit 0 = all passed
#
# Needs a C compiler, docker (buildx, arm64 emulation) and the network. Works in
# .out/test-recovery/ (kept for the logs).
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-recovery
rm -rf "$O"; mkdir -p "$O/kit"
NATIVE=$(docker version -f '{{.Server.Arch}}' 2>/dev/null || uname -m)
case $NATIVE in x86_64) NATIVE=amd64 ;; aarch64) NATIVE=arm64 ;; esac

echo "== unit (versions 1 and 2 in the recovery build)"
${CC:-cc} -DGLASSINE_RECOVERY -O2 -Wall -Wextra -Wno-unused-function -pthread -o "$O/unit" "$P/ramenv/test/unit.c"
timeout 300 "$O/unit"
echo "== unit (version 3)"
${CC:-cc} -DGLASSINE_RECOVERY -O2 -Wall -Wextra -Wno-unused-function -pthread -o "$O/unit-recovery" "$P/ramenv/test/unit-recovery.c"
timeout 300 "$O/unit-recovery"
[ "${1:-}" != --unit-only ] || exit 0

echo "== the recovery stage (production initramfs)"
timeout 2400 docker buildx build -q --platform linux/arm64 --target recovery -o "type=local,dest=$O/stage" "$P" > "$O/stage.log" 2>&1 \
	|| { cat "$O/stage.log" >&2; echo "test-recovery: the recovery stage failed" >&2; exit 1; }
set -- "$O"/stage/out/recovery/*.cpio.gz
[ $# = 1 ] && [ -f "$1" ] || { echo "test-recovery: expected one initramfs, found: $*" >&2; exit 1; }
cp "$1" "$O/kit/recovery.cpio.gz"
echo "initramfs $(basename "$1"), $(stat -c %s "$1") bytes"

echo "== the guest kernel and the USB client"
OWN="$(id -u):$(id -g)"
timeout 1800 docker run --rm --platform linux/arm64 -e OWNER="$OWN" -v "$P/ramenv/test/kit.sh:/run/kit.sh:ro" \
	-v "$O/kit:/out" debian:trixie sh /run/kit.sh
timeout 900 docker run --rm --platform linux/arm64 -v "$P/ramenv:/src:ro" -v "$O/kit:/out" alpine:3.24 sh -c \
	'apk add -q gcc musl-dev linux-headers >/dev/null && gcc -static -O2 -Wall -Werror -Wno-unused-function -pthread \
	-o /out/client-usb /src/test/client-usb.c && chown '"$OWN"' /out/client-usb'

echo "== QEMU"
timeout 3600 docker run --rm --platform "linux/$NATIVE" -e OWNER="$OWN" -v "$P/ramenv:/src:ro" -v "$O/kit:/out" alpine:3.24 sh /src/test/qemu-recovery.sh
