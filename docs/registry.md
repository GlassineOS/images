# The registry

What CI publishes to the registry, under which names and keys, and how a build uses it
(specs/003-kernel-outputs-registry). `scripts/glassine_pins.py` computes the keys,
`scripts/glassine_registry.py` talks to the registry, `scripts/registry` runs the CI
steps and `scripts/build` uses the same code. This page owns the names, the keys and
the image layout, all at `format=1`: a key's definition, a name or an annotation never
changes within a format.

The registry is transport and cache only. A base is still a btrfs subvolume made on
the build computer (docs/artifacts.md), and losing what the registry holds costs time,
never correctness: every export can be built from source with the same bytes.

## What is published

The four exports a build makes besides the base, each in its own package, tagged with
its key:

| Export | Package | Holds |
|---|---|---|
| `kernel-export` | `ghcr.io/glassineos/images-kernel:<key>` | `modules/<release>/`: the kernel, its modules, its `linux-firmware` files, `kernel.manifest` |
| `dtb-export` | `ghcr.io/glassineos/images-dtb:<key>` | `boot/dtb/<device>@<id>.dtb` and `.manifest` |
| `initramfs-export` | `ghcr.io/glassineos/images-initramfs:<key>` | `boot/initramfs/<commit12>@<id>.cpio.gz` and `.manifest` |
| `boot-export` | `ghcr.io/glassineos/images-boot:<key>` | `bootimg/<id>.img` and `.manifest`, `select/<device>` |

and the layer cache of the stages each export is built from, as a BuildKit registry
cache (`mode=max`), at `ghcr.io/glassineos/images-cache:<export>`.

- **The image.** One OCI image manifest (no index, no provenance or SBOM) for the
  target's platform (`linux/<arch>`), with one layer: the export's files at the root,
  exactly as the export stage wrote them (paths, types, modes, contents; every time is
  0). Its digest is the sha256 of the manifest's bytes.
- **Annotations** on the manifest: `org.glassine.format` (`1`), `org.glassine.export`
  (the export's name), `org.glassine.key` (the key, as in the tag),
  `org.glassine.tree.<input>` for each git input in the key (its commit argument in
  lower case, such as `org.glassine.tree.linux_sdm660`; the value is the commit's tree,
  which a build that pulls the export records in place of fetching the commit), and
  `org.opencontainers.image.source`. Readers match annotation names without regard to
  case.
- **Readable without a login.** The packages are public. A package that isn't public
  reads as not published, and the build makes the export from source.
- **Published only by CI on `main`** (`.github/workflows/kernel.yml`, its `publish`
  job, the only one with write access to the packages). Pull requests, trials and
  builds on a person's computer never publish.
- **Kept.** A published key is never published again and never removed while any
  commit on `main` pins its inputs; nothing removes them. The cache may be dropped or
  overwritten at any time (each export's cache is replaced by its next build on `main`).
- **Nothing vendor-derived.** The kernel export carries only `linux-firmware` files,
  each pinned by its checksum in the `Dockerfile`; CI runs the device-file check
  (`scripts/device-files.c`) over all four exports before publishing.

`GLASSINE_REGISTRY` replaces `ghcr.io/glassineos` in every name above (tests point it
at a local registry).

## Keys

An export's key is the sha256 (64 hex digits, lower case) of a text that holds every
input that can change the export's bytes, and nothing else. `scripts/registry keys
TARGET` prints the keys, `--explain EXPORT` the text. The text has one line per item,
each ended by a newline, in this order:

```
format=1
export=<export>
stage=<instruction>          ...
platform=linux/<arch>        (only when one of those stages runs on the target's platform)
arg.<NAME>=<value>           ... sorted by name
file=<path> <x|-> <sha256>   ... sorted by the bytes of the path; or file=<path> -> <target>
in.<export>=<key>            ... sorted by export
```

- **The export's own stages** are the stages it is built from: its export stage and
  every stage that one reads (`FROM`, `--mount=...,from=`, `COPY --from=`), up to the
  other registry exports it takes in, which stand as their keys (`in.`). So the boot
  image's key holds the kernel's, device tree's and initramfs's keys, and the
  initramfs's holds no kernel input.
- **`stage=`**: each instruction of those stages, in `Dockerfile` order, as written
  (nothing expanded): continuation lines joined, runs of white space made one space,
  comments and blank lines left out. A recipe change is a key change; a comment isn't.
  The firmware's checksums are in the stage's `ADD --checksum=` lines.
- **`platform=`**: present when one of those stages starts from an image without a
  constant `--platform` (it runs on the target's platform, as the initramfs stage
  does). A stage on `$BUILDPLATFORM` must give the same files on every build platform
  (only fetch stages do so) and adds nothing, so an amd64 and an arm64 computer compute
  the same keys.
- **`arg.`**: each build argument those stages declare (`ARG`) or name in `FROM`, with
  the `Dockerfile` default, one level of `${X}` expanded, and the overrides of the build
  applied (`DEVICE` is the target). An argument declared without a default and not set
  is left out. These never change bytes and are left out:

  | Argument | Left out of | Why |
  |---|---|---|
  | `JOBS` | every key | parallel jobs: the same output |
  | `KCACHE` | every key | the id of the kernel's cache mount: an empty mount gives the same bytes |
  | `LOCK` | every key | check or refresh: a build that passes the check installs exactly the lock, which is in the key |
  | `LINUX_FIRMWARE` | every key | where the firmware is downloaded from: each file is pinned by its checksum |
  | `BOOT` | every key | where GlassineOS/boot is fetched from: the commit fixes the content, and no output names the address |
  | `LINUX` | `dtb-export` | `kernel.manifest` names the kernel's repository (`source=`), a device tree's record doesn't |
  | `LINUX_SDM660` | `dtb-export` | the device tree builds from `DTB_COMMIT` (which follows the kernel commit unless set apart) |
  | `KERNEL_BUILD_IMAGE` | `dtb-export`, `boot-export` | the digest fixes the builder; only `kernel.manifest` names it (`builder=`) |

  The table is `KEY_IGNORED` in `scripts/glassine_pins.py`; any other argument a stage
  declares is in the key.
- **`file=`**: every file of the build context those stages read (a bind mount without
  `from=`, a `COPY` or `ADD` source that isn't a URL), and every file under such a
  directory: its path in the checkout, `x` when its owner may execute it (the only mode
  bit git keeps; the others follow the computer's umask) and its sha256, or `->` and a
  symlink's target. Directories add no line. The files are read as they are in the
  checkout, so a change git doesn't know about yet (a trial) changes the key too.
- **What feeds which key**, for the reference `Dockerfile`: the kernel commit, its stage
  files (`stages/kernel-sdm660/`), `scripts/kernel.sh`, the builder's name and digest, the
  firmware's checksums and names and the kernel's repository: the kernel. The
  device-tree commit, `targets/<device>/target`, `scripts/kernel.sh`, the builder's
  digest and the device: the device tree. The boot commit, `stages/alpine/`,
  `stages/initramfs/`, `scripts/apk-stage.sh`, `scripts/initramfs.sh`, the repository key
  in `keys/`, the base image (`ALPINE`) and the platform: the initramfs.
  `scripts/bootimg.sh`, `targets/<device>/board.conf`, the device and the three other
  keys: the boot image. `scripts/git-fetch.sh` feeds all four. `scripts/test-registry.sh`
  checks each of these.

### Equal keys mean equal bytes

A key names bytes only if building its inputs again gives the same bytes. CI on `main`
publishes an export only after building it a second time from scratch (its own stages
without layer cache, the kernel with an empty cache mount) and finding both builds the
same byte for byte (`scripts/registry reproduce`, compared by `scripts/kernel-check
--compare`); an export whose second build differs is not published, and the workflow
fails. A run started by hand with `reproduce` builds every export again from scratch,
the pulled ones too, and compares them with what is published.

What the key does not hold, and what keeps it honest anyway:
- `ALPINE` is a tag, not a digest. The initramfs's packages are pinned by
  `stages/alpine/lock` and `stages/initramfs/lock`: a moved tag either installs the same
  packages or fails the lock check.
- Packages are named by version in the locks, not by checksum: the repository serving
  other bytes under a version a lock names would go unnoticed until the next
  comparison.
- The `# syntax=` frontend and the BuildKit version aren't in the key: an export's
  bytes come from the scripts inside its stages, which fix their own times and modes.

## Using the registry

`scripts/build TARGET` (docs/artifacts.md):

1. Computes each export's key, and asks the registry for `<package>:<key>` (`docker
   buildx imagetools inspect --raw`, anonymous for a public package). An answer whose
   annotations name another export or key is not used.
2. An export published under its key is pulled: a one-line build `FROM
   <package>@<digest>` exported to a directory, so BuildKit checks every blob against
   the digest the registry gave for the key. Then every time in it is set to 0, as the
   export stages leave them. A failed pull is tried again; the last failure ends the
   build.
3. An export built here takes in the pulled exports it reads in place of their stages
   (`--build-context <export>=docker-image://<package>@<digest>`), and reads its layer
   cache from `images-cache:<export>`.
4. `scripts/kernel-check` and `scripts/boot-check` run on all four, pulled or built.
5. The build record states for each export its key and where it came from
   (`export.<export>.key`, `export.<export>.from`, docs/artifacts.md).

The preflight asks the registry first, then fetches only the git inputs an export built
here needs; an input only pulled exports use isn't fetched (its tree comes from the
published export's annotation). Not published, a package that isn't public, or no
answer from the registry: the export is built here and the preflight says why; when its
source can't be fetched either, the preflight fails naming both. `--preflight-only`
prints which exports will be pulled and which built. `--no-registry` ignores the
registry and builds every export from source: the same bytes.

A trial (a changed build argument, a checkout with changes) changes the keys of exactly
the exports whose inputs it changes: those are built here, and the others are still
pulled. A local checkout of a git input (`scripts/build --local`) is a trial even at a
published commit: every export that reads one of that repository's inputs, and every
export that takes such an export in, is built here from the checkout without asking the
registry. A local checkout of `boot` builds the initramfs and the boot image here and
still pulls the kernel and the device tree.

## Building from source

Every fetch of a git input has a time limit and is tried again when it timed out or
failed for a network reason, with a growing pause; any other failure (a commit that
isn't there) ends at once. The final failure names the step, the repository and the
commit. In the stages that is `scripts/git-fetch.sh` (`GIT_FETCH_TIMEOUT`,
`GIT_FETCH_STALL`, `GIT_FETCH_TRIES`, `GIT_FETCH_PAUSE`); in the preflight and in
`scripts/registry`, `git_fetch` in `scripts/glassine_registry.py` (`GIT_TIMEOUT`,
`GIT_TRIES`).

The kernel's source is kept between builds on one computer, in the BuildKit cache mount
`glassine-src-linux`: a bare repository that keeps every fetched commit as
`refs/kept/<commit>`, so the next fetch of another commit transfers only the objects it
adds. `docker buildx prune` removes it; that costs time only.
