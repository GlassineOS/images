#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of a distribution kernel's rule (GlassineOS/boot's docs/kernel-artifacts.md,
# "A distribution's kernel"), without a build or the network:
# - scripts/kernel-lock.sh hold on made-up refreshes: only firmware moved → firmware and
#   microcode held at their locked versions, everything else moves; linux-lts moved (also
#   only its revision) → all move; no old lock → nothing held; a firmware package only
#   one side names is reported.
# - scripts/kernel-lock.sh tag: the tag and its commit follow the firmware version (an
#   annotated tag's peeled commit, from a local git repository); unchanged when equal;
#   refused, the Dockerfile untouched, for a version that isn't a tag's form, a tag
#   upstream doesn't have, mixed versions, and a Raspberry Pi pin Alpine's APKBUILD moved.
# - scripts/kernel-release-check: the same tree passes, another tree under the same
#   release fails (artifacts folder, the newest release folder, and the registry through
#   a stand-in docker), owners and hard links don't count, an unreachable registry fails.
#   scripts/test-kernel-lock.sh     exit 0 = all checks pass
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$(mktemp -d)
trap 'rm -rf "$O"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
KL="sh $P/scripts/kernel-lock.sh"

# --- hold
cat > "$O/old" <<EOF
amd-ucode=20260519-r0
busybox=1.37.0-r31
intel-ucode=20260812-r0
linux-firmware-dell=20260519-r0
linux-firmware-intel=20260519-r0
linux-lts=6.18.63-r0
musl=1.2.6-r3
EOF
# only firmware, microcode and musl moved
sed 's/20260519-r0/20260620-r0/; s/20260812-r0/20260915-r0/; s/musl=1.2.6-r3/musl=1.2.6-r4/' "$O/old" > "$O/new"
$KL hold "$O/old" "$O/new" > "$O/hold.out"
check "hold: only firmware moved: the kernel is held"               'grep -qx "kernel held 6.18.63-r0" "$O/hold.out"'
check "hold: firmware and microcode keep their locked versions"     'grep -qx "linux-firmware-intel=20260519-r0" "$O/new" && grep -qx "linux-firmware-dell=20260519-r0" "$O/new" && grep -qx "amd-ucode=20260519-r0" "$O/new" && grep -qx "intel-ucode=20260812-r0" "$O/new"'
check "hold: other packages move"                                   'grep -qx "musl=1.2.6-r4" "$O/new"'
check "hold: each held package is named"                            'grep -qx "held intel-ucode 20260812-r0 20260915-r0" "$O/hold.out" && [ "$(grep -c "^held " "$O/hold.out")" = 4 ]'
check "hold: the lock stays sorted, one line each"                  '[ "$(LC_ALL=C sort "$O/new")" = "$(cat "$O/new")" ] && [ "$(wc -l < "$O/new")" = 7 ]'
# linux-lts moved: everything moves
sed 's/20260519-r0/20260620-r0/; s/linux-lts=6.18.63-r0/linux-lts=6.18.70-r0/' "$O/old" > "$O/new2"
cp "$O/new2" "$O/new2.want"
$KL hold "$O/old" "$O/new2" > "$O/hold2.out"
check "hold: linux-lts moved: all move"                            'grep -qx "kernel moved 6.18.63-r0 6.18.70-r0" "$O/hold2.out" && cmp -s "$O/new2" "$O/new2.want"'
sed 's/20260519-r0/20260620-r0/; s/linux-lts=6.18.63-r0/linux-lts=6.18.63-r1/' "$O/old" > "$O/new3"
cp "$O/new3" "$O/new3.want"
$KL hold "$O/old" "$O/new3" > "$O/hold3.out"
check "hold: a new revision of linux-lts is a move"                 'grep -q "^kernel moved" "$O/hold3.out" && cmp -s "$O/new3" "$O/new3.want"'
cp "$O/new2.want" "$O/new4"
$KL hold "$O/missing" "$O/new4" > "$O/hold4.out"
check "hold: no old lock: nothing held"                            'grep -qx "kernel new 6.18.70-r0" "$O/hold4.out" && cmp -s "$O/new4" "$O/new2.want"'
grep -v linux-firmware-dell "$O/old" | sed 's/20260519-r0/20260620-r0/' > "$O/new5"
echo linux-firmware-xe=20260620-r0 >> "$O/new5"
$KL hold "$O/old" "$O/new5" > "$O/hold5.out"
check "hold: a firmware package one side names is reported"        'grep -qx "added linux-firmware-xe=20260620-r0" "$O/hold5.out" && grep -qx "dropped linux-firmware-dell=20260519-r0" "$O/hold5.out"'

# --- tag
G=$O/fw.git
git init -q "$G"
gg() { git -C "$G" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
gg commit -q --allow-empty -m one; gg tag -a -m t 20260519
gg commit -q --allow-empty -m two; gg tag -a -m t 20260620
C2=$(gg rev-parse 20260620^{commit})
C1=$(gg rev-parse 20260519^{commit})
cat > "$O/Dockerfile" <<EOF
ARG ALPINE=alpine:3.24
ARG LINUX_FIRMWARE_GIT=https://example.invalid/linux-firmware.git
ARG LINUX_FIRMWARE_TAG=20260519
ARG LINUX_FIRMWARE_TAG_COMMIT=$C1
ARG RPI_BLUEZ_FIRMWARE=https://raw.example.invalid/bluez-firmware/aaaa
ARG RPI_FIRMWARE_NONFREE=https://raw.example.invalid/firmware-nonfree/bbbb
EOF
cp "$O/Dockerfile" "$O/Dockerfile.orig"
printf 'pkgname=linux-firmware\npkgver=20260620\n_rpi_bt=aaaa\n_rpi_brcm=bbbb\n' > "$O/APKBUILD"
export LINUX_FIRMWARE_GIT="$G" APKBUILD_URL="file://$O/APKBUILD"
$KL tag "$O/new2.want" "$O/Dockerfile" > "$O/tag.out" 2>&1 && rc=0 || rc=$?
check "tag: linux-lts moved: the tag follows the firmware"         '[ $rc = 0 ] && grep -qx "ARG LINUX_FIRMWARE_TAG=20260620" "$O/Dockerfile"'
check "tag: its commit is the annotated tag's peeled commit"       'grep -qx "ARG LINUX_FIRMWARE_TAG_COMMIT=$C2" "$O/Dockerfile" && [ "$(grep -c "^ARG" "$O/Dockerfile")" = 6 ]'
cp "$O/Dockerfile" "$O/Dockerfile.moved"
$KL tag "$O/new2.want" "$O/Dockerfile" > "$O/tag2.out" 2>&1
check "tag: equal: unchanged"                                      'grep -q "(unchanged)" "$O/tag2.out" && cmp -s "$O/Dockerfile" "$O/Dockerfile.moved"'
tagfail() {	# tagfail NAME LOCK PATTERN: refused, the Dockerfile unchanged
	cp "$O/Dockerfile.orig" "$O/Dockerfile"
	$KL tag "$2" "$O/Dockerfile" > "$O/tf.out" 2>&1 && r=0 || r=$?
	pat=$3
	check "tag: $1: refused, nothing changed" '[ $r != 0 ] && grep -q "$pat" "$O/tf.out" && cmp -s "$O/Dockerfile" "$O/Dockerfile.orig"'
}
sed 's/20260519-r0/20260777-r0/' "$O/old" > "$O/l-notag"
tagfail "a version upstream has no tag for" "$O/l-notag" "maps to no tag 20260777"
sed 's/linux-firmware-intel=20260519-r0/linux-firmware-intel=2026.05-r0/; s/=20260519-r0/=2026.05-r0/' "$O/old" > "$O/l-form"
tagfail "a version not of a tag's form" "$O/l-form" "isn't of the form YYYYMMDD-rN"
sed 's/linux-firmware-intel=20260519-r0/linux-firmware-intel=20260620-r0/' "$O/old" > "$O/l-mixed"
tagfail "mixed firmware versions" "$O/l-mixed" "aren't one version"
printf 'pkgname=linux-firmware\npkgver=20260620\n_rpi_bt=cccc\n_rpi_brcm=bbbb\n' > "$O/APKBUILD"
tagfail "a Raspberry Pi pin Alpine moved" "$O/new2.want" "move RPI_BLUEZ_FIRMWARE"
export APKBUILD_URL="file://$O/no-such-APKBUILD"
cp "$O/Dockerfile.orig" "$O/Dockerfile"
$KL tag "$O/new2.want" "$O/Dockerfile" > "$O/tag3.out" 2>&1 && rc=0 || rc=$?
check "tag: the APKBUILD unreadable: moved, with a warning"        '[ $rc = 0 ] && grep -q "warning: can.t read" "$O/tag3.out" && grep -qx "ARG LINUX_FIRMWARE_TAG=20260620" "$O/Dockerfile"'

# --- kernel-release-check
RC="python3 -I $P/scripts/kernel-release-check"
REL=6.18.63-0-lts
mkk() {	# mkk DIR FIRMWARE-BYTES: a kernel export
	rm -rf "$1"; mkdir -p "$1/modules/$REL/firmware/intel" "$1/modules/$REL/kernel"
	echo vmlinuz > "$1/modules/$REL/vmlinuz"; echo mod > "$1/modules/$REL/kernel/a.ko"
	echo "$2" > "$1/modules/$REL/firmware/intel/fw.bin"
	ln "$1/modules/$REL/firmware/intel/fw.bin" "$1/modules/$REL/firmware/intel/fw-link.bin"
	printf 'format=1\nrelease=%s\n' "$REL" > "$1/modules/$REL/kernel.manifest"
	chmod -R u+rwX,go+rX,go-w "$1"
}
mkk "$O/k1" one
A=$O/art; mkdir -p "$A/modules"
python3 -I "$P/scripts/tree-manifest.py" "$O/k1/modules/$REL" | sed 's/^\([^ ]* [^ ]*\) [0-9]*:[0-9]* /\1 0:0 /' > "$A/modules/$REL.manifest"
$RC "$O/k1" --artifacts "$A" --no-registry > "$O/rc1.out" 2>&1 && rc=0 || rc=$?
check "release check: the same tree passes"                         '[ $rc = 0 ] && grep -q "the same as $A/modules/$REL.manifest" "$O/rc1.out"'
# the same files without the hard link: the same tree
mkk "$O/k1b" one; rm "$O/k1b/modules/$REL/firmware/intel/fw-link.bin"; cp "$O/k1b/modules/$REL/firmware/intel/fw.bin" "$O/k1b/modules/$REL/firmware/intel/fw-link.bin"
check "release check: hard links and owners don't count"            '[ "$($RC --tree "$O/k1")" = "$($RC --tree "$O/k1b")" ]'
mkk "$O/k2" two
$RC "$O/k2" --artifacts "$A" --no-registry > "$O/rc2.out" 2>&1 && rc=0 || rc=$?
check "release check: only the firmware changed: fails, naming the release" '[ $rc = 1 ] && grep -q "release $REL: .* holds another tree" "$O/rc2.out" && grep -q "kernel-lock.sh" "$O/rc2.out"'
$RC "$O/k2" --artifacts "$O/empty" --no-registry > "$O/rc3.out" 2>&1 && rc=0 || rc=$?
check "release check: an unpublished release passes"                '[ $rc = 0 ] && grep -q "not published yet" "$O/rc3.out"'
mkdir -p "$O/art2/t/releases/20261101-1" "$O/art2/t/releases/20261102-1"
echo '{"artifacts": {"kernel": {"kernel_release": "6.1.0-0-lts"}}}' > "$O/art2/t/releases/20261102-1/release.json"
echo '{"artifacts": {"kernel": {"kernel_release": "'"$REL"'"}}}' > "$O/art2/t/releases/20261101-1/release.json"
$RC "$O/k2" --artifacts "$O/art2" --no-registry > "$O/rc4.out" 2>&1 && rc=0 || rc=$?
check "release check: an older release folder isn't the newest"     '[ $rc = 0 ]'
echo '{"artifacts": {"kernel": {"kernel_release": "'"$REL"'"}}}' > "$O/art2/t/releases/20261102-1/release.json"
$RC "$O/k2" --artifacts "$O/art2" --no-registry > "$O/rc5.out" 2>&1 && rc=0 || rc=$?
check "release check: the newest release folder carries the release, nothing to compare: fails" '[ $rc = 1 ] && grep -q "release folder .*20261102-1 carries it" "$O/rc5.out"'
# the registry, through a stand-in docker: release-<release> with a release.tree
TID1=$($RC --tree "$O/k1" | cut -d" " -f2)
mkdir -p "$O/bin"
cat > "$O/bin/docker" <<EOF
#!/bin/sh
case "\$FAKE_MODE" in
down) echo "connection refused" >&2; exit 1 ;;
none) echo "manifest unknown" >&2; exit 1 ;;
esac
[ "\$*" = "buildx imagetools inspect --raw fake.example/glassineos/images-kernel:release-$REL" ] || { echo "unexpected: \$*" >&2; exit 1; }
printf '{"schemaVersion":2,"layers":[],"annotations":{"org.glassine.export":"kernel-export","org.glassine.key":"k","org.glassine.release":"$REL","org.glassine.release.tree":"$TID1"}}'
EOF
chmod +x "$O/bin/docker"
export GLASSINE_REGISTRY=fake.example/glassineos
PATH="$O/bin:$PATH" FAKE_MODE=have $RC "$O/k1" > "$O/rr1.out" 2>&1 && rc=0 || rc=$?
check "release check, registry: the published tree passes"          '[ $rc = 0 ] && grep -q "the same as fake.example/glassineos/images-kernel@sha256:" "$O/rr1.out"'
PATH="$O/bin:$PATH" FAKE_MODE=have $RC "$O/k2" > "$O/rr2.out" 2>&1 && rc=0 || rc=$?
check "release check, registry: another tree under the release fails" '[ $rc = 1 ] && grep -q "published in the registry .* with tree $TID1" "$O/rr2.out"'
PATH="$O/bin:$PATH" FAKE_MODE=none $RC "$O/k2" > "$O/rr3.out" 2>&1 && rc=0 || rc=$?
check "release check, registry: not published passes"               '[ $rc = 0 ]'
PATH="$O/bin:$PATH" FAKE_MODE=down $RC "$O/k2" > "$O/rr4.out" 2>&1 && rc=0 || rc=$?
check "release check, registry: no answer fails (can't tell)"       '[ $rc = 1 ] && grep -q "can.t tell" "$O/rr4.out"'

echo "$fails failure(s)"
[ "$fails" = 0 ]
