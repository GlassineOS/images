#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of scripts/materialize without a stage build. A fixture tree with one entry
# of each kind a base must keep (FR-005: a regular file owned by another user, setuid, a
# sticky directory, a symlink, a dangling symlink, a hardlink pair, a FIFO, a character
# device, security.capability, a user.* xattr) is made by one script, both in a
# container (tarred with GNU tar) and through BuildKit's own tar export, and the two are
# compared. With a fixture repository (Dockerfile chain with locks and branch pins, a
# target) and a fake kernel export, it checks: a new base and its records, a reused base
# with a second build record, build ids (-N when taken), the default parent by build
# time (A, B, A, then C gets A), a delta that writes only the changed file and the base
# manifest, trial reasons, cut files never taken as complete, the host lock, the content
# manifest and id of a known tree, and that /etc/resolv.conf or a kernel mismatch fails.
#   scripts/test-materialize.sh     exit 0 = all checks pass
# Needs docker (privileged containers, buildx) and python3. Works in
# .out/test-materialize/ under the checkout and removes it at the end.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-materialize
rm -rf "$O"; mkdir -p "$O"
export XDG_RUNTIME_DIR="$O"        # the host lock, apart from any real run
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
M() { "$P/scripts/materialize" --repo "$O/repo" "$@"; }
v() { sed -n "s/^$1=//p" "$2" | head -n 1; }
BOOT_COMMIT=0123456789abcdef0123456789abcdef01234567
REL=7.3.0-fake.abcdef-g0123456789ab

# --- the fixture repository: a chain with a stage that has no lock (skipped by locks)
R=$O/repo; mkdir -p "$R/stages/base0" "$R/stages/middle" "$R/stages/device-fixture" "$R/targets/fixture"
cat > "$R/Dockerfile" <<EOF
ARG DEVICE=fixture
ARG LOCK=check
# branch: main
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

# --- the fixture tree: one script, run in a container and inside a BuildKit stage
F=$O/fx; mkdir -p "$F"
cat > "$F/mkfix.sh" <<'EOS'
set -eu
r=$1; mkdir -p $r/etc $r/usr/bin $r/usr/lib $r/run $r/dev $r/tmp $r/lib/apk/db
echo "127.0.0.1 localhost" > $r/etc/hosts
z=$(python3 -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha1(open(sys.argv[1], "rb").read()).digest()).decode())' $r/etc/hosts)
printf 'P:musl\nV:1.0-r0\n\nP:fixture-hosts\nV:1.0-r0\nF:etc\nR:hosts\nZ:Q1%s\n\nP:busybox\nV:1.0-r0\n\n' "$z" > $r/lib/apk/db/installed
echo one > $r/etc/config
echo user > $r/etc/owned; chown 1000:1000 $r/etc/owned
echo su > $r/usr/bin/su; chmod 4755 $r/usr/bin/su
chmod 1777 $r/tmp
ln -s su $r/usr/bin/link
ln -s /nonexistent/target $r/usr/bin/dangling
echo pair > $r/usr/lib/a; ln $r/usr/lib/a $r/usr/lib/b
mkfifo $r/run/fifo
mknod $r/dev/null c 1 3
echo ping > $r/usr/bin/ping; setcap cap_net_raw+ep $r/usr/bin/ping
echo note > $r/usr/lib/note; setfattr -n user.glassine.test -v hello $r/usr/lib/note
EOS
cat > "$F/Dockerfile" <<'EOF'
FROM alpine:3.24 AS make
RUN apk add -q --no-progress attr libcap-utils python3
COPY mkfix.sh /mkfix.sh
RUN sh /mkfix.sh /r
FROM scratch
COPY --from=make /r/ /
EOF
docker buildx build -q -o "type=tar,dest=$O/buildkit.tar" "$F" > /dev/null 2>"$O/buildkit.log" \
	|| { cat "$O/buildkit.log"; echo "FAIL BuildKit fixture build"; fails=$((fails + 1)); }

docker run --rm --privileged -v "$O":/o -v "$P/scripts":/s:ro -e HOST="$(id -u):$(id -g)" alpine:3.24 sh -euc '
apk add -q --no-progress tar attr libcap-utils python3 >/dev/null
mkdir /t && mount -t tmpfs tmpfs /t && cd /t
sh /o/fx/mkfix.sh r
mk() { tar -C r --numeric-owner --xattrs --xattrs-include="*" -cf /o/$1.tar $(ls -A r); }
mk base1
echo two > r/etc/config; mk base2
echo three > r/etc/config; mk base3
echo "nameserver 10.0.0.1" > r/etc/resolv.conf; mk resolv
# the fixture and the BuildKit export, each extracted as materialize does
x() { mkdir $2; tar -C $2 --numeric-owner --xattrs --xattrs-include="*" -xpf $1; python3 -I /s/tree-manifest.py $2 > /o/$3.manifest; }
x /o/base1.tar f fixture
[ ! -s /o/buildkit.tar ] || x /o/buildkit.tar bk buildkit
# a known tree: its manifest and id are fixed bytes
mkdir -p k/d; printf "abc" > k/d/f; chmod 644 k/d/f; ln k/d/f k/d/g; ln -s d/f k/l
chmod 755 k k/d; chown -R 0:0 k
python3 -I /s/tree-manifest.py k > /o/known.manifest
chown -R "$HOST" /o'

# --- FR-005 through BuildKit's tar export
if [ -s "$O/buildkit.manifest" ]; then
	diff "$O/fixture.manifest" "$O/buildkit.manifest" | sed 's/^/    /' || :
fi
check "BuildKit's tar export keeps every FR-005 kind (same content manifest as the fixture)" \
	"[ -s '$O/buildkit.manifest' ] && cmp -s '$O/fixture.manifest' '$O/buildkit.manifest'"

# --- the content manifest and id of a known tree (FR-010)
cat > "$O/known.expect" <<'EOF'
. d 0:0 0755 0 -
d d 0:0 0755 0 -
d/f - 0:0 0644 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad =d/f
d/g - 0:0 0644 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad =d/f
l l 0:0 0777 0 -> d/f
EOF
check "content manifest of a known tree: exact bytes" "cmp -s '$O/known.manifest' '$O/known.expect'"
check "its tree16: sha256 of the manifest + the base manifest's lines other than base=" \
	"[ \"\$( { cat '$O/known.expect'; printf 'format=1\nlocks=%064d\nneeds=\nfeatures=\n' 0; } | sha256sum | cut -c1-16)\" = 55ba5152d7965324 ]"

A=$O/art; T=$A/fixture
EKEY=$(printf %064d 1); EREF=registry.example/images-kernel@sha256:$(printf %064d 2)
clean_info() { printf 'images_commit=%040d\nimages_clean=yes\ninput.BOOT_COMMIT.tree=t1\nbuilder.kernel-build=sha256:00\nunmerged=\nexport.kernel-export.key=%s\nexport.kernel-export.from=%s\nexport.boot-export.key=%s\nexport.boot-export.from=built\n' 7 "$EKEY" "$EREF" "$EKEY" > "$O/info"; }
clean_info

# --- 1. a new base (no build records yet: no parent)
out=$(M --time 2026-01-01T10:00:00Z --build-info "$O/info" "$O/base1.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | sed 's/^/    /'
check "new base: exit 0" "[ $rc = 0 ]"
ID1=$(ls "$T/bases" | head -n 1); B=$T/bases/$ID1; R1=$T/builds/20260101-100000
check "base id = build date + tree16 (content manifest + base manifest without base=)" "[ '$ID1' = 20260101-\$(cat '$B/tree.manifest' | { cat; grep -v '^base=' '$B/base.manifest'; } | sha256sum | cut -c1-16) ]"
check "build id = the start time" "[ -s '$R1/manifest' ] && [ \"\$(v build '$R1/manifest')\" = 20260101-100000 ]"
check "base files" "for f in record base.manifest tree.manifest packages base.btrfs.zst; do [ -s '$B'/\$f ] || exit 1; done && ! ls '$B'/base.from-* >/dev/null 2>&1"
check "build files" "for f in manifest kernel.manifest boot.manifest select; do [ -s '$R1'/\$f ] || exit 1; done"
check "modules stream and manifest, boot image, dtb, initramfs" "[ -s '$A/modules/$REL.btrfs.zst' ] && [ -s '$A/modules/$REL.manifest' ] && [ -s '$A/bootimg/$IMG.img' ] && [ -s '$A/boot/dtb/$DTB.dtb' ] && [ -s '$A/boot/initramfs/$IRD.manifest' ]"
check "nothing temporary left, outputs owned by the invoking user" "[ -z \"\$(find '$A' -name '.*' -o -name '*.tmp')\" ] && [ -z \"\$(find '$A' ! -user \$(id -u))\" ]"
check "copies of the kernel, boot and select records" "cmp -s '$R1/kernel.manifest' '$K/modules/$REL/kernel.manifest' && cmp -s '$R1/boot.manifest' '$K/bootimg/$IMG.manifest' && cmp -s '$R1/select' '$K/select/fixture'"
check "packages: name=version, sorted" "[ \"\$(cat '$B/packages')\" = \"\$(printf 'busybox=1.0-r0\nfixture-hosts=1.0-r0\nmusl=1.0-r0')\" ]"
check "base manifest: format, base, locks of the fixture chain, empty needs/features" "[ \"\$(cat '$B/base.manifest')\" = \"\$(printf 'format=1\nbase=%s\nlocks=%s\nneeds=\nfeatures=' '$ID1' $LOCKS)\" ]"
check "build manifest: format=1 first, every key" "[ \"\$(head -n 1 '$R1/manifest')\" = format=1 ] && for k in build base target tree parent reused uuid received_uuid built images_commit images_clean trial trial_reasons unmerged locks lock.base0 lock.device-fixture arg.DEVICE arg.LOCK arg.BOOT_COMMIT input.BOOT_COMMIT.commit input.BOOT_COMMIT.tree input.BOOT_COMMIT.branch input.BOOT_COMMIT.local builder.kernel-build kernel_release bootimg boot_commit stream stream_sha256 delta delta_sha256 modules_stream modules_stream_sha256; do grep -q \"^\$k=\" '$R1/manifest' || { echo \"    missing \$k\"; exit 1; }; done"
check "build manifest values" "[ \"\$(v base '$R1/manifest')\" = '$ID1' ] && [ \"\$(v reused '$R1/manifest')\" = no ] && [ -z \"\$(v parent '$R1/manifest')\" ] && [ \"\$(v locks '$R1/manifest')\" = $LOCKS ] && [ \"\$(v lock.base0 '$R1/manifest')\" = \"\$(sha256sum < '$R/stages/base0/lock' | cut -c1-64)\" ] && [ \"\$(v kernel_release '$R1/manifest')\" = $REL ] && [ \"\$(v bootimg '$R1/manifest')\" = $IMG ] && [ \"\$(v boot_commit '$R1/manifest')\" = $BOOT_COMMIT ] && [ \"\$(v input.BOOT_COMMIT.branch '$R1/manifest')\" = main ] && [ \"\$(v input.BOOT_COMMIT.commit '$R1/manifest')\" = $BOOT_COMMIT ] && [ \"\$(v input.BOOT_COMMIT.tree '$R1/manifest')\" = t1 ] && [ \"\$(v stream '$R1/manifest')\" = 'fixture/bases/$ID1/base.btrfs.zst' ] && [ \"\$(v stream_sha256 '$R1/manifest')\" = \"\$(sha256sum < '$B/base.btrfs.zst' | cut -c1-64)\" ]"
check "build manifest: each export's key and where it came from (specs/003 FR-009)" "[ \"\$(v export.kernel-export.key '$R1/manifest')\" = $EKEY ] && [ \"\$(v export.kernel-export.from '$R1/manifest')\" = $EREF ] && [ \"\$(v export.boot-export.from '$R1/manifest')\" = built ]"
check "pinned clean build: not a trial" "[ \"\$(v trial '$R1/manifest')\" = no ] && [ -z \"\$(v trial_reasons '$R1/manifest')\" ]"
check "uuid = received_uuid, both set, in the build and the base record" "[ -n \"\$(v uuid '$R1/manifest')\" ] && [ \"\$(v uuid '$R1/manifest')\" = \"\$(v received_uuid '$R1/manifest')\" ] && [ \"\$(v uuid '$B/record')\" = \"\$(v uuid '$R1/manifest')\" ] && [ \"\$(v build '$B/record')\" = 20260101-100000 ]"
check "locked stages only (middle has no lock)" "! grep -q '^lock.middle=' '$R1/manifest'"
TM=$B/tree.manifest
check "FR-005 in the content manifest: owner, setuid, sticky, symlinks, hardlinks" "grep -qx 'etc/owned - 1000:1000 0644 5 .*' '$TM' && grep -q '^usr/bin/su - 0:0 4755 ' '$TM' && grep -qx 'tmp d 0:0 1777 0 -' '$TM' && grep -qx 'usr/bin/link l 0:0 0777 0 -> su' '$TM' && grep -qx 'usr/bin/dangling l 0:0 0777 0 -> /nonexistent/target' '$TM' && grep -q '^usr/lib/a .* =usr/lib/a\$' '$TM' && grep -q '^usr/lib/b .* =usr/lib/a\$' '$TM'"
check "FR-005 in the content manifest: FIFO, device node, capability, user xattr" "grep -qx 'run/fifo p 0:0 0644 0 -' '$TM' && grep -qx 'dev/null c 0:0 0644 0 dev 1,3' '$TM' && grep -q '^usr/bin/ping .* security.capability=' '$TM' && grep -q '^usr/lib/note .* user.glassine.test=68656c6c6f\$' '$TM'"
check "per-step times reported" "echo \"\$out\" | grep -q '^time extract into subvolume ' && echo \"\$out\" | grep -q '^time full stream ' && echo \"\$out\" | grep -q '^time materialize (total) '"

# the base manifest and FR-005, read back from the full stream by an independent receive
docker run --rm --privileged -v "$B":/b:ro alpine:3.24 sh -euc '
apk add -q --no-progress btrfs-progs zstd attr libcap-utils >/dev/null
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
mkdir /w && mount -t tmpfs tmpfs /w && truncate -s 1073741824 /w/f && mkfs.btrfs -q /w/f && mkdir /w/m && mount -o loop /w/f /w/m
zstd -dc /b/base.btrfs.zst | btrfs -q receive /w/m
cd /w/m/*; echo "subvolume=${PWD##*/}"; btrfs property get -ts . ro
cmp usr/share/glassine/base.manifest /b/base.manifest && echo manifest=same
stat -c "mode=%a owner=%u:%g" usr/share/glassine/base.manifest
getcap usr/bin/ping; getfattr --only-values -n user.glassine.test usr/lib/note; echo
stat -c "%F %t,%T" run/fifo dev/null
cd /; umount /w/m' > "$O/recv" 2>&1 || true
sed 's/^/    /' "$O/recv"
check "received: one read-only subvolume named by the id, base manifest 0644 root" "grep -qx 'subvolume=$ID1' '$O/recv' && grep -qx ro=true '$O/recv' && grep -qx manifest=same '$O/recv' && grep -qx 'mode=644 owner=0:0' '$O/recv'"
check "received: capability, user xattr, FIFO, device node 1,3" "grep -q 'usr/bin/ping cap_net_raw=ep' '$O/recv' && grep -qx hello '$O/recv' && grep -q '^fifo ' '$O/recv' && grep -qx 'character special file 1,3' '$O/recv'"

# --- 2. the same tree again, on a later day: reused, a second build record
out=$(M --time 2026-01-02T10:00:00Z --build-info "$O/info" "$O/base1.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | sed 's/^/    /'
R2=$T/builds/20260102-100000
check "same tree: exit 0, says reused" "[ $rc = 0 ] && echo \"\$out\" | grep -q 'base $ID1 (reused)'"
check "same tree: same base (first build's date), no new base or stream" "[ \"\$(ls '$T/bases')\" = '$ID1' ] && ! echo \"\$out\" | grep -q '^time full stream'"
check "same tree: its own build record, reused=yes, the base's uuid and stream" "[ \"\$(v reused '$R2/manifest')\" = yes ] && [ \"\$(v base '$R2/manifest')\" = '$ID1' ] && [ \"\$(v uuid '$R2/manifest')\" = \"\$(v uuid '$R1/manifest')\" ] && [ \"\$(v stream_sha256 '$R2/manifest')\" = \"\$(v stream_sha256 '$R1/manifest')\" ]"
M --time 2026-01-02T10:00:00Z --build-info "$O/info" "$O/base1.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "a build id that is taken gets -2" "[ $rc = 0 ] && [ \"\$(v build '$T/builds/20260102-100000-2/manifest')\" = 20260102-100000-2 ]"

# --- the host lock (FR-003)
python3 -c 'import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(30)' \
	"$O/glassine-images-materialize.lock" & holder=$!
sleep 1
M --time 2026-01-03T09:00:00Z "$O/base2.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
kill $holder; wait $holder 2>/dev/null || :
check "lock held elsewhere: exit 4, nothing made" "[ $rc = 4 ] && [ \"\$(ls '$T/builds' | wc -l)\" = 3 ]"

# --- 3. B: parent + delta, the parent by default (the base of the newest build record)
out=$(M --time 2026-01-03T10:00:00Z --build-info "$O/info" "$O/base2.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | sed 's/^/    /'
R3=$T/builds/20260103-100000; ID2=$(v base "$R3/manifest"); B2=$T/bases/$ID2
check "B: exit 0, new base, parent = the newest record's base" "[ $rc = 0 ] && [ '$ID2' != '$ID1' ] && [ \"\$(v parent '$R3/manifest')\" = '$ID1' ] && [ \"\$(v parent '$B2/record')\" = '$ID1' ]"
check "delta file named with its parent, in both records" "[ -s '$B2/base.from-$ID1.btrfs.zst' ] && [ \"\$(v delta '$B2/record')\" = 'base.from-$ID1.btrfs.zst' ] && [ \"\$(v delta '$R3/manifest')\" = 'fixture/bases/$ID2/base.from-$ID1.btrfs.zst' ] && [ \"\$(v delta_sha256 '$R3/manifest')\" = \"\$(sha256sum < '$B2/base.from-$ID1.btrfs.zst' | cut -c1-64)\" ]"
written=$(echo "$out" | awk 'f && /^(materialize|time|==)/ { f = 0 } f; /^== delta: files written/ { f = 1 }')
check "the delta writes only the changed file and the base manifest" "[ \"\$(echo \"\$written\" | sort | tr '\n' ' ')\" = 'etc/config usr/share/glassine/base.manifest ' ]"
check "full stream and parent + delta compared, same received UUID" "echo \"\$out\" | grep -q 'same content: received parent + delta' && echo \"\$out\" | grep -q 'full stream and parent + delta: received UUID'"
check "modules stream reused for the same release" "echo \"\$out\" | grep -q 'the artifacts folder has its stream'"

# --- 4. A again (reused), then C: its parent is A, the base of the newest record
M --time 2026-01-04T10:00:00Z --build-info "$O/info" "$O/base1.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "A again: reused" "[ $rc = 0 ] && [ \"\$(v base '$T/builds/20260104-100000/manifest')\" = '$ID1' ]"
out=$(M --time 2026-01-05T10:00:00Z --build-info "$O/info" "$O/base3.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
R5=$T/builds/20260105-100000
check "A, B, A, then C: C's parent is A, not B" "[ $rc = 0 ] && [ \"\$(v parent '$R5/manifest')\" = '$ID1' ] && [ \"\$(v base '$R5/manifest')\" != '$ID2' ]"
ID3=$(v base "$R5/manifest")
M --time 2026-01-05T11:00:00Z --no-parent --build-info "$O/info" "$O/base3.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "a reused base keeps its one delta (no second parent)" "[ $rc = 0 ] && [ \"\$(ls '$T/bases/$ID3' | grep -c '^base.from-')\" = 1 ]"

# --- 5. trial reasons (FR-017)
printf 'images_clean=no\ninput.BOOT_COMMIT.local=yes\n' > "$O/info-trial"
M --time 2026-01-06T10:00:00Z --arg LOCK=refresh --build-info "$O/info-trial" "$O/base1.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
R6=$T/builds/20260106-100000
check "trial: local input, argument off its default, dirty checkout" "[ $rc = 0 ] && [ \"\$(v trial '$R6/manifest')\" = yes ] && [ \"\$(v trial_reasons '$R6/manifest')\" = 'local:BOOT_COMMIT arg:LOCK dirty' ] && [ \"\$(v arg.LOCK '$R6/manifest')\" = refresh ] && [ \"\$(v input.BOOT_COMMIT.local '$R6/manifest')\" = yes ]"
M --time 2026-01-06T11:00:00Z --arg LOCK=check --build-info "$O/info" "$O/base1.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "an argument set to its default is no trial" "[ $rc = 0 ] && [ \"\$(v trial '$T/builds/20260106-110000/manifest')\" = no ]"

# --- 6. cut files are never complete
A2=$O/art2
mkdir -p "$A2/modules" "$A2/fixture/bases/.incoming-1"
echo cut > "$A2/modules/$REL.btrfs.zst.tmp"; cp "$A/modules/$REL.manifest" "$A2/modules/$REL.manifest"
cp "$B/tree.manifest" "$B/record" "$A2/fixture/bases/.incoming-1/"
head -c 1000 "$B/base.btrfs.zst" > "$A2/fixture/bases/.incoming-1/base.btrfs.zst"
out=$(M --time 2026-01-07T10:00:00Z "$O/base1.tar" "$K" fixture "$A2" 2>&1) && rc=0 || rc=$?
check "a .tmp stream and a staging directory are not taken: new modules stream, new base" "[ $rc = 0 ] && echo \"\$out\" | grep -q '^time modules subvolume + stream' && [ \"\$(v reused \"\$(ls -d '$A2'/fixture/builds/*)/manifest\")\" = no ]"
cp "$B2/base.btrfs.zst" "$O/b2.keep"; truncate -s 1000 "$B2/base.btrfs.zst"
M --time 2026-01-07T11:00:00Z --parent "$ID2" "$O/base3.tar" "$K" fixture "$A" > "$O/o" 2>&1 && rc=0 || rc=$?
check "a cut stream as named parent: exit 1, named" "[ $rc = 1 ] && grep -q 'not the stream its record names' '$O/o'"
M --time 2026-01-07T12:00:00Z "$O/base2.tar" "$K" fixture "$A" > "$O/o" 2>&1 && rc=0 || rc=$?
check "a cut stream is not reused: exit 1, named" "[ $rc = 1 ] && grep -q \"base $ID2: its full stream doesn't match\" '$O/o'"
cp "$O/b2.keep" "$B2/base.btrfs.zst"
M --parent 20260101-0000000000000000 "$O/base2.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "a named parent that isn't there: exit 1" "[ $rc = 1 ]"

# --- 7. FR-020 and the inputs
n=$(ls "$T/builds" | wc -l)
out=$(M --no-parent "$O/resolv.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
echo "$out" | grep -e FAIL | sed 's/^/    /'
check "/etc/resolv.conf in the export: exit 1, named, no record" "[ $rc = 1 ] && echo \"\$out\" | grep -q 'resolv.conf is in the tree' && [ \"\$(ls '$T/builds' | wc -l)\" = $n ]"
printf 'images_comit=x\n' > "$O/bad-info"
M --build-info "$O/bad-info" "$O/base1.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "unknown build-info key: exit 1" "[ $rc = 1 ]"
printf 'input.LINUX.tree=x\n' > "$O/bad-info"
M --build-info "$O/bad-info" "$O/base1.tar" "$K" fixture "$A" > /dev/null 2>&1 && rc=0 || rc=$?
check "build-info for an input without a branch pin: exit 1" "[ $rc = 1 ]"
sed -i 's/^needs=$/needs=btrfs/' "$K/boot/initramfs/$IRD.manifest"
M "$O/base1.tar" "$K" fixture "$A" > "$O/o" 2>&1 && rc=0 || rc=$?
check "initramfs needs not provided: exit 1" "[ $rc = 1 ] && grep -q 'does not provide what the initramfs needs' '$O/o'"
sed -i "s/^commit=.*/commit=$(printf %040d 1)/; s/^needs=btrfs$/needs=/" "$K/boot/initramfs/$IRD.manifest"
M "$O/base1.tar" "$K" fixture "$A" > "$O/o" 2>&1 && rc=0 || rc=$?
check "initramfs from another boot commit: exit 1" "[ $rc = 1 ] && grep -q 'pinned boot commit' '$O/o'"
sed -i "s/^kernel=.*/kernel=7.3.0-fake.000000-g0123456789ab/" "$K/select/fixture"
out=$(M --no-parent "$O/base1.tar" "$K" fixture "$A" 2>&1) && rc=0 || rc=$?
check "select record names another kernel: exit 1 before any container" "[ $rc = 1 ] && echo \"\$out\" | grep -q 'select record kernel=' && ! echo \"\$out\" | grep -q '^time '"

rm -rf "$O"
echo "$fails failed"; [ $fails = 0 ]
