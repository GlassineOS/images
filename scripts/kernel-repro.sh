#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Reproducibility of the kernel and device-tree stages: build them twice, the second time
# from scratch (no layer cache for those stages, an empty kernel cache mount), check both
# exports with scripts/kernel-check and compare them byte for byte.
#   scripts/kernel-repro.sh OUTDIR [--build-arg NAME=VALUE]...
# The first build uses the usual cache mount, so it may be an incremental build on top of
# an earlier commit's objects: the comparison then also shows that an incremental build
# gives what a full one gives. The empty mount is removed afterwards. Needs about 8 GB
# of free space for that mount while it runs; with KERNEL_REPRO_DROP=1 the usual mount
# is removed after the first build to make room (the next build is then a full one).
set -eu
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: scripts/kernel-repro.sh OUTDIR [--build-arg NAME=VALUE]..." >&2; exit 2; }
out=$1; shift
[ ! -e "$out" ] || { echo "kernel-repro: $out exists" >&2; exit 2; }
check_args=
for a in "$@"; do case $a in --build-arg) ;; *=*) check_args="$check_args --arg $a" ;; esac; done
salt=kernel-sdm660-repro-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
b() { # b DEST [extra args]: both exports into DEST
	d=$1; shift
	for t in kernel-export dtb-export; do
		docker buildx build --progress=plain --platform linux/arm64 --target $t \
			-o "type=local,dest=$d.$t" "$@" . > "$d.$t.log" 2>&1 \
			|| { tail -n 30 "$d.$t.log" >&2; echo "kernel-repro: $t failed, log $d.$t.log" >&2; return 1; }
	done
	mkdir -p "$d"; cp -a "$d.kernel-export/." "$d.dtb-export/." "$d/"
	rm -rf "$d.kernel-export" "$d.dtb-export"
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
s=$(date +%s); b "$out/a" "$@"; echo "kernel-repro: build a (cache mount kernel-sdm660): $(( $(date +%s) - s )) s"
[ "${KERNEL_REPRO_DROP:-0}" != 1 ] || drop kernel-sdm660 || exit 1
s=$(date +%s); salted=1
b "$out/b" --no-cache-filter kernel-sdm660,dtb --build-arg KCACHE="$salt" "$@"
echo "kernel-repro: build b (from scratch, cache mount $salt): $(( $(date +%s) - s )) s"
rc=0
# shellcheck disable=SC2086
scripts/kernel-check $check_args "$out/a" > "$out/a.check" || rc=1
# shellcheck disable=SC2086
scripts/kernel-check $check_args "$out/b" > "$out/b.check" || rc=1
scripts/kernel-check --compare "$out/a" "$out/b" || rc=1
tail -n 1 "$out/a.check" "$out/b.check"
exit $rc
