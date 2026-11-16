#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# What a lock refresh changed, as Markdown for the pull request, and whether a change
# brings a security fix from Alpine's security database (secdb).
#   scripts/lock-diff.sh OLD_DIR NEW_DIR [OUT_FLAG]
# OLD_DIR and NEW_DIR hold lock files (any names); packages are compared across all of
# them. OUT_FLAG (optional) gets "security" (a change brings a fix from Alpine's secdb),
# "gone" (a version OLD_DIR names is no longer offered by Alpine's or our repository, so
# builds of the current locks fail; also a line NEW_DIR holds for the kernel package,
# scripts/kernel-lock.sh, that is no longer offered) or "routine". Lines held for the
# kernel get a table of their own, with the fixes their newer versions would bring. Runs in an Alpine container (needs apk
# for version comparison, jq, wget). ARCH (optional): the architecture whose
# repositories the locks are checked against, as apk names it (x86_64); default the
# container's. Run once per architecture, each on that architecture's lock files only.
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
arch=${ARCH:-$(apk --print-arch)}
for r in main community; do
	wget -qO- "https://dl-cdn.alpinelinux.org/alpine/$rel/$r/$arch/APKINDEX.tar.gz" | tar -xzO APKINDEX
done > "$t/alpine"
awk -F: '/^P:/{p=$2} /^o:/{print p, $2}' "$t/alpine" | LC_ALL=C sort -u > "$t/origins"
# every name=version the repositories offer (ours keeps earlier versions, Alpine's not)
wget -qO- "https://pkgs.glassine.org/alpine/$rel/glassine/$arch/APKINDEX.tar.gz" | tar -xzO APKINDEX > "$t/ours"
cat "$t/alpine" "$t/ours" | awk -F: '/^P:/{p=$2} /^V:/{print p "=" $2}' | LC_ALL=C sort -u > "$t/offered"
# changed lines of the old locks that are gone (an unchanged line was installable now)
awk '$2 != "-" {print $1 "=" $2}' "$t/changes" | LC_ALL=C sort | LC_ALL=C comm -23 - "$t/offered" > "$t/gone"
for r in main community; do
	wget -qO- "https://secdb.alpinelinux.org/$rel/$r.json"
done | jq -r '.packages[].pkg as $p | $p.secfixes // {} | to_entries[]
	| select(.key | test("^[0-9]")) | "\($p.name) \(.key) \(.value | join(","))"' > "$t/secfixes"

# held: a kernel package's firmware or microcode kept at its locked version because the
# kernel package didn't move (scripts/kernel-lock.sh) while Alpine offers another one.
# Alpine keeps only its newest version, so a held line is gone too unless our
# repository has it: a gone held line breaks the kernel's build until the kernel moves
# "name locked alpine" for such lines of the new locks
awk -F: '/^P:/{p=$2} /^V:/{print p, $2}' "$t/alpine" | LC_ALL=C sort -u > "$t/alpine-v"
awk -F= '$1 ~ /^(linux-firmware-.*|amd-ucode|intel-ucode)$/ {print $1, $2}' "$t/new" \
	| awk 'NR == FNR {a[$1] = $2; next} ($1 in a) && a[$1] != $2 {print $1, $2, a[$1]}' "$t/alpine-v" - > "$t/held"
: > "$t/heldgone"
while read -r p o n; do
	grep -qx "$p=$o" "$t/offered" || echo "$p=$o" >> "$t/heldgone"
done < "$t/held"

security=routine
[ ! -s "$t/gone" ] && [ ! -s "$t/heldgone" ] || security=gone
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
# what a held line's newer version would fix (it waits for the kernel; no PR kind of its own)
: > "$t/heldsec"
while read -r p o n; do
	origin=$(awk -v p="$p" '$1 == p {print $2; exit}' "$t/origins")
	origin=${origin:-$p}
	awk -v o="$origin" '$1 == o {print $2, $3}' "$t/secfixes" | while read -r fix cves; do
		if [ "$(apk version -t "$o" "$fix")" = "<" ] && [ "$(apk version -t "$fix" "$n")" != ">" ]; then
			echo "$p $cves"
		fi
	done >> "$t/heldsec"
done < "$t/held"

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
if [ -s "$t/gone" ]; then
	echo "**Locked versions no longer offered** (builds of the current locks fail until this merges):"
	echo
	sed 's/^/- `/; s/$/`/' "$t/gone"
	echo
fi
if [ -s "$t/held" ]; then
	echo "**Held for the kernel** (its firmware and microcode move only with the kernel package;"
	echo "they move at its next version):"
	echo
	echo "| Package | Locked | Alpine offers | Locked version offered | Fixes waiting |"
	echo "|---|---|---|---|---|"
	while read -r p o n; do
		off=yes; grep -qx "$p=$o" "$t/heldgone" && off="**no**: the kernel's build fails until the kernel moves"
		fx=$(awk -v p="$p" '$1 == p && $2 != "" {printf "%s%s", s, $2; s = ","}' "$t/heldsec")
		echo "| \`$p\` | $o | $n | $off | ${fx:--} |"
	done < "$t/held"
	echo
fi
echo "| Package | Was | Now |"
echo "|---|---|---|"
awk '{printf "| `%s` | %s | %s |\n", $1, $2, $3}' "$t/changes"
[ -z "$flag" ] || echo "$security" > "$flag"
