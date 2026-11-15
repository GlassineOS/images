# SPDX-License-Identifier: GPL-2.0-or-later
# Shared by the recovery's tools (docs/recovery.md): glassine-deploy at the boot commit
# the image was built with, and the configuration the init wrote for this start.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export GLASSINE_DEPLOY_CONF=/etc/glassine/deploy.conf
GD=/sbin/glassine-deploy
TAB=$(printf '\t')
# shellcheck source=/dev/null
[ -r /etc/glassine/deploy.conf ] && . /etc/glassine/deploy.conf
# shellcheck source=/dev/null
[ -r /etc/glassine/recovery.version ] && . /etc/glassine/recovery.version

# porcelain FIELD LINE: one key=value field of a porcelain record
field() { printf '%s\n' "$2" | tr '\t' '\n' | sed -n "s/^$1=//p" | head -n 1; }

# deploy_state: S_STATUS (the status record), S_LIST (the deployment records)
deploy_state() {
	S_STATUS=$("$GD" status --porcelain 2>/dev/null | grep '^type=status')
	S_LIST=$("$GD" list --porcelain 2>/dev/null | grep '^type=deployment')
}

# offered ACTION: does this glassine-deploy have the verb (its usage names it)
offered() {
	case $1 in
	select|rollback|reset|reset-full) return 0 ;;
	remove) "$GD" 2>&1 | grep -q '^glassine-deploy remove ' ;;
	*) return 1 ;;
	esac
}
