#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs inside a stage's RUN, with the stage directory bind-mounted at /run/stage:
#   packages  plain package names (one per line, # comments)
#   lock      the whole installed set after this stage, name=version, sorted
#   rootfs/   files the stage copies over the tree afterwards (optional)
# Installs the packages, then fails if the installed set differs from the lock.
# LOCK=refresh skips the comparison (scripts/lock.sh writes the locks).
set -eu
S=/run/stage
pk=$(sed 's/#.*//' "$S/packages" | tr -s ' \t\n' ' ')
# shellcheck disable=SC2086
[ -z "${pk# }" ] || apk add -q --cache-dir /var/cache/apk $pk

# a copied file must not belong to a package
if [ -d "$S/rootfs" ]; then
	bad=$(cd "$S/rootfs" && find . ! -type d | sed 's|^\.||' | while read -r f; do
		if apk info -q --who-owns "$f" >/dev/null 2>&1; then echo "$f"; fi
	done)
	[ -z "$bad" ] || { echo "apk-stage: rootfs/ files that a package owns:" $bad >&2; exit 1; }
fi

[ "${LOCK:-check}" = refresh ] && exit 0
have=$(awk -F: '/^P:/{p=$2} /^V:/{print p "=" $2}' /lib/apk/db/installed | LC_ALL=C sort)
[ -f "$S/lock" ] || { echo "apk-stage: no lock for this stage: run scripts/lock.sh" >&2; exit 1; }
if [ "$have" != "$(cat "$S/lock")" ]; then
	echo "apk-stage: installed packages differ from the lock (- lock, + installed):" >&2
	printf '%s\n' "$have" > /tmp/have
	diff "$S/lock" /tmp/have | grep '^[-+][^-+]' >&2 || :
	echo "apk-stage: refresh the locks with scripts/lock.sh" >&2
	exit 1
fi
