#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of the registry side of a build (specs/003-kernel-outputs-registry) without a
# stage build:
#
# 1. Keys (FR-001): on a copy of this checkout, each input of an export is changed in
#    turn (a commit, the builder, a firmware checksum, a stage file, a script, a target
#    file, the platform, a file's executable bit) and exactly the keys that input feeds
#    must change; inputs that don't change an export's bytes (JOBS, KCACHE, LOCK, the
#    firmware's and boot's addresses, the base's stages, comments, a file's other mode
#    bits) change none; the keys don't depend on where the checkout is.
# 2. scripts/git-fetch.sh (FR-012, FR-013) in an Alpine container, on a local fixture
#    repository: a second commit fetched through the kept repository transfers only its
#    new objects; a commit that isn't there fails at once, naming the step, repository and
#    commit; a server that never answers is stopped by the time limit and tried again.
# 3. A registry (registry:2 on this computer, a docker-container builder on the host's
#    network): a fake export is published, found under its key with its annotations,
#    pulled back by digest with the same files (paths, types, modes, contents; times 0),
#    not published again, a missing key and a stopped registry tell apart; scripts/
#    registry status, exports (all four pulled), and publish (only what a rebuild
#    confirmed, never from a checkout with changes).
#
#   scripts/test-registry.sh     exit 0 = all checks pass (KEEP=1 keeps .out/test-registry/)
# Needs python3, git and docker (buildx, a container from registry:2 and alpine:3.24).
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-registry
rm -rf "$O"; mkdir -p "$O"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# a git copy of this checkout (tracked and untracked files, not the ignored ones)
copy() {
	mkdir -p "$1"
	(cd "$P" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - 2>/dev/null) | tar -C "$1" -xf -
}
R=$O/repo; copy "$R"
TARGET=$(ls "$R/targets" | head -n 1)

# --- 1. keys
python3 -I - "$R" "$O/repo2" "$TARGET" > "$O/keys.out" 2>&1 <<'EOF' || true
import os, re, shutil, stat, subprocess, sys
repo, repo2, target = sys.argv[1:4]
sys.path.insert(0, os.path.join(repo, 'scripts')); import glassine_pins as g
DF = os.path.join(repo, 'Dockerfile')
K, D, I, B = 'kernel-export', 'dtb-export', 'initramfs-export', 'boot-export'
def keys(over=None, arch='arm64', r=repo):
    o = {'DEVICE': target, **(over or {})}
    return {e: v['key'] for e, v in g.export_keys(os.path.join(r, 'Dockerfile'), r, o, arch).items()}
base = keys()
args, fw = g.pins(DF, {'DEVICE': target})
def report(name, got, want):
    changed = {e for e in base if got[e] != base[e]}
    print(('ok   ' if changed == set(want) else 'FAIL ') + f'key: {name}: changes '
          f'{" ".join(sorted(changed)) or "nothing"}' + ('' if changed == set(want) else f' (want {" ".join(sorted(want)) or "nothing"})'))
def over(name, o, want, arch='arm64'):
    report(name, keys(o, arch), want)
def edit(name, path, fn, want):
    p = os.path.join(repo, path)
    old = open(p, 'rb').read() if os.path.exists(p) else None
    mode = os.stat(p).st_mode if old is not None else None
    fn(p)
    try:
        report(name, keys(), want)
    finally:
        if old is None:
            os.remove(p)
        else:
            open(p, 'wb').write(old); os.chmod(p, mode)
def append(text):
    return lambda p: open(p, 'a').write(text)
def sub(a, b):
    def f(p):
        s = open(p).read(); assert a in s, (p, a); open(p, 'w').write(s.replace(a, b, 1))
    return f
c = '1' * 40
print('ok   key: the same inputs, the same keys' if keys() == base else 'FAIL key: not deterministic')
over('the kernel commit (the device tree follows it)', {'LINUX_SDM660': c}, [K, D, B])
over('the kernel commit, the device-tree commit kept', {'LINUX_SDM660': c, 'DTB_COMMIT': args['DTB_COMMIT']}, [K, B])
over('the device-tree commit', {'DTB_COMMIT': c}, [D, B])
over('the boot commit', {'BOOT_COMMIT': c}, [I, B])
over('the builder digest', {'KERNEL_BUILD_DIGEST': 'sha256:' + '2' * 64}, [K, D, B])
over('the builder name', {'KERNEL_BUILD_IMAGE': 'registry.example/kernel-build'}, [K, B])
over('the kernel repository', {'LINUX': 'https://example.org/linux'}, [K, B])
over('the base image', {'ALPINE': 'alpine:3.99'}, [I, B])
over('the device', {'DEVICE': 'other-device'}, [D, B])
over('the platform', {}, [I, B], arch='amd64')
over('extra command-line words', {'CMDLINE_EXTRA': 'glassine.devmode=usb'}, [B])
for a, v in (('JOBS', '3'), ('KCACHE', 'other'), ('LOCK', 'refresh'), ('LINUX_FIRMWARE', 'https://example.org/fw'),
             ('BOOT', 'https://example.org/boot')):
    over(f'{a} (no byte depends on it)', {a: v}, [])
first = sorted(fw.values())[0]
edit('a firmware checksum', 'Dockerfile', sub(first, '3' * 64), [K, B])
edit('a firmware file\'s name', 'Dockerfile', sub('/qcom/a530_pfp.fw /qcom/a530_pfp.fw', '/qcom/a530_pfp.fw /qcom/a530_pfp.bin'), [K, B])
edit('the boot stage\'s instructions', 'Dockerfile', sub('DEVICE=$DEVICE CMDLINE_EXTRA=', 'DEVICE=$DEVICE X=1 CMDLINE_EXTRA='), [B])
edit('the base\'s last stages', 'Dockerfile', sub('FROM validation AS base-export', 'FROM validation AS base-export\nRUN true'), [])
edit('a comment in a kernel stage', 'Dockerfile', sub('# One device\'s tree, from DTB_COMMIT', '# Another comment\n# One device\'s tree, from DTB_COMMIT'), [])
edit('the kernel stage files', 'stages/kernel-sdm660/build.config', append('CONFIG_X=y\n'), [K, B])
edit('the kernel build script', 'scripts/kernel.sh', append('# x\n'), [K, D, B])
edit('the fetch script', 'scripts/git-fetch.sh', append('# x\n'), [K, D, I, B])
edit('the initramfs packages', 'stages/initramfs/packages', append('# x\n'), [I, B])
edit('the alpine lock', 'stages/alpine/lock', append('x=1\n'), [I, B])
edit('the package stage script', 'scripts/apk-stage.sh', append('# x\n'), [I, B])
edit('the initramfs script', 'scripts/initramfs.sh', append('# x\n'), [I, B])
edit('the repository key', [os.path.join('keys', n) for n in os.listdir(os.path.join(repo, 'keys')) if n.endswith('.pub')][0],
     append('x\n'), [I, B])
edit('the boot image script', 'scripts/bootimg.sh', append('# x\n'), [B])
edit('the target file', f'targets/{target}/target', append('# x\n'), [D, B])
edit('the board file', f'targets/{target}/board.conf', append('# x\n'), [B])
edit('an untracked file in the initramfs stage', 'stages/initramfs/extra', lambda p: open(p, 'w').write('x\n'), [I, B])
edit('the executable bit of a kernel stage file', 'stages/kernel-sdm660/kernel',
     lambda p: os.chmod(p, os.stat(p).st_mode | 0o100), [K, B])
edit('other mode bits of a kernel stage file', 'stages/kernel-sdm660/kernel',
     lambda p: os.chmod(p, os.stat(p).st_mode | 0o020), [])
for path in ('README.md', 'scripts/materialize', 'scripts/build', 'scripts/validate.sh',
             'stages/glassine-common/packages', 'stages/eink/lock', 'docs/artifacts.md'):
    edit(f'{path} (not an export\'s input)', path, append('# x\n'), [])
shutil.copytree(repo, repo2, symlinks=True)
print('ok   key: the same in a checkout elsewhere' if keys(r=repo2) == base else 'FAIL key: depends on the checkout\'s path')
EOF
cat "$O/keys.out"
n_ok=$(grep -c '^ok' "$O/keys.out" || true); n_fail=$(grep -c '^FAIL' "$O/keys.out" || true)
fails=$((fails + n_fail))
grep -q Traceback "$O/keys.out" && { echo "FAIL key: the test itself failed"; fails=$((fails + 1)); }
echo "keys: $n_ok ok, $n_fail failed"

# --- 2. scripts/git-fetch.sh
G=$O/git; mkdir -p "$G"
git init -q "$G/w"
gc() { git -C "$G/w" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
i=0; while [ $i -lt 100 ]; do head -c 3000 /dev/urandom | od -An -tx1 > "$G/w/f$i"; i=$((i + 1)); done
gc add -A; gc commit -q -m one; C1=$(gc rev-parse HEAD)
echo change >> "$G/w/f0"; gc commit -q -am two; C2=$(gc rev-parse HEAD)
git clone -q --bare "$G/w" "$G/src.git"
git -C "$G/src.git" config uploadpack.allowAnySHA1InWant true
docker run --rm -v "$P/scripts":/s:ro -v "$G/src.git":/src.git:ro -e C1="$C1" -e C2="$C2" alpine:3.24 sh -euc '
apk add -q --no-progress git >/dev/null 2>&1
git config --global --add safe.directory "*"
objs() { git -C /m count-objects -v | awk "/^count:|^in-pack:/ {n += \$2} END {print n}"; }
sh /s/git-fetch.sh one file:///src.git $C1 /d1 /m && echo "d1=$(git -C /d1 rev-parse HEAD)"
a=$(objs)
sh /s/git-fetch.sh two file:///src.git $C2 /d2 /m && echo "d2=$(git -C /d2 rev-parse HEAD)"
echo "added=$(( $(objs) - a ))"
echo "status=$(git -C /d2 status --porcelain | wc -l) shallow=$(git -C /d2 rev-parse --is-shallow-repository)"
s=$(date +%s)
sh /s/git-fetch.sh missing file:///src.git 0000000000000000000000000000000000000001 /d3 /m 2> /tmp/e1 && echo "missing=passed" || echo "missing=failed $(( $(date +%s) - s ))s"
cat /tmp/e1
( while :; do sleep 20 | nc -l -p 8099 > /dev/null 2>&1 || sleep 1; done ) &
sleep 1
GIT_FETCH_TIMEOUT=3 GIT_FETCH_TRIES=2 GIT_FETCH_PAUSE=1 sh /s/git-fetch.sh hang http://127.0.0.1:8099/r.git $C1 /d4 2> /tmp/e2 && echo "hang=passed" || echo "hang=failed"
cat /tmp/e2
' > "$O/fetch.out" 2>&1 || true
sed 's/^/     | /' "$O/fetch.out"
f() { grep -q -- "$1" "$O/fetch.out"; }
check "git-fetch: the first commit checked out"                   'f "^d1=$C1$"'
check "git-fetch: the second commit checked out"                  'f "^d2=$C2$"'
check "git-fetch: the second commit transfers only its new objects (3)" 'f "^added=3$"'
check "git-fetch: a clean, shallow checkout"                      'f "^status=0 shallow=true$"'
check "git-fetch: a missing commit fails at once"                 'grep -q "^missing=failed [0-4]s$" "$O/fetch.out" && ! f "missing: try"'
check "git-fetch: the failure names step, repository and commit"  'f "git-fetch: missing: fetching 0000000000000000000000000000000000000001 from file:///src.git failed"'
check "git-fetch: a silent server: tried again after the time limit" 'f "git-fetch: hang: try 1 of 2 failed (timed out after 3 s"'
check "git-fetch: a silent server: the final failure names it all" 'f "git-fetch: hang: fetching $C1 from http://127.0.0.1:8099/r.git failed after 2 tries: " && f "^hang=failed$"'

# --- 3. a registry
REG=glassine-test-registry-$$; BLD=glassine-test-builder-$$
cleanup() {
	docker rm -f "$REG" >/dev/null 2>&1 || true
	docker buildx rm "$BLD" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker run -d --name "$REG" -p 127.0.0.1::5000 registry:2 >/dev/null
PORT=$(docker port "$REG" 5000/tcp | head -n 1 | sed 's/.*://')
printf '[registry."localhost:%s"]\n  http = true\n  insecure = true\n' "$PORT" > "$O/buildkitd.toml"
docker buildx create --name "$BLD" --driver docker-container --driver-opt network=host \
	--buildkitd-config "$O/buildkitd.toml" >/dev/null
export BUILDX_BUILDER="$BLD" GLASSINE_REGISTRY="localhost:$PORT/glassineos"
i=0; until curl -fs "http://localhost:$PORT/v2/" >/dev/null || [ $i -ge 30 ]; do sleep 1; i=$((i + 1)); done

# a fake export with nested directories, a private file and times of 0, as exports have
X=$O/x; mkdir -p "$X/modules/7.0-fake/kernel/drivers" "$X/modules/7.0-fake/firmware/qcom"
echo image > "$X/modules/7.0-fake/Image.gz"; echo mod > "$X/modules/7.0-fake/kernel/drivers/a.ko"
echo fw > "$X/modules/7.0-fake/firmware/qcom/a.fw"; chmod 600 "$X/modules/7.0-fake/firmware/qcom/a.fw"
chmod -R go-w "$X"; find "$X" -exec touch -h -d @0 {} +
KEY=$(printf %064d 5)
python3 -I - "$P/scripts" "$X" "$O" "$KEY" > "$O/reg.out" 2>&1 <<'EOF' || true
import os, subprocess, sys
sys.path.insert(0, sys.argv[1]); import glassine_registry as r
x, o, key = sys.argv[2:5]
w = os.path.join(o, 'w')
print('missing', r.lookup('kernel-export', key))
st, ref = r.publish('kernel-export', key, x, 'linux/arm64', w, {'tree.linux_sdm660': 'abc'})
print('published', st, ref)
got = r.lookup('kernel-export', key)
print('lookup', got['state'], got.get('ref') == ref, r.trees(got.get('annotations', {})))
print('again', r.publish('kernel-export', key, x, 'linux/arm64', w))
print('pull', r.pull('kernel-export', ref, os.path.join(o, 'pulled'), 'linux/arm64', w))
c = subprocess.run([sys.executable, os.path.join(sys.argv[1], 'kernel-check'), '--compare', x, os.path.join(o, 'pulled')],
                   capture_output=True, text=True)
print('compare', c.returncode, c.stdout.strip().splitlines()[-1] if c.stdout.strip() else '')
times = {os.lstat(os.path.join(d, n)).st_mtime for d, ds, fs in os.walk(os.path.join(o, 'pulled')) for n in ds + fs}
print('times', sorted(times))
bad = ref.split('@')[0] + '@sha256:' + '0' * 64
print('baddigest', r.pull('kernel-export', bad, os.path.join(o, 'bad'), 'linux/arm64', w, tries=1))
EOF
sed 's/^/     | /' "$O/reg.out"
q() { grep -q -- "$1" "$O/reg.out"; }
check "registry: a key never published: missing"                 "q \"^missing {'state': 'missing', 'why': 'not published'}\""
check "registry: published under the key, pinned by digest"      'q "^published published localhost:$PORT/glassineos/images-kernel@sha256:[0-9a-f]\{64\}$"'
check "registry: found with the same digest and its annotations" "q \"^lookup published True {'LINUX_SDM660': 'abc'}\""
check "registry: a published key isn't published again"          'q "^again (.present., .localhost:$PORT/glassineos/images-kernel@sha256:"'
check "registry: pulled by digest"                               'q "^pull None$"'
check "registry: the pulled files are the published ones"        'q "^compare 0 "'
check "registry: every pulled time is 0, as in an export"        'q "^times \[0.0\]$"'
check "registry: a digest the registry doesn't have fails the pull" 'q "^baddigest pulling kernel-export from .*failed after 1 tries"'

# scripts/registry on a git copy of this checkout: status, exports, publish
C=$O/clean; copy "$C"
git -C "$C" init -q; git -C "$C" add -A
git -C "$C" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m copy
"$C/scripts/registry" keys "$TARGET" > "$O/keys.list"
# every export published with fake files under this checkout's keys
for e in kernel-export dtb-export initramfs-export boot-export; do
	mkdir -p "$O/fake/$e/$e"; echo "$e" > "$O/fake/$e/$e/file"; find "$O/fake/$e" -exec touch -h -d @0 {} +
done
python3 -I - "$P/scripts" "$O" "$O/keys.list" > "$O/pub.out" 2>&1 <<'EOF' || true
import os, sys
sys.path.insert(0, sys.argv[1]); import glassine_registry as r
o = sys.argv[2]
TREES = {'tree.linux_sdm660': 't', 'tree.dtb_commit': 't', 'tree.boot_commit': 't'}
for line in open(sys.argv[3]):
    e, key = line.split()
    if e != 'boot-export':
        print(e, r.publish(e, key, os.path.join(o, 'fake', e), 'linux/arm64', os.path.join(o, 'w'), TREES))
EOF
timeout 120 "$C/scripts/registry" status "$TARGET" > "$O/status.out" 2>&1 || true
sed 's/^/     | /' "$O/status.out"
check "registry status: published exports with their digest"    '[ "$(grep -c " localhost:$PORT/glassineos/images-[a-z]*@sha256:" "$O/status.out")" = 3 ]'
check "registry status: the other one, not published"           'grep -q "^boot-export [0-9a-f]\{64\} not published: not published$" "$O/status.out"'
# exports with the boot image published as well: all four pulled
python3 -I - "$P/scripts" "$O" "$O/keys.list" >> "$O/pub.out" 2>&1 <<'EOF' || true
import os, sys
sys.path.insert(0, sys.argv[1]); import glassine_registry as r
o = sys.argv[2]
TREES = {'tree.linux_sdm660': 't', 'tree.dtb_commit': 't', 'tree.boot_commit': 't'}
for line in open(sys.argv[3]):
    e, key = line.split()
    if e == 'boot-export':
        print(e, r.publish(e, key, os.path.join(o, 'fake', e), 'linux/arm64', os.path.join(o, 'w'), TREES))
EOF
timeout 300 "$C/scripts/registry" exports "$TARGET" "$O/out" > "$O/exports.out" 2>&1 && erc=0 || erc=$?
tail -n 5 "$O/exports.out" | sed 's/^/     | /'
check "registry exports: exit 0"                                  '[ $erc = 0 ]'
check "registry exports: all four pulled (plan names the digests)" '[ "$(grep -c " localhost:$PORT/glassineos/images-[a-z]*@sha256:" "$O/out/plan" 2>/dev/null)" = 4 ]'
check "registry exports: the pulled files"                        'for e in kernel-export dtb-export initramfs-export boot-export; do [ "$(cat "$O/out/$e/$e/file")" = "$e" ] || exit 1; done'
check "registry exports: input trees from the annotations"        'grep -qx "LINUX_SDM660 t" "$O/out/trees" && grep -qx "BOOT_COMMIT t" "$O/out/trees"'

# publish: only what a rebuild confirmed, never from a checkout with changes
P2=$O/p2; mkdir -p "$P2"
while read -r e key; do
	cp -a "$O/fake/$e" "$P2/$e"
	case $e in
	kernel-export) echo "$e $key built" ;;
	*) echo "$e $key localhost:$PORT/glassineos/images-x@sha256:$(printf %064d 0)" ;;
	esac
done < "$O/keys.list" > "$P2/plan"
NEWKEY=$(printf %064d 9)
sed -i "s/^kernel-export [0-9a-f]* built$/kernel-export $NEWKEY built/" "$P2/plan"
timeout 120 "$C/scripts/registry" publish "$TARGET" "$P2" > "$O/pubwrong.out" 2>&1 && prc=0 || prc=$?
check "registry publish: an OUT whose keys aren't the checkout's: refused" '[ $prc != 0 ] && grep -q "isn.t this checkout.s" "$O/pubwrong.out"'
KK=$(grep '^kernel-export ' "$O/keys.list" | cut -d' ' -f2)
sed -i "s/^kernel-export $NEWKEY built$/kernel-export $KK built/" "$P2/plan"
# the kernel's key is published already (above); give it a key no one published by
# changing the kernel stage in the copy, committed, so the checkout stays clean
echo '# a change' >> "$C/stages/kernel-sdm660/build.config"
git -C "$C" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -am change
"$C/scripts/registry" keys "$TARGET" > "$O/keys2.list"
K2=$(grep '^kernel-export ' "$O/keys2.list" | cut -d' ' -f2)
while read -r e key; do
	case $e in
	kernel-export) echo "$e $key built" ;;
	*) echo "$e $key localhost:$PORT/glassineos/images-x@sha256:$(printf %064d 0)" ;;
	esac
done < "$O/keys2.list" > "$P2/plan"
echo "LINUX_SDM660 t" > "$P2/trees"
echo "kernel-export $K2 differs" > "$P2/reproduced"
timeout 120 "$C/scripts/registry" publish "$TARGET" "$P2" > "$O/pubdiff.out" 2>&1 && prc=0 || prc=$?
check "registry publish: a rebuild that differs: not published, exit 1" '[ $prc = 1 ] && grep -q "kernel-export: NOT published: no rebuild from scratch gave the same bytes" "$O/pubdiff.out"'
check "registry publish: pulled exports aren't published"        'grep -q "dtb-export: pulled" "$O/pubdiff.out"'
echo "kernel-export $K2 same" > "$P2/reproduced"
echo dirty > "$C/untracked-file"
timeout 120 "$C/scripts/registry" publish "$TARGET" "$P2" > "$O/pubdirty.out" 2>&1 && prc=0 || prc=$?
rm "$C/untracked-file"
check "registry publish: a checkout with changes: nothing published" '[ $prc != 0 ] && grep -q "the checkout has changes" "$O/pubdirty.out"'
timeout 300 "$C/scripts/registry" publish "$TARGET" "$P2" > "$O/pubok.out" 2>&1 && prc=0 || prc=$?
sed 's/^/     | /' "$O/pubok.out" | grep 'registry:' || true
check "registry publish: a confirmed export: published"          '[ $prc = 0 ] && grep -q "kernel-export: published localhost:$PORT/glassineos/images-kernel@sha256:" "$O/pubok.out"'
timeout 300 "$C/scripts/registry" publish "$TARGET" "$P2" > "$O/pubagain.out" 2>&1 && prc=0 || prc=$?
check "registry publish: again: already published, not pushed"   '[ $prc = 0 ] && grep -q "kernel-export: already published" "$O/pubagain.out" && ! grep -q "docker buildx build" "$O/pubagain.out"'
check "registry publish: its annotations name the inputs' trees" 'python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import glassine_registry as r; a = r.lookup(\"kernel-export\", sys.argv[2]); sys.exit(0 if r.trees(a[\"annotations\"]) == {\"LINUX_SDM660\": \"t\"} else 1)" "$P/scripts" "$K2"'

# the registry stopped: no answer, told apart from not published
docker stop "$REG" >/dev/null
python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import glassine_registry as r; print(r.lookup('kernel-export', '0' * 64, timeout=20))" "$P/scripts" > "$O/down.out" 2>&1 || true
check "registry: stopped: unreachable, not 'not published'"     'grep -q "registry unreachable" "$O/down.out"'

[ -n "${KEEP-}" ] || rm -rf "$O"
echo "test-registry: $fails failure(s)"
[ "$fails" = 0 ]
