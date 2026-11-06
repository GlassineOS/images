#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The validation stage: what a base must not carry. Reads only.
set -eu
fail=0
no() { echo "validation: $*" >&2; fail=1; }
# plain names only, so live upgrades and package replay work
grep -q '[<>=~]' /etc/apk/world && no "pinned versions in /etc/apk/world: $(grep '[<>=~]' /etc/apk/world | tr '\n' ' ')"
# the package cache is a build cache mount, never part of the tree
[ -z "$(find /var/cache/apk -mindepth 1 -print -quit 2>/dev/null)" ] || no "package cache in the tree"
# each installation makes its own machine ID (GlassineOS/hub#19)
[ ! -s /etc/machine-id ] || no "/etc/machine-id is filled in"
[ ! -e /var/log/apk.log ] || no "apk's build log in the tree"
# every enabled service has its script
for l in /etc/runlevels/*/*; do
	[ -e "$l" ] || [ ! -L "$l" ] || no "enabled service without a script: $l -> $(readlink "$l")"
done
exit $fail
