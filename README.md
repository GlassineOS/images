# GlassineOS/images

System images of GlassineOS: the root file systems and boot images a device installs.
**Empty so far:** nothing builds from here yet.

## Plan

The design is in [GlassineOS/hub#8](https://github.com/GlassineOS/hub/issues/8). In short:

- Images are built as Dockerfile stages with BuildKit, each stage on top of the one
  before: `alpine` → `glassine-common` → `eink` → `device-<name>`.
- The boot image is a separate chain of stages: `boot-<device>`, built from the
  kernel, `dtb-<device>` and `initramfs-<device>`. The kernel stays out of the root
  file system chain, so a kernel change doesn't rebuild the root.
- Each stage has one lockfile: the exact package versions it installed. A weekly
  pull request updates the lockfiles, and so does a security fix.
- The stages are kept on GHCR by digest. That is the record of every image ever built.
- No vendor firmware anywhere. A device's firmware comes from the device itself
  (see the device's bootstrap repository).

Packages come from [GlassineOS/packages](https://github.com/GlassineOS/packages);
the build containers from `GlassineOS/builders`.

## Waiting for

The root file system model: read-only bases, deployments, and what stays writable.
That has to be decided first, and the first step tried on a device, because the
stages produce exactly that layout.

## License

GPL-2.0-or-later (`LICENSE`). Images contain software under many licenses; each
package carries its own.
