# syntax=docker/dockerfile:1
# Spike for GlassineOS/hub#8: just enough stages to prove BuildKit -> Btrfs.
# Not the real stage chain: package lists are a realistic-size sample, the
# device is fake, there are no lockfiles yet.
ARG ALPINE=alpine:3.24

FROM ${ALPINE} AS alpine
RUN sed -i 's/^#//' /etc/apk/repositories

# Plain names only: `apk add name=version` would pin them in /etc/apk/world.
FROM alpine AS glassine-common
RUN --mount=type=bind,source=packages/glassine-common.txt,target=/run/pk \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add -q --cache-dir /var/cache/apk $(cat /run/pk)

FROM glassine-common AS eink
RUN --mount=type=bind,source=packages/eink.txt,target=/run/pk \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add -q --cache-dir /var/cache/apk $(cat /run/pk)

FROM eink AS device-fake
RUN --mount=type=bind,source=packages/device-fake.txt,target=/run/pk \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add -q --cache-dir /var/cache/apk $(cat /run/pk)
COPY device-fake/ /

# What a base must not carry from the build. Read-only: it adds nothing to the
# tree. /etc/resolv.conf and /etc/hosts are mounted into every RUN, so their
# absence is checked on the exported tree, not here.
FROM device-fake AS validation
RUN if grep -q '[<>=~]' /etc/apk/world; then echo "pinned versions in /etc/apk/world"; exit 1; fi; \
    if [ -n "$(find /var/cache/apk -mindepth 1 -print -quit)" ]; then echo "package cache in the base"; exit 1; fi

# The tree a base is made from.
FROM validation AS base-export
