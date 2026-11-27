#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of scripts/keep-updates.sh in Alpine (busybox awk, as the device stage runs
# it), on made-up descriptions: the value, 1 when absent, every refused form, and the
# line appended to a deploy.conf. With INSTALLER_CHECKOUT=DIR also the installer's own
# devices/uefi-pc.toml (its value, whatever it is, must derive).
#   scripts/test-keep-updates.sh     exit 0 = all checks pass
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
I=${INSTALLER_CHECKOUT:+$(cd "$INSTALLER_CHECKOUT" && pwd)}
docker run --rm -v "$P/scripts":/s:ro ${I:+-v "$I":/i:ro} alpine:3.24 sh -euc '
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
K="sh /s/keep-updates.sh"
T=/tmp/t; mkdir -p $T
d() { printf "%b" "$2" > $T/$1.toml; }
d four   "# a PC\nformat = 5\nid = \"pc\"\n\n[[identity]]\nkey = \"keep_updates_not\"\n\n[data_partition]\nname = \"glassine-userdata\"\nkeep_updates = 4 # kept\n\n[[partitions]]\nclass = \"never-write\"\n"
d absent "format = 5\n[data_partition]\nname = \"userdata\"\n"
d zero   "format = 5\n[data_partition]\nkeep_updates = 0\n"
d str    "format = 5\n[data_partition]\nkeep_updates = \"4\"\n"
d neg    "format = 5\n[data_partition]\nkeep_updates = -2\n"
d frac   "format = 5\n[data_partition]\nkeep_updates = 2.5\n"
d other  "format = 5\n[data_partition]\nname = \"u\"\n[other]\nkeep_updates = 4\n"
d dotted "format = 5\ndata_partition.keep_updates = 4\n[data_partition]\nname = \"u\"\n"
d twice  "format = 5\n[data_partition]\nkeep_updates = 2\nkeep_updates = 3\n"
d old    "format = 4\n[data_partition]\nname = \"u\"\n"
d nofmt  "[data_partition]\nkeep_updates = 2\n"
d nodp   "format = 5\nid = \"x\"\n"
d sp     "format=5\n  [ data_partition ]  # the data\n  keep_updates=12\n"
check "the value: 4 (comments, other tables around it)" "[ \"\$($K $T/four.toml)\" = 4 ]"
check "absent: 1" "[ \"\$($K $T/absent.toml)\" = 1 ]"
check "spacing and a header comment: 12" "[ \"\$($K $T/sp.toml)\" = 12 ]"
for b in zero str neg frac other dotted twice old nofmt nodp; do
	rc=0; $K $T/$b.toml > $T/out 2> $T/err || rc=$?
	check "refused: $b (exit 1, no value, a reason)" "[ $rc = 1 ] && [ ! -s $T/out ] && [ -s $T/err ]"
done
rc=0; $K /nonexistent > /dev/null 2>&1 || rc=$?
check "no description: exit 1" "[ $rc = 1 ]"
rc=0; $K > /dev/null 2>&1 || rc=$?
check "usage: exit 2" "[ $rc = 2 ]"
printf "SYSTEM_DEV=/dev/x\n" > $T/deploy.conf
$K $T/four.toml $T/deploy.conf > /dev/null
check "appended: the one KEEP_UPDATES line, the file before it kept" "[ \"\$(grep -c ^KEEP_UPDATES= $T/deploy.conf)\" = 1 ] && grep -qx KEEP_UPDATES=4 $T/deploy.conf && head -n 1 $T/deploy.conf | grep -qx SYSTEM_DEV=/dev/x"
check "appended: read as glassine-deploy reads it (sourced)" "[ \"\$(. $T/deploy.conf; echo \$KEEP_UPDATES)\" = 4 ]"
rc=0; $K $T/four.toml $T/deploy.conf > /dev/null 2>&1 || rc=$?
check "a deploy.conf that already sets KEEP_UPDATES: refused, unchanged" "[ $rc = 1 ] && [ \"\$(grep -c ^KEEP_UPDATES= $T/deploy.conf)\" = 1 ]"
if [ -d /i ]; then
	v=$($K /i/devices/uefi-pc.toml) && rc=0 || rc=$?
	check "the installer'"'"'s devices/uefi-pc.toml derives (keep_updates $v)" "[ $rc = 0 ] && [ -n \"$v\" ]"
	v=$($K /i/devices/onyx-noteair.toml) && rc=0 || rc=$?
	check "the installer'"'"'s devices/onyx-noteair.toml derives (keep_updates $v)" "[ $rc = 0 ] && [ -n \"$v\" ]"
fi
echo "$fails failed"; [ $fails = 0 ]'
