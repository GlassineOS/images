#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of scripts/build's preflight (FR-004), without a stage build and without
# the network: docker is a stand-in on PATH (its answers set by FAKE_* variables), every
# git input points at a local fixture repository (file://), and a copy of this checkout
# runs the command. Checks that a good environment passes with the right build info
# (each input's tree, unmerged for a commit off its branch) and that each failure ends
# the command within seconds (exit 3) naming its cause: a commit that doesn't exist, a
# missing lock, a missing stage of the target, an unknown --build-arg, a parent whose
# record or stream is missing, a builder digest that can't be pulled, no emulation for
# the target's arch, no loop devices in a privileged container, too little free space.
#   scripts/test-build.sh     exit 0 = all checks pass
# Needs python3, git and sh. Works in .out/test-build/ under the checkout, removed at
# the end.
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
O=$P/.out/test-build
rm -rf "$O"; mkdir -p "$O/bin"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# --- docker, as far as the preflight asks it
cat > "$O/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
"buildx inspect") echo "Name: fake"; echo "Platforms: linux/amd64, ${FAKE_PLATFORMS-linux/arm64}" ;;
"buildx imagetools")
	for a; do r=$a; done
	case "$r" in *sha256:0000000000000000*) echo "ERROR: $r: not found" >&2; exit 1 ;; esac
	echo "Name: $r" ;;
"run --rm")
	if [ -n "${FAKE_PRIV_FAIL-}" ]; then echo "probe: no free loop device"; exit 3; fi
	echo "probe: df 1000000000 900000000" ;;
"info --format") echo "$FAKE_DOCKER_ROOT" ;;
*) echo "fake docker: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$O/bin/docker"
export PATH="$O/bin:$PATH" FAKE_DOCKER_ROOT="$O"

# --- a copy of this checkout (tracked and untracked files, not the ignored ones)
R=$O/repo; mkdir -p "$R"
(cd "$P" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - 2>/dev/null) | tar -C "$R" -xf -
TARGET=$(ls "$R/targets" | head -n 1)

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

run() {	# run NAME ARGS...: the preflight in the copy; output in $O/NAME.out, seconds in $O/NAME.s
	n=$1; shift
	t=$(date +%s)
	set +e
	# shellcheck disable=SC2086
	timeout 60 "$R/scripts/build" "$TARGET" --preflight-only --artifacts "$O/a.$n" $OVER "$@" > "$O/$n.out" 2>&1
	echo $? > "$O/$n.rc"
	set -e
	echo $(( $(date +%s) - t )) > "$O/$n.s"
}
rc() { cat "$O/$1.rc"; }
has() { grep -q -- "$2" "$O/$1.out"; }
fast() { [ "$(cat "$O/$1.s")" -le 20 ]; }

# --- a good environment
run good
check "good: preflight passes"                  '[ "$(rc good)" = 0 ]'
check "good: within seconds"                     'fast good'
check "good: each input's tree"                  '[ "$(grep -c "^input\..*\.tree=$BTREE$" "$O/good.out")" = "$(echo "$INPUTS" | wc -l)" ]'
check "good: nothing unmerged"                   'has good "^unmerged=$"'
check "good: inputs not local"                   '! grep "^input\..*\.local=" "$O/good.out" | grep -qv "=no$"'
check "good: builder digest in the build info"   'has good "^builder\..*=sha256:"'

# --- a commit that is not on its branch (fetched, then unshallowed to decide)
run unmerged --build-arg "$LAST=$C"
check "unmerged: preflight passes"               '[ "$(rc unmerged)" = 0 ]'
check "unmerged: names the input"                'has unmerged "^unmerged=$LAST$"'
check "unmerged: its tree"                       'has unmerged "^input\.$LAST\.tree=$CTREE$"'

# --- failures: exit 3, within seconds, the cause named
fail() {	# fail NAME PATTERN DESCRIPTION
	check "$3: fails (exit 3)"  "[ \"\$(rc $1)\" = 3 ]"
	check "$3: within seconds"  "fast $1"
	check "$3: names the cause" "has $1 '$2'"
	if [ "$(rc "$1")" != 3 ] || ! has "$1" "$2"; then sed 's/^/     | /' "$O/$1.out"; fi
}
run nocommit --build-arg "$LAST=0000000000000000000000000000000000000001"
fail nocommit "FAIL: $LAST: commit 0000000000000000000000000000000000000001 not reachable" "a nonexistent commit"

LOCKED=$(cd "$R/stages" && for s in *; do [ -f "$s/lock" ] && [ -f "$s/packages" ] && echo "$s"; done | head -n 1)
mv "$R/stages/$LOCKED/lock" "$O/lock.saved"
run nolock
mv "$O/lock.saved" "$R/stages/$LOCKED/lock"
fail nolock "FAIL: stage $LOCKED: no lock" "a missing lock"

mkdir -p "$R/targets/nodevice"; cp "$R/targets/$TARGET/target" "$R/targets/nodevice/target"
t0=$TARGET; TARGET=nodevice; run nostage; TARGET=$t0
fail nostage "FAIL: the base chain of nodevice starts from .device-nodevice.: no such stage" "a target without its stage"

run badarg --build-arg NO_SUCH_ARG=1
fail badarg "FAIL: --build-arg NO_SUCH_ARG: not an ARG" "an unknown build argument"

mkdir -p "$O/a.noparentrec/$TARGET/builds/20200101-000000"
printf 'format=1\nbase=20200101-0123456789abcdef\n' > "$O/a.noparentrec/$TARGET/builds/20200101-000000/manifest"
run noparentrec
fail noparentrec "FAIL: parent: base 20200101-0123456789abcdef: no .*record (incomplete)" "a parent without its record"

mkdir -p "$O/a.cutparent/$TARGET/bases/20200101-0123456789abcdef"
(cd "$O/a.cutparent/$TARGET/bases/20200101-0123456789abcdef" \
	&& printf 'format=1\nstream_sha256=%064d\n' 0 > record && : > tree.manifest && echo cut > base.btrfs.zst)
run cutparent --parent 20200101-0123456789abcdef
fail cutparent "FAIL: parent: base 20200101-0123456789abcdef: base.btrfs.zst missing or not the stream" "a named parent with a cut stream"

run nobuilder --build-arg KERNEL_BUILD_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
fail nobuilder "FAIL: image .*@sha256:0000000000000000.* not pullable" "a builder digest that can't be pulled"

ARCH=$(sed -n 's/^arch=//p' "$R/targets/$TARGET/target")
case "$(uname -m)" in aarch64|arm64) HOST=arm64 ;; x86_64) HOST=amd64 ;; *) HOST=$(uname -m) ;; esac
if [ "$HOST" != "$ARCH" ]; then
	FAKE_PLATFORMS= run noemu
	fail noemu "FAIL: no $ARCH emulation" "no emulation for the target's arch"
else
	echo "skip no emulation: this host is $ARCH"
fi

FAKE_PRIV_FAIL=1 run nopriv
fail nopriv "FAIL: privileged container with loop devices failed .*no free loop device" "no loop devices"

BUILD_MIN_ARTIFACTS_GIB=1000000 run nospace
fail nospace "FAIL: not enough free space for the artifacts folder" "too little free space"

check "no work directory left behind" '! ls -d "$O"/a.*/.work-* >/dev/null 2>&1'

[ -n "${KEEP-}" ] || rm -rf "$O"
echo "test-build: $fails failure(s)"
[ "$fails" = 0 ]
