#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Host test of scripts/device-files.c in an Alpine container, on made-up files only:
# a synthetic waveform, a crafted ELF with a Qualcomm hash segment, split-image names,
# and ordinary files that must pass (the container's own binaries, a RIFF file, a file
# whose offset 4 holds its size but whose header isn't a waveform).
#   scripts/test-device-files.sh     exit 0 = all checks pass
set -eu
P=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm -v "$P/scripts":/s:ro alpine:3.24 sh -euc '
apk add -q build-base python3 >/dev/null 2>&1
cc -O2 -Wall -Wextra -static -o /tmp/device-files /s/device-files.c
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
T=/tmp/t; rm -rf $T; mkdir -p $T/usr/lib/a $T/proc/x $T/fw
python3 - "$T" <<"EOF"
import struct, sys
t = sys.argv[1]
def wbf(path, n, modes=8, temps=14):
    d = bytearray(n); d[0:4] = b"\0\0\0\0"; d[4:8] = struct.pack("<I", n); d[0x25] = modes; d[0x26] = temps
    open(path, "wb").write(d)
def elf32(path, flags):
    eh = b"\x7fELF\x01\x01\x01" + b"\0" * 9 + struct.pack("<HHIIIIIHHHHHH", 2, 164, 1, 0, 52, 0, 0, 52, 32, 2, 0, 0, 0)
    ph = struct.pack("<IIIIIIII", 0, 0, 0, 0, 0, 0, 0, 0) + struct.pack("<IIIIIIII", 0, 0x1000, 0, 0, 64, 64, flags, 0x1000)
    open(path, "wb").write(eh + ph + b"\0" * 64)
wbf(t + "/usr/lib/a/panel.bin", 4096)                 # a waveform under another name
wbf(t + "/usr/lib/a/notwbf", 4096, modes=200)        # size at offset 4, not a waveform
elf32(t + "/usr/lib/a/modem", 0x02200000)            # hash segment
elf32(t + "/usr/lib/a/plain32", 0x5)                 # an ordinary ELF32
open(t + "/usr/lib/a/sound.wav", "wb").write(b"RIFF" + struct.pack("<I", 4092) + b"WAVE" + b"\0" * 4084)
open(t + "/fw/adsp.mdt", "wb").write(b"x" * 100)
open(t + "/fw/adsp.b02", "wb").write(b"x" * 100)
open(t + "/fw/lonely.b02", "wb").write(b"x" * 100)    # no .mdt beside it: passes
open(t + "/fw/eink.wbf", "wb").write(b"x" * 10)
wbf(t + "/proc/x/skipped", 4096)                      # /proc is skipped
EOF
cp /bin/busybox $T/usr/lib/a/
mkdir -p $T/lib/firmware/qcom $T/usr/lib/firmware; echo x > $T/lib/firmware/qcom/a530_pm4.fw; echo x > $T/usr/lib/firmware/cam.fw
ln -s /tmp/t/usr/lib/a/panel.bin $T/usr/lib/a/link
out=$(/tmp/device-files $T) && rc=0 || rc=$?
echo "$out"
check "found: exit 1" "[ $rc = 1 ]"
check "a waveform by its header" "echo \"\$out\" | grep -qx \"/usr/lib/a/panel.bin: an E Ink waveform (WBF header)\""
check "a signed image by its hash segment" "echo \"\$out\" | grep -q \"^/usr/lib/a/modem: a signed Qualcomm image\""
check "split image names (.mdt, .bNN next to it, .wbf)" "echo \"\$out\" | grep -q \"^/fw/adsp.mdt:\" && echo \"\$out\" | grep -q \"^/fw/adsp.b02:\" && echo \"\$out\" | grep -q \"^/fw/eink.wbf:\""
check "ordinary files pass (busybox, ELF32, RIFF, size field only, lone .b02)" "! echo \"\$out\" | grep -q -e busybox -e plain32 -e sound.wav -e notwbf -e lonely"
check "anything under /lib/firmware and /usr/lib/firmware" "echo \"\$out\" | grep -q \"^/lib/firmware/qcom/a530_pm4.fw: firmware in the base\" && echo \"\$out\" | grep -q \"^/usr/lib/firmware/cam.fw:\""
check "/proc skipped, symlinks not followed" "! echo \"\$out\" | grep -q -e /proc/ -e /link"
out2=$(/tmp/device-files $T/) && rc2=0 || rc2=$?
check "ROOT with a trailing slash: the same findings, firmware included" "[ $rc2 = 1 ] && [ \"\$out2\" = \"\$out\" ] && echo \"\$out2\" | grep -q \"^/lib/firmware/qcom/a530_pm4.fw:\""
# a waveform in a file and in a directory that a non-root user cannot read: an error
# (exit 2, each named on stderr), not "none found". Root reads them anyway.
U=/tmp/u; rm -rf $U; mkdir -p $U/d; cp $T/usr/lib/a/panel.bin $U/f; cp $T/usr/lib/a/panel.bin $U/d/w; chmod 000 $U/f $U/d
if [ "$(id -u)" = 0 ] && su -s /bin/sh nobody -c true 2>/dev/null; then
	uout=$(su -s /bin/sh nobody -c "/tmp/device-files $U" 2>/tmp/uerr) && urc=0 || urc=$?
	cat /tmp/uerr
	check "unreadable file and directory: exit 2, both on stderr, nothing on stdout" "[ $urc = 2 ] && [ -z \"\$uout\" ] && grep -q \"^device-files: $U/f:\" /tmp/uerr && grep -q \"^device-files: $U/d:\" /tmp/uerr"
	check "the same tree read as root: found" "/tmp/device-files $U >/dev/null; [ \$? = 1 ]"
else
	echo "skipped: unreadable entries (needs root in the container to run the check as nobody)"
fi
rm -rf $U /tmp/uerr
rm -rf $T/usr/lib/a/panel.bin $T/usr/lib/a/modem $T/fw $T/usr/lib/a/link $T/lib/firmware $T/usr/lib/firmware
check "a clean tree: exit 0" "/tmp/device-files $T >/dev/null"
rm -rf $T
check "the container itself is clean (a real Alpine tree)" "/tmp/device-files / >/dev/null"
check "usage: exit 2" "/tmp/device-files >/dev/null 2>&1; [ \$? = 2 ]"
echo "$fails failed"; [ $fails = 0 ]'
