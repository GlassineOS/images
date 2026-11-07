# GlassineOS/images

System images of GlassineOS: the root file systems and boot images a device installs.
The design is [GlassineOS/hub#8](https://github.com/GlassineOS/hub/issues/8), and the
decision is record 0013 in [GlassineOS/docs](https://github.com/GlassineOS/docs).

**Status:** the root file system's stage chain builds. It doesn't make a base yet (a
Btrfs subvolume and its send stream), nor a kernel or a boot image. Most of
GlassineOS's own software isn't packaged yet either, so the tree isn't a usable system.

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
| `validation` | fails the build on what a base must not carry, including files only a device may supply (waveforms, signed firmware, any firmware; `scripts/device-files.c`, by contents); adds nothing |
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

    docker buildx build --platform linux/arm64 -o type=tar,dest=base.tar .

builds the default device's tree (`--build-arg DEVICE=<name>` for another). On an
amd64 computer, arm64 runs through QEMU (`docker run --privileged --rm
tonistiigi/binfmt --install arm64` once). Keep to the tar export: image exports drop
`user.*` extended attributes.

## License

GPL-2.0-or-later (`LICENSE`). Images contain software under many licenses; each
package carries its own.
