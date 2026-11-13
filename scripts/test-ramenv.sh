#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The RAM environment's tests (docs/ramenv.md):
#   1. the unit test (ramenv/test/unit.c), built and run on this computer: the protocol
#      over a socket pair from a file, and the reader's read-only rules;
#   2. the ramenv stage as the Dockerfile builds it (--target ramenv, locks checked):
#      the production initramfs;
#   3. QEMU (arm64 virt, emulated): that initramfs on Debian's arm64 kernel, which has
#      the dummy USB host controller, with two disk images standing in for the eMMC.
#      The whole of each disk is read over the USB gadget (FunctionFS, inside the
#      guest) and over a virtio-serial stream (from outside), each checked against the
#      image's sha256; the images must be unchanged afterwards (ramenv/test/qemu-inner.sh).
# The device's own kernel, its USB controller and the boot loader's fastboot boot are not
# part of this test: only a device run shows those.
#
#   scripts/test-ramenv.sh [--unit-only]      exit 0 = all passed
#
# Needs a C compiler, docker (buildx, arm64 emulation) and the network (Alpine and
# Debian packages). Works in .out/test-ramenv/ (kept for the logs).
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-ramenv
rm -rf "$O"; mkdir -p "$O/kit"
NATIVE=$(docker version -f '{{.Server.Arch}}' 2>/dev/null || uname -m)
case $NATIVE in x86_64) NATIVE=amd64 ;; aarch64) NATIVE=arm64 ;; esac

echo "== unit"
${CC:-cc} -O2 -Wall -Wextra -Wno-unused-function -pthread -o "$O/unit" "$P/ramenv/test/unit.c"
timeout 300 "$O/unit"
[ "${1:-}" != --unit-only ] || exit 0

echo "== the ramenv stage (production initramfs)"
timeout 1800 docker buildx build -q --platform linux/arm64 --target ramenv -o "type=local,dest=$O/stage" "$P" > "$O/stage.log" 2>&1 \
	|| { cat "$O/stage.log" >&2; echo "test-ramenv: the ramenv stage failed" >&2; exit 1; }
set -- "$O"/stage/out/ramenv/*.cpio.gz
[ $# = 1 ] && [ -f "$1" ] || { echo "test-ramenv: expected one initramfs, found: $*" >&2; exit 1; }
cp "$1" "$O/kit/ramenv.cpio.gz"
echo "initramfs $(basename "$1"), $(stat -c %s "$1") bytes"

echo "== the guest kernel and the USB client"
# the containers run as root: what they write gets this user back (OWNER)
OWN="$(id -u):$(id -g)"
timeout 1800 docker run --rm --platform linux/arm64 -e OWNER="$OWN" -v "$P/ramenv/test/kit.sh:/run/kit.sh:ro" \
	-v "$O/kit:/out" debian:trixie sh /run/kit.sh
timeout 900 docker run --rm --platform linux/arm64 -v "$P/ramenv:/src:ro" -v "$O/kit:/out" alpine:3.24 sh -c \
	'apk add -q gcc musl-dev linux-headers >/dev/null && gcc -static -O2 -Wall -Werror -Wno-unused-function -pthread \
	-o /out/client-usb /src/test/client-usb.c && chown '"$OWN"' /out/client-usb'

echo "== QEMU"
timeout 2700 docker run --rm --platform "linux/$NATIVE" -e OWNER="$OWN" -v "$P/ramenv:/src:ro" -v "$O/kit:/out" alpine:3.24 sh /src/test/qemu-inner.sh
