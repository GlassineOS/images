#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The guest side of scripts/test-first-start-qemu.sh: installed by the test's base
# (a test stage FROM base-export) as /usr/local/sbin/qtest-first-start and started by
# its OpenRC service in the default runlevel. It only reads and reports, with the
# base's own tools, then powers the machine off. Every result is a line
# "QTEST ok|FAIL <check>" on the console; the host greps them.
#
#   a bare boot      the first start should have rebooted before the default
#                    runlevel: FAIL, its kernel log lines, power off
#   a deployment     the first deployment the first start made: its meta, the
#                    boot-success step accepts it, it is current, the person's
#                    storage is made on userdata, nothing of the other system is
#                    left there; power off
# Each check is a test command followed by `res $? NAME`, on purpose:
# shellcheck disable=SC2319
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
UD=/run/glassine/userdata
SYS=/run/glassine/system
P=media/glassine
ACCEPT_AFTER=120
# shellcheck source=/dev/null
[ -r /etc/glassine/deploy.conf ] && . /etc/glassine/deploy.conf

say() { echo "QTEST $*" > /dev/console; }
res() { if [ "$1" = 0 ]; then say "ok $2"; else say "FAIL $2"; fi; }
up() { cut -d. -f1 /proc/uptime; }
st() { glassine-deploy status --porcelain 2>/dev/null | sed -n 2p | tr '\t' '\n' | sed -n "s/^$1=//p"; }
off() { say "poweroff"; sync; poweroff; exit 0; }
booted=$(cat /run/glassine/booted 2>/dev/null)
say "agent: booted=$booted uptime=$(up)"

case $booted in
''|bare:*)
	say "FAIL a deployment is booted, not a bare boot (booted=$booted): the first start did not reboot into one"
	dmesg | sed -n 's/.*\(glassine-first-start: .*\)/\1/p' | while read -r l; do say "info $l"; done
	[ ! -e $SYS/state/install ]; res $? "the install marker is gone"
	off ;;
esac

meta() { sed -n "s/^$1=//p" "$UD/$P/deployments/$booted/meta" 2>/dev/null | head -n 1; }
bases=$(ls $SYS/bases 2>/dev/null)
[ "$(meta kind)" = install ]; res $? "the booted deployment $booted is the first start's (kind=$(meta kind))"
[ -n "$bases" ] && [ "$(meta base)" = "$bases" ]; res $? "on the only base ($(meta base); bases/: $(echo "$bases" | tr '\n' ' '))"
[ ! -e $SYS/state/install ]; res $? "the install marker is gone"
root=$(awk '$2 == "/" { l = $0 } END { print l }' /proc/mounts)
echo "$root" | awk '{ exit !($3 == "overlay" && $4 ~ /^ro(,|$)/) }'; res $? "/ is the overlay, read-only"
grep -qx '[0-9a-f]\{32\}' /etc/machine-id; res $? "the machine id is filled in"

# the boot-success step: the candidate becomes current
n=0
while [ "$(st current)" != "$booted" ] && [ $n -lt $((ACCEPT_AFTER + 300)) ]; do sleep 5; n=$((n + 5)); done
dmesg | grep -q "glassine-deploy-accept: $booted accepted"; res $? "$booted accepted by the boot-success step"
dmesg | grep -q "glassine-deploy-accept: $booted accepted" ||
	say "info the boot-success step said: $(dmesg | sed -n 's/.*\(glassine-deploy-accept: .*\)/\1/p' | tr '\n' '|')"
# a board whose loader record is on the raw boot partition (BOOT_FORM=raw) without that
# partition: the healthy mark is said to fail, nothing is written, the accept goes on
if grep -qx 'BOOT_FORM=raw' /etc/glassine-bootimg/board.conf 2>/dev/null; then
	dmesg | grep -q 'glassine-loader-mark: the boot partition: 0 partitions named glassine-boot: nothing written'
	res $? "BOOT_FORM=raw, no glassine-boot partition: the loader mark says so and writes nothing"
	dmesg | grep -q 'glassine-deploy-accept: the healthy mark failed (exit 1)' && [ ! -e /run/glassine/loader-marked ]
	res $? "BOOT_FORM=raw, no glassine-boot partition: the accept step goes on without the mark"
	# the loader update runs only after a mark this start wrote: nothing is tried here
	! dmesg | grep -q 'glassine-loader-update:' && ! dmesg | grep -q 'glassine-deploy-accept: the loader update'
	res $? "BOOT_FORM=raw, no healthy mark: the loader update doesn't run, nothing written"
fi
[ "$(st current)" = "$booted" ] && [ -z "$(st candidate)" ]; res $? "$booted is current, no candidate (status: $(glassine-deploy status --porcelain 2>/dev/null | sed -n 2p | tr '\t' ' '))"

# userdata is GlassineOS's now: the other system's files are gone, the person's storage is made
[ ! -e "$UD/qtest-stock" ]; res $? "nothing of the other system on userdata (qtest-stock/ gone)"
[ -d "$UD/$P/home" ]; res $? "the person's storage is made on userdata ($P/home)"
awk '$2 == "/home" { f = 1 } END { exit !f }' /proc/mounts; res $? "/home is bound from userdata"
say "info storage: $(tr '\n' ' ' < /run/glassine/storage 2>/dev/null)"
off
