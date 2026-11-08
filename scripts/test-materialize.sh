#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of scripts/materialize without a stage build: a fixture tar with one entry of
# each kind a base must keep (FR-005: a regular file owned by another user, setuid, a
# sticky directory, a symlink, a dangling symlink, a hardlink pair, a FIFO, a character
# device, security.capability, a user.* xattr), made in a container; a fixture
# repository (Dockerfile chain + locks + target) and a fake kernel export. Checks: a full
# build and its records, a parent + delta build whose delta writes only the changed file
# (and the base manifest), the refusal of a tree that has a base (FR-011), the host
# lock, the content manifest and id of a known tree, the base manifest with its locks,
# and that /etc/resolv.conf or a kernel mismatch fails (FR-019).
#   scripts/test-materialize.sh     exit 0 = all checks pass
# Needs docker (privileged containers) and python3. Works in .out/test-materialize/
# under the checkout and removes it at the end.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-materialize
rm -rf "$O"; mkdir -p "$O"
export XDG_RUNTIME_DIR="$O"        # the host lock, apart from any real run
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
M() { "$P/scripts/materialize" --repo "$O/repo" "$@"; }
BOOT_COMMIT=0123456789abcdef0123456789abcdef01234567
REL=7.3.0-fake.abcdef-g0123456789ab

# --- the fixture repository: a chain with a stage that has no lock (skipped by locks)
R=$O/repo; mkdir -p "$R/stages/base0" "$R/stages/middle" "$R/stages/device-fixture" "$R/targets/fixture"
cat > "$R/Dockerfile" <<EOF
ARG DEVICE=fixture
ARG BOOT_COMMIT=$BOOT_COMMIT
FROM scratch AS base0
FROM base0 AS middle
FROM middle AS device-fixture
FROM base0 AS device-other
FROM device-\${DEVICE} AS finish
FROM finish AS base-export
EOF
printf 'busybox=1.0-r0\nmusl=1.0-r0\n' > "$R/stages/base0/lock"
printf 'busybox=1.0-r0\nfixture-hosts=1.0-r0\nmusl=1.0-r0\n' > "$R/stages/device-fixture/lock"
printf 'arch=arm64\nkernel=fake\n' > "$R/targets/fixture/target"
LOCKS=$(for s in base0 device-fixture; do printf '%s\n' $s; cat "$R/stages/$s/lock"; done | sha256sum | cut -c1-64)

# --- the fake kernel export (owned by the invoking user, like a local export)
K=$O/k; mkdir -p "$K/modules/$REL/kernel" "$K/boot/dtb" "$K/boot/initramfs" "$K/bootimg" "$K/select"
echo image > "$K/modules/$REL/Image.gz"; echo ko > "$K/modules/$REL/kernel/x.ko"
printf 'format=1\nrelease=%s\nprovides=\nfeatures=\n' $REL > "$K/modules/$REL/kernel.manifest"
DTB=fixture@0000000000000001; IRD=0123456789ab@0000000000000002; IMG=00000000000000aa
echo dtb > "$K/boot/dtb/$DTB.dtb"; printf 'format=1\ndevice=fixture\n' > "$K/boot/dtb/$DTB.manifest"
echo ird > "$K/boot/initramfs/$IRD.cpio.gz"
printf 'format=1\ncommit=%s\nneeds=\nfeatures=\n' $BOOT_COMMIT > "$K/boot/initramfs/$IRD.manifest"
echo img > "$K/bootimg/$IMG.img"
printf 'format=1\nid=%s\ndevice=fixture\nkernel=%s\ndtb=%s\ninitramfs=%s\n' $IMG $REL $DTB $IRD > "$K/bootimg/$IMG.manifest"
printf 'format=1\ndevice=fixture\nkernel=%s\ndtb=%s\ninitramfs=%s\n' $REL $DTB $IRD > "$K/select/fixture"

# --- the fixture tars, and the content manifest of a known tree, made as root
docker run --rm --privileged -v "$O":/o -v "$P/scripts":/s:ro -e HOST="$(id -u):$(id -g)" alpine:3.24 sh -euc '
apk add -q --no-progress tar attr libcap-utils python3 >/dev/null
mkdir /t && mount -t tmpfs tmpfs /t && cd /t
mkdir -p r/etc r/usr/bin r/usr/lib r/run r/dev r/tmp r/lib/apk/db
echo "127.0.0.1 localhost" > r/etc/hosts
python3 - <<"EOF"
import base64, hashlib
z = base64.b64encode(hashlib.sha1(open("r/etc/hosts", "rb").read()).digest()).decode()
open("r/lib/apk/db/installed", "w").write(
    "P:musl\nV:1.0-r0\n\nP:fixture-hosts\nV:1.0-r0\nF:etc\nR:hosts\nZ:Q1" + z + "\n\nP:busybox\nV:1.0-r0\n\n")
EOF
echo one > r/etc/config
echo user > r/etc/owned; chown 1000:1000 r/etc/owned
echo su > r/usr/bin/su; chmod 4755 r/usr/bin/su
chmod 1777 r/tmp
ln -s su r/usr/bin/link
ln -s /nonexistent/target r/usr/bin/dangling
echo pair > r/usr/lib/a; ln r/usr/lib/a r/usr/lib/b
mkfifo r/run/fifo
mknod r/dev/null c 1 3
echo ping > r/usr/bin/ping; setcap cap_net_raw+ep r/usr/bin/ping
echo note > r/usr/lib/note; setfattr -n user.glassine.test -v hello r/usr/lib/note
mk() { tar -C r --numeric-owner --xattrs --xattrs-include="*" -cf /o/$1.tar $(ls -A r); }
mk base1
echo two > r/etc/config; mk base2
echo "nameserver 10.0.0.1" > r/etc/resolv.conf; mk resolv; rm r/etc/resolv.conf
# a known tree: its manifest and id are fixed bytes
mkdir -p k/d; printf "abc" > k/d/f; chmod 644 k/d/f; ln k/d/f k/d/g; ln -s d/f k/l
chmod 755 k k/d; chown -R 0:0 k
python3 -I /s/tree-manifest.py k > /o/known.manifest
chown -R "$HOST" /o/base1.tar /o/base2.tar /o/resolv.tar /o/known.manifest'

A=$O/art

# --- the content manifest and id of a known tree (FR-010)
cat > "$O/known.expect" <<'EOF'
. d 0:0 0755 0 -
d d 0:0 0755 0 -
d/f - 0:0 0644 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad =d/f
d/g - 0:0 0644 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad =d/f
l l 0:0 0777 0 -> d/f
EOF
check "content manifest of a known tree: exact bytes" "cmp -s '$O/known.manifest' '$O/known.expect'"
check "its id: <date>-<first 16 hex of sha256>" "[ 20260101-\$(sha256sum < '$O/known.expect' | cut -c1-16) = 20260101-cd49ba9443a681bc ]"

# --- a full build
printf 'images_commit=%s\nimages_clean=yes\ninput.linux.commit=c1\ninput.linux.tree=t1\ninput.linux.local=no\nbuilder.kernel-build=sha256:00\ntrial=no\nunmerged=\n' \
	"$(printf %040d 7)" > "$O/info"
out=$(M --no-parent --date 20260101 --arg EXTRA=value --build-info "$O/info" "$O/base1.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | sed 's/^/    /'
check "full build: exit 0" "[ $rc = 0 ]"
ID1=$(ls "$A/fixture" | head -n 1); B=$A/fixture/$ID1
check "id = date + tree16 of tree.manifest" "[ '$ID1' = 20260101-\$(sha256sum < '$B/tree.manifest' | cut -c1-16) ]"
check "FR-014/020 files" "for f in manifest packages tree.manifest kernel.manifest boot.manifest select base.btrfs.zst; do [ -s '$B'/\$f ] || exit 1; done"
check "no delta without a parent" "! ls '$B'/base.from-* >/dev/null 2>&1"
check "modules stream and manifest, boot image, dtb, initramfs" "[ -s '$A/modules/$REL.btrfs.zst' ] && [ -s '$A/modules/$REL.manifest' ] && [ -s '$A/bootimg/$IMG.img' ] && [ -s '$A/boot/dtb/$DTB.dtb' ] && [ -s '$A/boot/initramfs/$IRD.manifest' ]"
check "outputs owned by the invoking user" "[ -z \"\$(find '$A' ! -user \$(id -u))\" ]"
check "copies of the kernel, boot and select records" "cmp -s '$B/kernel.manifest' '$K/modules/$REL/kernel.manifest' && cmp -s '$B/boot.manifest' '$K/bootimg/$IMG.manifest' && cmp -s '$B/select' '$K/select/fixture'"
check "packages: name=version, sorted" "[ \"\$(cat '$B/packages')\" = \"\$(printf 'busybox=1.0-r0\nfixture-hosts=1.0-r0\nmusl=1.0-r0')\" ]"
v() { sed -n "s/^$1=//p" "$2" | head -n 1; }
check "build manifest: format=1 first, every FR-013 key" "[ \"\$(head -n 1 '$B/manifest')\" = format=1 ] && for k in base target tree parent uuid received_uuid built images_commit images_clean locks lock.base0 lock.device-fixture arg.DEVICE arg.BOOT_COMMIT input.linux.commit input.linux.tree input.linux.local builder.kernel-build kernel_release bootimg boot_commit trial unmerged stream_sha256 modules_stream_sha256; do grep -q \"^\$k=\" '$B/manifest' || { echo \"    missing \$k\"; exit 1; }; done"
check "build manifest values" "[ \"\$(v base '$B/manifest')\" = '$ID1' ] && [ \"\$(v target '$B/manifest')\" = fixture ] && [ -z \"\$(v parent '$B/manifest')\" ] && [ \"\$(v tree '$B/manifest')\" = \"\$(sha256sum < '$B/tree.manifest' | cut -c1-64)\" ] && [ \"\$(v locks '$B/manifest')\" = $LOCKS ] && [ \"\$(v lock.base0 '$B/manifest')\" = \"\$(sha256sum < '$R/stages/base0/lock' | cut -c1-64)\" ] && [ \"\$(v kernel_release '$B/manifest')\" = $REL ] && [ \"\$(v bootimg '$B/manifest')\" = $IMG ] && [ \"\$(v boot_commit '$B/manifest')\" = $BOOT_COMMIT ] && [ \"\$(v arg.DEVICE '$B/manifest')\" = fixture ] && [ \"\$(v input.linux.tree '$B/manifest')\" = t1 ] && [ \"\$(v stream_sha256 '$B/manifest')\" = \"\$(sha256sum < '$B/base.btrfs.zst' | cut -c1-64)\" ]"
check "an override in the pins view (--arg)" "grep -qx arg.EXTRA=value '$B/manifest'"
check "uuid = received_uuid, both set" "[ -n \"\$(v uuid '$B/manifest')\" ] && [ \"\$(v uuid '$B/manifest')\" = \"\$(v received_uuid '$B/manifest')\" ]"
check "locked stages only (middle has no lock)" "! grep -q '^lock.middle=' '$B/manifest'"
T=$B/tree.manifest
check "FR-005 in the content manifest: owner, setuid, sticky, symlinks, hardlinks" "grep -qx 'etc/owned - 1000:1000 0644 5 .*' '$T' && grep -q '^usr/bin/su - 0:0 4755 ' '$T' && grep -qx 'tmp d 0:0 1777 0 -' '$T' && grep -qx 'usr/bin/link l 0:0 0777 0 -> su' '$T' && grep -qx 'usr/bin/dangling l 0:0 0777 0 -> /nonexistent/target' '$T' && grep -q '^usr/lib/a .* =usr/lib/a\$' '$T' && grep -q '^usr/lib/b .* =usr/lib/a\$' '$T'"
check "FR-005 in the content manifest: FIFO, device node, capability, user xattr" "grep -qx 'run/fifo p 0:0 0644 0 -' '$T' && grep -qx 'dev/null c 0:0 0644 0 dev 1,3' '$T' && grep -q '^usr/bin/ping .* security.capability=' '$T' && grep -q '^usr/lib/note .* user.glassine.test=68656c6c6f\$' '$T'"
check "no base manifest in the content manifest" "! grep -q base.manifest '$T'"
check "per-step times reported" "echo \"\$out\" | grep -q '^time extract into subvolume ' && echo \"\$out\" | grep -q '^time full stream ' && echo \"\$out\" | grep -q '^time materialize (total) '"

# the base manifest and FR-005, read back from the full stream by an independent receive
docker run --rm --privileged -v "$B":/b:ro alpine:3.24 sh -euc '
apk add -q --no-progress btrfs-progs zstd attr libcap-utils >/dev/null
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
mkdir /w && mount -t tmpfs tmpfs /w && truncate -s 1073741824 /w/f && mkfs.btrfs -q /w/f && mkdir /w/m && mount -o loop /w/f /w/m
zstd -dc /b/base.btrfs.zst | btrfs -q receive /w/m
cd /w/m/*; echo "subvolume=${PWD##*/}"; btrfs property get -ts . ro
cat usr/share/glassine/base.manifest; stat -c "mode=%a owner=%u:%g" usr/share/glassine/base.manifest
getcap usr/bin/ping; getfattr --only-values -n user.glassine.test usr/lib/note; echo
stat -c "%F" run/fifo dev/null
cd /; umount /w/m' > "$O/recv" 2>&1 || true
sed 's/^/    /' "$O/recv"
check "received: one read-only subvolume named by the id" "grep -qx 'subvolume=$ID1' '$O/recv' && grep -qx ro=true '$O/recv'"
check "base manifest: format, base, locks of the fixture chain, empty needs/features, 0644 root" "[ \"\$(sed -n '/^format=/,/^features=/p' '$O/recv')\" = \"\$(printf 'format=1\nbase=%s\nlocks=%s\nneeds=\nfeatures=' '$ID1' $LOCKS)\" ] && grep -qx 'mode=644 owner=0:0' '$O/recv'"
check "received: capability, user xattr, FIFO, device node" "grep -q 'usr/bin/ping cap_net_raw=ep' '$O/recv' && grep -qx hello '$O/recv' && grep -qx fifo '$O/recv' && grep -qx 'character special file' '$O/recv'"

# --- FR-011: the same tree again
out=$(M --date 20260202 "$O/base1.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | sed 's/^/    /'
check "same tree: exit 3, names the existing base" "[ $rc = 3 ] && echo \"\$out\" | grep -q 'exists: fixture/$ID1'"
check "same tree: no new base, no staging left" "[ \"\$(ls -A '$A/fixture')\" = '$ID1' ]"

# --- the host lock (FR-003)
python3 -c 'import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(30)' \
	"$O/glassine-images-materialize.lock" & holder=$!
sleep 1
M --date 20260303 "$O/base2.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
kill $holder; wait $holder 2>/dev/null || :
check "lock held elsewhere: exit 4, nothing made" "[ $rc = 4 ] && [ \"\$(ls -A '$A/fixture')\" = '$ID1' ]"

# --- parent + delta, the parent by default (the last base of the target)
out=$(M --date 20260303 "$O/base2.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | sed 's/^/    /'
ID2=$(ls "$A/fixture" | grep -vx "$ID1" | head -n 1); B2=$A/fixture/$ID2
check "delta build: exit 0, the parent picked by default" "[ $rc = 0 ] && echo \"\$out\" | grep -q 'parent: $ID1 ' && [ \"\$(v parent '$B2/manifest')\" = '$ID1' ]"
check "delta file named with its parent, checksum in the manifest" "[ -s '$B2/base.from-$ID1.btrfs.zst' ] && [ \"\$(v delta '$B2/manifest')\" = 'base.from-$ID1.btrfs.zst' ] && [ \"\$(v delta_sha256 '$B2/manifest')\" = \"\$(sha256sum < '$B2/base.from-$ID1.btrfs.zst' | cut -c1-64)\" ]"
written=$(echo "$out" | awk 'f && /^(materialize|time|==)/ { f = 0 } f; /^== delta: files written/ { f = 1 }')
check "the delta writes only the changed file and the base manifest" "[ \"\$(echo \"\$written\" | sort | tr '\n' ' ')\" = 'etc/config usr/share/glassine/base.manifest ' ]"
check "full stream and parent + delta compared, same received UUID" "echo \"\$out\" | grep -q 'same content: received parent + delta' && echo \"\$out\" | grep -q 'full stream and parent + delta: received UUID'"
check "modules stream reused for the same release" "echo \"\$out\" | grep -q 'the artifacts folder has its stream'"

# --- FR-019
out=$(M --no-parent --date 20260404 "$O/resolv.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -e FAIL | sed 's/^/    /'
check "/etc/resolv.conf in the export: exit 1, named, nothing made" "[ $rc = 1 ] && echo \"\$out\" | grep -q 'resolv.conf is in the tree' && [ \"\$(ls -A '$A/fixture' | wc -l)\" = 2 ]"
sed -i "s/^kernel=.*/kernel=7.3.0-fake.000000-g0123456789ab/" "$K/select/fixture"
out=$(M --no-parent --date 20260404 "$O/resolv.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -e FAIL | sed 's/^/    /'
check "select record names another kernel: exit 1 before any container" "[ $rc = 1 ] && echo \"\$out\" | grep -q 'select record kernel=' && ! echo \"\$out\" | grep -q '^time '"
M --parent 20260101-0000000000000000 "$O/base2.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "a named parent that isn't there: exit 1" "[ $rc = 1 ]"
printf 'images_comit=x\n' > "$O/bad-info"
M --build-info "$O/bad-info" "$O/base1.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "unknown build-info key: exit 1" "[ $rc = 1 ]"

rm -rf "$O"
echo "$fails failed"; [ $fails = 0 ]
