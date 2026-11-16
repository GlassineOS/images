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
alpine → glassine-common → device-uefi-pc → finish → validation → base-export   (x86-64)
```

Two architectures: the Note Air's chain (and `device-example`) is arm64's, the generic
x86-64 UEFI PC's (`device-uefi-pc`) x86-64's. The same Dockerfile builds both; the
architecture is `--platform` (`linux/arm64`, `linux/amd64`), and a stage built for both
keeps a lock for each (below).

| Stage | Holds |
|---|---|
| `alpine` | Alpine 3.24 and its repositories, plus ours (`glassine-keys`) |
| `glassine-common` | what every GlassineOS system needs, whatever its display or device |
| `eink` | any e-ink device: the panel daemons, the compositor with the e-ink output, the keyboard, the desktop session and compressed swap with background-app parking (both enabled at boot) |
| `device-onyx-noteair` | the Onyx Boox Note Air's packages and system configuration, and its `targets/onyx-noteair/board.conf` as `/etc/glassine-bootimg/board.conf` (the board keys the booted system reads) |
| `device-uefi-pc` | a generic x86-64 PC that boots by UEFI, on `glassine-common` (no e-ink): the EFI system partition's tools (`dosfstools`), the firmware's boot entries (`efibootmgr`), and the power button (busybox's `acpid`, enabled at boot). Its kernel is `kernel-lts` (below), which also carries the firmware: the base has none |
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
| `lock` | the whole installed set after this stage on arm64, as `name=version` |
| `lock.x86_64` | the same on x86-64, for a stage built there (`alpine`, `glassine-common`, `device-uefi-pc`, `initramfs`, `kernel-lts`) |
| `rootfs/` | files copied over the tree (any stage). None may belong to a package |
| `expect` | a device stage's values its finished tree must hold, `FILE KEY=VALUE` per line (the file read as its programs read it); the validation stage checks them. The Note Air's: the partitions and the userdata reserve in `/etc/glassine/deploy.conf` |

**What goes where:** behavior goes in packages, which upgrade live. Configuration and
seeds go in a stage's `rootfs/` and change only with a new base. Applications aren't in
any stage, because people install them as live packages. Generic stages carry no device
names.

A new device is a new `device-<name>` stage on top of `eink` (or `glassine-common`),
and nothing above it changes.

## Locks

A stage installs exactly the versions its `lock` names (`scripts/apk-stage.sh`), so a
newer version in a repository changes nothing until the locks are refreshed. The pins
stay out of `/etc/apk/world`: a virtual package holds them during the install, the world
gets the stage's plain names, and the virtual goes, so a live `apk upgrade` moves on as
before. The build then compares everything installed with the lock and fails, saying to
refresh, on any difference (a package the stage pulls in that the lock lacks, a lock
line nothing needs any more). The lock is also an input of its stage, so a refreshed
lock rebuilds that stage and the ones after it.

    scripts/lock.sh                   # rebuild from scratch, rewrite every arm64 lock
    scripts/lock.sh --arch x86_64     # the same for x86-64: every lock.x86_64

`scripts/apk-stage.sh` reads the lock of the architecture it runs on (`apk --print-arch`):
`lock` on aarch64, `lock.<arch>` elsewhere, and fails naming the file when the stage has
none. Each architecture refreshes on its own, natively (through QEMU elsewhere), so a
refresh of one never moves the other's versions.

A locked version must still be offered. Our repository keeps every version for 30 days
after a newer one replaces it, and every version `main`'s locks name (GlassineOS/packages,
README "Earlier versions"), so our publishes don't break builds. Alpine's repositories
keep only the newest version of each package: when Alpine updates a locked package, the
build fails before installing anything, naming the lock line and the versions offered,
and the locks need a refresh. (Packages the `alpine:3.24` image already carries are
offered from its installed database; if that tag moves to a new point release, the same
applies.) A refresh upgrades those too, so a lock never keeps an outdated version just
because the Alpine image carries it; a check build then installs the newer locked version
over the image's.

The `lock-refresh` workflow refreshes every day, arm64's locks on an arm64 runner and
x86-64's on an x86-64 runner (a failed x86-64 refresh leaves its locks as they were and
says so in the pull request; arm64's goes on), and keeps one pull
request (branch `lock-refresh`) with the changed packages: on Mondays for any change, and
on any day when a change brings a fix from Alpine's security database or when a version
the current locks name is no longer offered (the build is broken until it merges). It
can also be started by hand. `scripts/lock-diff.sh` writes the pull request's
description, once per architecture. It pushes and opens the pull request with the token of the
`glassine-lock-refresh` GitHub App (variable `LOCK_REFRESH_APP_CLIENT_ID`, secret
`LOCK_REFRESH_APP_KEY`), so the pull request gets its checks. Without the app it falls
back to the workflow's own token, whose push and pull request start no checks; it then
starts `build`, `boot-qemu` and `safety` on the branch itself (their results show on the
commit and in Actions; closing and reopening the pull request puts them in its checks).

`scripts/test-apk-stage.sh` tests the install and the comparison in an Alpine container
on a made-up repository.

## Building

    scripts/build <target>

builds everything a device receives for a target (a directory under `targets/`): it
checks the host first and fails within seconds naming what is missing, builds the base's
tree, takes the kernel, device tree, initramfs and boot image from the registry when they
are published under their keys or builds them (docs/registry.md), checks them, and makes the
base and the build record with `scripts/materialize` (specs/001-base-build). The result
goes to `artifacts/` in the checkout (git-ignored; `--artifacts DIR` for another
folder), laid out as `docs/artifacts.md` defines; each run's log is kept under
`artifacts/.logs/<target>/`. `scripts/build --help` lists the options and the checks;
`scripts/test-build.sh` tests the checks without a build, `scripts/test-registry.sh` the
keys, the fetches and a registry round trip.

    scripts/build <target> --local BOOT_COMMIT=../boot

builds the kernel or `boot` from a clean local checkout instead of the pinned commit: a
trial, which can go to a device but is never promoted.

    scripts/build <target> --build-arg CMDLINE_EXTRA=glassine.devmode=usb

builds a developer boot image: the words are appended to the command line of this one
boot image (the boot record's `cmdline` and the board.conf the image carries say so),
while `targets/<target>/board.conf` stays as it is. A board's own `CMDLINE` never
carries `glassine.devmode` (GlassineOS/boot's rule: it gives anyone with a cable a root
shell), so a device test that needs the developer mode uses this. Setting it makes the
build a trial. `scripts/boot-check` fails a boot image whose command line carries
`glassine.devmode` unless it is told the build's words (`--cmdline-extra`, which
`scripts/build` passes); a build that isn't a trial never sets them.

    scripts/promote <build-id> [--at <commit>]

checks a build that is not a trial against a commit of this repository (default
`origin/main`) and the inputs' branches, and stages its record under `promoted/`
for a commit (`docs/artifacts.md`, "Promoted builds").

One stage on its own:

    docker buildx build --platform linux/arm64 -o type=tar,dest=base.tar .

builds the default device's tree (`--build-arg DEVICE=<name>` for another).

    docker buildx build --platform linux/amd64 --build-arg DEVICE=uefi-pc -o type=tar,dest=base.tar .

builds the x86-64 UEFI PC's. `scripts/build` doesn't build that target yet: it makes an
Android boot image and a device tree, which a PC has neither of; how a PC selects its
deployment is GlassineOS/boot's spec 010. On an
amd64 computer, arm64 runs through QEMU (`docker run --privileged --rm
tonistiigi/binfmt --install arm64` once). Keep to the tar export: image exports drop
`user.*` extended attributes.

## A release for the installer

    scripts/pool-image artifacts onyx-noteair --ramenv out-ramenv --recovery out-recovery

makes `artifacts/onyx-noteair/releases/<build-id>/`: `release.json` and the files it
names, the format GlassineOS/installer reads. The base goes as a **pool image**: a small
btrfs file system laid out by GlassineOS/boot's `glassine-deploy init` with the install
marker, the base received (read-only, with its received UUID, so updates arrive as
deltas) and the kernel's modules, which the installer writes to the system partition as
bytes and the first start grows to the partition. The boot image, the RAM environment
and the recovery go as they are. The boot loader and the partition layout aren't made
here: `targets/<target>/release.conf` pins them by URL and SHA-256 (GlassineOS/abl's
release, GlassineOS/installer's `layouts/`), and pool-image fetches them. Details: `docs/artifacts.md`, "Releases";
`scripts/test-pool-image.sh` tests it.

`scripts/test-first-start-qemu.sh` (CI: boot-qemu's `first-start` job) runs the route's
last step in QEMU: a release of the generic reference base, made by pool-image, written
to a virtual `system_b` beside a userdata that holds another system's ext4, booted bare.
The first start must grow the pool to the partition, format userdata (ext4, 4096-byte
blocks, no `orphan_file`, the Note Air's `USERDATA_RESERVE_KIB` free at its end, taken
from `stages/device-onyx-noteair/expect`) and select the first deployment, which boots
and is accepted. Its header says what differs from the device (the kernel, the base).

## Kernel and device trees

(For the x86-64 PC's kernel, see "The x86-64 kernel" below.)

Built apart from the root file system, to the contract in GlassineOS/boot's
`docs/kernel-artifacts.md`. A kernel change doesn't rebuild a base, and a base change
doesn't rebuild the kernel.

```
linux-<soc>-src + firmware-<soc> → kernel-<soc> → kernel-export   modules/<release>/
dtb-src → dtb → dtb-export                                         boot/dtb/<device>@<id>.*
```

| Stage | Makes |
|---|---|
| `linux-sdm660-src` | the kernel source, `GlassineOS/linux` at the commit pinned in the Dockerfile (`LINUX_SDM660`), with a one-commit `.git`; fetched by `scripts/git-fetch.sh` (time limits, tries again on network failures) through a repository kept in a cache mount, so a new commit transfers only what it adds |
| `firmware-sdm660` | firmware the kernel depends on, from `linux-firmware` at pinned checksums: the Adreno 5xx CP microcode and the WCN3990's ath10k `firmware-5.bin`, each with its license. Never vendor files |
| `kernel-sdm660` | one compile for every device whose target names `kernel=sdm660`: `Image.gz`, the stripped modules with depmod's files, `firmware/` and `kernel.manifest` |
| `kernel-export` | `modules/<release>/`, the tree a device receives as its modules subvolume |
| `dtb-src`, `dtb` | one device's tree (`DEVICE`), from `DTB_COMMIT` (the kernel's commit unless set), so a fixed tree ships without a new kernel |
| `dtb-export` | `boot/dtb/<device>@<sha256-16>.dtb` and its `.manifest` |
| `kernel-<soc>recovery`, `recovery-kernel-export` | the recovery's kernel: the same source, the system kernel's configuration with nothing as a module and what the recovery needs built in, no firmware; only the recovery's boot image reads it (docs/recovery.md, "The kernel") |

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
| `stages/kernel-<soc>recovery/` | the same for the recovery's kernel; `modules=no` in its `kernel` leaves out every module before its `build.config` is merged |
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

## The x86-64 kernel

    docker buildx build --platform linux/amd64 --build-arg KERNEL=lts --target kernel-export -o type=local,dest=out .

`kernel-lts` installs Alpine's `linux-lts` as a package, at the version its
`lock.x86_64` names, with the `linux-firmware` subpackages for common PC hardware (GPUs
of AMD and Intel, Wi-Fi and Bluetooth of Intel, Qualcomm Atheros, Realtek, Broadcom,
Cypress and MediaTek, Realtek's Ethernet; `stages/kernel-lts/packages` lists them) and
the CPU microcode (`linux-firmware-amd-ucode`, `amd-ucode`, `intel-ucode`). Decision
0016: firmware published for redistribution, as locked distribution packages, never
committed files. `scripts/kernel-package.sh` lays it out as kernel-export's
`modules/<release>/`: the modules and depmod's files, the image as `vmlinuz` (the EFI
stub), `firmware/`, `microcode/` and `kernel.manifest`.
- **firmware/** is what the packages installed in `/lib/firmware` (about 261 MB, already
  zstd-compressed by Alpine; a package's symlinks become hard links), bound on
  `/lib/firmware/updates` at boot like any kernel's. The packages carry no license
  files, so `firmware-licenses-pc` adds them from upstream at the packages' own tag
  (checked against its pinned commit): `WHENCE` (which license covers which file) and
  every license file at the top of the tree, plus the Debian copyright files of the two
  Raspberry Pi sources Alpine adds to `brcm/` and `cypress/` (pinned by checksum). The build fails when the packages' version isn't
  that tag (`LINUX_FIRMWARE_TAG`), so a lock refresh that moves `linux-firmware` needs
  the new tag's licenses. `kernel.manifest`'s `firmware` lists every file
  (`name@sha256-16`; a space in a name as `%20`, a `%` as `%25`), as a compiled
  kernel's does.
- **microcode/** holds the early microcode archives (`intel-ucode.img`,
  `amd-ucode.img`) and their licenses. The kernel loads microcode only early, from an
  uncompressed archive in front of the initramfs; nothing puts them there yet (the
  loader's job).
- NVIDIA's firmware (nouveau) isn't included yet.

Unlike a kernel compiled here, the release is the package's own (`6.18.63-0-lts`),
`source=` names the package and its version, there is no builder, layout or
configuration hash, and `scripts/kernel-check` (an arm64 compile's checks) doesn't
apply. The release doesn't follow the firmware: a lock refresh that moves only
`linux-firmware` gives a different `firmware/` (and `kernel.manifest`) under the same
release name.

`scripts/test-boot-qemu-x86_64.sh` (CI: boot-qemu's `boot-qemu-x86_64` job, with KVM)
boots the PC's base, this kernel and the initramfs built for x86-64 in
`qemu-system-x86_64` under UEFI firmware (OVMF starts the kernel's EFI stub;
`-kernel`/`-initrd`, no boot loader) through boot's outside-base harness, the same
lifecycle and the same `QTEST DONE` as the arm64 test, and checks that every boot
started under UEFI and loaded all of its boot modules. The kernel set's initramfs is the
release's initramfs, a board archive (the harness's partition names) and the kernel's
boot-modules archive (boot's `build-boot-modules.sh`: `linux-lts` builds its disk and
file system drivers as modules). No stage here assembles a PC's kernel set, so the test
does; on a PC that is the loader's and the installer's (GlassineOS/boot spec 010). Its
header says what else differs from a real PC.

## The registry

CI on `main` publishes the kernel, device-tree, initramfs and boot-image exports to
`ghcr.io/glassineos/images-*`, each under a key computed from every input that can
change its bytes, once a second build from scratch gave the same bytes, and the layer
cache beside them; anyone can read them without a login. `scripts/build` pulls an export
published under its key instead of fetching the kernel's source and compiling, and
builds the others; `--no-registry` builds everything. Names, keys and the image layout:
`docs/registry.md`.

    scripts/registry keys onyx-noteair             # each export's key
    scripts/registry keys onyx-noteair --explain kernel-export   # what went into it
    scripts/registry status onyx-noteair           # published under its key, or why not

## Initramfs and boot image

```
boot-src + alpine → initramfs → initramfs-export           boot/initramfs/<commit12>@<id>.*
kernel-export + dtb-export + initramfs-export + boot-src → boot → boot-export
                                                           bootimg/<id>.*, select/<device>
```

| Stage | Makes |
|---|---|
| `boot-src` | GlassineOS/boot at the commit pinned in the Dockerfile (`BOOT_COMMIT`) |
| `initramfs` | boot's `build-initramfs.sh` in arm64 Alpine, with a locked package set (`stages/initramfs`). No board.conf and no kernel modules in it, so one initramfs serves every device |
| `initramfs-export` | `boot/initramfs/<commit12>@<sha256-16>.cpio.gz` and its `.manifest`: named by boot's commit and the content, since the locked tools also shape the bytes |
| `boot` | one device's boot image, packed by boot's `lib/glassine-bootimg-pack` from the other three exports (a published export given as a build context stands in for building it) |
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

## RAM environment

A boot image that runs from RAM and serves the device's whole storage to a computer over
USB: read-only for the backup before an install, and writable only in the ranges the
installer arms (the partition table and the system's partitions). Built only with
`--target ramenv-export`; [docs/ramenv.md](docs/ramenv.md).

## Recovery

The GlassineOS recovery (GlassineOS/boot spec 008) is the RAM environment plus
glassine-deploy (boot's, at `BOOT_COMMIT`), diagnostics and a text menu on a USB serial
function. It speaks the RAM environment's protocol (versions 1 and 2 unchanged), so it
can stand in for it in an install. Protocol version 3 adds STATUS, DEPLOY (select, roll
back, reset, each confirmed by a token) and DIAG. It boots its own kernel, with everything built
in and no modules (`--target recovery-kernel-export`). It has no screen yet. Built only with
`--target recovery-export`; tested by `scripts/test-recovery.sh`;
[docs/recovery.md](docs/recovery.md).

## License

GPL-2.0-or-later (`LICENSE`). Images contain software under many licenses; each
package carries its own.
