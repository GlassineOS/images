#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The screen's headless part of test-recovery.sh (docs/recovery.md, "The screen"), in an
# arm64 Alpine container with the GlassineOS package repository. Mounts: /src the ramenv
# directory (read-only), /keys the repository's keys (read-only), /out the kit.
#   1. glassine-rscreen built as build.sh builds it (its type from the GlassineOS
#      shell's IBM Plex, rasterized by font-gen), the panel adapter from the device
#      package;
#   2. its pages drawn without a panel: --events scripts (test/screen/*.events) against
#      screen-core.py, a stand-in core (full with a hibernated session, idle 9 s, empty,
#      and no core at all); each page shot is compared with its golden image
#      test/screen/NAME.png (pixel for pixel); /out/screen/ gets them all (UPDATE=1: the
#      host copies them over the goldens);
#   3. the QEMU screen run's programs, static: epd-sink (a stand-in panel daemon) and
#      screen-drive (uinput), into /out.
# Prints ok/FAIL lines; exit 0 = all passed.
set -eu
trap '[ -z "${OWNER:-}" ] || chown -R "$OWNER" /out/screen /out/epd-sink /out/screen-drive 2>/dev/null || :' EXIT
cp /keys/glassine-20261015.rsa.pub /etc/apk/keys/
echo https://pkgs.glassine.org/alpine/v3.24/glassine >> /etc/apk/repositories
apk add -q gcc musl-dev linux-headers freetype-dev pkgconf python3 glassine-shell-fonts glassine-epdd-dev >/dev/null
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
W=/tmp/s; rm -rf $W; mkdir -p $W/b $W/shots
O=/out/screen; rm -rf $O; mkdir -p $O
F=/usr/share/fonts/glassine
S=/src/recovery/screen
# shellcheck disable=SC2046
gcc -O2 -Wall -Wextra -Werror -o $W/b/font-gen $S/font-gen.c $(pkg-config --cflags --libs freetype2)
$W/b/font-gen $W/b/rs-font.h title $F/IBMPlexSans-VF.ttf 600 64 body $F/IBMPlexSans-VF.ttf 400 40 \
	bold $F/IBMPlexSans-VF.ttf 600 40 small $F/IBMPlexSans-VF.ttf 400 32 label $F/IBMPlexMono-Medium.ttf 0 28
gcc -static -O2 -Wall -Wextra -Werror -Wno-unused-function -DGLASSINE_RECOVERY -pthread -I$W/b \
	-o $W/b/glassine-rscreen $S/glassine-rscreen.c
ok "glassine-rscreen built (freetype $(apk info -e -v freetype), $(apk info -e -v glassine-shell-fonts))"
apk fetch -q --stdout device-onyx-noteair > $W/adapter.apk
tar -xzOf $W/adapter.apk etc/glassine/epd.conf > $W/epd.conf

run() {	# run NAME EVENTS IDLE CORE-ARGS...: the client through EVENTS against screen-core.py
	n=$1 ev=$2 idle=$3; shift 3
	python3 /src/test/screen-core.py $W/$n.sock $W/$n.core.log "$@" > $W/$n.core.out 2>&1 &
	cp=$!
	for _ in $(seq 50); do [ -S $W/$n.sock ] && break; sleep 0.1; done
	mkdir -p $W/shots/$n
	if timeout 300 $W/b/glassine-rscreen --core $W/$n.sock --epd $W/none.sock --conf $W/epd.conf --idle "$idle" \
		--shot $W/shots/$n --events "$ev" > $W/$n.client.log 2>&1; then ok "$n: the script ran to its end"
	else bad "$n: the client exited $? ($(tail -n 1 $W/$n.client.log))"; fi
	grep -q 'script: no button\|script: unknown line' $W/$n.client.log && bad "$n: $(grep 'script: no button\|script: unknown' $W/$n.client.log | head -n 1)"
	kill -TERM $cp; wait $cp || :
	sed -n 's/^QTEST //p' $W/$n.core.out | while read -r l; do echo "$l [$n]"; done
	grep -q '^QTEST FAIL' $W/$n.core.out && fails=$((fails + 1))
	return 0
}
run main /src/test/screen/main.events 600 full --hibernated
run idle /src/test/screen/idle.events 9 full
run empty /src/test/screen/empty.events 600 empty
# no core: the page that says so
printf 'await no-core\nshot no-core\nquit\n' > $W/nocore.events
mkdir -p $W/shots/nocore
timeout 60 $W/b/glassine-rscreen --core $W/absent.sock --epd $W/none.sock --conf $W/epd.conf --idle 600 \
	--shot $W/shots/nocore --events $W/nocore.events > $W/nocore.client.log 2>&1 && ok "nocore: the script ran to its end" \
	|| bad "nocore: the client exited $?"
grep -c CONFIRMED $W/main.core.log | { read -r c; [ "$c" = 5 ] && ok "main: 5 operations confirmed (select, rollback, rollback with the discard, remove, full reset)" \
	|| { echo "FAIL main: $c operations confirmed, 5 expected"; exit 1; }; } || fails=$((fails + 1))

# the goldens: every explicit shot, and the working page (it takes no input, so the
# script can't shoot it: the client shoots each such page as shown-NAME)
for d in main idle empty nocore; do
	for p in $W/shots/$d/*.pgm; do
		b=$(basename "$p" .pgm)
		case $d:$b in main:shown-working) b=working ;; *:shown-*) continue ;; esac
		python3 /src/test/screen-png.py png "$p" $O/$b.png
		g=/src/test/screen/$b.png
		if [ ! -f "$g" ]; then bad "$b: no golden image"
		elif python3 /src/test/screen-png.py same $O/$b.png "$g"; then ok "$b: the page = its golden image"
		else bad "$b: the page differs from its golden image (/out/screen/$b.png)"; fi
	done
done
for g in /src/test/screen/*.png; do
	[ -f "$g" ] || continue
	[ -f $O/"$(basename "$g")" ] || bad "$(basename "$g" .png): a golden image no run drew"
done

# the QEMU run's programs
gcc -static -O2 -Wall -Wextra -Werror -o /out/epd-sink /src/test/epd-sink.c
gcc -static -O2 -Wall -Wextra -Werror -o /out/screen-drive /src/test/screen-drive.c
ok "epd-sink and screen-drive built (static)"
echo "screen-headless: $fails failed"
[ $fails = 0 ]
