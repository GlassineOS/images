#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds kernel artifacts to GlassineOS/boot's docs/kernel-artifacts.md. Runs inside the
# kernel-build image, from the Dockerfile's kernel and device-tree stages:
#
#   kernel.sh build   compile the kernel; write /out/modules/<release>/ (Image.gz, the
#                     modules, depmod's files, firmware/, kernel.manifest)
#   kernel.sh dtb     one device's tree: /out/boot/dtb/<device>@<id>.dtb + .manifest
#
# Mounts: /src/linux the source at the pinned commit, with its shallow .git (read-only),
# /run/stage the kernel stage's directory, /run/firmware the firmware stage and /cache the
# build cache (build), /run/target the device's target description (dtb). Environment:
# REPO and COMMIT (the pinned source), BUILDER (the kernel-build image as
# <image>@sha256:<digest>, build), DEVICE (dtb), JOBS.
set -eu
S=/src/linux
# The tree layout version (kernel.manifest's layout, part of cfg6): bump it with any change
# in how modules/<release>/ is made from the compile (strip flags, depmod, the files kept).
LAYOUT=1
die() { echo "kernel.sh: $*" >&2; exit 1; }
# a key's value in a key=value file
val() { sed -n "s/^$1=//p" "$2" | tail -n 1; }
sha() { sha256sum "$1" | cut -c1-64; }
c12() { printf '%.12s' "$1"; }
# fixed mtimes and modes, so two builds export the same tree
settle() { chmod -R u=rwX,go=rX "$1"; find "$1" -exec touch -h -d @0 {} +; }

# the pinned commit, with nothing changed (a build from a changed tree is refused)
check_source() {
	head=$(git -C $S rev-parse HEAD) || die "$S is not a git checkout"
	[ "$head" = "$COMMIT" ] || die "the source is at $head, the pin is $COMMIT"
	[ -z "$(git -C $S --no-optional-locks status --porcelain)" ] || die "the source tree has changes"
}

# a fragment by name, where kbuild looks for it: kernel/configs/ (the source's
# architecture-independent ones) or arch/arm64/configs/; a name in both is refused,
# since kbuild would merge both
fragment_path() {
	set -- "$S/kernel/configs/$1" "$S/arch/arm64/configs/$1"
	if [ -f "$1" ] && [ -f "$2" ]; then die "fragment $(basename "$1") is in kernel/configs and arch/arm64/configs"
	elif [ -f "$1" ]; then echo "$1"
	elif [ -f "$2" ]; then echo "$2"
	else die "no fragment $(basename "$1") in kernel/configs or arch/arm64/configs"; fi
}

# every option the fragments ask for (FILES..., merged in that order: a later one
# overrides an earlier one, so the last line for a symbol counts) must be in the final
# configuration CONFIG: CONFIG_X=v exactly, "# CONFIG_X is not set" as no CONFIG_X= line
# (a symbol whose dependencies are off is absent, which is the same), where X must be a
# symbol the source defines (a misspelled or renamed one would pass as absent).
# CONFIG_LOCALVERSION is the build's.
check_fragments() {
	cfg=$1; shift
	bad=0
	for f in "$@"; do
		grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set)' "$f" | sed "s|^|$(basename "$f") |"
	done | grep -v ' CONFIG_LOCALVERSION=' \
		| awk '{ f = $1; l = substr($0, length(f) + 2)
		         s = l ~ /^# / ? $3 : substr(l, 1, index(l, "=") - 1)
		         if (!(s in w)) o[++n] = s; w[s] = l; src[s] = f }
		       END { for (i = 1; i <= n; i++) print src[o[i]], w[o[i]] }' > /tmp/want
	while read -r f l; do
		case $l in
		'# '*) s=${l#\# }; s=${s%% *}
			git -C $S grep -qE "^[[:space:]]*(menu)?config ${s#CONFIG_}[[:space:]]*\$" -- '*Kconfig*' \
				|| { echo "kernel.sh: $f: no symbol ${s#CONFIG_} in the source's Kconfig files" >&2; false; } \
				&& ! grep -q "^$s=" "$cfg" ;;
		*) grep -qxF "$l" "$cfg" ;;
		esac || { echo "kernel.sh: $f: option not applied: $l" >&2; bad=1; }
	done < /tmp/want
	return $bad
}

# a device tree at /src/linux into $2 (any configuration builds the same tree)
build_dtb() {
	make -s --no-print-directory -C $S O=/tmp/dtb-obj ARCH=arm64 defconfig >/dev/null
	make -s --no-print-directory -C $S O=/tmp/dtb-obj ARCH=arm64 -j"${JOBS:-$(nproc)}" "$1.dtb"
	cp "/tmp/dtb-obj/arch/arm64/boot/dts/$1.dtb" "$2"
}

build() {
	check_source
	flavor=$(val flavor /run/stage/kernel)
	defconfig=$(val defconfig /run/stage/kernel)
	fragments=$(val fragments /run/stage/kernel)
	[ -n "$flavor" ] && [ -n "$defconfig" ] || die "/run/stage/kernel: flavor and defconfig are required"
	echo "$BUILDER" | grep -qE '^[^@[:space:]]+@sha256:[0-9a-f]{64}$' \
		|| die "BUILDER is not <image>@sha256:<digest>: $BUILDER"
	# firmware this kernel needs, by the names the drivers request: name@sha256-16, names
	# relative to firmware/, sorted by bytes (kernel.manifest's firmware, part of cfg6)
	fw=$(cd /run/firmware && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
		printf '%s@%.16s ' "$f" "$(sha "$f")"; done)
	fw=${fw% }
	# The source goes into the cache by content: a file that didn't change keeps its
	# mtime, so make rebuilds only what the new commit changed. An empty cache is a full
	# build with the same result.
	mkdir -p /cache/src /cache/obj
	rsync -rlpc --delete --exclude=/.git $S/ /cache/src/
	# a fixed build identity: the version string tells the commit's time, not when,
	# where or how often it was built
	KBUILD_BUILD_TIMESTAMP=$(TZ=UTC git -C $S log -1 --format=%cd --date=format-local:'%a %b %d %H:%M:%S UTC %Y')
	export KBUILD_BUILD_USER=glassine KBUILD_BUILD_HOST=images KBUILD_BUILD_VERSION=1 KBUILD_BUILD_TIMESTAMP
	M="make --no-print-directory -C /cache/src O=/cache/obj ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
	# the configuration, made fresh every time
	# shellcheck disable=SC2086
	$M -s $defconfig $fragments >/dev/null
	{ cat /run/stage/build.config; echo 'CONFIG_LOCALVERSION=""'
	  echo '# CONFIG_LOCALVERSION_AUTO is not set'; } >> /cache/obj/.config
	$M -s olddefconfig >/dev/null
	ok=0
	paths=
	for f in $fragments; do paths="$paths $(fragment_path "$f")"; done
	# shellcheck disable=SC2086
	check_fragments /cache/obj/.config $paths /run/stage/build.config || ok=1
	grep -qx 'CONFIG_LOCALVERSION=""' /cache/obj/.config || ok=1
	! grep -q '^CONFIG_LOCALVERSION_AUTO=' /cache/obj/.config || ok=1
	[ $ok = 0 ] || die "the configuration isn't what the fragments ask for"
	# the release: <KERNELVERSION>-<flavor>.<cfg6>-g<commit12>, cfg6 over the final
	# .config followed by the lines builder=, firmware= and layout=
	cfg6=$({ cat /cache/obj/.config; printf 'builder=%s\nfirmware=%s\nlayout=%s\n' "$BUILDER" "$fw" "$LAYOUT"; } \
		| sha256sum | cut -c1-6)
	lv="-$flavor.$cfg6-g$(c12 "$COMMIT")"
	rel="$($M -s kernelversion)$lv"
	$M -s -j"${JOBS:-$(nproc)}" LOCALVERSION="$lv" Image.gz modules
	got=$($M -s LOCALVERSION="$lv" kernelrelease)
	[ "$got" = "$rel" ] || die "the kernel calls itself $got, expected $rel"
	o=/out/modules/$rel
	rm -rf /tmp/mod /out
	mkdir -p "$o"
	# stripped modules, depmod run against the tree (-b)
	$M -s LOCALVERSION="$lv" INSTALL_MOD_PATH=/tmp/mod INSTALL_MOD_STRIP=1 modules_install >/dev/null
	rm -f "/tmp/mod/lib/modules/$rel/build" "/tmp/mod/lib/modules/$rel/source"
	cp -a "/tmp/mod/lib/modules/$rel/." "$o/"
	# kbuild gzips with -n, so the checksum doesn't depend on the build time
	cp /cache/obj/arch/arm64/boot/Image.gz "$o/Image.gz"
	mkdir -p "$o/firmware"
	cp -R /run/firmware/. "$o/firmware/"
	# no symlinks or other special files anywhere in the tree
	[ -z "$(find "$o" ! -type f ! -type d)" ] \
		|| die "modules/$rel has entries that are neither files nor directories: $(find "$o" ! -type f ! -type d | head -n 3)"
	# modules_sha256: sha256 over "<path> <sha256>" lines, one per regular file under
	# modules/<release>/ except the top-level Image.gz and kernel.manifest and everything
	# under firmware/, paths relative without ./, sorted by bytes
	ms=$(cd "$o" && find . -path ./firmware -prune -o -type f ! -path ./Image.gz -print \
		| sed 's|^\./||' | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(sha "$f")"; done \
		| sha256sum | cut -c1-64)
	# provides and features come from GlassineOS/boot's conf/kernel-features, which
	# doesn't exist yet: both stay empty until it does
	cat > "$o/kernel.manifest" <<-EOF
	format=1
	release=$rel
	source=$REPO@$COMMIT
	builder=$BUILDER
	layout=$LAYOUT
	config_sha256=$(sha /cache/obj/.config)
	image_sha256=$(sha "$o/Image.gz")
	modules_sha256=$ms
	firmware=$fw
	provides=
	features=
	EOF
	rm -rf /tmp/mod /tmp/want
	mkdir -p /out/debug
	cp /cache/obj/vmlinux /cache/obj/System.map /cache/obj/.config /out/debug/
	gzip -n -1 /out/debug/vmlinux
	(cd /cache/obj && find . -type f ! -name '.tmp_vmlinux*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > /out/debug/obj.sha
	aarch64-linux-gnu-objcopy --strip-debug /cache/obj/vmlinux.o /out/debug/vmlinux.o
	cp /cache/obj/arch/arm64/boot/Image /out/debug/Image
	gzip -n -1 /out/debug/vmlinux.o /out/debug/Image
	settle /out
	echo "kernel.sh: $rel: $(find "$o" -name '*.ko' | wc -l) modules, Image.gz $(stat -c %s "$o/Image.gz") bytes"
	cat "$o/kernel.manifest"
}

dtb() {
	check_source
	dts=$(val dts /run/target/target)
	[ -n "$dts" ] || die "/run/target/target has no dts"
	rm -rf /out
	mkdir -p /out/boot/dtb
	build_dtb "$dts" /tmp/dtb
	id=$DEVICE@$(sha /tmp/dtb | cut -c1-16)
	cp /tmp/dtb "/out/boot/dtb/$id.dtb"
	# only facts about the bytes: the same tree gives the same manifest from any build
	printf 'format=1\ndevice=%s\nsha256=%s\n' "$DEVICE" "$(sha /tmp/dtb)" > "/out/boot/dtb/$id.manifest"
	rm -rf /tmp/dtb-obj /tmp/dtb
	settle /out
	echo "kernel.sh: $id.dtb from $(c12 "$COMMIT")"
}

case ${1:-} in
build|dtb) "$1" ;;
*) die "usage: kernel.sh build|dtb" ;;
esac
