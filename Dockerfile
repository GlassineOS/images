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
# manifest digest; that digest goes into the release (cfg6). On an arm64 computer it runs
# through QEMU (hence the constant --platform, and the lint check skipped above). The kernel compiles in a cache mount, so a small source change rebuilds
# only what it touches; an empty cache gives the same result. KCACHE names the mount.
ARG KERNEL_BUILD=ghcr.io/glassineos/kernel-build@sha256:ff546bc6cc2071c50738a8881c88997645e10b4e11019eebca86e553ae84f3b3
ARG LINUX=https://github.com/GlassineOS/linux
# glassine/sdm660-7.3
ARG LINUX_SDM660=d476aaa52d6a070127b93599f4322d06e8f56159
# the commit device trees build from: a fixed tree ships without a new kernel
ARG DTB_COMMIT=${LINUX_SDM660}
ARG KERNEL=sdm660
ARG LINUX_FIRMWARE=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/20250509

# The source at the pinned commit, with a shallow .git (one commit: the build checks it
# is that commit, unchanged). BuildKit's own git source would fetch the whole history
# for a commit id.
FROM --platform=linux/amd64 ${KERNEL_BUILD} AS linux-sdm660-src
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
# names kernel=sdm660. The device trees for kernel.manifest's dtbs are built in the
# second step, so adding a device doesn't rerun the compile.
FROM --platform=linux/amd64 ${KERNEL_BUILD} AS kernel-sdm660
ARG KERNEL_BUILD LINUX LINUX_SDM660
ARG KCACHE=kernel-sdm660
ARG JOBS
RUN --mount=type=bind,from=linux-sdm660-src,source=/src/linux,target=/src/linux \
    --mount=type=bind,source=stages/kernel-sdm660,target=/run/stage \
    --mount=type=bind,source=scripts/kernel.sh,target=/run/kernel.sh \
    --mount=type=cache,id=${KCACHE},target=/cache,sharing=locked \
    REPO=$LINUX COMMIT=$LINUX_SDM660 BUILDER=${KERNEL_BUILD#*@} JOBS=$JOBS sh /run/kernel.sh build
RUN --mount=type=bind,from=linux-sdm660-src,source=/src/linux,target=/src/linux \
    --mount=type=bind,from=firmware-sdm660,target=/run/firmware \
    --mount=type=bind,source=targets,target=/run/targets \
    --mount=type=bind,source=scripts/kernel.sh,target=/run/kernel.sh \
    REPO=$LINUX COMMIT=$LINUX_SDM660 FLAVOR=sdm660 JOBS=$JOBS sh /run/kernel.sh manifest

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

FROM --platform=linux/amd64 ${KERNEL_BUILD} AS dtb
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

# Build leftovers out: the machine ID (dbus writes one at install time; each
# installation makes its own, GlassineOS/hub#19) and apk's log of this build.
FROM device-${DEVICE} AS finish
RUN : > /etc/machine-id && rm -f /var/log/apk.log

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
