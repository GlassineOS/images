#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Fetches one commit of a git input and checks it out, for the Dockerfile's source stages:
#
#   git-fetch.sh STEP URL COMMIT DEST [MIRROR]
#
# DEST becomes (or, when it is one already, moves to) a checkout of COMMIT with a
# shallow .git holding that commit. With MIRROR, a bare repository kept between builds
# (a cache mount), the commit is fetched into MIRROR first and kept there as
# refs/kept/<commit>, so a later fetch of another commit transfers only the objects it
# adds; DEST is then filled from MIRROR. Removing MIRROR costs time only.
#
# Every fetch from URL has a time limit (GIT_FETCH_TIMEOUT seconds, default 1800) and is
# stopped when it moves less than 1 KiB/s for GIT_FETCH_STALL seconds (default 120). A
# fetch that timed out or failed for a network reason is tried again, up to
# GIT_FETCH_TRIES tries (default 4), after GIT_FETCH_PAUSE seconds (default 15), then
# twice as long each time; any other failure (the commit isn't in the repository) ends at
# once. The final failure names the step, the repository and the commit.
set -eu
[ $# -ge 4 ] || { echo "usage: git-fetch.sh STEP URL COMMIT DEST [MIRROR]" >&2; exit 2; }
step=$1 url=$2 commit=$3 dest=$4 mirror=${5:-}
tries=${GIT_FETCH_TRIES:-4} limit=${GIT_FETCH_TIMEOUT:-1800} stall=${GIT_FETCH_STALL:-120}
die() { echo "git-fetch: $step: $*" >&2; exit 1; }

# fetch_url GITDIR REFSPEC: from URL, with the time limit and the tries
fetch_url() {
	n=1 pause=${GIT_FETCH_PAUSE:-15}
	while :; do
		rc=0
		GIT_TERMINAL_PROMPT=0 timeout "$limit" git -C "$1" -c protocol.version=2 \
			-c http.lowSpeedLimit=1024 -c http.lowSpeedTime="$stall" \
			fetch -q --depth=1 "$url" "$2" 2> /tmp/git-fetch.err || rc=$?
		[ $rc = 0 ] && return 0
		why=$(grep -E '^(fatal|error):' /tmp/git-fetch.err | head -n 1)
		[ -n "$why" ] || why=$(tail -n 1 /tmp/git-fetch.err)
		case $rc in
		124|137|143) why="timed out after $limit s${why:+: $why}"; net=1 ;;
		*) net=0
		   if grep -qiE "could not resolve|timed out|timeout|connection|connect to|rpc failed|early eof|unexpected disconnect|hung up|transfer closed|ssl|tls|gnutls|returned error: (5[0-9][0-9]|429)|too slow|empty reply|recv failure|send failure" /tmp/git-fetch.err; then
		       net=1; fi ;;
		esac
		if [ $net = 0 ]; then
			die "fetching $commit from $url failed: $why"
		fi
		if [ "$n" -ge "$tries" ]; then
			die "fetching $commit from $url failed after $n tries: $why"
		fi
		echo "git-fetch: $step: try $n of $tries failed ($why); again in $pause s" >&2
		sleep "$pause"
		n=$((n + 1)) pause=$((pause * 2))
	done
}

[ -d "$dest/.git" ] || { mkdir -p "$dest" && git -C "$dest" init -q; }
if [ -n "$mirror" ]; then
	[ -d "$mirror/objects" ] || git init -q --bare "$mirror"
	if ! git -C "$mirror" rev-parse -q --verify "refs/kept/$commit^{commit}" >/dev/null; then
		fetch_url "$mirror" "+$commit:refs/kept/$commit"
	fi
	git -C "$dest" fetch -q --depth=1 "file://$mirror" "refs/kept/$commit" \
		|| die "copying $commit from the kept repository $mirror failed"
else
	fetch_url "$dest" "$commit"
fi
git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD \
	|| die "checking out $commit from $url failed"
[ "$(git -C "$dest" rev-parse HEAD)" = "$commit" ] || die "$url gave $(git -C "$dest" rev-parse HEAD), not $commit"
rm -f /tmp/git-fetch.err
