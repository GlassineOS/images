#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of scripts/build without a stage build and without the network: docker is a
# stand-in on PATH (its answers set by FAKE_* variables; `buildx build` writes a fake
# export of each target), every git input points at a local fixture repository
# (file://), and a git copy of this checkout runs the command (its kernel-check and
# boot-check stubbed, since the exports are fake).
#
# Preflight: a good environment passes with the right build info (each input's tree,
# unmerged for a commit off its branch, the checkout's commit and cleanliness, where an
# untracked file is dirty and an ignored one isn't); each failure ends the command
# within seconds (exit 3) naming its cause, every other check still named in the same
# run: a commit that doesn't exist, a branch that can't be fetched, a missing lock, a
# missing stage of the target, a target on another kernel, an unknown --build-arg, a
# parent whose record or stream is missing or isn't UTF-8, a builder digest that can't
# be pulled, no emulation, no loop devices, too little free space (one file system,
# two, or a remote daemon's), a threshold that isn't a number.
# Local checkouts (--local): a clean clone passes as local with its commit's tree,
# merged when pushed on its branch, unmerged when not pushed, by the input's or the
# repository's ARG; refused: uncommitted changes (untracked or changed; an ignored file
# is fine), another repository, no directory, not the top of a checkout, --build-arg of
# the same input, an unknown name. Past preflight, every export gets the commit and the
# source stage's context, a fresh copy of that commit.
# Unit checks: the emulation check on a stubbed arm64 and amd64 machine, the GitHub
# compare answers mapped to merged / not / unknown, the trial reasons of local inputs.
# Promotion (scripts/promote, run in the copy, records written by the test): a clean
# pinned build is staged under promoted/ byte for byte, also again and at another commit
# with the same tree, and with an input commit whose tree is on its branch; refused: a
# trial, another images tree, a missing --at commit, an input tree on no commit of its
# branch, a dirty checkout, a promoted record with other bytes, an unknown build.
# Past preflight: a failed export (exit 1, work directory removed), a held host lock
# (exit 4), --no-cache's per-export filter lists, non-UTF-8 build output, a checkout
# changed during the build (exit 1), SIGTERM (exit 143, the build step and the work
# directory gone), and stale work directories of dead runs removed.
#   scripts/test-build.sh     exit 0 = all checks pass (KEEP=1 keeps .out/test-build/)
# Needs python3, git, flock and sh. Works in .out/test-build/ under the checkout,
# removed at the end.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-build
rm -rf "$O"; mkdir -p "$O/bin" "$O/rt"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# --- docker, as far as scripts/build asks it
cat > "$O/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
"buildx inspect") echo "Name: fake"; echo "Platforms: ${FAKE_PLATFORMS-linux/amd64, linux/arm64}" ;;
"buildx imagetools")
	for a; do r=$a; done
	case "$r" in *sha256:0000000000000000*) echo "ERROR: $r: not found" >&2; exit 1 ;; esac
	echo "Name: $r" ;;
"buildx build")
	echo "$*" >> "$FAKE_BUILD_LOG"
	echo $$ > "$FAKE_BUILD_LOG.pid"
	shift 2; t=; o=; bc=
	while [ $# -gt 0 ]; do
		case "$1" in
		--target) t=$2; shift ;; -o) o=$2; shift ;;
		--build-arg) case "$2" in BOOT_COMMIT=*) bc=${2#BOOT_COMMIT=} ;; esac; shift ;;
		--build-context) # a source stage's context: the checkout's commit, unchanged
			cd=${2#*=}
			for g in "$cd"/*/*/.git "$cd"/*/.git; do
				[ -e "$g" ] || continue
				echo "context ${2%%=*} $(git -C "${g%/.git}" rev-parse HEAD) $(git -C "${g%/.git}" status --porcelain | wc -l)" >> "$FAKE_BUILD_LOG.ctx"
				break
			done
			shift ;;
		esac; shift
	done
	printf 'step 1 \377 not UTF-8\n'
	[ "${FAKE_BUILD_SLEEP-}" ] && sleep "$FAKE_BUILD_SLEEP"
	[ "$t" = "${FAKE_BUILD_FAIL-}" ] && { echo "ERROR: fake failure of $t"; exit 1; }
	[ "$t" = base-export ] && [ "${FAKE_TOUCH-}" ] && echo touched >> "$FAKE_TOUCH"
	d=${o#*dest=}; R=7.3.0-fake.abcdef-g0123456789ab; T=$FAKE_TARGET
	DTB=$T@0000000000000001; IRD=0123456789ab@0000000000000002; IMG=00000000000000aa
	case "$t" in
	base-export) mkdir -p "$d.dir/etc" && tar -C "$d.dir" -cf "$d" . ;;
	kernel-export) mkdir -p "$d/modules/$R" && echo i > "$d/modules/$R/Image.gz" \
		&& printf 'format=1\nrelease=%s\nprovides=\nfeatures=\n' $R > "$d/modules/$R/kernel.manifest" ;;
	dtb-export) mkdir -p "$d/boot/dtb" && echo d > "$d/boot/dtb/$DTB.dtb" \
		&& printf 'format=1\ndevice=%s\n' "$T" > "$d/boot/dtb/$DTB.manifest" ;;
	initramfs-export) mkdir -p "$d/boot/initramfs" && echo r > "$d/boot/initramfs/$IRD.cpio.gz" \
		&& printf 'format=1\ncommit=%s\nneeds=\nfeatures=\n' "$bc" > "$d/boot/initramfs/$IRD.manifest" ;;
	boot-export) mkdir -p "$d/bootimg" "$d/select" && echo b > "$d/bootimg/$IMG.img" \
		&& printf 'format=1\nid=%s\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\n' $IMG "$T" $R $DTB $IRD > "$d/bootimg/$IMG.manifest" \
		&& printf 'format=1\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\n' "$T" $R $DTB $IRD > "$d/select/$T" ;;
	esac ;;
"run --rm")
	if [ -n "${FAKE_PRIV_FAIL-}" ]; then echo "probe: no free loop device"; exit 3; fi
	echo "probe: df ${FAKE_DF-1000000000 900000000}" ;;
"info --format") echo "$FAKE_DOCKER_ROOT" ;;
*) echo "fake docker: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$O/bin/docker"
export PATH="$O/bin:$PATH" FAKE_DOCKER_ROOT="$O" FAKE_BUILD_LOG="$O/buildx.log" XDG_RUNTIME_DIR="$O/rt"

# --- a git copy of this checkout (tracked and untracked files, not the ignored ones)
R=$O/repo; mkdir -p "$R"
(cd "$P" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - 2>/dev/null) | tar -C "$R" -xf -
for c in kernel-check boot-check; do
	printf 'import sys\nprint("stub: 0 failure(s)")\n' > "$R/scripts/$c"
done
rg() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
rg init -q; rg add -A; rg commit -q -m copy
TARGET=$(ls "$R/targets" | head -n 1)
export FAKE_TARGET="$TARGET"

# --- the fixture repository: A ← B on every input's branch, C off A on no branch
G=$O/src.git
git init -q --bare "$G"
git -C "$G" config uploadpack.allowAnySHA1InWant true
git -C "$G" config uploadpack.allowFilter true
W=$O/w; git init -q "$W"
gc() { git -C "$W" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
echo a > "$W/f"; gc add f; GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' gc commit -q -m A
A=$(gc rev-parse HEAD)
echo b > "$W/f"; GIT_COMMITTER_DATE='2020-01-02T00:00:00Z' gc commit -q -am B
B=$(gc rev-parse HEAD); BTREE=$(gc rev-parse "$B^{tree}")
gc checkout -q "$A"; echo c > "$W/f"; GIT_COMMITTER_DATE='2020-01-03T00:00:00Z' gc commit -q -am C
C=$(gc rev-parse HEAD); CTREE=$(gc rev-parse "$C^{tree}")
# every input: its commit ARG, the ARG naming its repository, its branch
INPUTS=$(python3 -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import glassine_pins as g
d = sys.argv[1] + '/../Dockerfile'; b = g.branches(d)
for c, u in g.repos(d).items(): print(c, u, b[c])" "$R/scripts")
OVER=""
for br in $(echo "$INPUTS" | awk '{print $3}' | sort -u); do git -C "$W" push -q "$G" "$B:refs/heads/$br"; done
git -C "$W" push -q "$G" "$C:refs/side/c"     # in the repository, on no branch
for c in $(echo "$INPUTS" | awk '{print $1}'); do OVER="$OVER --build-arg $c=$B"; done
for u in $(echo "$INPUTS" | awk '{print $2}' | sort -u); do OVER="$OVER --build-arg $u=file://$G"; done
LAST=$(echo "$INPUTS" | tail -n 1 | awk '{print $1}')
LASTBR=$(echo "$INPUTS" | tail -n 1 | awk '{print $3}')

PF=--preflight-only
run() {	# run NAME ARGS...: the command in the copy; output in $O/NAME.out, exit in .rc, seconds in .s
	n=$1; shift
	t=$(date +%s)
	set +e
	# shellcheck disable=SC2086
	timeout 120 "$R/scripts/build" "$TARGET" $PF --artifacts "$O/a.$n" $OVER "$@" > "$O/$n.out" 2>&1
	echo $? > "$O/$n.rc"
	set -e
	echo $(( $(date +%s) - t )) > "$O/$n.s"
}
rc() { cat "$O/$1.rc"; }
has() { grep -q -- "$2" "$O/$1.out"; }
fast() { [ "$(cat "$O/$1.s")" -le 20 ]; }
show() { sed 's/^/     | /' "$O/$1.out"; }

# --- a good environment
run good
check "good: preflight passes"                  '[ "$(rc good)" = 0 ]'
check "good: within seconds"                     'fast good'
check "good: each input's tree"                  '[ "$(grep -c "^input\..*\.tree=$BTREE$" "$O/good.out")" = "$(echo "$INPUTS" | wc -l)" ]'
check "good: nothing unmerged"                   'has good "^unmerged=$"'
check "good: inputs not local"                   '! grep "^input\..*\.local=" "$O/good.out" | grep -qv "=no$"'
check "good: builder digest in the build info"   'has good "^builder\..*=sha256:"'
check "good: the checkout's commit"              'has good "^images_commit=$(rg rev-parse HEAD)$"'
check "good: a clean checkout"                   'has good "^images_clean=yes$"'
[ "$(rc good)" = 0 ] || show good

mkdir -p "$R/artifacts"; echo x > "$R/artifacts/ignored"
run ignored
check "an ignored file leaves the checkout clean" 'has ignored "^images_clean=yes$"'
STAGE1=$(ls "$R/stages" | head -n 1)
echo x > "$R/stages/$STAGE1/untracked-file"
run untracked
rm "$R/stages/$STAGE1/untracked-file"
check "an untracked file makes the checkout dirty" 'has untracked "^images_clean=no$"'
# an artifacts folder inside the checkout: refused unless git ignores it
mkdir -p "$R/myart"; echo x > "$R/myart/old-export"
run artin --artifacts "$R/myart"
check "artifacts inside the checkout, not ignored: exit 3" '[ "$(rc artin)" = 3 ]'
check "artifacts inside the checkout, not ignored: named" 'has artin "not ignored by git"'
rm -r "$R/myart"
mkdir -p "$R/artifacts/inner"; echo x > "$R/artifacts/inner/old-export"
run artign --artifacts "$R/artifacts/inner"
check "artifacts inside the checkout, ignored: preflight passes, clean" '[ "$(rc artign)" = 0 ] && has artign "^images_clean=yes$"'

# --- a commit that is not on its branch (fetched, then unshallowed to decide)
run unmerged --build-arg "$LAST=$C"
check "unmerged: preflight passes"               '[ "$(rc unmerged)" = 0 ]'
check "unmerged: names the input"                'has unmerged "^unmerged=$LAST$"'
check "unmerged: its tree"                       'has unmerged "^input\.$LAST\.tree=$CTREE$"'

run noarg --build-arg JOBS=2
check "an ARG without a default can be set"     '[ "$(rc noarg)" = 0 ]'

# --- local checkouts (--local): of LAST's repository, cloned from the fixture
LASTREPO=$(echo "$INPUTS" | tail -n 1 | awk '{print $2}')
OVER_PINNED=$OVER
OVER=$(echo "$OVER" | sed "s| --build-arg $LAST=$B||")
lc() { d=$1; shift; git -C "$d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
L=$O/local; git clone -q --no-checkout "$G" "$L"; git -C "$L" checkout -q "$B"
run local --local "$LAST=$L"
check "local: preflight passes"                  '[ "$(rc local)" = 0 ]'
check "local: the input is local"                'has local "^input\.$LAST\.local=yes$"'
check "local: its tree is the checkout's"        'has local "^input\.$LAST\.tree=$BTREE$"'
check "local: a pushed commit on its branch is merged" 'has local "^unmerged=$"'
check "local: the other inputs are not local"    '[ "$(grep -c "^input\..*\.local=yes$" "$O/local.out")" = "$(echo "$INPUTS" | awk -v r="$LASTREPO" "\$2 == r" | wc -l)" ]'
[ "$(rc local)" = 0 ] || show local
run localrepo --local "$LASTREPO=$L"
check "local by its repository's ARG: the input is local" '[ "$(rc localrepo)" = 0 ] && has localrepo "^input\.$LAST\.local=yes$"'
echo "ignored-by-git" >> "$L/.git/info/exclude"; echo x > "$L/ignored-by-git"
run localign --local "$LAST=$L"
check "local: an ignored file leaves it clean"   '[ "$(rc localign)" = 0 ]'
echo d > "$L/new-file"; lc "$L" add new-file; GIT_COMMITTER_DATE='2020-01-04T00:00:00Z' lc "$L" commit -q -m D
D=$(lc "$L" rev-parse HEAD); DTREE=$(lc "$L" rev-parse "$D^{tree}")
run unpushed --local "$LAST=$L"
check "local, not pushed: preflight passes"      '[ "$(rc unpushed)" = 0 ]'
check "local, not pushed: unmerged"              'has unpushed "^unmerged=$LAST$"'
check "local, not pushed: its tree"              'has unpushed "^input\.$LAST\.tree=$DTREE$"'
[ "$(rc unpushed)" = 0 ] || show unpushed
echo x > "$L/untracked-file"
run localdirty --local "$LAST=$L"
rm "$L/untracked-file"
check "local, an untracked file: refused (exit 3)" '[ "$(rc localdirty)" = 3 ] && has localdirty "FAIL: --local $LAST=.*: uncommitted changes"'
echo e > "$L/f"
run localmod --local "$LAST=$L"
lc "$L" checkout -q f
check "local, a changed file: refused (exit 3)"  '[ "$(rc localmod)" = 3 ] && has localmod "FAIL: --local $LAST=.*: uncommitted changes, 1 path(s) (f)"'
X=$O/other; git init -q "$X"; echo o > "$X/o"; lc "$X" add o; lc "$X" commit -q -m other
run localwrong --local "$LAST=$X"
check "local, another repository: refused (exit 3)" '[ "$(rc localwrong)" = 3 ] && has localwrong "FAIL: --local $LAST=.*: not a checkout of file://$G"'
run localnodir --local "$LAST=$O/no-such-dir"
check "local, no directory: refused (exit 3)"    '[ "$(rc localnodir)" = 3 ] && has localnodir "FAIL: --local $LAST=.*: no such directory"'
run localsub --local "$LAST=$L/.git"
check "local, not the top of a checkout: refused" '[ "$(rc localsub)" = 3 ]'
run localboth --local "$LAST=$L" --build-arg "$LAST=$B"
check "local and --build-arg of one input: refused" '[ "$(rc localboth)" = 3 ] && has localboth "FAIL: --local $LAST: the checkout gives its commit"'
run localname --local NO_SUCH_INPUT="$L"
check "local, not an input: refused"             '[ "$(rc localname)" = 3 ] && has localname "FAIL: --local NO_SUCH_INPUT: not a git input"'
# past preflight (the host lock held): the commit and the context reach every export
flock "$O/rt/glassine-images-materialize.lock" sleep 60 & HOLD=$!
sleep 1; : > "$FAKE_BUILD_LOG"; rm -f "$FAKE_BUILD_LOG.ctx"
PF= run localbuild --local "$LAST=$L"
kill $HOLD 2>/dev/null || true
LSTAGE=$(python3 -I -c "
import sys; sys.path.insert(0, sys.argv[1]); import glassine_pins as g
print(g.sources(sys.argv[1] + '/../Dockerfile')[sys.argv[2]][0])" "$R/scripts" "$LAST")
check "local build: past preflight (exit 4 at the lock)" '[ "$(rc localbuild)" = 4 ]'
check "local build: every export gets the commit" '[ "$(grep -c -- "--build-arg $LAST=$D" "$FAKE_BUILD_LOG")" = "$(wc -l < "$FAKE_BUILD_LOG")" ]'
check "local build: every export gets the context" '[ "$(grep -c -- "--build-context $LSTAGE=" "$FAKE_BUILD_LOG")" = "$(wc -l < "$FAKE_BUILD_LOG")" ]'
check "local build: the context is the commit, unchanged" 'grep -q "^context $LSTAGE $D 0$" "$FAKE_BUILD_LOG.ctx" && ! grep -v "^context $LSTAGE $D 0$" "$FAKE_BUILD_LOG.ctx" | grep -q .'
check "local build: the step is timed"           'has localbuild "time local checkouts"'
[ "$(rc localbuild)" = 4 ] || show localbuild
OVER=$OVER_PINNED

# --- failures: exit 3, within seconds, the cause named
fail() {	# fail NAME PATTERN DESCRIPTION
	check "$3: fails (exit 3)"  "[ \"\$(rc $1)\" = 3 ]"
	check "$3: within seconds"  "fast $1"
	check "$3: names the cause" "has $1 '$2'"
	if [ "$(rc "$1")" != 3 ] || ! has "$1" "$2"; then show "$1"; fi
}
run nocommit --build-arg "$LAST=0000000000000000000000000000000000000001"
fail nocommit "FAIL: $LAST: commit 0000000000000000000000000000000000000001 not reachable" "a nonexistent commit"

# a renamed branch pin and an unknown argument in one run: both named
sed -i "s|^# branch: $LASTBR\$|# branch: no-such-branch|" "$R/Dockerfile"
run nobranch --build-arg NO_SUCH=1
git -C "$R" checkout -q Dockerfile
fail nobranch "FAIL: $LAST: branch no-such-branch can.t be fetched" "a branch that can't be fetched"
check "a branch that can't be fetched: the unknown argument named too" 'has nobranch "FAIL: --build-arg NO_SUCH: not an ARG"'

LOCKED=$(cd "$R/stages" && for s in *; do [ -f "$s/lock" ] && [ -f "$s/packages" ] && echo "$s"; done | head -n 1)
mv "$R/stages/$LOCKED/lock" "$O/lock.saved"
run nolock
mv "$O/lock.saved" "$R/stages/$LOCKED/lock"
fail nolock "FAIL: stage $LOCKED: no lock" "a missing lock"

mkdir -p "$R/targets/nodevice"; cp "$R/targets/$TARGET/target" "$R/targets/nodevice/target"
t0=$TARGET; TARGET=nodevice; run nostage; TARGET=$t0
fail nostage "FAIL: the base chain of nodevice starts from .device-nodevice.: no such stage" "a target without its stage"
sed -i 's/^kernel=.*/kernel=otherkernel/' "$R/targets/nodevice/target"
TARGET=nodevice; run nokernel; TARGET=$t0; rm -r "$R/targets/nodevice"
fail nokernel "FAIL: .* names kernel=otherkernel, the build would use KERNEL=" "a target on another kernel"

run badarg --build-arg NO_SUCH_ARG=1
fail badarg "FAIL: --build-arg NO_SUCH_ARG: not an ARG" "an unknown build argument"

mkdir -p "$O/a.noparentrec/$TARGET/builds/20200101-000000"
printf 'format=1\nbase=20200101-0123456789abcdef\n' > "$O/a.noparentrec/$TARGET/builds/20200101-000000/manifest"
run noparentrec
fail noparentrec "FAIL: parent: base 20200101-0123456789abcdef: no .*record (incomplete)" "a parent without its record"

mkdir -p "$O/a.badrecord/$TARGET/builds/20200101-000000"
printf 'format=1\nbase=\377\n' > "$O/a.badrecord/$TARGET/builds/20200101-000000/manifest"
run badrecord --build-arg NO_SUCH=1
fail badrecord "FAIL: parent: UnicodeDecodeError" "a build record that isn't UTF-8"
check "a build record that isn't UTF-8: the other failure named too" 'has badrecord "FAIL: --build-arg NO_SUCH"'

mkdir -p "$O/a.cutparent/$TARGET/bases/20200101-0123456789abcdef"
(cd "$O/a.cutparent/$TARGET/bases/20200101-0123456789abcdef" \
	&& printf 'format=1\nstream_sha256=%064d\n' 0 > record && : > tree.manifest && echo cut > base.btrfs.zst)
run cutparent --parent 20200101-0123456789abcdef
fail cutparent "FAIL: parent: base 20200101-0123456789abcdef: base.btrfs.zst missing or not the stream" "a named parent with a cut stream"

run nobuilder --build-arg KERNEL_BUILD_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
fail nobuilder "FAIL: image .*@sha256:0000000000000000.* not pullable" "a builder digest that can't be pulled"

FAKE_PLATFORMS= run noemu
fail noemu "FAIL: no emulation for linux/" "no emulation"

FAKE_PRIV_FAIL=1 run nopriv
fail nopriv "FAIL: privileged container with loop devices failed .*no free loop device" "no loop devices"

BUILD_MIN_ARTIFACTS_GIB=1000000 run nospace
fail nospace "FAIL: not enough free space for the artifacts folder" "too little free space"
BUILD_MIN_ARTIFACTS_GIB=2G run badthreshold --build-arg NO_SUCH=1
fail badthreshold "FAIL: free space: BUILD_MIN_ARTIFACTS_GIB=.2G.: not a number" "a threshold that isn't a number"
check "a threshold that isn't a number: the other failure named too" 'has badthreshold "FAIL: --build-arg NO_SUCH"'
# two file systems: the probe's docker root (1 GiB free) is not the artifacts' file system
FAKE_DF="1000000000 1048576" run twofs
fail twofs "FAIL: not enough free space for the docker root: 1.0 GiB free, 10.0 GiB needed" "a docker root short of space on its own file system"
check "two file systems: not taken as one" '! has twofs "one file system"'
# a remote daemon: DockerRootDir isn't a path here, the probe's answer counts
FAKE_DOCKER_ROOT=/no/such/docker/root FAKE_DF="1000000000 1048576" run remote
fail remote "FAIL: not enough free space for the docker root: 1.0 GiB free" "a remote daemon short of space"
# one file system: the probe sees the artifacts' file system, the sum is needed
SAME=$(python3 -c "import os,sys; s=os.statvfs(sys.argv[1]); print(s.f_blocks*s.f_frsize//1024, s.f_bavail*s.f_frsize//1024)" "$O")
FAKE_DF="$SAME" BUILD_MIN_DOCKER_GIB=1000000 run onefs
fail onefs "FAIL: not enough free space for the artifacts folder and the docker root (one file system)" "one file system short of space"

# --- unit checks: emulation on a stubbed machine, the GitHub compare answers
python3 -I - "$P/scripts/build" > "$O/unit.out" 2>&1 <<'EOF' || true
import importlib.machinery, importlib.util, io, json, os, sys, urllib.error
l = importlib.machinery.SourceFileLoader('build', sys.argv[1])
s = importlib.util.spec_from_loader('build', l); b = importlib.util.module_from_spec(s); l.exec_module(b)
def emu(machine, plats, arch, others):
    b.platform.machine = lambda: machine
    os.environ['FAKE_PLATFORMS'] = plats
    return b.check_emulation(arch, others)
print('arm64-host-no-amd64', emu('aarch64', 'linux/arm64', 'arm64', ['linux/amd64']))
print('arm64-host-amd64', emu('aarch64', 'linux/arm64, linux/amd64', 'arm64', ['linux/amd64']))
print('amd64-host-no-arm64', emu('x86_64', 'linux/amd64', 'arm64', ['linux/amd64']))
print('amd64-host-arm64', emu('x86_64', 'linux/amd64, linux/arm64', 'arm64', ['linux/amd64']))
class R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False
def gh(answer):
    def urlopen(req, timeout=0):
        if isinstance(answer, BaseException):
            raise answer
        return R(json.dumps(answer).encode())
    b.urllib.request.urlopen = urlopen
    return b.gh_merged('https://github.com/o/r', '0' * 40, 'main')
for st in ('ahead', 'identical', 'behind', 'diverged', 'unknown'):
    print('gh', st, gh({'status': st}))
print('gh 404', gh(urllib.error.HTTPError('u', 404, 'Not Found', {}, None)))
print('gh incomplete', gh(b.http.client.IncompleteRead(b'x')))
print('gh not-json', gh(ValueError('x')))
print('gh no-status', gh({'message': 'x'}))
print('gh not-github', b.gh_merged('https://example.org/o/r', '0' * 40, 'main'))
EOF
u() { grep -q -- "^$1" "$O/unit.out"; }
check "emulation: arm64 host without amd64 fails"  'u "arm64-host-no-amd64 \[.no emulation for linux/amd64"'
check "emulation: arm64 host with amd64 passes"    'u "arm64-host-amd64 \[\]"'
check "emulation: amd64 host without arm64 fails"  'u "amd64-host-no-arm64 \[.no emulation for linux/arm64"'
check "emulation: amd64 host with arm64 passes"    'u "amd64-host-arm64 \[\]"'
check "compare: ahead, identical = merged"         'u "gh ahead True" && u "gh identical True"'
check "compare: behind, diverged = not merged"     'u "gh behind False" && u "gh diverged False"'
check "compare: unknown, 404, cut, bad = no answer" 'u "gh unknown None" && u "gh 404 None" && u "gh incomplete None" && u "gh not-json None" && u "gh no-status None" && u "gh not-github None"'
if grep -q "Traceback" "$O/unit.out"; then sed 's/^/     | /' "$O/unit.out"; fi

# --- past preflight (the fake exports)
PF=
nowork() { ! ls -d "$O/a.$1"/.work-* >/dev/null 2>&1; }
FAKE_BUILD_FAIL=dtb-export run exportfail
check "a failed export: exit 1"                    '[ "$(rc exportfail)" = 1 ]'
check "a failed export: named"                     'has exportfail "build: dtb-export failed"'
check "a failed export: work directory removed"    'nowork exportfail'
check "a failed export: no artifact written"       '[ -z "$(ls "$O/a.exportfail")" ]'

LOCKF=$O/rt/glassine-images-materialize.lock
flock "$LOCKF" sleep 60 & HOLD=$!
sleep 1
: > "$FAKE_BUILD_LOG"
run locked --no-cache
kill $HOLD 2>/dev/null || true
check "a held lock: exit 4"                        '[ "$(rc locked)" = 4 ]'
check "a held lock: named"                         'has locked "another materialization holds the host lock"'
check "a held lock: work directory removed"        'nowork locked'
check "non-UTF-8 build output: the build went on"  'has locked "build: boot-export"'
[ "$(rc locked)" = 4 ] || show locked
python3 -I - "$FAKE_BUILD_LOG" "$R/scripts" "$TARGET" > "$O/filters.out" <<'EOF'
import re, sys
sys.path.insert(0, sys.argv[2]); import glassine_pins as g
lists = []
for line in open(sys.argv[1]):
    t = re.search(r'--target (\S+)', line).group(1)
    m = re.search(r'--no-cache-filter (\S+)', line)
    lists.append((t, m.group(1).split(',') if m else []))
seen = [s for _, l in lists for s in l]
want = g.reachable(sys.argv[2] + '/../Dockerfile', [t for t, _ in lists], {'DEVICE': sys.argv[3]})
print('exports', ' '.join(t for t, _ in lists))
print('once', len(seen) == len(set(seen)))
print('all', sorted(seen) == sorted(want))
print('boot-export', ','.join(dict(lists).get('boot-export', [])))
EOF
check "--no-cache: every export built"             'grep -q "^exports base-export kernel-export dtb-export initramfs-export boot-export$" "$O/filters.out"'
check "--no-cache: each stage built once"          'grep -q "^once True$" "$O/filters.out"'
check "--no-cache: every stage built"              'grep -q "^all True$" "$O/filters.out"'
check "--no-cache: boot-export rebuilds only its own" 'grep -q "^boot-export ." "$O/filters.out" && ! grep "^boot-export" "$O/filters.out" | grep -q kernel'

FAKE_TOUCH="$R/README.md" run changed
git -C "$R" checkout -q README.md
check "a checkout changed during the build: exit 1" '[ "$(rc changed)" = 1 ]'
check "a checkout changed during the build: named"  'has changed "the checkout changed during the build"'
check "a checkout changed during the build: work directory removed" 'nowork changed'

# SIGTERM while an export runs; a stale work directory of a dead run beside a live one
mkdir -p "$O/a.term/.work-4194999" "$O/a.term/.work-$$"
: > "$FAKE_BUILD_LOG"; rm -f "$FAKE_BUILD_LOG.pid"
# shellcheck disable=SC2086
FAKE_BUILD_SLEEP=30 timeout 120 "$R/scripts/build" "$TARGET" --artifacts "$O/a.term" $OVER > "$O/term.out" 2>&1 & BP=$!
i=0; while [ ! -s "$FAKE_BUILD_LOG.pid" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.5
CHILD=$(cat "$FAKE_BUILD_LOG.pid" 2>/dev/null || echo 0)
TBUILD=$(pgrep -P $BP -f scripts/build || echo $BP)
kill -TERM "$TBUILD"; set +e; wait $BP; echo $? > "$O/term.rc"; set -e
check "SIGTERM: exit 143"                          '[ "$(rc term)" = 143 ]'
check "SIGTERM: the build step stopped"            '[ "$CHILD" != 0 ] && ! kill -0 "$CHILD" 2>/dev/null'
check "SIGTERM: its work directory removed"        '! ls -d "$O/a.term"/.work-* | grep -v -e "work-$$\$" -e "work-4194999\$" | grep -q .'
check "a dead run's work directory removed"        '[ ! -d "$O/a.term/.work-4194999" ]'
check "a live process's work directory kept"       '[ -d "$O/a.term/.work-$$" ]'
[ "$(rc term)" = 143 ] || show term

# --- trial reasons (materialize): a local input's commit is local:, not arg: too
python3 -I - "$P/scripts/materialize" > "$O/reasons.out" 2>&1 <<'EOF' || true
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader('materialize', sys.argv[1])
s = importlib.util.spec_from_loader('materialize', l); m = importlib.util.module_from_spec(s); l.exec_module(m)
inputs = {'K': 'main', 'T': 'main', 'B': 'main'}
d = {'K': 'k0', 'T': 'k0', 'B': 'b0', 'JOBS': None}
print('pinned', m.trial_reasons({'images_clean': 'yes'}, inputs, dict(d), d))
print('local', m.trial_reasons({'images_clean': 'yes', 'input.K.local': 'yes', 'input.T.local': 'yes'},
                               inputs, dict(d, K='k1', T='k1'), d))
print('arg', m.trial_reasons({'images_clean': 'no'}, inputs, dict(d, B='b1', JOBS='2'), d))
EOF
check "trial reasons: pinned and clean, none"      'grep -q "^pinned \[\]$" "$O/reasons.out"'
check "trial reasons: local inputs, local: only"   'grep -q "^local \[.local:K., .local:T.\]$" "$O/reasons.out"'
check "trial reasons: arguments and a dirty checkout" 'grep -q "^arg \[.arg:B., .arg:JOBS., .dirty.\]$" "$O/reasons.out"'
if grep -q Traceback "$O/reasons.out"; then sed 's/^/     | /' "$O/reasons.out"; fi

# --- promotion (scripts/promote): records written here, the copy's checkout promotes
PA=$O/p; HEADC=$(rg rev-parse HEAD)
# E: a commit with B's tree, on no branch (a squash or rebase of B)
E=$(gc commit-tree "$BTREE" -p "$A" -m E); git -C "$W" push -q "$G" "$E:refs/side/e"
record() {	# record ID KEY=VALUE...: a build record of TARGET, the inputs at B, KEY=VALUE replacing
	id=$1; shift; d=$PA/$TARGET/builds/$id; mkdir -p "$d"
	{ echo format=1; echo "build=$id"; echo "target=$TARGET"; echo built=2020-01-05T00:00:00Z
	  echo "images_commit=$HEADC"; echo images_clean=yes; echo trial=no; echo trial_reasons=
	  echo "$INPUTS" | while read -r c u b; do
		echo "arg.$u=file://$G"; echo "input.$c.commit=$B"; echo "input.$c.tree=$BTREE"
		echo "input.$c.branch=$b"; echo "input.$c.local=no"; done
	} | awk '!seen[$0]++' > "$d/manifest"
	for l; do
		k=${l%%=*}; grep -v "^$k=" "$d/manifest" > "$d/x"; echo "$l" >> "$d/x"; mv "$d/x" "$d/manifest"
	done
}
promote() {	# promote NAME ARGS...: the copy's scripts/promote; output in $O/NAME.out, exit in .rc
	n=$1; shift; set +e
	timeout 120 "$R/scripts/promote" "$@" > "$O/$n.out" 2>&1; echo $? > "$O/$n.rc"; set -e
}
staged() { git -C "$R" diff --cached --name-only; }
record 20200105-000000
promote pgood 20200105-000000 --artifacts "$PA" --at HEAD
check "promote: a pinned, clean build passes"      '[ "$(rc pgood)" = 0 ]'
check "promote: the record staged under promoted/" '[ "$(staged)" = "promoted/$TARGET/20200105-000000/manifest" ]'
check "promote: the same bytes"                    'cmp -s "$R/promoted/$TARGET/20200105-000000/manifest" "$PA/$TARGET/builds/20200105-000000/manifest"'
check "promote: says what to commit"               'has pgood "git commit"'
check "promote: no work directory left"            '! ls -d "$PA"/.work-* >/dev/null 2>&1'
[ "$(rc pgood)" = 0 ] || show pgood
promote pagain "$PA/$TARGET/builds/20200105-000000" --at HEAD
check "promote: again, by its directory: passes"   '[ "$(rc pagain)" = 0 ]'
rg reset -q; rm -rf "$R/promoted"
SAMETREE=$(rg commit-tree "HEAD^{tree}" -p HEAD -m same)
promote psame 20200105-000000 --artifacts "$PA" --at "$SAMETREE"
check "promote: another commit with the same tree passes" '[ "$(rc psame)" = 0 ]'
rg reset -q; rm -rf "$R/promoted"
OTHERTREE=$(rg commit-tree "$(rg mktree < /dev/null)" -p HEAD -m other)
promote ptree 20200105-000000 --artifacts "$PA" --at "$OTHERTREE"
check "promote: images tree differs: refused"      '[ "$(rc ptree)" = 1 ] && has ptree "FAIL: images_commit .* has tree .*, $OTHERTREE has tree"'
check "promote: refused, nothing staged or written" '[ -z "$(staged)" ] && [ ! -e "$R/promoted" ]'
promote pnoat 20200105-000000 --artifacts "$PA"
check "promote: default origin/main missing: refused" '[ "$(rc pnoat)" = 1 ] && has pnoat "FAIL: --at origin/main: not a commit of this checkout"'
record 20200105-000001 trial=yes "trial_reasons=local:$LAST" "input.$LAST.local=yes"
promote ptrial 20200105-000001 --artifacts "$PA" --at HEAD
check "promote: a trial: refused"                  '[ "$(rc ptrial)" = 1 ] && has ptrial "FAIL: a trial (local:$LAST)"'
record 20200105-000002 "input.$LAST.commit=$C" "input.$LAST.tree=$CTREE"
promote poff 20200105-000002 --artifacts "$PA" --at HEAD
check "promote: an input tree on no commit of its branch: refused" '[ "$(rc poff)" = 1 ] && has poff "FAIL: input $LAST: tree $CTREE is the tree of no commit on $LASTBR"'
record 20200105-000003 "input.$LAST.commit=$E"
promote psquash 20200105-000003 --artifacts "$PA" --at HEAD
check "promote: another commit with a tree on the branch passes" '[ "$(rc psquash)" = 0 ]'
[ "$(rc psquash)" = 0 ] || show psquash
rg reset -q; rm -rf "$R/promoted"
record 20200105-000004 images_clean=no
promote pdirty 20200105-000004 --artifacts "$PA" --at HEAD
check "promote: a dirty checkout without trial=yes: refused" '[ "$(rc pdirty)" = 1 ] && has pdirty "FAIL: images_clean=no"'
mkdir -p "$R/promoted/$TARGET/20200105-000000"; echo other > "$R/promoted/$TARGET/20200105-000000/manifest"
promote pexists 20200105-000000 --artifacts "$PA" --at HEAD
rm -rf "$R/promoted"
check "promote: promoted already with other bytes: refused" '[ "$(rc pexists)" = 1 ] && has pexists "exists with other content"'
promote pnone 20200105-999999 --artifacts "$PA" --at HEAD
check "promote: no such build: refused"            '[ "$(rc pnone)" = 1 ] && has pnone "FAIL: build 20200105-999999: not in"'

[ -n "${KEEP-}" ] || rm -rf "$O"
echo "test-build: $fails failure(s)"
[ "$fails" = 0 ]
