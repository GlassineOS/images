#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Reproducibility of the kernel and device-tree stages: build them twice, the second time
# from scratch (no layer cache for those stages, an empty kernel cache mount), check both
# exports with scripts/kernel-check and compare them byte for byte.
#   scripts/kernel-repro.sh OUTDIR [--build-arg NAME=VALUE]...
#   scripts/kernel-repro.sh --recovery OUTDIR [--build-arg NAME=VALUE]...
# --recovery does the same for the recovery's kernel (recovery-kernel-export, its stage
# kernel-sdm660recovery and its cache mount kernel-sdm660recovery), checked with
# scripts/kernel-check --stage kernel-sdm660recovery --partial.
# The first build uses the usual cache mount, so it may be an incremental build on top of
# an earlier commit's objects: the comparison then also shows that an incremental build
# gives what a full one gives. The empty mount is removed afterwards. Needs about 8 GB
# of free space for that mount while it runs; with KERNEL_REPRO_DROP=1 the usual mount
# is removed after the first build to make room (the next build is then a full one).
set -eu
cd "$(dirname "$0")/.."
# the exports, the stages built again from scratch, the cache mount, and the check's options
targets='kernel-export dtb-export' stages=kernel-sdm660,dtb mount=kernel-sdm660 cachearg=KCACHE check_mode=
if [ "${1:-}" = --recovery ]; then
	targets=recovery-kernel-export stages=kernel-sdm660recovery mount=kernel-sdm660recovery cachearg=RKCACHE
	check_mode='--stage kernel-sdm660recovery --partial'
	shift
fi
[ $# -ge 1 ] || { echo "usage: scripts/kernel-repro.sh [--recovery] OUTDIR [--build-arg NAME=VALUE]..." >&2; exit 2; }
out=$1; shift
[ ! -e "$out" ] || { echo "kernel-repro: $out exists" >&2; exit 2; }
check_args=
for a in "$@"; do case $a in --build-arg) ;; *=*) check_args="$check_args --arg $a" ;; esac; done
salt=$mount-repro-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
b() { # b DEST [extra args]: both exports into DEST
	d=$1; shift
	for t in $targets; do
		docker buildx build --progress=plain --platform linux/arm64 --target $t \
			-o "type=local,dest=$d.$t" "$@" . > "$d.$t.log" 2>&1 \
			|| { tail -n 30 "$d.$t.log" >&2; echo "kernel-repro: $t failed, log $d.$t.log" >&2; return 1; }
	done
	mkdir -p "$d"
	for t in $targets; do cp -a "$d.$t/." "$d/"; rm -rf "$d.$t"; done
}
drop() { # drop KCACHE: remove the kernel cache mount(s) KCACHE-<builder digest>; fails if
	# none is found or one is still there afterwards (an ~8 GB mount left behind silently)
	ids=$(docker buildx du --verbose 2>/dev/null | awk -v a="with id \"$1-sha256:" -v b="with id \"/$1-sha256:" '
		/^ID:/ {id=$2} /^Description:/ && (index($0, a) || index($0, b)) {print id}')
	[ -n "$ids" ] || { echo "kernel-repro: no cache mount $1-sha256:… found in docker buildx du; remove it by hand" >&2; return 1; }
	for i in $ids; do
		docker buildx prune -f --filter "id=$i" >/dev/null \
			|| { echo "kernel-repro: docker buildx prune failed for $i ($1)" >&2; return 1; }
		! docker buildx du --verbose 2>/dev/null | grep -qx "ID:[[:space:]]*$i" \
			|| { echo "kernel-repro: cache mount $i ($1) is still there" >&2; return 1; }
	done
	echo "kernel-repro: removed cache mount $1 ($ids)" >&2
}
salted=0
trap 'st=$?; [ $salted = 0 ] || drop "$salt" || st=1; exit $st' EXIT
mkdir -p "$out"
s=$(date +%s); b "$out/a" "$@"; echo "kernel-repro: build a (cache mount $mount): $(( $(date +%s) - s )) s"
[ "${KERNEL_REPRO_DROP:-0}" != 1 ] || drop $mount || exit 1
s=$(date +%s); salted=1
b "$out/b" --no-cache-filter $stages --build-arg $cachearg="$salt" "$@"
echo "kernel-repro: build b (from scratch, cache mount $salt): $(( $(date +%s) - s )) s"
rc=0
# shellcheck disable=SC2086
scripts/kernel-check $check_mode $check_args "$out/a" > "$out/a.check" || rc=1
# shellcheck disable=SC2086
scripts/kernel-check $check_mode $check_args "$out/b" > "$out/b.check" || rc=1
scripts/kernel-check --compare "$out/a" "$out/b" || rc=1
tail -n 1 "$out/a.check" "$out/b.check"
exit $rc
