# syntax=docker/dockerfile:1
# check=skip=FromPlatformFlagConstDisallowed
# SPDX-License-Identifier: GPL-2.0-or-later
# The root file system of a GlassineOS base, as a chain of stages (GlassineOS/hub#8):
#
#   alpine → glassine-common → eink → device-<name> → finish → validation → base-export
#
# Each stage installs the plain package names in stages/<stage>/packages, then compares
# the whole installed set with stages/<stage>/lock and fails if they differ
# (scripts/lock.sh refreshes the locks). Versions are never pinned at install time:
# `apk add name=version` would write the pin into /etc/apk/world and block live upgrades.
#
#   docker buildx build --platform linux/arm64 -o type=tar,dest=base.tar .
#
# builds the default device's tree. DEVICE picks another device-<name> stage. The kernel
# and device-tree stages come first and build only when a --target asks for them; base-export
# stays the last stage, so it is what a build without --target makes.
ARG ALPINE=alpine:3.24
ARG DEVICE=onyx-noteair

# ---------------------------------------------------------------------------------------
# Kernel artifacts, to GlassineOS/boot's docs/kernel-artifacts.md, independent of the
# root file system's stages below:
#
#   linux-<soc>-src + firmware-<soc> → kernel-<soc> → kernel-export   modules/<release>/
#   dtb-src → dtb → dtb-export                                         boot/dtb/<device>@<id>.*
#
#   docker buildx build --platform linux/arm64 --target kernel-export -o type=local,dest=out .
#   docker buildx build --platform linux/arm64 --target dtb-export -o type=local,dest=out .
#
# The compiler is the amd64 kernel-build image (GlassineOS/builders), pinned by its amd64
# manifest digest; that reference goes into the release (cfg6). On an arm64 computer it runs
# through QEMU (hence the constant --platform, and the lint check skipped above). The
# kernel compiles in a cache mount, so a small source change rebuilds only what it touches;
# an empty cache gives the same result. The mount's id is KCACHE, a dash and the builder's
# digest, so a new builder starts from an empty mount. The builder is only ever named by
# these two (no combined argument to override), so the mount's id always follows it.
ARG KERNEL_BUILD_IMAGE=ghcr.io/glassineos/kernel-build
ARG KERNEL_BUILD_DIGEST=sha256:ff546bc6cc2071c50738a8881c88997645e10b4e11019eebca86e553ae84f3b3
ARG LINUX=https://github.com/GlassineOS/linux
# Each git input's commit has the branch it follows on the line above it, as
# "# branch: <name>" (the pins, read by scripts/glassine_pins.py).
# branch: glassine/sdm660-7.3
ARG LINUX_SDM660=deb74f03e647c3d0a21377168758e1a138042152
# the commit device trees build from: a fixed tree ships without a new kernel
# branch: glassine/sdm660-7.3
ARG DTB_COMMIT=${LINUX_SDM660}
ARG KERNEL=sdm660
ARG LINUX_FIRMWARE=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/20250509
# GlassineOS/boot: the initramfs and the boot image packer
ARG BOOT=https://github.com/GlassineOS/boot
# branch: main
ARG BOOT_COMMIT=9b0078a16986c4766eaab5329b9bf90159a4d698

# The source at the pinned commit, with a shallow .git (one commit: the build checks it
# is that commit, unchanged). BuildKit's own git source would fetch the whole history
# for a commit id.
FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS linux-sdm660-src
ARG LINUX LINUX_SDM660
WORKDIR /src/linux
RUN git init -q && git fetch -q --depth=1 "$LINUX" "$LINUX_SDM660" \
    && git -c advice.detachedHead=false checkout -q FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$LINUX_SDM660"

# Firmware the sdm660 kernel depends on, from linux-firmware (redistributable; never
# vendor files): the Adreno 5xx CP microcode, whose PFP carries the marker the driver
# needs for its multiple rings and preemption.
FROM scratch AS firmware-sdm660
ARG LINUX_FIRMWARE
ADD --checksum=sha256:7ab3cd917e1f875f6a8387f8bc5efcf11ce9c88542ef2fc3cbda7d4b7b163286 \
    ${LINUX_FIRMWARE}/qcom/a530_pfp.fw /qcom/a530_pfp.fw
ADD --checksum=sha256:6419f35956ec7307af83723fedfba752520bacd8389eda0d0120e185e4cb1d3f \
    ${LINUX_FIRMWARE}/qcom/a530_pm4.fw /qcom/a530_pm4.fw
ADD --checksum=sha256:be904cd28cb292b80cdb6cf412ab0d9159d431671e987ad433c1f62e0988a9bc \
    ${LINUX_FIRMWARE}/LICENSE.qcom /LICENSE.qcom

# The kernel for SoCs of the sdm660 family: compiled once for every device whose target
# names kernel=sdm660, with the firmware it needs. It names no device tree: those are
# built by the dtb stage and paired with a kernel by a device's select record.
FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS kernel-sdm660
ARG KERNEL_BUILD_IMAGE KERNEL_BUILD_DIGEST LINUX LINUX_SDM660
ARG KCACHE=kernel-sdm660
ARG JOBS
RUN --mount=type=bind,from=linux-sdm660-src,source=/src/linux,target=/src/linux \
    --mount=type=bind,source=stages/kernel-sdm660,target=/run/stage \
    --mount=type=bind,from=firmware-sdm660,target=/run/firmware \
    --mount=type=bind,source=scripts/kernel.sh,target=/run/kernel.sh \
    --mount=type=cache,id=${KCACHE}-${KERNEL_BUILD_DIGEST},target=/cache,sharing=locked \
    REPO=$LINUX COMMIT=$LINUX_SDM660 BUILDER=$KERNEL_BUILD_IMAGE@$KERNEL_BUILD_DIGEST JOBS=$JOBS sh /run/kernel.sh build

FROM kernel-${KERNEL} AS kernel
FROM scratch AS kernel-export
COPY --from=kernel /out/ /

# One device's tree, from DTB_COMMIT: the kernel's source, moved to that commit if it
# differs (a fixed tree ships without a new kernel).
FROM linux-sdm660-src AS dtb-src
ARG LINUX DTB_COMMIT
RUN if [ "$(git rev-parse HEAD)" != "$DTB_COMMIT" ]; then \
        git fetch -q --depth=1 "$LINUX" "$DTB_COMMIT" \
        && git -c advice.detachedHead=false checkout -q FETCH_HEAD; fi \
    && test "$(git rev-parse HEAD)" = "$DTB_COMMIT"

FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS dtb
ARG LINUX DTB_COMMIT DEVICE JOBS
RUN --mount=type=bind,from=dtb-src,source=/src/linux,target=/src/linux \
    --mount=type=bind,source=targets/${DEVICE},target=/run/target \
    --mount=type=bind,source=scripts/kernel.sh,target=/run/kernel.sh \
    REPO=$LINUX COMMIT=$DTB_COMMIT DEVICE=$DEVICE JOBS=$JOBS sh /run/kernel.sh dtb

FROM scratch AS dtb-export
COPY --from=dtb /out/ /
# ---------------------------------------------------------------------------------------

# Alpine, its repositories, and ours (the key, the line, then glassine-keys, which owns
# both from here on and moves them along on an Alpine release change).
FROM ${ALPINE} AS alpine
ARG LOCK=check
COPY keys/glassine-20261015.rsa.pub /etc/apk/keys/
RUN echo https://pkgs.glassine.org/alpine/v3.24/glassine >> /etc/apk/repositories
RUN --mount=type=bind,source=stages/alpine,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh

# What every GlassineOS system has, whatever its display or device.
FROM alpine AS glassine-common
ARG LOCK=check
RUN --mount=type=bind,source=stages/glassine-common,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
# A base boots as a deployment (GlassineOS/boot's docs/boot.md, "Deployments layout"):
# its `/` is a read-only bind of the deployment's overlay, and OpenRC remounts `/`
# read-write unless fstab says otherwise. `bind,ro` keeps that bind read-only and leaves
# the read-write binds below it (/etc, /var) alone. alpine-baselayout owns the file (a
# protected configuration file, so apk never replaces it), hence a RUN, not rootfs/.
# /tmp is a tmpfs: `/` is read-only, and only /etc, /var, /usr/local and /opt are bound
# writable, so without it nothing could write a temporary file.
RUN printf '%s\n' 'overlay / overlay bind,ro 0 0' 'tmpfs /tmp tmpfs nosuid,nodev,mode=1777 0 0' > /etc/fstab
COPY stages/glassine-common/rootfs/ /

# Any e-ink device: the panel daemons and the e-ink session, started at boot.
FROM glassine-common AS eink
ARG LOCK=check
RUN --mount=type=bind,source=stages/eink,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
COPY stages/eink/rootfs/ /

# Onyx Boox Note Air: its packages and system configuration only. The copied files must
# not belong to a package (apk-stage.sh checks), so a live upgrade never fights them.
FROM eink AS device-onyx-noteair
ARG LOCK=check
RUN --mount=type=bind,source=stages/device-onyx-noteair,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
COPY stages/device-onyx-noteair/rootfs/ /

# A made-up device that tests the chain: it must build on the generic stages unchanged.
FROM eink AS device-example
ARG LOCK=check
RUN --mount=type=bind,source=stages/device-example,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
COPY stages/device-example/rootfs/ /

# ---------------------------------------------------------------------------------------
# The initramfs and the boot image (GlassineOS/boot's docs/kernel-artifacts.md):
#
#   boot-src + alpine → initramfs → initramfs-export          boot/initramfs/<commit12>@<id>.*
#   kernel + dtb + initramfs + boot-src → boot → boot-export  bootimg/<id>.*, select/<device>
#
# The initramfs is GlassineOS/boot's build-initramfs.sh at BOOT_COMMIT, built in arm64
# Alpine with a locked package set (stages/initramfs). The boot image packs with boot's
# lib/glassine-bootimg-pack and the device's targets/<device>/board.conf: no reference
# image. A change to the initramfs repacks without touching a kernel layer.

# GlassineOS/boot at BOOT_COMMIT, fetched on the build computer's own platform (no
# emulation on either kind of runner); git here is a fetch tool, not part of any output.
FROM --platform=$BUILDPLATFORM ${ALPINE} AS boot-src
ARG BOOT BOOT_COMMIT
WORKDIR /src/boot
RUN apk add -q --no-cache git \
    && git init -q && git fetch -q --depth=1 "$BOOT" "$BOOT_COMMIT" \
    && git -c advice.detachedHead=false checkout -q FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$BOOT_COMMIT"

FROM alpine AS initramfs
ARG LOCK=check
RUN --mount=type=bind,source=stages/initramfs,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
# declared after the tools, so a new boot commit doesn't reinstall them
ARG BOOT_COMMIT
RUN --mount=type=bind,from=boot-src,source=/src/boot,target=/src/boot \
    --mount=type=bind,source=scripts/initramfs.sh,target=/run/initramfs.sh \
    COMMIT=$BOOT_COMMIT sh /run/initramfs.sh

FROM scratch AS initramfs-export
COPY --from=initramfs /out/ /

# One device's boot image and its select record (which kernel, device tree and initramfs
# the device boots). Fails when the image doesn't fit the board's PART_SIZE, or the
# kernel isn't the release its directory names (--expect-release).
FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS boot
ARG DEVICE
RUN --mount=type=bind,from=kernel,source=/out/modules,target=/run/modules \
    --mount=type=bind,from=dtb,source=/out/boot/dtb,target=/run/dtb \
    --mount=type=bind,from=initramfs,source=/out/boot/initramfs,target=/run/initramfs \
    --mount=type=bind,from=boot-src,source=/src/boot,target=/src/boot \
    --mount=type=bind,source=targets/${DEVICE},target=/run/target \
    --mount=type=bind,source=scripts/bootimg.sh,target=/run/bootimg.sh \
    DEVICE=$DEVICE sh /run/bootimg.sh

FROM scratch AS boot-export
COPY --from=boot /out/ /
# ---------------------------------------------------------------------------------------

# Build leftovers out, so two builds of the same inputs give the same tree: the machine
# ID (dbus writes one at install time; each installation makes its own,
# GlassineOS/hub#19), apk's log of this build, fontconfig's cache (it records file times;
# the system builds its own at boot, glassine-font-cache) and the build day that adding
# a system account writes into its shadow row (its password is locked, so the date of
# its last change means nothing).
FROM device-${DEVICE} AS finish
RUN : > /etc/machine-id && rm -f /var/log/apk.log \
    && rm -rf /var/cache/fontconfig/* /var/cache/fontconfig/.[!.]* \
    && for f in /etc/shadow /etc/shadow-; do \
        [ ! -e "$f" ] || sed -i 's/^\([^:]*:[!*][^:]*\):[0-9][0-9]*:/\1::/' "$f"; done

# What a base must not carry. Reads only, adds nothing. /etc/resolv.conf and /etc/hosts
# are mounted into every RUN, so their absence is checked on the exported tree.
# The device-file check (scripts/device-files.c), built static apart from the tree so
# that validation adds nothing to it.
FROM ${ALPINE} AS device-files
RUN --mount=type=bind,source=scripts/device-files.c,target=/src/device-files.c \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add build-base && cc -O2 -static -o /device-files /src/device-files.c

FROM finish AS validation
RUN --mount=type=bind,source=scripts/validate.sh,target=/run/validate.sh \
    --mount=type=bind,from=device-files,source=/device-files,target=/run/device-files \
    sh /run/validate.sh

# The tree a base is made from.
FROM validation AS base-export
