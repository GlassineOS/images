# GlassineOS/images

System images of GlassineOS: the root file systems and boot images a device installs.
The design is [GlassineOS/hub#8](https://github.com/GlassineOS/hub/issues/8), and the
decision is record 0013 in [GlassineOS/docs](https://github.com/GlassineOS/docs).

**Status:** the root file system's stage chain builds, and so do the kernel, device tree,
initramfs and boot image artifacts. It doesn't make a base yet (a Btrfs subvolume and
its send stream). Most of GlassineOS's own software isn't packaged yet either, so the tree isn't a usable system.

## Stages

```
alpine → glassine-common → eink → device-<name> → finish → validation → base-export
```

| Stage | Holds |
|---|---|
| `alpine` | Alpine 3.24 and its repositories, plus ours (`glassine-keys`) |
| `glassine-common` | what every GlassineOS system needs, whatever its display or device |
| `eink` | any e-ink device: the panel daemons, the compositor with the e-ink output, the keyboard, the desktop session and compressed swap with background-app parking (both enabled at boot) |
| `device-onyx-noteair` | the Onyx Boox Note Air's packages and system configuration |
| `device-example` | a made-up device for testing: CI checks that it builds on the generic stages unchanged. Never shipped |
| `finish` | removes build leftovers: the machine ID, apk's log |
| `validation` | fails the build on what a base must not carry, including files only a device may supply (waveforms, signed firmware, any firmware; `scripts/device-files.c`, by contents); adds nothing. It reads the final tree, after `finish`, not each stage: a file added in one stage and removed in a later one isn't seen |
| `base-export` | the tree a base is made from |

`scripts/device-files.c` knows a waveform by header offsets that no file in this
repository confirms: the mode and temperature counts agree with what the panel engine
reads, the length at offset 4 rests on one real file checked by hand, and the test
writes its waveform with the same offsets the check reads. Its header comment has the
details.

A stage lives in `stages/<stage>/`:

| File | What |
|---|---|
| `packages` | plain package names, one per line |
| `lock` | the whole installed set after this stage, as `name=version` |
| `rootfs/` | files copied over the tree (any stage). None may belong to a package |

**What goes where:** behavior goes in packages, which upgrade live. Configuration and
seeds go in a stage's `rootfs/` and change only with a new base. Applications aren't in
any stage, because people install them as live packages. Generic stages carry no device
names.

A new device is a new `device-<name>` stage on top of `eink` (or `glassine-common`),
and nothing above it changes.

## Locks

A stage installs its plain names, then compares everything installed with its `lock`.
A difference fails the build and says to refresh. The lock is also an input of its
stage, so a refreshed lock rebuilds that stage and the ones after it. Versions are
never pinned at install time: `apk add name=version` would write the pin into
`/etc/apk/world` and block live upgrades.

    scripts/lock.sh                   # rebuild from scratch, rewrite every lock

A build that fails after Alpine or our repository moved on is expected: refresh the
locks and review what changed.

The `lock-refresh` workflow does this every day on an arm64 runner and keeps one pull
request (branch `lock-refresh`) with the changed packages: on Mondays for any change,
and on any day when a change brings a fix from Alpine's security database. It can also
be started by hand. `scripts/lock-diff.sh` writes the pull request's description.

## Building

    scripts/build <target>

builds everything a device receives for a target (a directory under `targets/`): it
checks the host first and fails within seconds naming what is missing, builds the base's
tree and the kernel, device tree, initramfs and boot image, checks them, and makes the
base and the build record with `scripts/materialize` (specs/001-base-build). The result
goes to `artifacts/` in the checkout (git-ignored; `--artifacts DIR` for another
folder), laid out as `docs/artifacts.md` defines; each run's log is kept under
`artifacts/.logs/<target>/`. `scripts/build --help` lists the options and the checks;
`scripts/test-build.sh` tests the checks without a build.

One stage on its own:

    docker buildx build --platform linux/arm64 -o type=tar,dest=base.tar .

builds the default device's tree (`--build-arg DEVICE=<name>` for another). On an
amd64 computer, arm64 runs through QEMU (`docker run --privileged --rm
tonistiigi/binfmt --install arm64` once). Keep to the tar export: image exports drop
`user.*` extended attributes.

## Kernel and device trees

Built apart from the root file system, to the contract in GlassineOS/boot's
`docs/kernel-artifacts.md`. A kernel change doesn't rebuild a base, and a base change
doesn't rebuild the kernel.

```
linux-<soc>-src + firmware-<soc> → kernel-<soc> → kernel-export   modules/<release>/
dtb-src → dtb → dtb-export                                         boot/dtb/<device>@<id>.*
```

| Stage | Makes |
|---|---|
| `linux-sdm660-src` | the kernel source, `GlassineOS/linux` at the commit pinned in the Dockerfile (`LINUX_SDM660`), with a one-commit `.git` |
| `firmware-sdm660` | firmware the kernel depends on, from `linux-firmware` at pinned checksums: the Adreno 5xx CP microcode and the WCN3990's ath10k `firmware-5.bin`, each with its license. Never vendor files |
| `kernel-sdm660` | one compile for every device whose target names `kernel=sdm660`: `Image.gz`, the stripped modules with depmod's files, `firmware/` and `kernel.manifest` |
| `kernel-export` | `modules/<release>/`, the tree a device receives as its modules subvolume |
| `dtb-src`, `dtb` | one device's tree (`DEVICE`), from `DTB_COMMIT` (the kernel's commit unless set), so a fixed tree ships without a new kernel |
| `dtb-export` | `boot/dtb/<device>@<sha256-16>.dtb` and its `.manifest` |

The release is `<KERNELVERSION>-<flavor>.<cfg6>-g<commit12>`, with `cfg6` the first six
hex digits of sha256 over the final `.config` followed by the lines `builder=<image>@sha256:…`,
`firmware=` (`kernel.manifest`'s value) and `layout=` (the tree layout version in
`scripts/kernel.sh`), each ended by a newline. The builder is GlassineOS/builders'
`kernel-build`, pinned by its amd64 manifest digest, so the kernel stages run natively on
amd64 and through QEMU elsewhere. A kernel names no device tree; the two are paired by a
device's `select` record.

| File | What |
|---|---|
| `stages/kernel-<soc>/kernel` | the flavor, the source's defconfig and its config fragments (from `kernel/configs/` or `arch/arm64/configs/`, where kbuild finds them) |
| `stages/kernel-<soc>/build.config` | options this build sets over the source's configuration |
| `targets/<device>/target` | the device's target description: architecture, SoC, kernel stage, device tree |

Every option the fragments and `build.config` ask for must be in the final configuration,
or the build fails; an option a fragment turns off must exist in the source's Kconfig
files, so a misspelled or renamed one fails too. The kernel compiles in a cache mount
that holds a copy of the source and the objects: a new commit rebuilds only what it
changed, and an empty cache gives the same bytes. The mount is named after the builder's
digest, so a new builder starts from an empty one.

    docker buildx build --platform linux/arm64 --target kernel-export -o type=local,dest=out .
    docker buildx build --platform linux/arm64 --target dtb-export -o type=local,dest=out .
    scripts/kernel-check out              # the release, the manifests, every checksum
    scripts/kernel-check --partial out    # only one of the two exports in out/
    scripts/kernel-repro.sh repro         # two builds, the second from scratch: same bytes

The `kernel` workflow builds and checks these on changes to the kernel side; started by
hand it can also run the reproducibility check.

## Initramfs and boot image

```
boot-src + alpine → initramfs → initramfs-export           boot/initramfs/<commit12>@<id>.*
kernel + dtb + initramfs + boot-src → boot → boot-export   bootimg/<id>.*, select/<device>
```

| Stage | Makes |
|---|---|
| `boot-src` | GlassineOS/boot at the commit pinned in the Dockerfile (`BOOT_COMMIT`) |
| `initramfs` | boot's `build-initramfs.sh` in arm64 Alpine, with a locked package set (`stages/initramfs`). No board.conf and no kernel modules in it, so one initramfs serves every device |
| `initramfs-export` | `boot/initramfs/<commit12>@<sha256-16>.cpio.gz` and its `.manifest`: named by boot's commit and the content, since the locked tools also shape the bytes |
| `boot` | one device's boot image, packed by boot's `lib/glassine-bootimg-pack` |
| `boot-export` | `bootimg/<id>.img`, its boot record `<id>.manifest`, and `select/<device>`: the kernel, device tree and initramfs the device's update installs |

The packer takes every header value from `targets/<device>/board.conf`, the boot section
of the target description (GlassineOS/boot's board.conf, verbatim); no reference image
is read. It adds the board.conf to the ramdisk, refuses a kernel that isn't the release
its directory names, and fails when the image is larger than `PART_SIZE`. A change to the
initramfs repacks without touching a kernel layer, and a kernel change reuses the
initramfs.

    docker buildx build --platform linux/arm64 --target boot-export -o type=local,dest=out .
    scripts/boot-check out                # header values, parts, id, size, boot record

(`boot-check` also needs the kernel, device-tree and initramfs exports in `out`.)

## License

GPL-2.0-or-later (`LICENSE`). Images contain software under many licenses; each
package carries its own.
