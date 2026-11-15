#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The install route's first start, end to end, in QEMU (arm64 virt, emulated): a real
# release made by scripts/pool-image is written to a virtual system_b the way the
# installer writes it, next to a userdata that holds another system's ext4, and the
# disk boots bare, as a device does after the install (GlassineOS/boot
# docs/deployments.md, "The first start"; spec 009).
#
#   1. Builds the generic reference base (DEVICE=example, the Dockerfile's chain up to
#      base-export) plus a test stage (a copy of the Dockerfile; no production stage
#      changes): the device facts the Note Air's tree must hold
#      (stages/device-onyx-noteair/expect: SYSTEM_DEV, USERDATA_DEV and
#      USERDATA_RESERVE_KIB, which validation checks on the Note Air's own tree)
#      appended to the example's deploy.conf, ACCEPT_AFTER=40, and what this VM needs
#      to accept a deployment (boot's test/qemu does the same in a deployment's layer;
#      a first deployment carries nothing, so here it is in the base): the session's
#      health check passes without a panel, Bluetooth refuses to start without the
#      kernel's support, and the agent (scripts/test-first-start-qemu-agent.sh).
#   2. The kernel side: Alpine's virt kernel and its modules (the export's release is
#      the virt kernel's, so the pool's modules/<release> is the one the guest runs),
#      the initramfs this repository exports (GlassineOS/boot at BOOT_COMMIT) with
#      the Note Air's board.conf appended as its packer does, and a shim archive that
#      loads virtio_blk, ext4, crc32c, btrfs and overlay first. The boot image is a placeholder
#      (nothing boots it).
#   3. scripts/materialize, then scripts/pool-image: the release folder.
#   4. The disk (scripts/test-first-start-qemu-container.sh disk): GPT, `userdata`
#      (1.5 GiB: another system's ext4, a file, the last USERDATA_RESERVE_KIB as its
#      footer) and `system_b` (release.json's min_partition_bytes, the size the
#      installer requires), the pool image written as bytes.
#   5. Boot 1, bare (the board's command line + skip_initramfs, as the boot loader
#      adds on a normal boot, + console): the first start must grow the pool, format
#      userdata, select the first deployment and reboot (QEMU -no-reboot exits). The
#      disk is checked from the host: the pool fills system_b, the marker is gone, a
#      candidate with 2 tries, state/kernel, userdata ext4 with 4096-byte blocks, no
#      orphan_file, ending USERDATA_RESERVE_KIB before the partition's end (the footer
#      untouched), nothing of the other system, both file systems clean.
#   6. Boot 2: the candidate boots, the agent waits for the boot-success step, checks
#      it is current and powers off; the disk is checked again.
#
#   scripts/test-first-start-qemu.sh
#   exit 0 = every QTEST check passed
#
# What differs from the device: the kernel (Alpine's virt kernel and a module shim, not
# the sdm660 kernel; the release's boot image is not booted), the base (the generic
# example target with the Note Air's deploy.conf values, and the test stage above:
# the Note Air's base needs its panel and radios to be accepted), the boot loader (QEMU
# -kernel/-initrd with the board's command line), the disk (virtio, two partitions),
# no network.
#
# LOCK=refresh: build with the lock comparison off (a local run while the locks are
# behind the repository). QTEST_BOOT_TIMEOUT: seconds per boot (default 1200).
# Needs docker (buildx, privileged containers, arm64 emulation), python3 and git.
# Works in .out/test-first-start-qemu/ under the checkout (kept for the logs; the
# large files are removed at the end, QTEST_KEEP=1 keeps them).
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-first-start-qemu
[ $# = 0 ] || { sed -n 's/^#   //p' "$0" >&2; exit 2; }
T0=$(date +%s); t0=$T0
tick() { t0=$(date +%s); }
tock() { printf 'time %-34s %5d s\n' "$1" $(($(date +%s) - t0)); }
v() { sed -n "s/^$1=//p" "$2" | head -n 1; }
pin() { sed -n "s/^ARG $1=//p" "$P/Dockerfile" | head -n 1; }
die() { echo "test-first-start-qemu: $*" >&2; exit 1; }
BOOT_COMMIT=$(pin BOOT_COMMIT)
ALPINE=$(pin ALPINE)
EXPECT=$P/stages/device-onyx-noteair/expect
BOARD=$P/targets/onyx-noteair/board.conf
C=$P/scripts/test-first-start-qemu-container.sh
UD_BYTES=$((1536 * 1048576))
TO=${QTEST_BOOT_TIMEOUT:-1200}
case $(uname -m) in aarch64|arm64) NATIVE=arm64 ;; *) NATIVE=amd64 ;; esac
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$O}"

rm -rf "$O"; mkdir -p "$O/qtest"
cleanup() {
	[ "${QTEST_KEEP:-}" = 1 ] && return
	# the large files; docker writes some as root, so through a container
	docker run --rm -v "$O":/o "$ALPINE" sh -c 'rm -rf /o/disk.img /o/base.tar /o/artifacts /o/release /o/k /o/ird /o/modules.tar /o/Image /o/initramfs.cpio.gz /o/ird.cpio.gz' >/dev/null 2>&1 || :
}
trap cleanup EXIT

# --- the device facts: what validation checks on the Note Air's tree --------------------
facts=$(awk '!/^[ \t]*#/ && $1 == "/etc/glassine/deploy.conf" { print $2 }' "$EXPECT")
RESERVE_KIB=$(echo "$facts" | sed -n 's/^USERDATA_RESERVE_KIB=//p')
case $RESERVE_KIB in ''|*[!0-9]*) die "$EXPECT names no USERDATA_RESERVE_KIB" ;; esac
echo "device facts ($EXPECT): $(echo "$facts" | tr '\n' ' ')"

# --- 1. the base: example + the test stage -----------------------------------------------
Q=$O/qtest
mkdir -p "$Q/usr/local/sbin" "$Q/etc/init.d" "$Q/etc/conf.d" "$Q/etc/glassine-bootimg/health.d" "$Q/etc/glassine"
install -m 755 "$P/scripts/test-first-start-qemu-agent.sh" "$Q/usr/local/sbin/qtest-first-start"
cat > "$Q/etc/init.d/qtest-first-start" <<'EOF'
#!/sbin/openrc-run
# scripts/test-first-start-qemu.sh: the agent, once the system is up
depend() { after *; }
start() { setsid /usr/local/sbin/qtest-first-start </dev/null >/dev/console 2>&1 & }
EOF
chmod 755 "$Q/etc/init.d/qtest-first-start"
cat > "$Q/etc/conf.d/bluetooth" <<'EOF'
# scripts/test-first-start-qemu.sh: no Bluetooth in the virt kernel (a crashed
# bluetoothd would keep the boot-success step from accepting the deployment)
start_pre() { [ -d /sys/class/bluetooth ] || { eerror "no Bluetooth in this kernel (test)"; return 1; }; }
EOF
{ echo "# scripts/test-first-start-qemu.sh: the Note Air's device facts ($EXPECT)"
  echo "$facts"; echo ACCEPT_AFTER=40; } > "$Q/etc/glassine/deploy.conf.qtest"
DF=$O/Dockerfile
{ cat "$P/Dockerfile"; cat <<'EOF'

# --- test-first-start-qemu only --------------------------------------------------------
FROM base-export AS qtest-first-start
COPY --from=qtest / /
RUN cat /etc/glassine/deploy.conf.qtest >> /etc/glassine/deploy.conf \
    && rm /etc/glassine/deploy.conf.qtest \
    && for h in /etc/glassine-bootimg/health.d/*desktop*; do \
        [ -e "$h" ] || continue; \
        printf '#!/bin/sh\n# test: no panel in the VM\nexit 0\n' > "$h"; done \
    && ln -s /etc/init.d/qtest-first-start /etc/runlevels/default/qtest-first-start
EOF
} > "$DF"
tick
docker buildx build -q --platform linux/arm64 --build-arg DEVICE=example --build-arg LOCK="${LOCK:-check}" \
	--build-context qtest="$Q" --target qtest-first-start -f "$DF" -o "type=tar,dest=$O/base.tar" "$P" \
	> "$O/build-base.log" 2>&1 || { cat "$O/build-base.log" >&2; die "the base's build failed"; }
tock "build base"
tick
docker buildx build -q --platform linux/arm64 --build-arg LOCK="${LOCK:-check}" --target initramfs-export \
	-o "type=local,dest=$O/ird" "$P" > "$O/build-initramfs.log" 2>&1 \
	|| { cat "$O/build-initramfs.log" >&2; die "the initramfs's build failed"; }
IRD=$(cd "$O/ird/boot/initramfs" && ls ./*.cpio.gz | sed 's|^\./||; s|\.cpio\.gz$||')
[ "$(echo "$IRD" | wc -l)" = 1 ] || die "initramfs-export: not one initramfs: $IRD"
cp "$O/ird/boot/initramfs/$IRD.cpio.gz" "$O/ird.cpio.gz"
tock "build initramfs"

# --- 2. the kernel side ------------------------------------------------------------------
tick
docker run --rm --platform linux/arm64 -v "$O":/o -v "$BOARD":/t/board.conf:ro -v "$C":/c.sh:ro "$ALPINE" \
	sh /c.sh files > "$O/files.log" 2>&1 || { cat "$O/files.log" >&2; die "the files step failed"; }
cat "$O/files.log"
KREL=$(cat "$O/krel")
tock "kernel + initramfs"
K=$O/k; mkdir -p "$K/modules/$KREL" "$K/boot/dtb" "$K/boot/initramfs" "$K/bootimg" "$K/select"
tar -C "$K/modules/$KREL" -xf "$O/modules.tar"
printf 'format=1\nrelease=%s\nprovides=\nfeatures=\n' "$KREL" > "$K/modules/$KREL/kernel.manifest"
DTB=example@0000000000000000; IMG=0000000000000000
echo placeholder > "$K/boot/dtb/$DTB.dtb"; printf 'format=1\ndevice=example\n' > "$K/boot/dtb/$DTB.manifest"
cp "$O/ird/boot/initramfs/$IRD.cpio.gz" "$O/ird/boot/initramfs/$IRD.manifest" "$K/boot/initramfs/"
echo placeholder > "$K/bootimg/$IMG.img"
printf 'format=1\nid=%s\ndevice=example\nkernel=%s\ndtb=%s\ninitramfs=%s\nsize=%s\nsha256=%s\n' $IMG "$KREL" $DTB "$IRD" \
	"$(stat -c %s "$K/bootimg/$IMG.img")" "$(sha256sum < "$K/bootimg/$IMG.img" | cut -c1-64)" > "$K/bootimg/$IMG.manifest"
printf 'format=1\ndevice=example\nkernel=%s\ndtb=%s\ninitramfs=%s\n' "$KREL" $DTB "$IRD" > "$K/select/example"

# --- 3. materialize, pool-image -------------------------------------------------------------
R=$O/repo; mkdir -p "$R/targets/example"
ln -s "$P/Dockerfile" "$R/Dockerfile"; ln -s "$P/stages" "$R/stages"
printf 'format=1\n# test-first-start-qemu: the generic reference target; its kernel is the virt kernel\narch=arm64\nkernel=qtest-virt\n' \
	> "$R/targets/example/target"
printf 'DEVICE=example\nPART_SIZE=67108864\n' > "$R/targets/example/board.conf"
clean=yes; [ -z "$(git -C "$P" status --porcelain --untracked-files=no)" ] || clean=no
printf 'images_commit=%s\nimages_clean=%s\n' "$(git -C "$P" rev-parse HEAD)" "$clean" > "$O/info"
A=$O/artifacts
tick
n=0
while :; do
	rc=0
	"$P/scripts/materialize" --repo "$R" --build-info "$O/info" --no-parent "$O/base.tar" "$K" example "$A" \
		> "$O/materialize.log" 2>&1 || rc=$?
	[ $rc = 4 ] && [ $n -lt 360 ] || break
	[ $n != 0 ] || echo "materialize: another materialization holds the host lock; waiting"
	sleep 10; n=$((n + 1))
done
[ $rc = 0 ] || { cat "$O/materialize.log" >&2; die "materialize failed (exit $rc)"; }
grep -A3 '^materialize: build ' "$O/materialize.log" || :
tock materialize
rm -f "$O/base.tar"
tick
"$P/scripts/pool-image" --repo "$R" --out "$O/release" "$A" example > "$O/pool-image.log" 2>&1 \
	|| { cat "$O/pool-image.log" >&2; die "pool-image failed"; }
grep -v '^time ' "$O/pool-image.log" | sed 's/^/    /'
tock pool-image
eval "$(python3 -I - "$O/release/release.json" <<'EOF'
import json, sys
b = json.load(open(sys.argv[1]))['artifacts']['base']
print(f"POOL={b['file']} SYS_BYTES={b['min_partition_bytes']} BASE={b['base']} PKREL={b['kernel_release']}")
EOF
)"
[ "$PKREL" = "$KREL" ] || die "the release's kernel is $PKREL, not the virt kernel $KREL"

# --- 4. the disk ---------------------------------------------------------------------------
tick
CENV="-e POOL=$POOL -e SYS_BYTES=$SYS_BYTES -e UD_BYTES=$UD_BYTES -e RESERVE_KIB=$RESERVE_KIB -e BASE=$BASE -e KREL=$KREL"
# shellcheck disable=SC2086  # CENV: -e options, no spaces inside one
docker run --rm --privileged --platform linux/$NATIVE $CENV -v "$O":/o -v "$O/release":/r:ro -v "$C":/c.sh:ro "$ALPINE" \
	sh /c.sh disk > "$O/disk.log" 2>&1 || { cat "$O/disk.log" >&2; die "the disk step failed"; }
cat "$O/disk.log"
tock disk

# --- 5, 6. the boots ------------------------------------------------------------------------
CMDLINE=$(sed -n 's/^CMDLINE="\(.*\)"$/\1/p' "$BOARD")
boot() {	# boot N: one boot until QEMU exits (a reboot or a power-off: -no-reboot)
	echo "--- boot $1"
	tick
	rc=0
	docker run --rm --platform linux/$NATIVE -v "$O":/o "$ALPINE" sh -c "apk add -q --no-progress qemu-system-aarch64 >/dev/null && \
		timeout $TO qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 4 -m 2048 -nographic -no-reboot \
		-kernel /o/Image -initrd /o/initramfs.cpio.gz \
		-append '$CMDLINE skip_initramfs console=ttyAMA0' \
		-drive if=none,id=d,file=/o/disk.img,format=raw -device virtio-blk-pci,drive=d \
		-nic none" > "$O/boot$1.log" 2>&1 || rc=$?
	grep -a 'QTEST\|glassine-first-start:\|glassine-deploy-accept:\|glassine-boot:\|glassine-switch:' "$O/boot$1.log" | sed 's/\r$//'
	if [ $rc = 0 ]; then echo "QTEST ok boot $1: QEMU exited by itself" | tee -a "$O/check$1.log"
	else echo "QTEST FAIL boot $1: QEMU exited by itself (exit $rc; 124 = the limit of $TO s)" | tee -a "$O/check$1.log"; fi
	tock "boot $1"
	# shellcheck disable=SC2086
	docker run --rm --privileged --platform linux/$NATIVE $CENV -v "$O":/o -v "$C":/c.sh:ro "$ALPINE" \
		sh /c.sh check "$1" >> "$O/check$1.log" 2>&1 || echo "QTEST FAIL after boot $1: the disk check ran (see check$1.log)" >> "$O/check$1.log"
	grep -v '^QTEST ok boot\|^QTEST FAIL boot' "$O/check$1.log"
}
boot 1
r=ok; grep -aq 'glassine-first-start: first deployment .* selected' "$O/boot1.log" || r=FAIL
echo "QTEST $r boot 1: the first start selected the first deployment and rebooted" | tee -a "$O/check1.log"
boot 2

pass=$(cat "$O"/boot*.log "$O"/check*.log | grep -ac 'QTEST ok' || true)
fail=$(cat "$O"/boot*.log "$O"/check*.log | grep -ac 'QTEST FAIL' || true)
acc=$(grep -ac "QTEST ok .* accepted by the boot-success step" "$O/boot2.log" || true)
t0=$T0; tock total
echo "test-first-start-qemu: $pass ok, $fail FAIL (USERDATA_RESERVE_KIB=$RESERVE_KIB, system_b $SYS_BYTES bytes, kernel $KREL)"
[ "$fail" = 0 ] && [ "$acc" = 1 ] && [ "$pass" -ge 40 ]
