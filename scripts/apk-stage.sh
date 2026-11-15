#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Runs inside a stage's RUN, with the stage directory bind-mounted at /run/stage:
#   packages  plain package names (one per line, # comments)
#   lock      the whole installed set after this stage, name=version, sorted
#   rootfs/   files the stage copies over the tree afterwards (optional)
# Installs exactly the versions the lock names, records the packages in /etc/apk/world
# by plain name (no pin there: a live `apk upgrade` moves them on), then fails if the
# installed set differs from the lock. A lock line that no repository offers any more
# fails before anything is installed, naming the line.
# LOCK=refresh installs the newest versions instead and skips the comparison
# (scripts/lock.sh writes the locks from that).
set -eu
S=/run/stage
C=/var/cache/apk
pk=$(sed 's/#.*//' "$S/packages" | tr -s ' \t\n' ' ')

refresh() {
	echo "apk-stage: refresh the locks with scripts/lock.sh" >&2
	exit 1
}

# -U / apk update: the index fresh every time. The cache mount keeps it between builds,
# and apk would reuse an index younger than its cache age, so a just-published version
# the lock asks for would be missing
if [ "${LOCK:-check}" = refresh ]; then
	# shellcheck disable=SC2086
	[ -z "${pk# }" ] || apk add -q -U --cache-dir "$C" $pk
else
	[ -f "$S/lock" ] || { echo "apk-stage: no lock for this stage: run scripts/lock.sh" >&2; exit 1; }
	apk update -q --cache-dir "$C"
	# every version of every locked name that apk can install (repositories and the
	# installed database): "name version source"
	# shellcheck disable=SC2046
	apk policy --cache-dir "$C" $(cut -d= -f1 "$S/lock") | awk '
		/^[^ ].* policy:$/ { p = $1; next }
		/^  [^ ].*:$/ { v = substr($1, 1, length($1) - 1); next }
		/^    / { print p, v, $1 }' > /tmp/apk-stage.offered
	missing=$(awk 'NR == FNR { ok[$1 "=" $2] = 1; next } !($0 in ok)' /tmp/apk-stage.offered "$S/lock")
	if [ -n "$missing" ]; then
		echo "apk-stage: lock lines that no repository offers any more:" >&2
		for l in $missing; do
			n=${l%%=*}
			has=$(awk -v n="$n" '$1 == n { v[$2] = 1; s[$2] = s[$2] ? s[$2] : $3 }
				END { for (x in v) { printf "%s%s (%s)", sep, x, s[x]; sep = ", " } }' /tmp/apk-stage.offered)
			echo "  $l   offered: ${has:-nothing}" >&2
		done
		echo "apk-stage: Alpine's repositories keep only the newest version of a package," >&2
		echo "apk-stage: so an Alpine update takes a locked version away; GlassineOS's keep" >&2
		echo "apk-stage: earlier versions for 30 days and every version images main locks." >&2
		refresh
	fi
	# the locked versions, held by a virtual package so the pins stay out of the world;
	# then the stage's packages by name (installed versions satisfy them: apk upgrades
	# nothing without -u); then the virtual goes, the versions stay
	# shellcheck disable=SC2046
	apk add -q --cache-dir "$C" -t .glassine-lock $(cat "$S/lock") || {
		echo "apk-stage: the locked versions don't install together" >&2; refresh; }
	# shellcheck disable=SC2086
	[ -z "${pk# }" ] || apk add -q --cache-dir "$C" $pk
	apk del -q --cache-dir "$C" .glassine-lock
fi

# a copied file must not belong to a package
if [ -d "$S/rootfs" ]; then
	bad=$(cd "$S/rootfs" && find . ! -type d | sed 's|^\.||' | while read -r f; do
		if apk info -q --who-owns "$f" >/dev/null 2>&1; then echo "$f"; fi
	done)
	[ -z "$bad" ] || { echo "apk-stage: rootfs/ files that a package owns:" $bad >&2; exit 1; }
fi

[ "${LOCK:-check}" = refresh ] && exit 0
have=$(awk -F: '/^P:/{p=$2} /^V:/{print p "=" $2}' /lib/apk/db/installed | LC_ALL=C sort)
if [ "$have" != "$(cat "$S/lock")" ]; then
	echo "apk-stage: installed packages differ from the lock (- lock, + installed):" >&2
	printf '%s\n' "$have" > /tmp/have
	diff "$S/lock" /tmp/have | grep '^[-+][^-+]' >&2 || :
	refresh
fi
