#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The acceptance test of specs/002-base-boot-acceptance for the generic x86-64 UEFI PC
# (DEVICE=uefi-pc, linux/amd64): the base boots as a deployment in QEMU (q35, UEFI
# firmware: OVMF) and goes through the deployment lifecycle, with GlassineOS/boot's
# outside-base harness at the pinned BOOT_COMMIT. The proof is the arm64 test's
# (scripts/test-boot-qemu.sh): every QTEST check of every boot passes and the agent
# reaches DONE. Besides, every boot must have started under UEFI (the kernel's
# "efi: EFI v" line), so a fallback to a legacy BIOS can't pass.
#
#   1. Builds the base (the chain up to base-export) and the second base of Scenario 2
#      (FR-005: the same base with one added file, from a test stage appended to a copy
#      of the Dockerfile), the kernel (kernel-export with KERNEL=lts: Alpine's linux-lts)
#      and the initramfs (initramfs-export), all for linux/amd64.
#   2. Materializes both bases into a test artifacts folder (scripts/materialize): a
#      full stream, then a delta. The kernel side is the real kernel and initramfs; the
#      boot image and device tree records are placeholders (a PC has neither), and the
#      target's description is made here (.out/, never under targets/).
#   3. Builds the guest's disk with boot's harness (test/qemu/build.sh disk: the base
#      received into bases/, the kernel's modules as modules/<release>, deployment d1
#      with the harness's agent in its build layer) and boots it with
#      qemu-system-x86_64 -kernel/-initrd under OVMF: OVMF starts the kernel's EFI stub.
#      No boot loader and no deployment selection on the firmware's side: that is
#      GlassineOS/boot's spec 010, not written yet. A file system check of both
#      partitions follows every boot (build.sh fsck).
#
# What differs from a PC: the initramfs is the release's with two archives appended,
# the board keys (/etc/glassine-boot/board.conf: the harness's partition names, which
# a PC's board doesn't define yet) and a shim that loads the kernel's storage and file
# system modules before boot's init. boot's initramfs loads no modules, and Alpine's
# linux-lts has those drivers as modules, so a real PC needs that step in boot itself
# (spec 010). The negative tests (defective bases) are the arm64 test's; they test the
# base's chain, not the architecture.
#
#   scripts/test-boot-qemu-x86_64.sh        exit 0 = the base passed
#
# BOOT_CHECKOUT=DIR: a local GlassineOS/boot checkout instead of BOOT_COMMIT, for the
# harness and the initramfs alike (a trial, as scripts/build --local).
# QTEST_BOOT_TIMEOUT: seconds per boot (default 900). KVM is used when /dev/kvm can be
# opened (a CI runner: minutes in all); otherwise QEMU emulates the CPU (TCG, slower).
# Needs docker (buildx, privileged containers), python3 and git; an x86-64 host, or
# amd64 emulation for the builds. Works in .out/test-boot-qemu-x86_64/ (kept for the logs).
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-boot-qemu-x86_64
case "${1:-}" in '') ;; *) sed -n 's/^#   //p' "$0" >&2; exit 2 ;; esac
T0=$(date +%s); t0=$T0
tick() { t0=$(date +%s); }
tock() { printf 'time %-34s %5d s\n' "$1" $(($(date +%s) - t0)); }
v() { sed -n "s/^$1=//p" "$2" | head -n 1; }
pin() { sed -n "s/^ARG $1=//p" "$P/Dockerfile" | head -n 1; }
BOOT_COMMIT=$(pin BOOT_COMMIT)
BOOT=$(pin BOOT)
SECOND=/usr/share/glassine-qtest/second
PLAT=linux/amd64
DEV=uefi-pc
case $(uname -m) in x86_64|amd64) NATIVE=amd64 ;; *) NATIVE=arm64 ;; esac

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
for f in test/qemu/build.sh test/qemu/build-base.sh test/qemu/agent-base.sh; do
	[ -f "$H/$f" ] || { echo "test-boot-qemu-x86_64: boot has no $f at this commit" >&2; exit 1; }
done

# --- the builds ---------------------------------------------------------------------------
DF=$O/Dockerfile
{ cat "$P/Dockerfile"; cat <<EOF

# --- test-boot-qemu-x86_64 only ----------------------------------------------------------
# The second base of Scenario 2: the same target's base with one added file (FR-005).
FROM base-export AS qtest-second
RUN mkdir -p ${SECOND%/*} && echo second > $SECOND
EOF
} > "$DF"
build() {	# build STAGE OUTPUT [OPTIONS]
	s=$1 out=$2; shift 2
	tick
	docker buildx build -q --platform $PLAT --build-arg DEVICE=$DEV "$@" --target "$s" \
		-f "$DF" -o "$out" "$P" > "$O/build-$s.log" 2>&1 \
		|| { cat "$O/build-$s.log" >&2; echo "test-boot-qemu-x86_64: the build of $s failed" >&2; exit 1; }
	tock "build $s"
}
K=$O/k
build base-export "type=tar,dest=$O/base1.tar"
build qtest-second "type=tar,dest=$O/base2.tar"
build kernel-export "type=local,dest=$K" --build-arg KERNEL=lts
# a local boot checkout is also the initramfs's source (its boot-src stage)
if [ -n "${BOOT_CHECKOUT:-}" ]; then
	mkdir -p "$O/boot-src/src"; cp -a "$H" "$O/boot-src/src/boot"
	build initramfs-export "type=local,dest=$K" --build-context boot-src="$O/boot-src"
else
	build initramfs-export "type=local,dest=$K"
fi
REL=$(ls "$K/modules")
IRD=$(cd "$K/boot/initramfs" && ls ./*.cpio.gz | sed 's|^\./||; s|\.cpio\.gz$||')
echo "kernel $REL, initramfs $IRD"

# --- materialize: the target and placeholder records for what a PC doesn't have ---------
R=$O/repo; mkdir -p "$R/targets/$DEV"
ln -s "$P/Dockerfile" "$R/Dockerfile"; ln -s "$P/stages" "$R/stages"
printf 'format=1\n# test-boot-qemu-x86_64: the generic x86-64 UEFI PC (no boot image, no device tree)\narch=x86_64\nkernel=lts\n' \
	> "$R/targets/$DEV/target"
DTB=$DEV@0000000000000000 IMG=0000000000000000
mkdir -p "$K/boot/dtb" "$K/bootimg" "$K/select"
echo placeholder > "$K/boot/dtb/$DTB.dtb"; printf 'format=1\ndevice=%s\n' $DEV > "$K/boot/dtb/$DTB.manifest"
echo placeholder > "$K/bootimg/$IMG.img"
printf 'format=1\nid=%s\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\n' $IMG $DEV "$REL" $DTB "$IRD" > "$K/bootimg/$IMG.manifest"
printf 'format=1\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\n' $DEV "$REL" $DTB "$IRD" > "$K/select/$DEV"
clean=yes; [ -z "$(git -C "$P" status --porcelain --untracked-files=no)" ] || clean=no
printf 'images_commit=%s\nimages_clean=%s\n' "$(git -C "$P" rev-parse HEAD)" "$clean" > "$O/info"
mat() {	# mat TAR ARTIFACTS [OPTIONS]: materialize; waits while another one holds the host lock
	tar=$1 art=$2; shift 2
	tick
	n=0
	while :; do
		rc=0
		"$P/scripts/materialize" --repo "$R" --build-info "$O/info" "$@" "$tar" "$K" $DEV "$art" \
			> "$O/materialize.log" 2>&1 || rc=$?
		[ $rc = 4 ] && [ $n -lt 360 ] || break
		[ $n != 0 ] || echo "materialize: another materialization holds the host lock; waiting"
		sleep 10; n=$((n + 1))
	done
	cat "$O/materialize.log" >> "$O/materialize-all.log"
	[ $rc = 0 ] || { cat "$O/materialize.log" >&2; echo "test-boot-qemu-x86_64: materialize $tar failed (exit $rc)" >&2; exit 1; }
	tock "materialize ${tar##*/}"
}
newest() { ls -d "$1/$DEV"/builds/*/ | sort | tail -n 1; }
A=$O/artifacts
mat "$O/base1.tar" "$A" --no-parent
M1=$(newest "$A")manifest
mat "$O/base2.tar" "$A"
M2=$(newest "$A")manifest
[ "$(v parent "$M2")" = "$(v base "$M1")" ] && [ -s "$A/$(v delta "$M2")" ] \
	|| { echo "test-boot-qemu-x86_64: the second base isn't a delta against the first" >&2; exit 1; }
echo "base 1 $(v base "$M1"), full stream $(du -h "$A/$(v stream "$M1")" | cut -f1)"
echo "base 2 $(v base "$M2"), delta $(du -h "$A/$(v delta "$M2")" | cut -f1)"

# --- the guest: the harness's disk, the kernel, the initramfs with the board and shim ---
G=$O/run; mkdir -p "$G"
tar -C "$K/modules/$REL" -cf "$G/modules.tar" .
echo "$REL" > "$G/krel"
cp "$K/modules/$REL/vmlinuz" "$G/vmlinuz"
tick
docker run --rm --privileged --platform linux/$NATIVE -e QTEST_BASE=1 -e "QTEST_BASE2_FILE=$SECOND" \
	-v "$A/$(v stream "$M1")":/in/base.btrfs.zst:ro -v "$A/$(v delta "$M2")":/in/base2.btrfs.zst:ro \
	-v "$H":/p:ro -v "$G":/out alpine:3.24 sh /p/test/qemu/build.sh disk > "$O/disk.log" 2>&1 \
	|| { cat "$O/disk.log" >&2; echo "test-boot-qemu-x86_64: the disk step failed" >&2; exit 1; }
grep '^disk:' "$O/disk.log" || :
tock "disk"
# the board keys (the harness's partition names) and the shim, appended to the initramfs
# as two more archives; the shim loads the modules (from the kernel's own tree), then
# execs boot's init, which keeps PID 1
cat > "$G/board.conf" <<'EOF'
ROOT_PART=system
ROOT_FSTYPE=btrfs
ROOT_LAYOUT=deployments
USERDATA_PART=userdata
USERDATA_PREFIX=media/glassine
DEFAULT_ROLE_MATCH=''
EOF
cp "$K/boot/initramfs/$IRD.cpio.gz" "$G/release.cpio.gz"
docker run --rm --platform $PLAT -v "$K/modules/$REL":/k:ro -v "$G":/out alpine:3.24 sh -euc '
apk add -q kmod cpio gzip zstd >/dev/null
rel=$(cat /out/krel)
mkdir -p /m/lib/modules /x/lib/qtest /b/etc/glassine-boot
ln -s /k /m/lib/modules/$rel
: > /x/lib/qtest/load.list
# the checksums btrfs needs come by soft dependency (modules.softdep), which --show-depends
# leaves out: named here by their crypto names
for m in virtio_pci virtio_blk ext4 crc32c xxhash64 sha256 blake2b-256 btrfs overlay vfat nls_cp437 nls_iso8859_1 nls_utf8; do
	modprobe -d /m -S "$rel" --show-depends $m | sed -n "s/^insmod \([^ ]*\).*/\1/p"
done | awk "!seen[\$0]++" | while read -r k; do
	b=${k##*/}; b=${b%.gz}; b=${b%.zst}; b=${b%.xz}
	case $k in *.gz) gzip -dc "$k" ;; *.zst) zstd -qdc "$k" ;; *.xz) xz -dc "$k" ;; *) cat "$k" ;; esac > /x/lib/qtest/$b
	echo "$b" >> /x/lib/qtest/load.list
done
echo "shim: $(tr "\n" " " < /x/lib/qtest/load.list)"
zcat /out/release.cpio.gz | (mkdir -p /r && cd /r && cpio -id --quiet)
cp /r/init /x/init.glassine
cat > /x/init <<"EOF"
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc 2>/dev/null
while read -r m; do /bin/busybox insmod /lib/qtest/$m; done < /lib/qtest/load.list
/bin/busybox umount /proc
exec /init.glassine
EOF
chmod 755 /x/init /x/init.glassine
install -m 644 /out/board.conf /b/etc/glassine-boot/board.conf
(cd /b && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > /out/board.cpio.gz
(cd /x && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > /out/shim.cpio.gz
cat /out/release.cpio.gz /out/board.cpio.gz /out/shim.cpio.gz > /out/initramfs.cpio.gz
rm /out/release.cpio.gz /out/board.cpio.gz /out/shim.cpio.gz /out/modules.tar 2>/dev/null || :
' | tee "$O/initramfs.log"

# --- the boots ---------------------------------------------------------------------------
KVM=''
if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then KVM='--device /dev/kvm'; ACCEL='-accel kvm -cpu host'
else ACCEL='-accel tcg -cpu max'; echo "no usable /dev/kvm: QEMU emulates the CPU (TCG)"; fi
TO=${QTEST_BOOT_TIMEOUT:-900}
BOOTS=8
n=0
while [ "$n" -lt "$BOOTS" ]; do
	n=$((n + 1))
	echo "--- boot $n"
	tick
	rc=0
	# shellcheck disable=SC2086  # KVM: one option and its value, or nothing
	docker run --rm $KVM -v "$G":/out alpine:3.24 sh -c "apk add -q qemu-system-x86_64 ovmf >/dev/null && \
		cp /usr/share/OVMF/OVMF_VARS.fd /tmp/vars.fd && \
		timeout $TO qemu-system-x86_64 -M q35 $ACCEL -smp 4 -m 1536 -nographic -no-reboot \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
		-drive if=pflash,format=raw,file=/tmp/vars.fd \
		-kernel /out/vmlinuz -initrd /out/initramfs.cpio.gz \
		-append 'console=ttyS0 rdinit=/init panic=10' \
		-drive if=none,id=d,file=/out/disk.img,format=raw -device virtio-blk-pci,drive=d \
		-nic user,model=virtio-net-pci \
		" > "$O/boot$n.log" 2>&1 || rc=$?
	grep -a 'QTEST\|glassine-switch:\|glassine-deploy-accept:\|glassine-boot:\|glassine-deploy:' "$O/boot$n.log" | sed 's/\r$//'
	if grep -aq 'efi: EFI v' "$O/boot$n.log"; then echo "QTEST ok boot $n: started by UEFI firmware ($(grep -a -m1 -o 'efi: EFI v[^ ]* by .*' "$O/boot$n.log" | tr -d '\r'))" | tee "$O/fsck$n.log"
	else echo "QTEST FAIL boot $n: started by UEFI firmware (no \"efi: EFI v\" line)" | tee "$O/fsck$n.log"; fi
	if [ $rc = 0 ]; then echo "QTEST ok boot $n: powered off by itself" | tee -a "$O/fsck$n.log"
	else echo "QTEST FAIL boot $n: powered off by itself (qemu exit $rc; 124 = the limit of $TO s)" | tee -a "$O/fsck$n.log"; fi
	docker run --rm --privileged --platform linux/$NATIVE -v "$H":/p:ro -v "$G":/out alpine:3.24 \
		sh /p/test/qemu/build.sh fsck "$n" >> "$O/fsck$n.log" 2>&1 || :
	grep -a 'QTEST .* after boot' "$O/fsck$n.log" || :
	[ "$(grep -ac 'QTEST .* after boot' "$O/fsck$n.log")" = 2 ] ||
		echo "QTEST FAIL after boot $n: the file system check ran (see fsck$n.log)" | tee -a "$O/fsck$n.log"
	tock "boot $n"
	grep -aq 'QTEST DONE' "$O/boot$n.log" && break
	[ $rc = 0 ] || break
	# no line from the agent: the deployment never came up, and the next boot won't either
	grep -aq 'QTEST ' "$O/boot$n.log" || { echo "QTEST FAIL boot $n: the agent ran (no QTEST line from the guest)" | tee -a "$O/fsck$n.log"; break; }
done
pass=$(cat "$O"/boot*.log "$O"/fsck*.log | grep -ac 'QTEST ok' || true)
fail=$(cat "$O"/boot*.log "$O"/fsck*.log | grep -ac 'QTEST FAIL' || true)
done=$(cat "$O"/boot*.log | grep -ac 'QTEST DONE' || true)
echo "qemu x86_64 (UEFI): $n boots, $pass ok, $fail FAIL, done: $done"
t0=$T0; tock total
[ "$fail" = 0 ] && [ "$done" = 1 ] && echo "test-boot-qemu-x86_64: passed" && exit 0
echo "test-boot-qemu-x86_64: failed"; exit 1
