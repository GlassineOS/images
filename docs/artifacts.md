# The artifacts folder

What a build leaves on the build computer (specs/001-base-build), and what the
workspace's tools and the hub read to send a build to a device. `scripts/materialize`
writes it. This page owns the layout, the build manifest, the base record and the
content manifest, all at `format=1`: a key's meaning never changes within a format, and
readers ignore keys they don't know.

Two identities are kept apart. A **base** is a tree: its id follows from its content,
and within one artifacts folder one tree is one base, made once (a delta applies only to
the exact subvolume it was made against). A **build** is one run for one target: a base,
new or reused, a kernel release, a boot image and the inputs they came from. Every build
has its own record.

## Layout

`scripts/build` writes `artifacts/` in the checkout unless given another folder. Its
work files (`.work-<pid>/`) and run logs (`.logs/<target>/<start>.log`) start with `.`
and are never artifacts.

```
<artifacts>/
├── <target>/
│   ├── bases/<base-id>/
│   │   ├── record                         the base record (below)
│   │   ├── base.manifest                  copy of the base manifest inside the base
│   │   ├── tree.manifest                  the content manifest (below)
│   │   ├── packages                       the installed packages, name=version, sorted by bytes
│   │   ├── base.btrfs.zst                 the full send stream (zstd)
│   │   └── base.from-<parent-id>.btrfs.zst  the delta against its parent, if it has one
│   └── builds/<build-id>/
│       ├── manifest                       the build manifest (below)
│       ├── kernel.manifest                copy of modules/<release>/kernel.manifest
│       ├── boot.manifest                  copy of the boot record
│       └── select                         copy of the target's select record
├── modules/
│   ├── <release>.btrfs.zst                the modules subvolume's full stream
│   └── <release>.manifest                 its content manifest (owner 0:0)
├── bootimg/<id>.img, <id>.manifest        boot images and their boot records
└── boot/
    ├── dtb/<device>@<id>.dtb, .manifest
    └── initramfs/<commit12>@<id>.cpio.gz, .manifest
```

- **Complete or absent.** Every file is written under a temporary name and renamed once
  complete; a base directory and a build directory are each assembled under a name
  starting with `.` and renamed as a whole. A name starting with `.` or ending in `.tmp`
  is never complete and is never read as an artifact. A base is complete when its
  `record`, `tree.manifest` and full stream are there and each stream's sha256 equals
  the one in its record; a base used as a parent or reused is checked this way first.
- **Streams** each hold one read-only subvolume, named by the base id (by the release
  for modules); they are what `glassine-deploy receive` takes (`--modules` for modules).
  The full stream and the parent plus the delta give the same tree and the same received
  UUID. A base has at most one delta, made with the base. Full streams stay: they are
  the parents of later bases.
- **Modules, boot images, device trees and initramfs** are named by their content
  (release, content ids), shared by every build that uses them and written once: an
  existing name with other bytes fails the build. A complete modules stream for a
  release is reused only when the export's content manifest equals `<release>.manifest`.
- **Parent of a new base:** by default the base of the newest build record of the target
  (by build id), which may be a base that build reused; or one named by its base id.

## Base id

`<yyyymmdd>-<tree16>`:

- `yyyymmdd`: the UTC date of the build that first made the base.
- `tree16`: the first 16 hex digits (lower case) of the sha256 of these bytes: the
  content manifest (`tree.manifest`, exactly as below), followed by the base manifest's
  lines other than its `base=` line, in their order in the base manifest, each ended by
  a newline. With `format=1` that is `format=1\nlocks=<locks>\nneeds=<needs>\nfeatures=<features>\n`.
  So a change of `locks`, `needs` or `features` is another base.

**Readers treat a base id as an opaque name.** They never parse, sort or compare its
parts: a time comes from a record's `built`, a tree from its `tree`. A delta finds its
parent by the received UUID, not by name. One reader doesn't follow this yet:
GlassineOS/boot's last-resort bare boot (no current deployment's base on the device)
takes the last base name in sort order (GlassineOS/boot#21). Until that changes, a new
id form must sort after the old ones.

A build whose `tree16` equals that of a complete base of the same target reuses it: no
new subvolume or stream. The base manifest
(`/usr/share/glassine/base.manifest`, GlassineOS/boot's `docs/kernel-artifacts.md`) is
written into the base, mode 0644, owner 0:0, before it is made read-only; it is not
part of the content manifest.

## The content manifest

The tar export extracted onto a plain directory as root (numeric owners, extended
attributes and capabilities kept), described by `scripts/tree-manifest.py`. One line
per entry, the tree's root included as `.`:

```
<path> <type> <uid>:<gid> <mode> <size> <what>[ =<first>][ <name>=<value>]...
```

| Field | Value |
|---|---|
| `path` | relative to the root, no leading `./`; the root is `.` |
| `type` | `-` regular file, `d` directory, `l` symlink, `c` character device, `b` block device, `p` FIFO, `s` socket |
| `uid:gid` | numeric |
| `mode` | the permission bits with setuid, setgid and sticky, 4 octal digits |
| `size` | a regular file's size in bytes; `0` for every other type |
| `what` | a regular file's sha256 (64 hex, lower case); `-> <target>` for a symlink, dangling or not; `dev <major>,<minor>` (decimal) for a device node; `-` otherwise |
| `=<first>` | only for an entry that is not a directory and has more than one hard link: the path of the group's first entry in manifest order (the first entry names itself) |
| `<name>=<value>` | every extended attribute (`security.capability` and `user.*` included), sorted by the bytes of the name; the value in lower-case hex |

Lines are sorted by the bytes of the raw path and each ends in a newline. In `path`,
`<target>` and attribute names, every byte outside `0x21`–`0x7e`, and the backslash,
is written as `\xHH` (lower-case hex); everything else as itself. No timestamps.

## The base record

`<target>/bases/<base-id>/record`, `key=value`, first line `format=1`.

| Key | Value |
|---|---|
| `base` | the base id |
| `tree` | the id's full sha256 (64 hex) |
| `parent` | the parent base id, or empty |
| `uuid` | the subvolume's UUID |
| `received_uuid` | the received UUID of the subvolume its streams give (equals `uuid`) |
| `build` | the build that made it |
| `stream_sha256` | sha256 of `base.btrfs.zst` |
| `delta` | the delta's file name (`base.from-<parent>.btrfs.zst`), or empty |
| `delta_sha256` | its sha256, or empty |

## The build manifest

`<target>/builds/<build-id>/manifest`, `key=value`, first line `format=1`. The build id
is the build's UTC start time `YYYYMMDD-HHMMSS`, with `-2`, `-3`, … when that one is
taken. The manifest never enters a base.

| Key | Value |
|---|---|
| `build` | the build id |
| `base` | the base id |
| `target` | the target |
| `tree` | the base id's full sha256 |
| `parent` | the base's parent, or empty |
| `reused` | `yes` when this build reused an existing base, else `no` |
| `uuid`, `received_uuid` | the base subvolume's UUID and received UUID |
| `built` | the build's start, `YYYY-MM-DDTHH:MM:SSZ` |
| `images_commit` | this repository's commit |
| `images_clean` | `yes` when the checkout had no uncommitted changes to tracked files and no untracked files git doesn't ignore (a stage's `COPY` reads those), `no` otherwise, empty when unknown |
| `trial` | `yes` or `no` |
| `trial_reasons` | why it is a trial, space-separated: `local:<input>`, `arg:<NAME>` (differs from the Dockerfile's default; never for the commit of an input marked `local`, which `local:<input>` covers), `dirty`, `clean-unknown` |
| `unmerged` | the inputs whose commits are not on their branch, space-separated; a local checkout's commit that its repository doesn't have (not pushed) is among them |
| `locks` | the base manifest's `locks` |
| `lock.<stage>` | sha256 of `stages/<stage>/lock`, for every locked stage the base and the boot image are built from |
| `arg.<NAME>` | every build argument in effect: the Dockerfile's defaults with the overrides applied (`DEVICE` is the target) |
| `input.<input>.commit` | a git input's commit; `<input>` is its commit argument (`LINUX_SDM660`, `DTB_COMMIT`, `BOOT_COMMIT`) |
| `input.<input>.tree` | that commit's tree (when no export built here fetched the commit, the tree a pulled export's annotation names, docs/registry.md) |
| `input.<input>.branch` | the branch it follows (the `# branch: <name>` line above the argument in `Dockerfile`) |
| `input.<input>.local` | `yes` when it came from a local checkout, else `no`. A checkout serves every input of its repository: a kernel checkout marks `DTB_COMMIT` too |
| `builder.<image>` | each builder image's digest |
| `export.<export>.key` | the key of each registry export (`kernel-export`, `dtb-export`, `initramfs-export`, `boot-export`), docs/registry.md |
| `export.<export>.from` | where that export came from: `<package>@sha256:<digest>`, the published export pulled under its key (the digest the registry gave for the key, which the pull was checked against), or `built` when it was built on this computer |
| `kernel_release` | the kernel release |
| `bootimg` | the boot image id |
| `boot_commit` | the GlassineOS/boot commit the initramfs is built from |
| `stream`, `stream_sha256` | the base's full stream, as a path under `<artifacts>`, and its sha256 |
| `delta`, `delta_sha256` | the base's delta, the same way, or empty |
| `modules_stream`, `modules_stream_sha256` | the modules stream, the same way |

A build is a trial when an input came from a local checkout, a build argument differs
from its `Dockerfile` default, or the checkout had uncommitted changes. A trial can be
sent to a device but is never promoted.

**A developer boot image.** `--build-arg CMDLINE_EXTRA=<words>` appends the words to
the command line of the build's boot image (such as `glassine.devmode=usb`, which a
board's `CMDLINE` never carries): the image is packed from a copy of the target's
`board.conf` whose last line is the longer `CMDLINE`, and its boot record's `cmdline`
and `board` describe that copy. The build record names it (`arg.CMDLINE_EXTRA`,
`trial_reasons` `arg:CMDLINE_EXTRA`). The boot image of a build that isn't a trial
carries no `glassine.devmode`: `scripts/boot-check` fails it otherwise.

**Local checkouts.** `scripts/build --local <NAME>=<DIR>` builds every input of a
repository from a clean checkout of it: the input's commit is the checkout's (`arg.*`
and `input.<input>.commit` name it), `input.<input>.tree` is that commit's tree, and
`input.<input>.local=yes` is what tells the build apart from one of the pinned source.
The records the build makes from that source keep the repository's URL:
`kernel.manifest`'s `source=<repository>@<commit>` is the pinned repository, since a
commit id names the same tree wherever it lies, and a path on the build computer would
mean nothing on another one.

## Promoted builds

`promoted/<target>/<build-id>/manifest` in this repository: the build manifest of a
promoted build, byte for byte. `scripts/promote` writes and stages it; the commit that
adds it is the promotion. A build is promoted at a commit of this repository only when:

- it is not a trial: `trial=no`, no `trial_reasons`, `images_clean=yes`, no input
  `local=yes`;
- its `images_commit` has the same tree as that commit;
- each git input's `tree` is the tree of a commit on its `branch` in its repository
  (the commit itself, or another one with the same files, such as a squash merge).

A promoted record never changes: promoting the same build again finds the same bytes.
Readers find the build's other files (the base, its streams, the modules stream, the
boot image) by the names this record holds, in an artifacts folder that has them.
