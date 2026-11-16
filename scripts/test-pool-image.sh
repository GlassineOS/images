#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of scripts/pool-image without a stage build. A fixture repository and a fake
# kernel export (as in test-materialize.sh), two fixture bases made by scripts/materialize
# (A, then B with A as its parent, so B has a delta from A), a fake ram environment and
# recovery export, and a fake boot loader and layout the fixture target pins (file:// URLs
# in its release.conf). It checks: the release folder and release.json (format 1, the
# installer's rules for an entry: plain path, 64 lower-case hex, size; kind,
# min_partition_bytes, nothing missing), the boot loader taken from --boot-loader and the
# layout fetched from its URL; a boot loader or layout that isn't the pinned one, and
# --boot-loader for a target without pins, refused before anything is made; a target
# without pins and without --ramenv / --recovery names those roles missing; the pool image is small (not the partition), mounts read-only with
# bases/<A> read-only and carrying the base record's received UUID, modules/<release>,
# state/format and the install marker; then, on a copy grown to min_partition_bytes as the
# first start does, B's INCREMENTAL stream (base.from-A, as materialize made it) receives
# onto A inside the image: B read-only, B's received UUID, B's content. Also: a boot
# without the init verb fails and leaves nothing; an existing --out is refused.
#
#   scripts/test-pool-image.sh                  the layout by GlassineOS/boot at the
#                                               Dockerfile's BOOT_COMMIT (fetched)
#   POOL_TEST_BOOT=DIR scripts/test-pool-image.sh   by the boot checkout DIR
# Needs docker (privileged containers), git and python3. Works in .out/test-pool-image/.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-pool-image
rm -rf "$O"; mkdir -p "$O"
export XDG_RUNTIME_DIR="$O"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
v() { sed -n "s/^$1=//p" "$2" | head -n 1; }
BOOT_COMMIT=0123456789abcdef0123456789abcdef01234567
REL=7.3.0-fake.abcdef-g0123456789ab

# --- the fixture repository and the fake kernel export (test-materialize.sh's)
R=$O/repo; mkdir -p "$R/stages/base0" "$R/targets/fixture"
cat > "$R/Dockerfile" <<EOF
ARG DEVICE=fixture
# branch: main
ARG BOOT_COMMIT=$BOOT_COMMIT
FROM scratch AS base0
FROM base0 AS device-fixture
FROM device-\${DEVICE} AS finish
FROM finish AS base-export
EOF
printf 'busybox=1.0-r0\n' > "$R/stages/base0/lock"
printf 'arch=arm64\nkernel=fake\n' > "$R/targets/fixture/target"
printf 'DEVICE=fixture\nPART_SIZE=67108864\n' > "$R/targets/fixture/board.conf"
K=$O/k; mkdir -p "$K/modules/$REL/kernel" "$K/boot/dtb" "$K/boot/initramfs" "$K/bootimg" "$K/select"
echo image > "$K/modules/$REL/Image.gz"; head -c 300000 /dev/urandom > "$K/modules/$REL/kernel/x.ko"
printf 'format=1\nrelease=%s\nprovides=\nfeatures=\n' $REL > "$K/modules/$REL/kernel.manifest"
# the device tree and the initramfs, named by their content as the build names them
sha() { sha256sum < "$1" | cut -c1-64; }
echo dtb > "$O/dtb"; DTB=fixture@$(sha "$O/dtb" | cut -c1-16); mv "$O/dtb" "$K/boot/dtb/$DTB.dtb"
printf 'format=1\ndevice=fixture\nsha256=%s\n' "$(sha "$K/boot/dtb/$DTB.dtb")" > "$K/boot/dtb/$DTB.manifest"
echo ird > "$O/ird"; IRD=0123456789ab@$(sha "$O/ird" | cut -c1-16); mv "$O/ird" "$K/boot/initramfs/$IRD.cpio.gz"
printf 'format=1\ncommit=%s\nsha256=%s\nneeds=\nfeatures=\n' $BOOT_COMMIT "$(sha "$K/boot/initramfs/$IRD.cpio.gz")" > "$K/boot/initramfs/$IRD.manifest"
IMG=00000000000000aa
head -c 4194304 /dev/urandom > "$K/bootimg/$IMG.img"
printf 'format=1\nid=%s\ndevice=fixture\nkernel=%s\ndtb=%s\ninitramfs=%s\nsize=%s\nsha256=%s\n' $IMG $REL $DTB $IRD \
	4194304 "$(sha256sum < "$K/bootimg/$IMG.img" | cut -c1-64)" > "$K/bootimg/$IMG.manifest"
printf 'format=1\ndevice=fixture\nkernel=%s\ndtb=%s\ninitramfs=%s\n' $REL $DTB $IRD > "$K/select/fixture"

# --- a fake ram environment export
RE=$O/ramenv; mkdir -p "$RE/ramenv"; RID=00000000000000bb
head -c 2097152 /dev/urandom > "$RE/ramenv/$RID.img"
printf 'format=1\nid=%s\ndevice=fixture\nkernel=%s\nsize=2097152\nsha256=%s\n' $RID $REL \
	"$(sha256sum < "$RE/ramenv/$RID.img" | cut -c1-64)" > "$RE/ramenv/$RID.manifest"

# --- a fake recovery export, and the boot loader and layout the fixture target pins
RC=$O/recovery; mkdir -p "$RC/recovery"; CID=00000000000000cc
head -c 3145728 /dev/urandom > "$RC/recovery/$CID.img"
printf 'format=1\nid=%s\ndevice=fixture\nkernel=%s\nsize=3145728\nsha256=%s\nrole=recovery\n' $CID $REL \
	"$(sha256sum < "$RC/recovery/$CID.img" | cut -c1-64)" > "$RC/recovery/$CID.manifest"
PIN=$O/pinned; mkdir -p "$PIN"
head -c 145592 /dev/urandom > "$PIN/abl.elf"; head -c 145592 /dev/urandom > "$PIN/other.elf"
printf '{"sector": 512, "entries": 64}\n' > "$PIN/layout.json"; printf '{"sector": 4096}\n' > "$PIN/other.json"
cp -r "$R" "$O/repo-nopins"
printf 'BOOT_LOADER_URL=file://%s\nBOOT_LOADER_SHA256=%s\nBOOT_LOADER_PART_SIZE=1048576\nLAYOUT_URL=file://%s\nLAYOUT_SHA256=%s\n' \
	"$PIN/abl.elf" "$(sha256sum < "$PIN/abl.elf" | cut -c1-64)" "$PIN/layout.json" "$(sha256sum < "$PIN/layout.json" | cut -c1-64)" \
	> "$R/targets/fixture/release.conf"

# --- boot: the commit this repository pins (BOOT_COMMIT), or a checkout given
if [ -n "${POOL_TEST_BOOT:-}" ]; then
	BOOT=$(cd "$POOL_TEST_BOOT" && pwd)
else
	BOOT=$O/boot
	pin=$(sed -n 's/^ARG BOOT_COMMIT=//p' "$P/Dockerfile"); url=$(sed -n 's/^ARG BOOT=//p' "$P/Dockerfile")
	sh "$P/scripts/git-fetch.sh" test-pool-image "$url" "$pin" "$BOOT" || { echo "FAIL fetching boot $pin"; exit 1; }
fi
echo "layout by boot $(git -C "$BOOT" rev-parse HEAD)"
NOINIT=$O/boot-noinit; mkdir -p "$NOINIT/sbin" "$NOINIT/lib"; : > "$NOINIT/lib/glassine-state.sh"
printf '#!/bin/sh\necho "usage: glassine-deploy status|..." >&2; exit 2\n' > "$NOINIT/sbin/glassine-deploy"
git -C "$NOINIT" init -q && git -C "$NOINIT" add -A && git -C "$NOINIT" -c user.name=t -c user.email=t@t commit -qm noinit

# --- two fixture bases: A, then B (one file changed), B's parent A
docker run --rm -v "$O":/o -e HOST="$(id -u):$(id -g)" alpine:3.24 sh -euc '
mkdir -p /r/etc /r/usr/lib /r/lib/apk/db && cd /r
printf "P:busybox\nV:1.0-r0\n\n" > lib/apk/db/installed
echo one > etc/config; head -c 2000000 /dev/urandom > usr/lib/blob
tar --numeric-owner -cf /o/a.tar $(ls -A)
echo two > etc/config; tar --numeric-owner -cf /o/b.tar $(ls -A)
chown "$HOST" /o/a.tar /o/b.tar'
A=$O/art
M() { "$P/scripts/materialize" --repo "$R" "$@" > "$O/m.log" 2>&1 || { cat "$O/m.log"; exit 1; }; }
M --time 2026-01-01T10:00:00Z --no-parent "$O/a.tar" "$K" fixture "$A"
M --time 2026-01-02T10:00:00Z "$O/b.tar" "$K" fixture "$A"
BA=$A/fixture/builds/20260101-100000; BB=$A/fixture/builds/20260102-100000
IDA=$(v base "$BA/manifest"); IDB=$(v base "$BB/manifest")
check "fixture: B is a new base with A as its parent and a delta" "[ '$IDA' != '$IDB' ] && [ \"\$(v parent '$BB/manifest')\" = '$IDA' ] && [ -s '$A/fixture/bases/$IDB/base.from-$IDA.btrfs.zst' ]"

PI() { "$P/scripts/pool-image" --repo "$R" "$@"; }

# --- a boot without init: refused, nothing left
PI --build 20260101-100000 --boot "$NOINIT" --out "$O/rel-noinit" "$A" fixture > "$O/o" 2>&1 && rc=0 || rc=$?
check "boot without the init verb: exit 1, named, nothing left" "[ $rc = 1 ] && grep -q 'no init verb' '$O/o' && [ ! -e '$O/rel-noinit' ] && [ -z \"\$(ls -A '$O' | grep '^\.rel-noinit')\" ]"

# --- pins: wrong bytes and options a target can't check are refused before anything is made
PI --build 20260101-100000 --boot "$BOOT" --boot-loader "$PIN/other.elf" --out "$O/rel-x" "$A" fixture > "$O/o" 2>&1 && rc=0 || rc=$?
check "a boot loader that isn't the pinned one: exit 1, named, nothing left" "[ $rc = 1 ] && grep -q 'boot-loader: .*not the file the target pins' '$O/o' && [ ! -e '$O/rel-x' ] && [ -z \"\$(ls -A '$O' | grep '^\.rel-x')\" ]"
PI --build 20260101-100000 --boot "$BOOT" --layout "$PIN/other.json" --out "$O/rel-x" "$A" fixture > "$O/o" 2>&1 && rc=0 || rc=$?
check "a layout that isn't the pinned one: exit 1, named" "[ $rc = 1 ] && grep -q 'partition-layout: .*not the file the target pins' '$O/o' && [ ! -e '$O/rel-x' ]"
"$P/scripts/pool-image" --repo "$O/repo-nopins" --build 20260101-100000 --boot "$BOOT" --boot-loader "$PIN/abl.elf" --out "$O/rel-x" "$A" fixture > "$O/o" 2>&1 && rc=0 || rc=$?
check "--boot-loader for a target without pins: exit 1" "[ $rc = 1 ] && grep -q 'no pins' '$O/o' && [ ! -e '$O/rel-x' ]"

# --- the release of build A
out=$(PI --build 20260101-100000 --boot "$BOOT" --ramenv "$RE" --recovery "$RC" --boot-loader "$PIN/abl.elf" --out "$O/rel" "$A" fixture 2>&1) && rc=0 || rc=$?
echo "$out" | sed 's/^/    /'
check "pool-image: exit 0" "[ $rc = 0 ]"
check "release folder: release.json, base, kernel, ram environment, nothing temporary" "[ -s '$O/rel/release.json' ] && [ -s '$O/rel/base/$IDA.pool.img' ] && [ -s '$O/rel/kernel/$IMG.img' ] && [ -s '$O/rel/ram-environment/$RID.img' ] && [ -z \"\$(find '$O/rel' -name '.*' -o -name '*.tmp' -o -name o)\" ] && [ -z \"\$(ls -A '$O' | grep '^\.rel\.')\" ]"
python3 -I - "$O/rel" "$IDA" "$IMG" "$RID" "$(v received_uuid "$BA/manifest")" "$CID" "$PIN" > "$O/json.log" 2>&1 <<'EOF' && jrc=0 || jrc=$?
import hashlib, json, os, re, sys
d, ida, img, rid, ruuid, cid, pin = sys.argv[1:]
r = json.load(open(os.path.join(d, 'release.json')))
assert r['release_format'] == 1, r['release_format']
plain = lambda p: p and not p.startswith('/') and '\\' not in p and ':' not in p and all(c not in ('', '.', '..') for c in p.split('/'))
for role, e in r['artifacts'].items():
    assert plain(e['file']), (role, e['file'])
    assert re.fullmatch(r'[0-9a-f]{64}', e['sha256']), role
    b = open(os.path.join(d, e['file']), 'rb').read()
    assert len(b) == e['size'], (role, len(b), e['size'])
    assert hashlib.sha256(b).hexdigest() == e['sha256'], role
    assert isinstance(e['min_partition_bytes'], int) and e['min_partition_bytes'] >= e['size'], role
assert sorted(r['artifacts']) == ['base', 'boot-loader', 'kernel', 'partition-layout', 'ram-environment', 'recovery'], sorted(r['artifacts'])
b = r['artifacts']['base']
assert b['kind'] == 'btrfs-pool-image' and b['file'] == f'base/{ida}.pool.img' and b['base'] == ida, b
assert b['received_uuid'] == ruuid, b
assert b['min_partition_bytes'] >= 1 << 30 and b['min_partition_bytes'] % (1 << 20) == 0, b
assert b['size'] % (1 << 20) == 0 and b['size'] < 512 << 20, b['size']
k = r['artifacts']['kernel']
assert k['kind'] == 'raw-image' and k['file'] == f'kernel/{img}.img' and k['min_partition_bytes'] == 67108864, k
e = r['artifacts']['ram-environment']
assert e['kind'] == 'raw-image' and e['file'] == f'ram-environment/{rid}.img', e
l = r['artifacts']['boot-loader']
assert l['kind'] == 'raw-image' and l['file'] == 'boot-loader/abl.elf' and l['min_partition_bytes'] == 1048576, l
assert l['url'] == f'file://{pin}/abl.elf' and open(os.path.join(d, l['file']), 'rb').read() == open(f'{pin}/abl.elf', 'rb').read(), l
y = r['artifacts']['partition-layout']
assert y['kind'] == 'gpt-recipe' and y['file'] == 'partition-layout/layout.json' and y['min_partition_bytes'] == y['size'], y
assert json.load(open(os.path.join(d, y['file']))) == {'sector': 512, 'entries': 64}, y
c = r['artifacts']['recovery']
assert c['kind'] == 'raw-image' and c['file'] == f'recovery/{cid}.img' and c['recovery'] == cid and c['min_partition_bytes'] == c['size'], c
assert r['missing'] == [], r['missing']
assert r['build'] == '20260101-100000' and r['target'] == 'fixture'
assert r['trial'] is True and any(w.startswith('boot:') for w in r['trial_reasons']), r
print('base size', b['size'], 'min', b['min_partition_bytes'])
EOF
sed 's/^/    /' "$O/json.log"
check "release.json: format 1, entries by the installer's rules, kinds, min_partition_bytes, all six roles, trial boot:" "[ $jrc = 0 ]"
"$P/scripts/pool-image" --repo "$O/repo-nopins" --build 20260101-100000 --boot "$BOOT" --out "$O/rel-nopins" "$A" fixture > "$O/o" 2>&1 && rc=0 || rc=$?
check "a target without pins, no --ramenv, no --recovery: those roles missing" "[ $rc = 0 ] && python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1])); assert r[\"missing\"] == [\"ram-environment\", \"boot-loader\", \"partition-layout\", \"recovery\"], r[\"missing\"]; assert sorted(r[\"artifacts\"]) == [\"base\", \"kernel\"]' '$O/rel-nopins/release.json'"
PI --build 20260101-100000 --boot "$BOOT" --out "$O/rel" "$A" fixture > "$O/o" 2>&1 && rc=0 || rc=$?
check "an existing --out: exit 1" "[ $rc = 1 ] && grep -q exists '$O/o'"

# --- the image: read-only check, then the first start's growth and B's delta onto A
MIN=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["artifacts"]["base"]["min_partition_bytes"])' "$O/rel/release.json" 2>/dev/null || echo 0)
docker run --rm --privileged -v "$O":/o -e MIN="$MIN" -e IDA="$IDA" -e IDB="$IDB" -e REL="$REL" alpine:3.24 sh -euc '
apk add -q --no-progress btrfs-progs zstd >/dev/null
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
mkdir /w && mount -t tmpfs -o size=4g tmpfs /w && mkdir /w/m
ru() { btrfs subvolume show "$1" | sed -n "s/^[[:space:]]*Received UUID:[[:space:]]*//p"; }
img=/o/rel/base/$IDA.pool.img
mount -o loop,ro $img /w/m
echo "bases=$(ls /w/m/bases | tr "\n" " ")"; echo "modules=$(ls /w/m/modules | tr "\n" " ")"
echo "a_$(btrfs property get -ts /w/m/bases/$IDA ro)"; echo "a_ruuid=$(ru /w/m/bases/$IDA)"
echo "m_$(btrfs property get -ts /w/m/modules/$REL ro)"
[ -f /w/m/state/format ] && echo "format=$(cat /w/m/state/format)"; [ -e /w/m/state/install ] && echo marker=yes
echo "boot=$(cd /w/m && find boot -type f | sort | tr "\n" " ")"
for f in $(cd /w/m && find boot -type f); do cmp -s /w/m/$f /o/k/$f && echo "same=$f"; done
umount /w/m
cp $img /w/pool.img
truncate -s "$MIN" /w/pool.img
mount -o loop,compress=zstd /w/pool.img /w/m && btrfs -q filesystem resize max /w/m
echo "grown=$(btrfs filesystem usage -b /w/m | awk "\$1 == \"Device\" && \$2 == \"size:\" { print \$3; exit }")"
zstd -dc /o/art/fixture/bases/$IDB/base.from-$IDA.btrfs.zst | btrfs -q receive /w/m/bases && echo delta=received
echo "b_$(btrfs property get -ts /w/m/bases/$IDB ro)"; echo "b_ruuid=$(ru /w/m/bases/$IDB)"
echo "b_config=$(cat /w/m/bases/$IDB/etc/config)"; echo "a_config=$(cat /w/m/bases/$IDA/etc/config)"
cmp /w/m/bases/$IDB/usr/share/glassine/base.manifest /o/art/fixture/bases/$IDB/base.manifest && echo b_manifest=same
cmp /w/m/bases/$IDB/usr/lib/blob /w/m/bases/$IDA/usr/lib/blob && echo blob=same
umount /w/m' > "$O/img.log" 2>&1 || true
sed 's/^/    /' "$O/img.log"
L=$O/img.log
check "image read-only: bases/A only, modules/<release> only, both read-only" "grep -qx 'bases=$IDA ' '$L' && grep -qx 'modules=$REL ' '$L' && grep -qx a_ro=true '$L' && grep -qx m_ro=true '$L'"
check "image: A carries the base record's received UUID" "grep -qx \"a_ruuid=\$(v received_uuid '$A/fixture/bases/$IDA/record')\" '$L'"
check "image: state/format and the install marker" "grep -q '^format=' '$L' && grep -qx marker=yes '$L'"
check "image: boot/ holds the boot image's device tree and initramfs with their manifests, the build's bytes (nothing else)" "grep -qx 'boot=boot/dtb/$DTB.dtb boot/dtb/$DTB.manifest boot/initramfs/$IRD.cpio.gz boot/initramfs/$IRD.manifest ' '$L' && [ \$(grep -c '^same=' '$L') = 4 ]"
check "grown to min_partition_bytes as the first start does" "grep -q '^grown=[0-9]' '$L' && [ \"\$(v grown '$L')\" -ge 1073741824 ]"
check "B's incremental stream receives onto A inside the image: read-only, B's received UUID" "grep -qx delta=received '$L' && grep -qx b_ro=true '$L' && grep -qx \"b_ruuid=\$(v received_uuid '$A/fixture/bases/$IDB/record')\" '$L'"
check "B's content: the changed file, its base manifest; A unchanged" "grep -qx b_config=two '$L' && grep -qx a_config=one '$L' && grep -qx b_manifest=same '$L' && grep -qx blob=same '$L'"

# --- a target without a boot image (a PC): the kernel set's parts
# A fixture PC target (exports=kernel-export) and its kernel export: vmlinuz, two microcode
# archives and a modules tree that builds btrfs, ext4 and overlay in (depmod's files made
# in a container), so boot's build-boot-modules.sh gives an archive with an empty load list.
mkdir -p "$R/targets/pcfix"
printf 'busybox=1.0-r0\n' > "$R/stages/base0/lock.x86_64"
printf 'FROM base0 AS device-pcfix\n' >> "$R/Dockerfile"
printf 'arch=x86_64\nkernel=fake\nexports=kernel-export\n' > "$R/targets/pcfix/target"
printf 'ROOT_PART=glassine-system\nCMDLINE="quiet panic=10"\n' > "$R/targets/pcfix/board.conf"
printf 'SPLASH_WIDTH=320\nSPLASH_HEIGHT=200\nSPLASH_COLOR=0x102030\n' > "$R/targets/pcfix/release.conf"
PK=$O/pk; PREL=6.18.0-0-fake
mkdir -p "$PK/modules/$PREL/microcode" "$PK/boot/initramfs"
head -c 100000 /dev/urandom > "$PK/modules/$PREL/vmlinuz"
head -c 3001 /dev/urandom > "$PK/modules/$PREL/microcode/intel-ucode.img"
head -c 2002 /dev/urandom > "$PK/modules/$PREL/microcode/amd-ucode.img"
printf 'format=1\nrelease=%s\nprovides=\nfeatures=\n' $PREL > "$PK/modules/$PREL/kernel.manifest"
echo pc-ird > "$O/pird"; PIRD=0123456789ab@$(sha "$O/pird" | cut -c1-16); mv "$O/pird" "$PK/boot/initramfs/$PIRD.cpio.gz"
printf 'format=1\ncommit=%s\nsha256=%s\nneeds=\nfeatures=\n' $BOOT_COMMIT "$(sha256sum < "$PK/boot/initramfs/$PIRD.cpio.gz" | cut -c1-64)" \
	> "$PK/boot/initramfs/$PIRD.manifest"
docker run --rm -v "$O":/o -v "$R/targets/pcfix/board.conf":/board.conf:ro -e HOST="$(id -u):$(id -g)" -e PREL=$PREL alpine:3.24 sh -euc '
apk add -q --no-progress kmod >/dev/null
mkdir -p /t/lib/modules/$PREL
printf "kernel/fs/btrfs/btrfs.ko\nkernel/fs/ext4/ext4.ko\nkernel/fs/overlayfs/overlay.ko\n" > /t/lib/modules/$PREL/modules.builtin
depmod -b /t $PREL
cp /t/lib/modules/$PREL/modules.* /o/pk/modules/$PREL/
mkdir -p /r/etc/glassine-bootimg /r/lib/apk/db && cd /r
printf "P:busybox\nV:1.0-r0\n\n" > lib/apk/db/installed
cp /board.conf etc/glassine-bootimg/board.conf
tar --numeric-owner -cf /o/pc.tar $(ls -A)
chown -R "$HOST" /o/pk /o/pc.tar'
M --time 2026-01-03T10:00:00Z --no-parent "$O/pc.tar" "$PK" pcfix "$A"
BP=$A/pcfix/builds/20260103-100000
check "materialize, a PC target: the build names no boot image and names its initramfs" "[ -z \"\$(v bootimg '$BP/manifest')\" ] && [ \"\$(v initramfs '$BP/manifest')\" = '$PIRD' ] && [ ! -e '$BP/boot.manifest' ]"
PI --build 20260103-100000 --boot "$BOOT" --out "$O/rel-pcx" "$A" pcfix > "$O/o" 2>&1 && rc=0 || rc=$?
check "a PC target without --kernel: exit 1, named" "[ $rc = 1 ] && grep -q -- '--kernel DIR' '$O/o' && [ ! -e '$O/rel-pcx' ]"
out=$(PI --build 20260103-100000 --boot "$BOOT" --kernel "$PK" --out "$O/rel-pc" "$A" pcfix 2>&1) && rc=0 || rc=$?
echo "$out" | sed 's/^/    /'
check "pool-image, a PC target: exit 0" "[ $rc = 0 ]"
python3 -I - "$O/rel-pc" "$PK/modules/$PREL" "$R/targets/pcfix/board.conf" "$PIRD" "$PREL" > "$O/json.log" 2>&1 <<'EOF' && jrc=0 || jrc=$?
import hashlib, json, os, re, struct, sys, zlib
d, kdir, board, ird, rel = sys.argv[1:]
r = json.load(open(os.path.join(d, 'release.json')))
a = r['artifacts']
for role, e in a.items():
    b = open(os.path.join(d, e['file']), 'rb').read()
    assert len(b) == e['size'] and hashlib.sha256(b).hexdigest() == e['sha256'], role
assert sorted(a) == ['base', 'board', 'boot-modules', 'initramfs', 'kernel', 'microcode-amd', 'microcode-intel', 'splash'], sorted(a)
assert r['missing'] == ['boot-loader', 'recovery'], r['missing']
k = a['kernel']
assert k['kind'] == 'efi-kernel' and k['release'] == rel and k['cmdline'] == 'quiet panic=10', k
assert open(os.path.join(d, k['file']), 'rb').read() == open(f'{kdir}/vmlinuz', 'rb').read()
assert k['min_partition_bytes'] % (1 << 20) == 0 and k['min_partition_bytes'] >= 2 * 64 << 20, k
for n in ('amd', 'intel'):
    m = a[f'microcode-{n}']
    assert m['kind'] == 'cpio' and os.path.basename(m['file']) == f'{n}-ucode.img', m
    assert open(os.path.join(d, m['file']), 'rb').read() == open(f'{kdir}/microcode/{n}-ucode.img', 'rb').read()
assert a['initramfs']['identity'] == ird and a['initramfs']['kind'] == 'initramfs', a['initramfs']
assert open(os.path.join(d, a['board']['file']), 'rb').read() == open(board, 'rb').read() and a['board']['kind'] == 'board-conf'
assert a['boot-modules']['kind'] == 'cpio-gz'
s = open(os.path.join(d, a['splash']['file']), 'rb').read()
assert s[:8] == b'GLSPLASH' and struct.unpack_from('<HHII', s, 8) == (1, 0, 320, 200), s[:32]
assert zlib.crc32(s[:52]) == struct.unpack_from('<I', s, 52)[0] and zlib.crc32(s[64:]) == struct.unpack_from('<I', s, 48)[0]
n, i, p = 0, 0, s[64:]
while i < len(p):
    c = p[i]; n += c + 1 if c < 128 else c - 126; i += 1 + ((c + 1) * 4 if c < 128 else 4)
    assert c < 128 or p[i - 4:i] == struct.pack('<I', 0x102030)
assert i == len(p) and n == 320 * 200, (i, len(p), n)
assert a['base']['kind'] == 'btrfs-pool-image' and a['base']['kernel_release'] == rel
print('kernel set: min boot partition', k['min_partition_bytes'])
EOF
sed 's/^/    /' "$O/json.log"
check "release.json, a PC target: the kernel set's parts, the board, the splash, boot-loader and recovery missing" "[ $jrc = 0 ]"
cp "$R/targets/pcfix/board.conf" "$O/board.saved"; echo 'CMDLINE="other"' > "$R/targets/pcfix/board.conf"
PI --build 20260103-100000 --boot "$BOOT" --kernel "$PK" --out "$O/rel-pcy" "$A" pcfix > "$O/o" 2>&1 && rc=0 || rc=$?
check "a PC target whose board.conf isn't the base's: exit 1, named" "[ $rc = 1 ] && grep -q \"is not the base's\" '$O/o' && [ ! -e '$O/rel-pcy' ]"
cp "$O/board.saved" "$R/targets/pcfix/board.conf"; echo tampered >> "$PK/modules/$PREL/vmlinuz"
PI --build 20260103-100000 --boot "$BOOT" --kernel "$PK" --out "$O/rel-pcz" "$A" pcfix > "$O/o" 2>&1 && rc=0 || rc=$?
check "a PC kernel that isn't the build's modules tree: exit 1, named" "[ $rc = 1 ] && grep -q 'kernel: .* is not the file modules/' '$O/o' && [ ! -e '$O/rel-pcz' ]"

# --- the boot/ files: the PC's pool holds its initramfs; a mismatched identity is refused
docker run --rm --privileged -v "$O":/o -e IDP="$(v base "$BP/manifest")" alpine:3.24 sh -euc '
for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
mkdir /m && mount -o loop,ro /o/rel-pc/base/$IDP.pool.img /m
echo "boot=$(cd /m && find boot -type f | sort | tr "\n" " ")"
for f in $(cd /m && find boot -type f); do cmp -s /m/$f /o/pk/$f && echo "same=$f"; done
umount /m' > "$O/pcimg.log" 2>&1 || true
sed 's/^/    /' "$O/pcimg.log"
check "image, a PC target: boot/ holds its initramfs and manifest, the build's bytes" "grep -qx 'boot=boot/initramfs/$PIRD.cpio.gz boot/initramfs/$PIRD.manifest ' '$O/pcimg.log' && [ \$(grep -c '^same=' '$O/pcimg.log') = 2 ]"
IM=$A/boot/initramfs/$IRD.manifest; cp "$IM" "$O/im.saved"
sed -i 's/^commit=.*/commit=fedcba9876540000000000000000000000000000/' "$IM"
PI --build 20260101-100000 --boot "$BOOT" --out "$O/rel-id" "$A" fixture > "$O/o" 2>&1 && rc=0 || rc=$?
check "an initramfs whose manifest names another commit: exit 1, named, nothing left" "[ $rc = 1 ] && grep -q 'initramfs $IRD: the manifest names' '$O/o' && [ ! -e '$O/rel-id' ]"
cp "$O/im.saved" "$IM"; DM=$A/boot/dtb/$DTB.manifest; cp "$DM" "$O/dm.saved"
sed -i 's/^sha256=.*/sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$DM"
PI --build 20260101-100000 --boot "$BOOT" --out "$O/rel-id" "$A" fixture > "$O/o" 2>&1 && rc=0 || rc=$?
check "a device tree that isn't its manifest's bytes: exit 1, named, nothing left" "[ $rc = 1 ] && grep -q 'dtb $DTB: .* is not the file its record names' '$O/o' && [ ! -e '$O/rel-id' ]"
cp "$O/dm.saved" "$DM"

rm -rf "$O"
echo "$fails failed"; [ $fails = 0 ]
