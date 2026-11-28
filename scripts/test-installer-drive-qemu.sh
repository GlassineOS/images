#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The installer drive, started and installed from (specs/004-installer-drive FR-011): the
# drive image as a USB stick on a virtual PC (QEMU q35, OVMF) with a blank NVMe disk; the
# drive's session installs on that disk through the test hook (FR-012), and the disk then
# starts alone through the first start into the first deployment
# (scripts/test-installer-drive-qemu.py has the steps and what each checks).
#
#   scripts/test-installer-drive-qemu.sh (--drive IMAGE | RELEASE_DIR)
#   exit 0 = every QTEST check passed
#
# With RELEASE_DIR, scripts/installer-drive makes the drive first (in the test's work
# folder). The installer's QEMU harness comes from the commit pinned in
# scripts/test-pc-release-qemu.installer (scripts/installer-build.sh), the same commit the
# drive carries.
#
# What differs from a PC: the test writes the serial console and the hook into the
# session's set.rec on its copy of the drive, and the installed set gets the console
# (console_on); the disk is NVMe, the network none. Needs docker (privileged containers;
# /dev/kvm used when present; without it the run takes hours), git and python3. Works in
# .out/test-installer-drive-qemu/ (the logs are kept, the disks removed at the end).
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-installer-drive-qemu
ALPINE=$(sed -n 's/^ARG ALPINE=//p' "$P/Dockerfile" | head -n 1)
die() { echo "test-installer-drive-qemu: $*" >&2; exit 1; }
DRIVE=''
case "${1:-}" in
--drive) DRIVE=$(cd "$(dirname "$2")" && pwd)/$(basename "$2") ;;
-* | '') sed -n 's/^#   //p' "$0" >&2; exit 2 ;;
*) REL=$1 ;;
esac
mkdir -p "$O"
rm -rf "$O/work" "$O"/*.log
cleanup() { docker run --rm -v "$O":/o "$ALPINE" sh -c 'rm -rf /o/work /o/drive' >/dev/null 2>&1 || :; }
trap cleanup EXIT

if [ -z "$DRIVE" ]; then
	"$P/scripts/installer-drive" --out "$O/drive" "$REL" > "$O/installer-drive.log" 2>&1 \
		|| { cat "$O/installer-drive.log" >&2; die "installer-drive failed"; }
	DRIVE=$(sed -n 's/^installer-drive: image //p' "$O/installer-drive.log" | tail -n 1)
fi
[ -f "$DRIVE" ] || die "no drive image $DRIVE"
echo "drive: $DRIVE"
"$P/scripts/installer-build.sh" "$O" > "$O/installer-build.out" || die "the installer's build failed"
I=$(sed -n 's/^installer-build: checkout \([^ ]*\) .*/\1/p' "$O/installer-build.out")

KVM=''; [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] && KVM='--device /dev/kvm'
mkdir -p "$O/work"
rc=0
# shellcheck disable=SC2086  # KVM: one option and its value, or nothing
docker run --rm --privileged $KVM -e PYTHONDONTWRITEBYTECODE=1 \
	-e QTEST_ACCEPT_WAIT="${QTEST_ACCEPT_WAIT:-240}" -e QTEST_SESSION_TIMEOUT="${QTEST_SESSION_TIMEOUT:-5400}" \
	-v "$I":/i:ro -v "$DRIVE":/drive.img:ro -v "$P/scripts":/s:ro -v "$O":/o "$ALPINE" sh -c '
apk add -q --no-progress python3 qemu-system-x86_64 ovmf sgdisk dosfstools mtools \
	btrfs-progs e2fsprogs e2fsprogs-extra util-linux coreutils >/dev/null || exit 1
python3 /s/test-installer-drive-qemu.py --installer /i --drive /drive.img --work /o/work
' 2>&1 | tee "$O/qemu.log" || :
grep -q '^test-installer-drive-qemu: 0 failed' "$O/qemu.log" || rc=1
cp "$O"/work/*.log "$O/" 2>/dev/null || :
pass=$(grep -c '^QTEST ok' "$O/qemu.log" || :)
echo "test-installer-drive-qemu: $pass ok$( [ $rc = 0 ] || echo ', FAILED')"
[ $rc = 0 ]
