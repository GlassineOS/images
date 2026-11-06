#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# What a lock refresh changed, as Markdown for the pull request, and whether a change
# brings a security fix from Alpine's security database (secdb).
#   scripts/lock-diff.sh OLD_DIR NEW_DIR [OUT_FLAG]
# OLD_DIR and NEW_DIR hold lock files (any names); packages are compared across all of
# them. OUT_FLAG (optional) gets "security" or "routine". Runs in an Alpine container
# (needs apk for version comparison, jq, wget).
set -eu
old=$1 new=$2 flag=${3:-}
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cat "$old"/* 2>/dev/null | LC_ALL=C sort -u > "$t/old"
cat "$new"/* | LC_ALL=C sort -u > "$t/new"

# name old new (empty side for added or removed)
awk -F= 'NR==FNR {o[$1]=$2; next} {n[$1]=$2}
	END {
		for (p in n) if (!(p in o)) print p, "-", n[p]; else if (o[p] != n[p]) print p, o[p], n[p]
		for (p in o) if (!(p in n)) print p, o[p], "-"
	}' "$t/old" "$t/new" | LC_ALL=C sort > "$t/changes"

# a package's origin (secdb lists origins: openssl, not libcrypto3)
rel=$(sed -n 's/^\([0-9]*\.[0-9]*\).*/v\1/p' /etc/alpine-release)
arch=$(apk --print-arch)
for r in main community; do
	wget -qO- "https://dl-cdn.alpinelinux.org/alpine/$rel/$r/$arch/APKINDEX.tar.gz" | tar -xzO APKINDEX
done | awk -F: '/^P:/{p=$2} /^o:/{print p, $2}' | LC_ALL=C sort -u > "$t/origins"
for r in main community; do
	wget -qO- "https://secdb.alpinelinux.org/$rel/$r.json"
done | jq -r '.packages[].pkg as $p | $p.secfixes // {} | to_entries[]
	| select(.key | test("^[0-9]")) | "\($p.name) \(.key) \(.value | join(","))"' > "$t/secfixes"

security=routine
: > "$t/sec"
while read -r p o n; do
	[ "$o" != - ] && [ "$n" != - ] || continue
	origin=$(awk -v p="$p" '$1 == p {print $2; exit}' "$t/origins")
	origin=${origin:-$p}
	awk -v o="$origin" '$1 == o {print $2, $3}' "$t/secfixes" | while read -r fix cves; do
		if [ "$(apk version -t "$o" "$fix")" = "<" ] && [ "$(apk version -t "$fix" "$n")" != ">" ]; then
			echo "$p $o $n $cves"
		fi
	done >> "$t/sec"
done < "$t/changes"
[ ! -s "$t/sec" ] || security=security

echo "Refreshed locks (\`scripts/lock.sh\`): $(wc -l < "$t/changes") packages changed."
echo
if [ "$security" = security ]; then
	echo "**Security fixes** (Alpine secdb):"
	echo
	echo "| Package | Version | Fixes |"
	echo "|---|---|---|"
	awk '{k = $1 " " $2 " " $3; if (!(k in c)) c[k] = ""; if ($4 != "") c[k] = (c[k] == "") ? $4 : c[k] "," $4}
		END {for (k in c) {split(k, f, " "); printf "| `%s` | %s → %s | %s |\n", f[1], f[2], f[3], c[k]}}' "$t/sec" | LC_ALL=C sort
	echo
fi
echo "| Package | Was | Now |"
echo "|---|---|---|"
awk '{printf "| `%s` | %s | %s |\n", $1, $2, $3}' "$t/changes"
[ -z "$flag" ] || echo "$security" > "$flag"
