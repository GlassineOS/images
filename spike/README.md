# Spike: BuildKit to Btrfs

Step 1 of [GlassineOS/hub#8](https://github.com/GlassineOS/hub/issues/8): does a base
built from Dockerfile stages survive the trip to a read-only Btrfs subvolume and its send
streams, and do small changes give small deltas? Scratch code, not the stage chain: the
package lists are a realistic-size sample of Alpine packages, the device is fake, and
there are no lockfiles.

## Files

| File | What |
|---|---|
| `Dockerfile` | `alpine` → `glassine-common` → `eink` → `device-fake` → `validation` → `base-export` |
| `packages/<stage>.txt` | plain package names per stage (627 Alpine packages) |
| `device-fake/` | the device stage's files, `COPY`'d over the tree |
| `materialize.sh DIR ID [PARENT_ID]` | `DIR/base-ID.tar` → `bases/ID` subvolume, full stream, delta against the parent, receive and compare, timings. This is the existing content-sync method (tar → subvolume, snapshot the parent + `rsync --checksum`, `send -p`), written generically. It worked as it is, so no other materialization method was tried |
| `tree-manifest.py ROOT` | one line per entry: type, owner, mode, size, sha256 or link target, hardlink group, every xattr |
| `probe/` | the fidelity probe: one file of each kind a base must keep |

## Run

```sh
docker buildx build --platform linux/arm64 --target base-export \
    -o type=tar,dest=DIR/base-A.tar spike
spike/materialize.sh DIR A            # first base: full stream
# change something, build base-B.tar the same way, then
spike/materialize.sh DIR B A          # delta against A
```

`materialize.sh` runs a privileged container with loop devices on a tmpfs. Nothing
touches a device.

## Results

Measured on one amd64 computer with Docker 29 (buildx 0.38, containerd snapshotter),
arm64 under QEMU user emulation. Base: 22,156 entries, 863 MB tar, 857 MiB raw stream,
294 MB zstd.

### Fidelity

- The `tar` exporter keeps owners, modes, setuid and sticky bits, symlinks (dangling too),
  hardlinks, FIFOs, `security.capability` and `user.*` xattrs (probe, pax headers).
- GNU tar 1.35 and bsdtar 3.8 both restore all of them, caps included, when extracting as
  root with `--xattrs --xattrs-include='*'`.
- `COPY --from=<stage> / /` into `scratch` keeps all of them too.
- **Image layers do not:** the OCI export and an image loaded into Docker keep the
  capability but drop the `user.*` xattr. So a stage pulled from a registry may differ
  from the tar export. The base itself has no `user.*` xattrs today, but the check has to
  stay.
- Every tree the script makes (subvolume, received full stream, received parent + delta)
  has the same manifest as the tar extracted onto a plain directory. Full stream and
  parent + delta give the same Received UUID.
- Nothing from the build environment leaks in: `/etc/resolv.conf` is absent; `/etc/hosts`
  and `/etc/hostname` are `alpine-baselayout`'s. BuildKit mounts `resolv.conf` into every
  `RUN`, so a check for it inside a stage always fails: it has to run on the export.

### Deltas

Each case builds on the one before it (parent in brackets).

| Case | Build | Delta (zstd) | What the delta writes |
|---|---|---|---|
| A: first build, empty caches | 91 s | (full 294 MB) | |
| A2: no change, cached | 8 s | none: tar byte-identical to A | |
| A3: no change, `--no-cache`, download cache warm (A) | 101 s | 152 KiB | `etc/machine-id`, 12 fontconfig caches, `var/log/apk.log`; 5,973 `utimes` |
| B: one config file added in `device-fake` (A3) | 12 s | 4 KiB | that file |
| C: 2 packages added to `device-fake` (B) | 16 s | 1.8 MiB | their files, `world`, `installed`, `apk.log` |
| D: 1 package added to `glassine-common` (C) | 46 s | 1.0 MiB | its files, plus A3's drift: machine-id, fontconfig, ~6,000 `utimes` |

- **Rewritten timestamps don't defeat the delta**, because the sync compares content
  (`rsync --checksum`): a file with the same bytes and a new mtime costs one `utimes`
  record, about 25 bytes zstd'd. In case D the changed mtimes were on 2,943 symlinks and
  2,038 directories, which apk creates with the install time, and on 995 files. The
  files are generated ones (`passwd`, `group`, `shadow`, the apk database, caches);
  regular files from packages keep the package's mtime. `NORMALIZE_MTIME` exists in the
  script but wasn't needed.
- **Sharing:** after a delta the new base has 0.3–2.6 MiB exclusive on the receiving
  Btrfs, the rest shared with its parent (`btrfs filesystem du`).
- A rerun stage regenerates whatever its install scripts and triggers write. The bytes
  that differ are the machine-id, fontconfig's caches and apk's log.

### Times

| Step | Time |
|---|---|
| tar export of a cached base | 5.5 s |
| extract into a subvolume | 4 s |
| snapshot parent + content sync | 2–3 s |
| full stream | 2–3 s |
| delta stream | < 0.5 s |
| receive (full, or parent + delta) | 3–6 s |
| whole `materialize.sh`, with all three compares | ~35 s |

A device-config change goes from edit to verified delta in under a minute.

## Findings for the real stages

1. **`/etc/machine-id` is in the base**, filled in by dbus's install script, so every
   device on a base shares one ID. The current builder's base has the same problem, which
   is the comparison the issue asks for. `validation` should require it to be empty or
   absent, and the boot should create it.
2. `var/log/apk.log` and `var/cache/fontconfig` are build leftovers that change on every
   rerun. Drop the log in the last stage. Regenerate the fontconfig cache on the device,
   or accept the drift.
3. Checks for build-environment files (`resolv.conf`) run on the exported tree, not in a
   stage.
4. Materialization stays on `--output type=tar`. A registry stage is a cache, not a source
   for the tree, unless an export from it is shown to match the tar.

## Not covered here

- A native arm64 build (QEMU only).
- A real GHCR push. The OCI export stands in for it.
- `FROM alpine` against an empty root made with `apk --root`.
- `apk audit` or a database consistency check on the result. The three `apk` transactions
  across stages succeeded, nothing more was checked.
- Live `apk upgrade` and package replay on a base from these stages.
- A kernel stage.
