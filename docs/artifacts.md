# The artifacts folder

What `scripts/materialize` leaves for a target build (specs/001-base-build, FR-013,
FR-014, FR-020), and what the workspace's tools read to send a base to a device. The
build manifest's format is `format=1`; a key's meaning never changes within it, and
readers ignore keys they don't know.

```
<artifacts>/
├── <target>/
│   └── <base-id>/
│       ├── manifest                       the build manifest (below)
│       ├── packages                       the installed packages, name=version, sorted by bytes
│       ├── tree.manifest                  the content manifest the id is computed from
│       ├── kernel.manifest                copy of modules/<release>/kernel.manifest
│       ├── boot.manifest                  copy of the boot record bootimg/<id>.manifest
│       ├── select                         copy of the target's select record
│       ├── base.btrfs.zst                 the full send stream (zstd)
│       └── base.from-<parent-id>.btrfs.zst  the delta against the parent, when built with one
├── modules/
│   ├── <release>.btrfs.zst                the modules subvolume's full stream
│   └── <release>.manifest                 its content manifest (owner 0:0)
├── bootimg/
│   ├── <id>.img                           the boot image
│   └── <id>.manifest                      its boot record
└── boot/
    ├── dtb/<device>@<id>.dtb, .manifest
    └── initramfs/<commit12>@<id>.cpio.gz, .manifest
```

- **Base id:** `<yyyymmdd>-<tree16>`: the build's UTC date and the first 16 hex digits of
  the sha256 of `tree.manifest`. `tree.manifest` is written by `scripts/tree-manifest.py`
  on the tar export extracted onto a plain directory, before the base manifest is added.
- **One tree, one base:** a build whose `tree16` matches a base under `<target>/` makes
  nothing and names that base (exit 3). A delta applies only to the exact subvolume it
  was made against, so a tree is materialized once.
- **Streams:** each holds one read-only subvolume, named by the base id (by the release
  for modules), and is what `glassine-deploy receive` (`--modules` for modules) takes.
  The full stream and the parent plus the delta give the same tree and the same received
  UUID. Full streams stay: they are the parents of later builds.
- **Modules, boot images, device trees, initramfs** are named by their content (release,
  content ids), shared by every base that uses them, and written once: an existing name
  with other bytes fails the build.
- A directory under `<target>/` whose name starts with `.` is a build in progress, never
  a base. A failed build leaves none behind.

## The build manifest

`<target>/<base-id>/manifest`, `key=value`, one per line, first line `format=1`. It
never enters the base (the base carries its own base manifest,
`/usr/share/glassine/base.manifest`, defined by GlassineOS/boot's
`docs/kernel-artifacts.md`).

| Key | Value |
|---|---|
| `base` | the base id |
| `target` | the target |
| `tree` | sha256 of `tree.manifest` (64 hex) |
| `parent` | the parent base id, or empty |
| `uuid` | the base subvolume's UUID |
| `received_uuid` | the received UUID of the subvolume a stream gives (equals `uuid`) |
| `built` | the build's UTC time, `YYYY-MM-DDTHH:MM:SSZ` |
| `images_commit` | this repository's commit |
| `images_clean` | `yes` when the checkout had no changes to tracked files, else `no` |
| `locks` | the base manifest's `locks` |
| `lock.<stage>` | sha256 of `stages/<stage>/lock`, for every locked stage the base and the boot image are built from |
| `arg.<NAME>` | every build argument in effect: the Dockerfile's defaults with the overrides applied (the pins) |
| `input.<name>.commit`, `.tree`, `.local` | each git input's commit, its tree, and `yes` when it came from a local checkout |
| `builder.<image>` | each builder image's digest |
| `kernel_release` | the kernel release (`modules/<release>`) |
| `bootimg` | the boot image id |
| `boot_commit` | the GlassineOS/boot commit the initramfs is built from |
| `trial` | `yes` when an input came from a local checkout |
| `unmerged` | the inputs whose commits are not on their main, space-separated |
| `stream`, `stream_sha256` | the full stream's file name and sha256 |
| `delta`, `delta_sha256` | the delta's file name and sha256, or empty |
| `modules_stream`, `modules_stream_sha256` | the modules stream's path under `<artifacts>` and its sha256 |
