#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds kernel artifacts to GlassineOS/boot's docs/kernel-artifacts.md. Runs inside the
# kernel-build image, from the Dockerfile's kernel and device-tree stages:
#
#   kernel.sh build      compile the kernel; write /out/modules/<release>/ (Image.gz,
#                        the modules, depmod's files) and the release to /meta
#   kernel.sh manifest   add firmware/ and kernel.manifest to /out/modules/<release>/
#   kernel.sh dtb        one device's tree: /out/boot/dtb/<device>@<id>.dtb + .manifest
#
# Mounts: /src/linux the source at the pinned commit, with its shallow .git (read-only),
# /run/stage the kernel stage's directory, /run/targets the target descriptions (dtb:
# /run/target, the device's own), /run/firmware the firmware stage, /cache the build
# cache (build only). Environment: REPO and COMMIT (the pinned source), BUILDER (the
# kernel-build image's digest), FLAVOR (manifest), DEVICE (dtb), JOBS.
set -eu
S=/src/linux
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

# every option a fragment asks for must be in the final configuration: CONFIG_X=v
# exactly, "# CONFIG_X is not set" as no CONFIG_X= line (a symbol whose dependencies are
# off is absent, which is the same), where X must be a symbol the source defines (a
# misspelled or renamed one would pass as absent). CONFIG_LOCALVERSION is the build's.
check_fragment() {
	bad=0
	grep -hE '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set)' "$1" \
		| grep -v '^CONFIG_LOCALVERSION=' > /tmp/want || :
	while read -r l; do
		case $l in
		'# '*) s=${l#\# }; s=${s%% *}
			git -C $S grep -qE "^[[:space:]]*(menu)?config ${s#CONFIG_}[[:space:]]*\$" -- '*Kconfig*' \
				|| { echo "kernel.sh: $(basename "$1"): no symbol ${s#CONFIG_} in the source's Kconfig files" >&2; false; } \
				&& ! grep -q "^$s=" "$2" ;;
		*) grep -qxF "$l" "$2" ;;
		esac || { echo "kernel.sh: $(basename "$1"): option not applied: $l" >&2; bad=1; }
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
	for f in $fragments; do check_fragment "$S/arch/arm64/configs/$f" /cache/obj/.config || ok=1; done
	check_fragment /run/stage/build.config /cache/obj/.config || ok=1
	grep -qx 'CONFIG_LOCALVERSION=""' /cache/obj/.config || ok=1
	! grep -q '^CONFIG_LOCALVERSION_AUTO=' /cache/obj/.config || ok=1
	[ $ok = 0 ] || die "the configuration isn't what the fragments ask for"
	# the release: <KERNELVERSION>-<flavor>.<cfg6>-g<commit12>, cfg6 over the final
	# .config followed by the builder's digest and a newline
	cfg6=$({ cat /cache/obj/.config; printf '%s\n' "$BUILDER"; } | sha256sum | cut -c1-6)
	lv="-$flavor.$cfg6-g$(c12 "$COMMIT")"
	rel="$($M -s kernelversion)$lv"
	$M -s -j"${JOBS:-$(nproc)}" LOCALVERSION="$lv" Image.gz modules
	got=$($M -s LOCALVERSION="$lv" kernelrelease)
	[ "$got" = "$rel" ] || die "the kernel calls itself $got, expected $rel"
	o=/out/modules/$rel
	rm -rf /tmp/mod /out /meta
	mkdir -p "$o" /meta
	# stripped modules, depmod run against the tree (-b)
	$M -s LOCALVERSION="$lv" INSTALL_MOD_PATH=/tmp/mod INSTALL_MOD_STRIP=1 modules_install >/dev/null
	rm -f "/tmp/mod/lib/modules/$rel/build" "/tmp/mod/lib/modules/$rel/source"
	cp -a "/tmp/mod/lib/modules/$rel/." "$o/"
	# kbuild gzips with -n, so the checksum doesn't depend on the build time
	cp /cache/obj/arch/arm64/boot/Image.gz "$o/Image.gz"
	cp /cache/obj/.config /meta/config
	echo "$rel" > /meta/release
	rm -rf /tmp/mod /tmp/want
	settle /out
	echo "kernel.sh: $rel: $(find "$o" -name '*.ko' | wc -l) modules, Image.gz $(stat -c %s "$o/Image.gz") bytes"
}

manifest() {
	check_source
	rel=$(cat /meta/release)
	o=/out/modules/$rel
	# firmware this kernel needs, by the names the drivers request
	mkdir -p "$o/firmware"
	cp -R /run/firmware/. "$o/firmware/"
	fw=$(cd "$o/firmware" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
		printf '%s@%.16s ' "$f" "$(sha "$f")"; done)
	# the device trees built at this commit: every target that boots this kernel
	dtbs=
	for t in /run/targets/*/target; do
		[ "$(val kernel "$t")" = "$FLAVOR" ] || continue
		d=$(basename "$(dirname "$t")")
		build_dtb "$(val dts "$t")" /tmp/dtb
		dtbs="$dtbs $d@$(sha /tmp/dtb | cut -c1-16)"
	done
	# modules_sha256: sha256 over "path sha256" lines, one per regular file under
	# modules/<release>/ except Image.gz, kernel.manifest and firmware/, paths relative,
	# sorted bytewise
	ms=$(cd "$o" && find . -path ./firmware -prune -o -type f ! -name Image.gz ! -name kernel.manifest -print \
		| sed 's|^\./||' | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(sha "$f")"; done \
		| sha256sum | cut -c1-64)
	[ -z "$(cd "$o" && find . -path ./firmware -prune -o ! -type f ! -type d -print)" ] \
		|| die "the modules tree has entries that are neither files nor directories"
	# provides and features come from GlassineOS/boot's conf/kernel-features, which
	# doesn't exist yet: both stay empty until it does
	cat > "$o/kernel.manifest" <<-EOF
	format=1
	release=$rel
	source=$REPO@$COMMIT
	config_sha256=$(sha /meta/config)
	image_sha256=$(sha "$o/Image.gz")
	modules_sha256=$ms
	firmware=${fw% }
	provides=
	features=
	dtbs=${dtbs# }
	EOF
	rm -rf /tmp/dtb-obj /tmp/dtb
	settle /out
	cat "$o/kernel.manifest"
}

dtb() {
	check_source
	dts=$(val dts /run/target/target)
	[ -n "$dts" ] || die "/run/target/target has no dts"
	mkdir -p /out/boot/dtb
	build_dtb "$dts" /tmp/dtb
	id=$DEVICE@$(sha /tmp/dtb | cut -c1-16)
	cp /tmp/dtb "/out/boot/dtb/$id.dtb"
	printf 'format=1\ndevice=%s\nsha256=%s\nsource=%s@%s\n' "$DEVICE" "$(sha /tmp/dtb)" "$REPO" "$COMMIT" \
		> "/out/boot/dtb/$id.manifest"
	rm -rf /tmp/dtb-obj /tmp/dtb
	settle /out
	echo "kernel.sh: $id.dtb from $(c12 "$COMMIT")"
}

case ${1:-} in
build|manifest|dtb) "$1" ;;
*) die "usage: kernel.sh build|manifest|dtb" ;;
esac
