# syntax=docker/dockerfile:1
# check=skip=FromPlatformFlagConstDisallowed
# SPDX-License-Identifier: GPL-2.0-or-later
# The root file system of a GlassineOS base, as a chain of stages (GlassineOS/hub#8):
#
#   alpine → glassine-common → eink → device-<name> → finish → validation → base-export
#
# Each stage installs exactly the versions stages/<stage>/lock names, then compares the
# whole installed set with the lock and fails if they differ or if a locked version is
# no longer offered (scripts/apk-stage.sh; scripts/lock.sh refreshes the locks, and only
# a refresh moves a version). The pins never reach /etc/apk/world, which holds the plain
# names of stages/<stage>/packages, so live upgrades move on from the locked versions.
#
#   docker buildx build --platform linux/arm64 -o type=tar,dest=base.tar .
#
# builds the default device's tree. DEVICE picks another device-<name> stage, and
# --platform the architecture: the Note Air's stages are arm64's, the generic UEFI PC's
# (DEVICE=uefi-pc, --platform linux/amd64) x86-64's; a stage locks each architecture it
# builds for apart (lock for arm64, lock.x86_64). The kernel
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
# branch: d7-pmic-watchdog
ARG LINUX_SDM660=d673c63928e1624b77885f3ccfe5cc8534a1a60f
# the commit device trees build from: a fixed tree ships without a new kernel
# branch: d7-pmic-watchdog
ARG DTB_COMMIT=${LINUX_SDM660}
ARG KERNEL=sdm660
ARG LINUX_FIRMWARE=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/20250509
# the license texts of the PC kernel's linux-firmware packages: upstream's repository at
# the tag of the packages' version (kernel-package.sh fails when the two differ) and that
# tag's commit, and the two Raspberry Pi sources Alpine adds to brcm/ and cypress/, at
# the commits its linux-firmware APKBUILD pins
ARG LINUX_FIRMWARE_GIT=https://gitlab.com/kernel-firmware/linux-firmware.git
ARG LINUX_FIRMWARE_TAG=20260519
ARG LINUX_FIRMWARE_TAG_COMMIT=d962a6a309b78778f458dc94713845eee105be14
ARG RPI_BLUEZ_FIRMWARE=https://raw.githubusercontent.com/RPi-Distro/bluez-firmware/cdf61dc691a49ff01a124752bd04194907f0f9cd
ARG RPI_FIRMWARE_NONFREE=https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/9794282eb9f4a2de1f23b41a738926740e975d83
# GlassineOS/boot: the initramfs and the boot image packer
ARG BOOT=https://github.com/GlassineOS/boot
# branch: main
ARG BOOT_COMMIT=eb4b269d4d5e77b54e2e16949947370e5a5eaa49

# The source at the pinned commit, with a shallow .git (one commit: the build checks it
# is that commit, unchanged). BuildKit's own git source would fetch the whole history
# for a commit id. scripts/git-fetch.sh limits the time of each fetch and tries again on
# network failures, and keeps the repository's objects in a cache mount, so a later
# commit transfers only what it adds.
FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS linux-sdm660-src
ARG LINUX LINUX_SDM660
RUN --mount=type=bind,source=scripts/git-fetch.sh,target=/run/git-fetch.sh \
    --mount=type=cache,id=glassine-src-linux,target=/cache/git,sharing=locked \
    sh /run/git-fetch.sh linux-sdm660-src "$LINUX" "$LINUX_SDM660" /src/linux /cache/git
WORKDIR /src/linux

# Firmware the sdm660 kernel depends on, from linux-firmware (redistributable; never
# vendor files): the Adreno 5xx CP microcode, whose PFP carries the marker the driver
# needs for its multiple rings and preemption, and the WCN3990's ath10k firmware file
# (firmware-5.bin: the features and interface versions ath10k uses; the WLAN firmware
# itself runs on the modem and comes from the device).
FROM scratch AS firmware-sdm660
ARG LINUX_FIRMWARE
ADD --checksum=sha256:7ab3cd917e1f875f6a8387f8bc5efcf11ce9c88542ef2fc3cbda7d4b7b163286 \
    ${LINUX_FIRMWARE}/qcom/a530_pfp.fw /qcom/a530_pfp.fw
ADD --checksum=sha256:6419f35956ec7307af83723fedfba752520bacd8389eda0d0120e185e4cb1d3f \
    ${LINUX_FIRMWARE}/qcom/a530_pm4.fw /qcom/a530_pm4.fw
ADD --checksum=sha256:be904cd28cb292b80cdb6cf412ab0d9159d431671e987ad433c1f62e0988a9bc \
    ${LINUX_FIRMWARE}/LICENSE.qcom /LICENSE.qcom
ADD --checksum=sha256:fef6539e0127579536bc977be57a90d018b83f2931fedc3a8870fbe38d6c4127 \
    ${LINUX_FIRMWARE}/ath10k/WCN3990/hw1.0/firmware-5.bin /ath10k/WCN3990/hw1.0/firmware-5.bin
ADD --checksum=sha256:337a55102138d7baa143ee4a4c6c91693e0113fece35d380b2a12109e8c23b3f \
    ${LINUX_FIRMWARE}/LICENSE.QualcommAtheros_ath10k /LICENSE.QualcommAtheros_ath10k

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

# The licenses of the PC kernel's firmware (decision 0016: firmware published for
# redistribution ships with its license). Alpine's linux-firmware subpackages carry the
# firmware but no license file, so they come from upstream at the packages' own tag:
# WHENCE (which license covers which file) and every license file at the top of the
# tree, about 1 MB. One shallow fetch without file contents, then only those files
# (GitLab limits its raw file downloads, so one ADD each would be refused); the tag must
# be the pinned commit. Alpine replaces or adds Raspberry Pi files in brcm/ and cypress/
# (Broadcom, Cypress and Synaptics licenses); their terms are in the Debian copyright
# files of the two sources, at the commits Alpine pins, each by its checksum.
# kernel-package.sh puts them all in the kernel's firmware/. Fetched on the build
# computer's own platform, as boot-src; the files are the same on every platform.
FROM --platform=$BUILDPLATFORM ${ALPINE} AS firmware-licenses-pc
ARG LINUX_FIRMWARE_GIT LINUX_FIRMWARE_TAG LINUX_FIRMWARE_TAG_COMMIT
RUN apk add -q --no-cache git && git init -q /src && cd /src \
    && git sparse-checkout set --no-cone /WHENCE '/LICEN*' \
    && n=1 && until timeout 600 git -c protocol.version=2 fetch -q --depth=1 --filter=blob:none \
            "$LINUX_FIRMWARE_GIT" "refs/tags/$LINUX_FIRMWARE_TAG" \
        && test "$(git rev-parse 'FETCH_HEAD^{commit}')" = "$LINUX_FIRMWARE_TAG_COMMIT" \
        && timeout 600 git -c advice.detachedHead=false checkout -q FETCH_HEAD; do \
        [ "$n" -lt 4 ] || { echo "firmware-licenses-pc: no tag $LINUX_FIRMWARE_TAG at $LINUX_FIRMWARE_TAG_COMMIT from $LINUX_FIRMWARE_GIT" >&2; exit 1; }; \
        sleep $((15 * n)); n=$((n + 1)); done \
    && test "$(git rev-parse HEAD)" = "$LINUX_FIRMWARE_TAG_COMMIT" \
    && mkdir /out && cp WHENCE LICEN* /out/ \
    && echo "firmware-licenses-pc: $(ls /out | wc -l) files from $LINUX_FIRMWARE_TAG"
ARG RPI_BLUEZ_FIRMWARE RPI_FIRMWARE_NONFREE
ADD --checksum=sha256:5f6acad870790f7e23150a30cab85c643f926266bf16e6a63acbde4257b957d4 \
    ${RPI_BLUEZ_FIRMWARE}/debian/copyright /out/copyright.rpi-bluez-firmware
ADD --checksum=sha256:0bbfd2c3ec95c4ec047923243ed647026e1cbe26d18d3e632361c81753506e23 \
    ${RPI_FIRMWARE_NONFREE}/debian/copyright /out/copyright.rpi-firmware-nonfree

# The kernel of a generic x86-64 PC (KERNEL=lts, --platform linux/amd64): Alpine's
# linux-lts, installed as a package at the version stages/kernel-lts/lock.x86_64 names,
# not compiled here, with the linux-firmware packages for common PC hardware and the CPU
# microcode. Its tree is the shape kernel-export's contract gives a device's modules
# subvolume (modules/<release>/: the modules and depmod's files, firmware/ with the
# packages' firmware and its licenses, kernel.manifest), with the EFI-stub image as
# vmlinuz and the early microcode archives in microcode/. From the Alpine image itself
# (the kernel is Alpine's; the alpine stage, with our repository, comes later in this
# file).
FROM ${ALPINE} AS kernel-lts
ARG LOCK=check
RUN --mount=type=bind,source=stages/kernel-lts,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
# A lock refresh (LOCK=refresh) only records what the stage installed: the newest
# packages, whose firmware may not be the licenses' tag yet (scripts/lock.sh moves the
# tag afterwards, scripts/kernel-lock.sh), so the tree is laid out only on a check build.
ARG LINUX_FIRMWARE_TAG
RUN --mount=type=bind,source=scripts/kernel-package.sh,target=/run/kernel-package.sh \
    --mount=type=bind,from=firmware-licenses-pc,source=/out,target=/run/firmware-licenses \
    if [ "$LOCK" = refresh ]; then mkdir -p /out; \
    else FIRMWARE_TAG=$LINUX_FIRMWARE_TAG sh /run/kernel-package.sh linux-lts /boot/vmlinuz-lts; fi

FROM kernel-${KERNEL} AS kernel
FROM scratch AS kernel-export
COPY --from=kernel /out/ /

# The recovery's kernel (docs/recovery.md; GlassineOS/boot spec 008, FR-014): the same
# source and commit, the system kernel's configuration with nothing as a module and what
# the recovery needs built in (stages/kernel-<KERNEL>recovery), and no firmware. Its
# export is modules/<release>/ with Image.gz, modules.builtin and kernel.manifest, read
# only by the recovery's boot image. Its own cache mount (RKCACHE), so the two kernels
# don't evict each other's objects.
FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS kernel-sdm660recovery
ARG KERNEL_BUILD_IMAGE KERNEL_BUILD_DIGEST LINUX LINUX_SDM660
ARG RKCACHE=kernel-sdm660recovery
ARG JOBS
RUN --mount=type=bind,from=linux-sdm660-src,source=/src/linux,target=/src/linux \
    --mount=type=bind,source=stages/kernel-sdm660recovery,target=/run/stage \
    --mount=type=tmpfs,target=/run/firmware \
    --mount=type=bind,source=scripts/kernel.sh,target=/run/kernel.sh \
    --mount=type=cache,id=${RKCACHE}-${KERNEL_BUILD_DIGEST},target=/cache,sharing=locked \
    REPO=$LINUX COMMIT=$LINUX_SDM660 BUILDER=$KERNEL_BUILD_IMAGE@$KERNEL_BUILD_DIGEST JOBS=$JOBS sh /run/kernel.sh build

FROM kernel-${KERNEL}recovery AS recovery-kernel
FROM scratch AS recovery-kernel-export
COPY --from=recovery-kernel /out/ /

# One device's tree, from DTB_COMMIT: the kernel's source, moved to that commit if it
# differs (a fixed tree ships without a new kernel).
FROM linux-sdm660-src AS dtb-src
ARG LINUX DTB_COMMIT
RUN --mount=type=bind,source=scripts/git-fetch.sh,target=/run/git-fetch.sh \
    --mount=type=cache,id=glassine-src-linux,target=/cache/git,sharing=locked \
    if [ "$(git rev-parse HEAD)" != "$DTB_COMMIT" ]; then \
        sh /run/git-fetch.sh dtb-src "$LINUX" "$DTB_COMMIT" /src/linux /cache/git; fi \
    && test "$(git rev-parse HEAD)" = "$DTB_COMMIT"

FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS dtb
ARG LINUX DTB_COMMIT DEVICE JOBS
RUN --mount=type=bind,from=dtb-src,source=/src/linux,target=/src/linux \
    --mount=type=bind,source=targets/${DEVICE}/target,target=/run/target/target \
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
# busybox-openrc's klogd service runs as the account klogd, which no package makes
RUN addgroup -S klogd && adduser -S -D -H -h /dev/null -s /sbin/nologin -G klogd -g klogd klogd
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
# the board keys the booted system reads (GlassineOS/boot: glassine-bootimg, the
# developer mode's DEVMODE_*): the target's board.conf, the same file every boot image
# carries as /etc/glassine-boot/board.conf
COPY --chmod=644 targets/onyx-noteair/board.conf /etc/glassine-bootimg/board.conf

# A made-up device that tests the chain: it must build on the generic stages unchanged.
FROM eink AS device-example
ARG LOCK=check
RUN --mount=type=bind,source=stages/device-example,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
COPY stages/device-example/rootfs/ /

# A generic x86-64 PC that boots by UEFI (--platform linux/amd64): what every such PC
# needs and nothing of a display, a panel or a vendor. On glassine-common, not on eink.
FROM glassine-common AS device-uefi-pc
ARG LOCK=check
RUN --mount=type=bind,source=stages/device-uefi-pc,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
COPY stages/device-uefi-pc/rootfs/ /
# the board keys the booted system reads: the target's board.conf, the same file a PC
# release names as its board role (the kernel set's board archive and command line)
COPY --chmod=644 targets/uefi-pc/board.conf /etc/glassine-bootimg/board.conf

# ---------------------------------------------------------------------------------------
# The initramfs and the boot image (GlassineOS/boot's docs/kernel-artifacts.md):
#
#   boot-src + alpine → initramfs → initramfs-export          boot/initramfs/<commit12>@<id>.*
#   kernel-export + dtb-export + initramfs-export + boot-src → boot → boot-export
#                                                             bootimg/<id>.*, select/<device>
#
# The initramfs is GlassineOS/boot's build-initramfs.sh at BOOT_COMMIT, built in arm64
# Alpine with a locked package set (stages/initramfs). The boot image packs with boot's
# lib/glassine-bootimg-pack and the device's targets/<device>/board.conf: no reference
# image. A change to the initramfs repacks without touching a kernel layer.

# GlassineOS/boot at BOOT_COMMIT, fetched on the build computer's own platform (no
# emulation on either kind of runner); git here is a fetch tool, not part of any output,
# and the stage gives the same files on every platform (docs/registry.md counts on it).
FROM --platform=$BUILDPLATFORM ${ALPINE} AS boot-src
ARG BOOT BOOT_COMMIT
RUN --mount=type=bind,source=scripts/git-fetch.sh,target=/run/git-fetch.sh \
    apk add -q --no-cache git \
    && sh /run/git-fetch.sh boot-src "$BOOT" "$BOOT_COMMIT" /src/boot
WORKDIR /src/boot

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
# kernel isn't the release its directory names (--expect-release). It reads the other
# exports, not their stages, so a published export given as a build context
# (--build-context kernel-export=docker-image://...) stands in for building it.
# CMDLINE_EXTRA: words appended to the board's command line for one build (a developer
# image, such as glassine.devmode=usb for a device test); setting it makes the build a
# trial, and the board's own CMDLINE never carries them.
FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS boot
ARG DEVICE CMDLINE_EXTRA
RUN --mount=type=bind,from=kernel-export,source=/modules,target=/run/modules \
    --mount=type=bind,from=dtb-export,source=/boot/dtb,target=/run/dtb \
    --mount=type=bind,from=initramfs-export,source=/boot/initramfs,target=/run/initramfs \
    --mount=type=bind,from=boot-src,source=/src/boot,target=/src/boot \
    --mount=type=bind,source=targets/${DEVICE},target=/run/target \
    --mount=type=bind,source=scripts/bootimg.sh,target=/run/bootimg.sh \
    DEVICE=$DEVICE CMDLINE_EXTRA="$CMDLINE_EXTRA" sh /run/bootimg.sh

FROM scratch AS boot-export
COPY --from=boot /out/ /

# ---------------------------------------------------------------------------------------
# The RAM environment (docs/ramenv.md): what the installer writes to the recovery
# partition (or starts once with fastboot boot) to read the whole disk for the backup,
# and to write the partitions it arms (read-only until then).
#
#   alpine → ramenv                                               (its initramfs)
#   kernel-export + dtb-export + ramenv + boot-src → ramenv-boot → ramenv-export
#                                                                 ramenv/<id>.img
#
#   docker buildx build --platform linux/arm64 --target ramenv-export -o type=local,dest=out .
#
# The device's own kernel and device tree, packed the way its boot image is (boot's
# packer, the target's board.conf), with this initramfs and its own command line. The
# device's facts (which disks, the USB controller, the command line) come from the
# device's ramenv/targets/<device>.conf (kept out of targets/<device>/, which the boot
# stage mounts whole: a ramenv change must not move boot-export's key); these stages
# name no device. Built only for --target
# ramenv-export, and nothing in it is a boot update (no select record).
FROM alpine AS ramenv
ARG LOCK=check
RUN --mount=type=bind,source=stages/ramenv,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
ARG DEVICE
RUN --mount=type=bind,source=ramenv,target=/src/ramenv \
    --mount=type=bind,source=ramenv/targets/${DEVICE}.conf,target=/run/ramenv.conf \
    sh /src/ramenv/build.sh /src/ramenv /run/ramenv.conf "$DEVICE" /out/ramenv

FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS ramenv-boot
ARG DEVICE
RUN --mount=type=bind,from=kernel-export,source=/modules,target=/run/modules \
    --mount=type=bind,from=dtb-export,source=/boot/dtb,target=/run/dtb \
    --mount=type=bind,from=ramenv,source=/out/ramenv,target=/run/ramenv \
    --mount=type=bind,from=boot-src,source=/src/boot,target=/src/boot \
    --mount=type=bind,source=targets/${DEVICE},target=/run/target \
    --mount=type=bind,source=ramenv/targets/${DEVICE}.conf,target=/run/ramenv.conf \
    --mount=type=bind,source=scripts/ramenv-bootimg.sh,target=/run/ramenv-bootimg.sh \
    DEVICE=$DEVICE sh /run/ramenv-bootimg.sh

FROM scratch AS ramenv-export
COPY --from=ramenv-boot /out/ /

# The recovery (docs/recovery.md): the RAM environment plus glassine-deploy (boot at
# BOOT_COMMIT, the commit the boot initramfs is built from), its tools and the console's
# menu; its reader speaks protocol version 3 (versions 1 and 2 as the RAM environment).
# Packed the same way, from the same device config, into recovery/.
#
#   alpine → recovery + boot-src ─────────────────────────────────┐
#   recovery-kernel-export + dtb-export + boot-src → recovery-boot → recovery-export
#                                                                  recovery/<id>.img
#
#   docker buildx build --platform linux/arm64 --target recovery-export -o type=local,dest=out .
FROM alpine AS recovery
ARG LOCK=check
RUN --mount=type=bind,source=stages/recovery,target=/run/stage \
    --mount=type=bind,source=scripts/apk-stage.sh,target=/run/apk-stage.sh \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    LOCK=$LOCK sh /run/apk-stage.sh
ARG DEVICE BOOT_COMMIT
RUN --mount=type=bind,source=ramenv,target=/src/ramenv \
    --mount=type=bind,source=ramenv/targets/${DEVICE}.conf,target=/run/ramenv.conf \
    --mount=type=bind,from=boot-src,source=/src/boot,target=/src/boot \
    sh /src/ramenv/build.sh --recovery /src/boot "$BOOT_COMMIT" /src/ramenv /run/ramenv.conf "$DEVICE" /out/recovery

FROM --platform=linux/amd64 ${KERNEL_BUILD_IMAGE}@${KERNEL_BUILD_DIGEST} AS recovery-boot
ARG DEVICE
RUN --mount=type=bind,from=recovery-kernel-export,source=/modules,target=/run/modules \
    --mount=type=bind,from=dtb-export,source=/boot/dtb,target=/run/dtb \
    --mount=type=bind,from=recovery,source=/out/recovery,target=/run/ramenv \
    --mount=type=bind,from=boot-src,source=/src/boot,target=/src/boot \
    --mount=type=bind,source=targets/${DEVICE},target=/run/target \
    --mount=type=bind,source=ramenv/targets/${DEVICE}.conf,target=/run/ramenv.conf \
    --mount=type=bind,source=scripts/ramenv-bootimg.sh,target=/run/ramenv-bootimg.sh \
    DEVICE=$DEVICE ROLE=recovery sh /run/ramenv-bootimg.sh

FROM scratch AS recovery-export
COPY --from=recovery-boot /out/ /
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

# The device's stage directory is mounted for its expectations (stages/device-<name>/expect,
# when it has one: values its finished tree must hold).
FROM finish AS validation
ARG DEVICE
RUN --mount=type=bind,source=scripts/validate.sh,target=/run/validate.sh \
    --mount=type=bind,from=device-files,source=/device-files,target=/run/device-files \
    --mount=type=bind,source=stages/device-${DEVICE},target=/run/device-stage \
    sh /run/validate.sh

# The tree a base is made from.
FROM validation AS base-export
