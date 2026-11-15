#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of scripts/apk-stage.sh in an Alpine container without network, on a made-up
# signed repository (apk mkpkg + mkndx) that holds two versions of one package:
# the locked older version installs although a newer one is offered, the world names the
# packages without a pin and matches a refresh build's, LOCK=refresh installs the
# newest; refused with "refresh the locks": a lock line no repository offers (nothing
# installed), a lock that misses a package the stage pulls in, a lock line nothing needs.
#   scripts/test-apk-stage.sh     exit 0 = all checks pass
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
K=$(mktemp -d)
trap 'rm -rf "$K"' EXIT
# the repository's signing key (the container has no network to install openssl)
openssl genrsa -out "$K/t.rsa" 2048 2>/dev/null
openssl rsa -in "$K/t.rsa" -pubout -out "$K/t.rsa.pub" 2>/dev/null
docker run --rm --network none -v "$P/scripts":/s:ro -v "$K":/k:ro alpine:3.24 sh -euc '
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# the repository: lib 1-r0 and 2-r0, app 1-r0 (needs lib), extra 1-r0
R=/repo/$(apk --print-arch)
mkdir -p "$R" /f/usr/share/t
mk() { echo "$1-$2" > /f/usr/share/t/$1
	apk mkpkg --sign-key /k/t.rsa -I name:$1 -I version:$2 -I arch:$(apk --print-arch) -I license:MIT -I "description:t" \
		${3:+-I depends:$3} -F /f -o "$R/$1-$2.apk"; rm /f/usr/share/t/$1; }
cp /k/t.rsa.pub /etc/apk/keys/
mk lib 1-r0; mk lib 2-r0; mk app 1-r0 lib; mk extra 1-r0
apk mkndx -q --sign-key /k/t.rsa -o "$R/APKINDEX.tar.gz" "$R"/*.apk
echo /repo > /etc/apk/repositories
cp -a /lib/apk/db /base-db; cp /etc/apk/world /base-world
base=$(awk -F: "/^P:/{p=\$2} /^V:/{print p \"=\" \$2}" /lib/apk/db/installed)
reset() { apk del -q app lib extra .glassine-lock >/dev/null 2>&1 || :
	rm -rf /lib/apk/db; cp -a /base-db /lib/apk/db; cp /base-world /etc/apk/world; }
# a stage directory: packages $1, lock = the base set + $2
stage() { rm -rf /run/stage; mkdir -p /run/stage; echo "$1" > /run/stage/packages
	printf "%s\n" $base $2 | LC_ALL=C sort > /run/stage/lock; }
run() { reset; sh /s/apk-stage.sh > /tmp/out 2>&1; }
inst() { awk -F: "/^P:/{p=\$2} /^V:/{print p \"=\" \$2}" /lib/apk/db/installed | grep -qx "$1"; }

stage app "app=1-r0 lib=1-r0"
run && rc=0 || rc=$?
check "the locked older version installs beside a newer one" "[ $rc = 0 ] && inst lib=1-r0 && inst app=1-r0"
check "the world names the packages without a pin" "! grep -q = /etc/apk/world && grep -qx app /etc/apk/world"
check "no lock virtual is left" "! grep -q glassine-lock /etc/apk/world && ! inst .glassine-lock=.*"
cp /etc/apk/world /tmp/world.check
LOCK=refresh run
check "LOCK=refresh installs the newest" "inst lib=2-r0"
check "the world matches the refresh build" "cmp -s /etc/apk/world /tmp/world.check"
reset
check "an upgrade moves the locked version on" "LOCK=check sh /s/apk-stage.sh >/dev/null 2>&1 && apk upgrade -q >/dev/null && inst lib=2-r0"

stage app "app=1-r0 lib=0.9-r0"
run && rc=0 || rc=$?
check "a lock line no repository offers: refused" "[ $rc != 0 ] && grep -q \"lib=0.9-r0 .*offered: \" /tmp/out && grep -q \"refresh the locks\" /tmp/out"
check "... naming what is offered" "grep -q \"1-r0 (/repo)\" /tmp/out && grep -q \"2-r0 (/repo)\" /tmp/out"
check "... before anything is installed" "! inst app=1-r0"

stage app "app=1-r0"
run && rc=0 || rc=$?
check "a lock that misses a pulled-in package: refused" "[ $rc != 0 ] && grep -q \"^+lib=\" /tmp/out && grep -q \"refresh the locks\" /tmp/out"

stage app "app=1-r0 lib=1-r0 extra=1-r0"
run && rc=0 || rc=$?
check "a lock line nothing needs: refused" "[ $rc != 0 ] && grep -q \"^-extra=1-r0\" /tmp/out"

stage "" "lib=1-r0"
run && rc=0 || rc=$?
check "a package dropped from the stage but still locked: refused" "[ $rc != 0 ] && grep -q \"^-lib=1-r0\" /tmp/out"

[ "$fails" = 0 ] && echo "all checks pass" || { echo "$fails failed"; exit 1; }
'
