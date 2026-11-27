#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The static glassine-install of GlassineOS/installer at the commit pinned in
# scripts/test-pc-release-qemu.installer (or the checkout INSTALLER_CHECKOUT=DIR names),
# built in the Rust image the installer's own Dockerfile starts from, for the Linux musl
# target. Used by scripts/test-pc-release-qemu.sh and scripts/installer-drive.
#
#   scripts/installer-build.sh WORKDIR
#
# Clones the installer into WORKDIR/installer (kept, fetched again only for a commit it
# lacks) unless INSTALLER_CHECKOUT is set, builds it, and prints two lines last:
#   installer-build: checkout <dir> <commit>
#   installer-build: binary <file>
# The build log is WORKDIR/installer-build.log. Needs docker and git.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "installer-build: $*" >&2; exit 1; }
[ $# = 1 ] && [ "${1#-}" = "$1" ] || { sed -n 's/^#   //p' "$0" >&2; exit 2; }
mkdir -p "$1"; O=$(cd "$1" && pwd)
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
RUST=$(sed -n 's/^FROM \(rust:[^ ]*\).*/\1/p' "$I/Dockerfile" | head -n 1)
[ -n "$RUST" ] || die "$I/Dockerfile: no rust image"
docker run --rm -e CARGO_HOME=/w/.cargo-home -e "OWNER=$(id -u):$(id -g)" -v "$I":/w -w /w "$RUST" sh -c \
	'apk add -q musl-dev; rc=0; cargo build -q --release -p glassine-install || rc=$?; chown -R "$OWNER" target .cargo-home; exit $rc' \
	> "$O/installer-build.log" 2>&1 || { tail -30 "$O/installer-build.log" >&2; die "the installer's build failed"; }
B=$I/target/release/glassine-install
[ -x "$B" ] || die "no $B"
echo "installer-build: checkout $I $(git -C "$I" rev-parse HEAD)"
echo "installer-build: binary $B"
