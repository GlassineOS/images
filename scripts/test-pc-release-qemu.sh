#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# A PC release, installed and started: GlassineOS/installer (at the commit pinned in
# scripts/test-pc-release-qemu.installer, or INSTALLER_CHECKOUT=DIR) checks the release
# folder scripts/pc-release makes and installs it with `install --pc` on a blank virtual
# PC (QEMU q35, OVMF), whose disk then starts through the firmware's new boot entry, the
# release's loader (GlassineOS/loader, pinned in targets/uefi-pc/release.conf) and the
# installed kernel set, through the first start into the first deployment
# (scripts/test-pc-release-qemu.py has the steps and what each checks).
#
#   scripts/test-pc-release-qemu.sh [RELEASE_DIR]
#   exit 0 = every QTEST check passed
#
# Without RELEASE_DIR, scripts/pc-release makes one first (in the test's artifacts).
#
# What differs from a PC: the set's command line gets console=ttyS0 loglevel=7 on the
# installed disk (its check line and the loader record's sum made again), so Linux
# reaches the serial log. QTEST_DIRECT_KERNEL=1 starts the set with -kernel/-initrd
# instead (the path for a release without a boot-loader). The disk is NVMe, the
# network none.
#
# Besides the QEMU run, the host checks the release with the installer's own check and
# plan (--release) on its PC facts fixtures: the release's least sizes fit the
# description's partitions.
#
# Needs docker (privileged containers; /dev/kvm used when present), git and python3.
# Works in .out/test-pc-release-qemu/ (the logs are kept; the disks and the release
# made here are removed at the end, QTEST_KEEP=1 keeps them).
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-pc-release-qemu
ALPINE=$(sed -n 's/^ARG ALPINE=//p' "$P/Dockerfile" | head -n 1)
die() { echo "test-pc-release-qemu: $*" >&2; exit 1; }
case "${1:-}" in -*) sed -n 's/^#   //p' "$0" >&2; exit 2 ;; esac
mkdir -p "$O"
rm -rf "$O/work" "$O"/*.log
cleanup() {
	[ "${QTEST_KEEP:-}" = 1 ] && return
	docker run --rm -v "$O":/o "$ALPINE" sh -c 'rm -rf /o/work /o/artifacts' >/dev/null 2>&1 || :
}
trap cleanup EXIT

# --- the release
if [ -n "${1:-}" ]; then
	REL=$(cd "$1" && pwd)
else
	rm -rf "$O/artifacts"
	"$P/scripts/pc-release" --artifacts "$O/artifacts" --no-parent > "$O/pc-release.log" 2>&1 \
		|| { cat "$O/pc-release.log" >&2; die "pc-release failed"; }
	REL=$(sed -n 's/^pc-release: //p' "$O/pc-release.log" | tail -n 1)
fi
[ -f "$REL/release.json" ] || die "$REL: no release.json"
echo "release: $REL"

# --- the installer: the pinned commit, built static in its own toolchain's base image
INSTALLER_COMMIT=$(sed -n 's/^commit=//p' "$P/scripts/test-pc-release-qemu.installer")
if [ -n "${INSTALLER_CHECKOUT:-}" ]; then
	I=$(cd "$INSTALLER_CHECKOUT" && pwd)
else
	[ -n "$INSTALLER_COMMIT" ] || die "scripts/test-pc-release-qemu.installer: no commit="
	I=$O/installer
	[ -d "$I/.git" ] || git clone -q https://github.com/GlassineOS/installer "$I"
	git -C "$I" cat-file -e "$INSTALLER_COMMIT^{commit}" 2>/dev/null || git -C "$I" fetch -q origin "$INSTALLER_COMMIT"
	git -C "$I" checkout -q --detach "$INSTALLER_COMMIT"
fi
echo "installer: $(git -C "$I" rev-parse HEAD)"
RUST=$(sed -n 's/^FROM \(rust:[^ ]*\).*/\1/p' "$I/Dockerfile" | head -n 1)
[ -n "$RUST" ] || die "$I/Dockerfile: no rust image"
docker run --rm -e CARGO_HOME=/w/.cargo-home -e "OWNER=$(id -u):$(id -g)" -v "$I":/w -w /w "$RUST" sh -c \
	'apk add -q musl-dev; rc=0; cargo build -q --release -p glassine-install || rc=$?; chown -R "$OWNER" target .cargo-home; exit $rc' \
	> "$O/installer-build.log" 2>&1 || { tail -30 "$O/installer-build.log" >&2; die "the installer's build failed"; }
B=$I/target/release/glassine-install
[ -x "$B" ] || die "no $B"

# --- the host: the installer's check and plan read the release's least sizes
fail=0
for f in pc-two-disks pc-windows; do
	F=$I/core/tests/fixtures/facts/$f.json
	rc=0; "$B" check --facts "$F" --release "$REL/release.json" --json > "$O/check-$f.json" 2>"$O/check-$f.err" || rc=$?
	if [ $rc = 0 ]; then echo "QTEST ok host: check --facts $f --release: exit 0"
	else echo "QTEST FAIL host: check --facts $f --release: exit $rc ($(head -c 400 "$O/check-$f.err"))"; fail=1; fi
	rc=0; "$B" plan --dry-run --facts "$F" --release "$REL/release.json" --developer --json > "$O/plan-$f.json" 2>"$O/plan-$f.err" || rc=$?
	if [ $rc = 0 ]; then echo "QTEST ok host: plan --dry-run --facts $f --release: a plan (exit 0)"
	else echo "QTEST FAIL host: plan --dry-run --facts $f --release: exit $rc ($(head -c 400 "$O/plan-$f.err"))"; fail=1; fi
done

# --- the guest: QEMU in a container with the tools of the installer's harness
KVM=''; [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] && KVM='--device /dev/kvm'
mkdir -p "$O/work" "$O/cache"
# the build's initramfs manifests (step 5 puts the release's initramfs in the pool): the
# artifacts folder holding the release (ARTIFACTS/<target>/releases/<build>), else
# QTEST_INITRAMFS_DIR
IRD=${QTEST_INITRAMFS_DIR:-$REL/../../../boot/initramfs}
IRM=''; [ -d "$IRD" ] && IRM="-v $(cd "$IRD" && pwd):/m:ro"
rc=0
# shellcheck disable=SC2086  # KVM, IRM: one option and its value, or nothing
docker run --rm --privileged $KVM -e PYTHONDONTWRITEBYTECODE=1 -e QTEST_ACCEPT_WAIT="${QTEST_ACCEPT_WAIT:-240}" -e QTEST_DIRECT_KERNEL="${QTEST_DIRECT_KERNEL:-}" -e QTEST_LIMIT="${QTEST_LIMIT:-1}" \
	$IRM -v "$I":/i:ro -v "$REL":/r:ro -v "$P/scripts":/s:ro -v "$O":/o "$ALPINE" sh -c '
apk add -q --no-progress python3 qemu-system-x86_64 ovmf sgdisk dosfstools mtools squashfs-tools \
	btrfs-progs e2fsprogs e2fsprogs-extra util-linux coreutils >/dev/null || exit 1
python3 /s/test-pc-release-qemu.py --installer /i --binary /i/target/release/glassine-install --release /r \
	--work /o/work --cache /o/cache $([ -d /m ] && echo --initramfs-dir /m)
' 2>&1 | tee "$O/qemu.log" || :
grep -q '^test-pc-release-qemu: 0 failed' "$O/qemu.log" || rc=1
cp "$O"/work/*.log "$O/" 2>/dev/null || :
pass=$(grep -c '^QTEST ok' "$O/qemu.log" || :)
echo "test-pc-release-qemu: guest $pass ok$( [ $rc = 0 ] || echo ', FAILED'); host checks $( [ $fail = 0 ] && echo passed || echo FAILED)"
[ $rc = 0 ] && [ $fail = 0 ]
