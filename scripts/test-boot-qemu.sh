#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The acceptance test of specs/002-base-boot-acceptance: a base built here boots as a
# deployment in QEMU (arm64 virt, emulated) and goes through the deployment lifecycle,
# with GlassineOS/boot's harness (test/qemu/test.sh --base) at the pinned BOOT_COMMIT.
#
#   1. Builds the generic reference base (DEVICE=example, the Dockerfile's chain up to
#      base-export) and, as the second base of Scenario 2 (FR-005), a build of the same
#      target with one added file. That file comes from a test stage appended to a copy
#      of the Dockerfile (qtest-second, FROM base-export), so no production stage
#      changes; the copy also holds the defective bases (below).
#   2. Materializes both into a test artifacts folder (scripts/materialize): the first
#      base gets a full stream, the second its delta against the first.
#   3. Runs boot's harness with the first base's full stream and the second base's delta:
#      every QTEST check of every boot must pass, and the agent must reach DONE.
#   4. Negative tests (SC-002): two bases with a defect, each of which must fail the
#      boot: one without the boot-success service (glassine-deploy-accept, a service a
#      deployment needs: its first boot is never accepted) and one whose fstab lists `/`
#      without `ro` (OpenRC remounts the deployment's root read-write). Both come from
#      test stages FROM finish, so the validation stage, which would refuse them, is
#      not in their chain: the boot test has to catch them by itself. Each runs one boot.
#
# What the guest runs: everything above the kernel is the base as built; the kernel and
# its modules are the harness's generic arm64 kernel (FR-003), the initramfs is the
# harness's build of boot. Nothing builds a kernel for the example device, so its
# kernel-side exports (modules, boot image, device tree, initramfs records) are
# placeholders made here, only so that materialize can write its records; their
# release is 0.0.0-qtest-placeholder. The example target's description is made here
# as well (.out/, never under targets/). The guest needs the network (QEMU user
# networking) for the live package and its replay.
#
#   scripts/test-boot-qemu.sh [--no-negative] [--negative-only]
#   exit 0 = the base passed and every defective base failed
#
# BOOT_CHECKOUT=DIR: a local GlassineOS/boot checkout instead of BOOT_COMMIT, to try a
# harness change before it is pinned. The pinned path is the default.
# QTEST_BOOT_TIMEOUT: seconds per boot (the harness's default: 900).
# Needs docker (buildx, privileged containers, arm64 emulation), python3 and git.
# Works in .out/test-boot-qemu/ under the checkout (kept for the logs).
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-boot-qemu
NEG=1 MAIN=1
case "${1:-}" in
--no-negative) NEG=0 ;;
--negative-only) MAIN=0 ;;
'') ;;
*) sed -n 's/^#   //p' "$0" >&2; exit 2 ;;
esac
T0=$(date +%s); t0=$T0
tick() { t0=$(date +%s); }
tock() { printf 'time %-34s %5d s\n' "$1" $(($(date +%s) - t0)); }
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
v() { sed -n "s/^$1=//p" "$2" | head -n 1; }
pin() { sed -n "s/^ARG $1=//p" "$P/Dockerfile" | head -n 1; }
BOOT_COMMIT=$(pin BOOT_COMMIT)
BOOT=$(pin BOOT)
SECOND=/usr/share/glassine-qtest/second

rm -rf "$O"; mkdir -p "$O"

# --- boot's harness: the pinned commit, or a local checkout -----------------------------
if [ -n "${BOOT_CHECKOUT:-}" ]; then
	H=$(cd "$BOOT_CHECKOUT" && pwd)
	echo "boot: local checkout $H at $(git -C "$H" rev-parse HEAD) (not the pinned $BOOT_COMMIT)"
else
	H=$O/boot
	git init -q "$H" && git -C "$H" fetch -q --depth=1 "$BOOT" "$BOOT_COMMIT" \
		&& git -C "$H" -c advice.detachedHead=false checkout -q FETCH_HEAD
	echo "boot: $BOOT_COMMIT (pinned)"
fi
if ! grep -q -- '--base FILE' "$H/test/qemu/test.sh" 2>/dev/null; then
	echo "test-boot-qemu: boot's test/qemu at this commit has no outside-base mode (test.sh --base);" >&2
	echo "  move BOOT_COMMIT to a commit that has it, or set BOOT_CHECKOUT to a checkout with it" >&2
	exit 1
fi

# --- the bases: the reference base, the second base, the defects ------------------------
# the Dockerfile with test stages appended (a copy; the production file is unchanged)
DF=$O/Dockerfile
{ cat "$P/Dockerfile"; cat <<EOF

# --- test-boot-qemu only ---------------------------------------------------------------
# The second base of Scenario 2: the same target's base with one added file (FR-005).
FROM base-export AS qtest-second
RUN mkdir -p ${SECOND%/*} && echo second > $SECOND
# Defects the boot must catch (SC-002). FROM finish: the validation stage would refuse
# them, and the boot test has to find them by itself.
FROM finish AS qtest-no-accept
RUN rm /etc/runlevels/default/glassine-deploy-accept
FROM finish AS qtest-rw-root
RUN echo 'overlay / overlay bind 0 0' > /etc/fstab
EOF
} > "$DF"
build() {	# build STAGE TAR (the copy's last stage is a test stage: always a --target)
	tick
	docker buildx build -q --platform linux/arm64 --build-arg DEVICE=example --target "$1" \
		-f "$DF" -o "type=tar,dest=$2" "$P" > "$O/build-$1.log" 2>&1 \
		|| { cat "$O/build-$1.log" >&2; echo "test-boot-qemu: the build of $1 failed" >&2; exit 1; }
	tock "build $1"
}
[ $MAIN = 0 ] || { build base-export "$O/base1.tar"; build qtest-second "$O/base2.tar"; }
[ $NEG = 0 ] || { build qtest-no-accept "$O/no-accept.tar"; build qtest-rw-root "$O/rw-root.tar"; }

# --- materialize: the example target and placeholder kernel-side exports ---------------
R=$O/repo; mkdir -p "$R/targets/example"
ln -s "$P/Dockerfile" "$R/Dockerfile"; ln -s "$P/stages" "$R/stages"
printf 'format=1\n# test-boot-qemu: the generic reference target; nothing builds its kernel\narch=arm64\nkernel=qtest-placeholder\n' \
	> "$R/targets/example/target"
REL=0.0.0-qtest-placeholder
K=$O/k; mkdir -p "$K/modules/$REL" "$K/boot/dtb" "$K/boot/initramfs" "$K/bootimg" "$K/select"
printf 'format=1\nrelease=%s\nprovides=\nfeatures=\n' $REL > "$K/modules/$REL/kernel.manifest"
DTB=example@0000000000000000; IRD=$(echo "$BOOT_COMMIT" | cut -c1-12)@0000000000000000; IMG=0000000000000000
echo placeholder > "$K/boot/dtb/$DTB.dtb"; printf 'format=1\ndevice=example\n' > "$K/boot/dtb/$DTB.manifest"
echo placeholder > "$K/boot/initramfs/$IRD.cpio.gz"
printf 'format=1\ncommit=%s\nneeds=\nfeatures=\n' "$BOOT_COMMIT" > "$K/boot/initramfs/$IRD.manifest"
echo placeholder > "$K/bootimg/$IMG.img"
printf 'format=1\nid=%s\ndevice=example\nkernel=%s\ndtb=%s\ninitramfs=%s\n' $IMG $REL $DTB $IRD > "$K/bootimg/$IMG.manifest"
printf 'format=1\ndevice=example\nkernel=%s\ndtb=%s\ninitramfs=%s\n' $REL $DTB $IRD > "$K/select/example"
clean=yes; [ -z "$(git -C "$P" status --porcelain --untracked-files=no)" ] || clean=no
printf 'images_commit=%s\nimages_clean=%s\n' "$(git -C "$P" rev-parse HEAD)" "$clean" > "$O/info"
mat() {	# mat TAR ARTIFACTS [OPTIONS]: materialize; waits while another one holds the host lock
	tar=$1 art=$2; shift 2
	tick
	n=0
	while :; do
		rc=0
		"$P/scripts/materialize" --repo "$R" --build-info "$O/info" "$@" "$tar" "$K" example "$art" \
			> "$O/materialize.log" 2>&1 || rc=$?
		[ $rc = 4 ] && [ $n -lt 360 ] || break
		[ $n != 0 ] || echo "materialize: another materialization holds the host lock; waiting"
		sleep 10; n=$((n + 1))
	done
	cat "$O/materialize.log" >> "$O/materialize-all.log"
	[ $rc = 0 ] || { cat "$O/materialize.log" >&2; echo "test-boot-qemu: materialize $tar failed (exit $rc)" >&2; exit 1; }
	grep -A3 '^materialize: build ' "$O/materialize.log" || :
	tock "materialize ${tar##*/}"
}
newest() { ls -d "$1"/example/builds/*/ | sort | tail -n 1; }

run() {	# run NAME [test.sh OPTIONS]: boot's harness, its exit code in $RC
	tick
	RC=0
	sh "$H/test/qemu/test.sh" "$@" "$O/run-$NAME" > "$O/run-$NAME.log" 2>&1 || RC=$?
	grep -a 'QTEST\|^time \|^qemu\|^stopping' "$O/run-$NAME.log" | sed 's/^/    /'
	tock "boot test $NAME"
}

if [ $MAIN = 1 ]; then
	A=$O/artifacts
	mat "$O/base1.tar" "$A" --no-parent
	M1=$(newest "$A")manifest
	mat "$O/base2.tar" "$A"
	M2=$(newest "$A")manifest
	check "the second base's parent is the first base, with a delta" \
		"[ \"\$(v parent '$M2')\" = \"\$(v base '$M1')\" ] && [ -s '$A/'\"\$(v delta '$M2')\" ]"
	echo "base 1 $(v base "$M1"), full stream $(du -h "$A/$(v stream "$M1")" | cut -f1)"
	echo "base 2 $(v base "$M2"), delta $(du -h "$A/$(v delta "$M2")" | cut -f1)"
	NAME=main; run --keep-going --base "$A/$(v stream "$M1")" --base2 "$A/$(v delta "$M2")" --base2-file "$SECOND"
	check "the base boots as a deployment and passes every scenario (boot's harness: exit 0, DONE)" "[ $RC = 0 ]"
fi
if [ $NEG = 1 ]; then
	A=$O/artifacts-no-accept; mat "$O/no-accept.tar" "$A" --no-parent; M=$(newest "$A")manifest
	NAME=no-accept; run --base "$A/$(v stream "$M")" --boots 1
	check "a base without the boot-success service fails: its first boot is not accepted" \
		"[ $RC != 0 ] && grep -aq 'QTEST FAIL d1 accepted by the boot-success step' '$O/run-no-accept.log'"
	A=$O/artifacts-rw-root; mat "$O/rw-root.tar" "$A" --no-parent; M=$(newest "$A")manifest
	NAME=rw-root; run --base "$A/$(v stream "$M")" --boots 1
	check "a base whose fstab leaves / writable fails: / is not read-only" \
		"[ $RC != 0 ] && grep -aq 'QTEST FAIL / is the overlay, read-only' '$O/run-rw-root.log'"
fi
t0=$T0; tock total
[ $fails = 0 ] && echo "test-boot-qemu: passed" || echo "test-boot-qemu: $fails FAIL"
[ $fails = 0 ]
