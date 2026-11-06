# syntax=docker/dockerfile:1
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
# builds the default device's tree. DEVICE picks another device-<name> stage.
ARG ALPINE=alpine:3.24
ARG DEVICE=onyx-noteair

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
FROM finish AS validation
RUN --mount=type=bind,source=scripts/validate.sh,target=/run/validate.sh \
    sh /run/validate.sh

# The tree a base is made from.
FROM validation AS base-export
