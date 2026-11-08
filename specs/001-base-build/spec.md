# Feature Specification: Building a base

**Feature branch:** `materialize`
**Created:** 2026-11-08 · **Status:** Draft
**Builds on:** the stage chain in `Dockerfile` · **Interfaces consumed:** GlassineOS/boot
[docs/deployments.md](https://github.com/GlassineOS/boot/blob/main/docs/deployments.md)
(bases, modules, `glassine-deploy receive`),
[docs/kernel-artifacts.md](https://github.com/GlassineOS/boot/blob/main/docs/kernel-artifacts.md)
(kernel, device tree, initramfs and boot records, the base manifest) · **Interface
owned:** [docs/artifacts.md](../../docs/artifacts.md) (the artifacts folder and the build
manifest) · **Ticket:** [hub#8](https://github.com/GlassineOS/hub/issues/8)

## Context

A device runs a base: a read-only btrfs subvolume holding a complete system, received
from a send stream. Kernel modules arrive the same way as their own subvolume, and the
boot image is written apart. This repository's stages produce the base's tree, the
kernel's artifacts and the boot image. This feature turns those exports into what a
device receives (subvolumes and streams), gives each base its identity, checks that the
base and the kernel fit, and records each build, so that a build can be traced, compared
with a commit and promoted.

Two identities, kept apart:
- A **base** is a tree. Its id follows from its content, and one tree is one base, made
  once, because a delta applies only to the exact subvolume it was made against.
- A **build** is one run for one target: a base (new or reused), a kernel release, a
  boot image, and the inputs they came from. Builds that differ only in the kernel or
  `boot` share a base and have their own records.

One command builds a target. Sending the result to a device is the workspace's job
(`dev`), which reads the records defined in `docs/artifacts.md`.

## User scenarios

### Scenario 1 – Build a target from a clean checkout (P1)

**Given** a stock Linux computer with Docker and this repository at a commit,
**When** the developer runs the build command for a target,
**Then** it checks the host first, builds every export the target needs, runs the
kernel, boot and base checks, and leaves in the artifacts folder the base (its full
stream, and a delta when it has a parent), the modules stream for the kernel release,
the boot image, and one build record naming all of them. Any failed check fails the
command and leaves nothing new behind.

### Scenario 2 – A small change gives a small delta (P1)

**Given** a build made earlier for the same target, its base's full stream in the
artifacts folder,
**When** the developer changes one configuration file and builds again,
**Then** the new base has the earlier build's base as its parent and a delta stream
against it that carries only what changed. Receiving the parent and then the delta
gives the same tree and the same received UUID as receiving the new full stream. The
build is a trial, because the checkout has an uncommitted change.

### Scenario 3 – Rebuilding the same inputs (P1)

**Given** a build made from some inputs,
**When** the same inputs are built again without any cache, on the same or a later day,
into the same artifacts folder,
**Then** the tree is the same, the build reuses the existing base (same id, no new
subvolume or stream) and writes a build record of its own.

### Scenario 4 – A kernel or boot trial (P2)

**Given** a local checkout of the kernel fork or of `boot` at a commit not on the
input's branch,
**When** the developer builds with that checkout in place of the pinned source,
**Then** the base is reused if its tree didn't change, the kernel or boot image is built
from the checkout, and the build record names the commit, its tree, that it came from a
local checkout, and that the build is a trial. The pinned build's record is untouched.
A trial can be sent to a device but never promoted.

### Scenario 5 – Promoting a build (P2)

**Given** a build of pinned inputs from a clean checkout,
**When** the maintainer promotes it at a commit of this repository,
**Then** promotion succeeds only if the checks of FR-018 hold, and the build record is
committed under `promoted/`.

### Scenario 6 – A host that can't build (P2)

**Given** a host without arm64 emulation, without loop devices, short of disk space, or
unable to reach a pinned commit,
**When** the developer runs the build command,
**Then** it fails within seconds, naming what is missing, before any stage builds.

## Requirements

### The command

- **FR-001**: One command builds one target: preflight, the base export, the kernel,
  device-tree, initramfs and boot exports, their checks, materialization, the base and
  kernel fit check, and the build record, in that order. It writes into the artifacts
  folder and nowhere else.
- **FR-002**: It runs on a stock Linux computer with Docker. Materialization runs in a
  privileged container with loop devices on a temporary file system; it never touches a
  block device of the host or any device.
- **FR-003**: Only one materialization runs on a host at a time (a host lock).

### Preflight

- **FR-004**: Before any stage builds, the command checks, and fails within seconds
  naming the cause: arm64 emulation for the build, privileged containers and loop
  devices, free space for the build and the artifacts, every pinned commit reachable,
  the builder images pullable, each stage's lock present, and the parent's full stream
  and record present and complete (FR-020).

### Materialization

- **FR-005**: The base's tree is taken from a tar export of the last stage. The export
  keeps contents, file types, owners, modes, setuid and sticky bits, symlinks (dangling
  ones too), hardlinks, device nodes with their numbers, FIFOs, extended attributes and
  file capabilities. A registry image is never the source of a base's tree.
- **FR-006**: A new base becomes a read-only subvolume named by its id (FR-010), and the
  base manifest (FR-012) is written into it before it is made read-only. Its full send
  stream is written, compressed.
- **FR-007**: A new base has a parent when the artifacts folder holds an earlier build
  of the same target: by default the base of the most recent build record by build time
  (which may be a base reused by that build), or one the developer names; the developer
  can also build without one. The new base is a snapshot of the parent's subvolume
  (received from the parent's full stream) with the new tree synced in by content, so
  unchanged files stay shared even when their timestamps changed, and a delta stream
  against the parent is written beside its full stream. A base has at most one delta,
  made when the base is made.
- **FR-008**: The kernel's `modules/<release>/` becomes a read-only subvolume named by
  the release, with its own full stream, unless the artifacts folder holds a complete
  stream for that release. In that case its content manifest must equal this export's,
  or the build fails.
- **FR-009**: Every subvolume made, and every tree received back from its streams (the
  full stream; the parent plus the delta), has the same content manifest as the tar
  export extracted onto a plain directory, with the base manifest added. The full stream
  and the parent plus delta give the same received UUID.

### Identity

- **FR-010**: A base's id is `<yyyymmdd>-<tree16>`. `yyyymmdd` is the UTC date of the
  build that first made the base. `tree16` is the first 16 hex digits of the sha256 of
  the content manifest followed by the base manifest's lines other than `base=`, so a
  change of `locks`, `needs` or `features` is a different base. The content manifest is
  defined in `docs/artifacts.md`: one line per entry with its path, type, owner, mode,
  size (regular files only), content hash, link target or device numbers, the first path
  of its hardlink group, and its extended attributes; no timestamps; sorted and escaped
  as defined there. Ids use only the characters a base name allows in `glassine-deploy`.
- **FR-011**: Within one artifacts folder, one tree is one base. A build whose tree
  matches a base of the same target reuses that base (no new subvolume or stream) and
  says so. In another artifacts folder the same tree, built on another day, gets another
  id: a different base with the same files.
- **FR-012**: The base manifest (`/usr/share/glassine/base.manifest`) is boot's: `format`,
  `base` (the id), `locks` as boot defines it from the locks of the target's stage chain,
  and `needs` and `features` from boot's feature table, empty while there is none.
- **FR-013**: A build's id is its UTC start time, `YYYYMMDD-HHMMSS`, with a `-N` suffix if
  that one is taken in the artifacts folder.

### Records

- **FR-014**: Every build writes a build record (the build manifest), even when it reuses
  a base. It never enters a base. Its keys are defined in `docs/artifacts.md`: the build
  and base ids, target, tree hash, parent, the subvolume's UUID and received UUID, the
  build time, whether the base was reused, this repository's commit and whether the
  checkout was clean, every build argument in effect (defaults and overrides), each git
  input's commit, tree, branch and whether it came from a local checkout, each stage
  lock's sha256, the kernel release, the boot image id, the `boot` commit, the builder
  image digests, `trial`, and `unmerged` (the inputs whose commits are not on their
  branch). Beside it: copies of the kernel manifest, the boot record and the select
  record.
- **FR-015**: Beside each base: its content manifest and its installed package list.
- **FR-016**: The pins are the build arguments' defaults in `Dockerfile`, each git input
  with the branch it follows, and the stage locks. A change of pins is a change to those
  files. The record's view of the pins is derived from them and the overrides in effect.

### Trials and promotion

- **FR-017**: A build is a trial when any of these holds: a source input came from a
  local checkout; a build argument differs from its `Dockerfile` default; the checkout
  of this repository has uncommitted changes to tracked files. The git inputs are the
  kernel source, the device-tree commit (same repository; it follows the kernel commit
  unless overridden) and `boot`. A local checkout must be clean; it replaces the fetched
  source of every stage that uses that repository, and its commit becomes the input's
  commit (a kernel checkout moves the device-tree commit with it unless that one is set
  apart). The record marks the input `local`.
- **FR-018**: Promotion takes a build record and a commit of this repository. It
  refuses a trial (FR-017), and it accepts the build only if the record's repository
  commit has the same tree as the given commit, and each git input's tree equals the
  tree of some commit on the input's branch. It then commits the build record under
  `promoted/<target>/<build-id>/`.

### Validation

- **FR-019**: Inside the last stages, where the package manager is available: the
  package database is consistent (the files packages installed are there and unchanged,
  and installing the world again changes nothing), there is no font cache, no account's
  shadow row carries a date of last change for a locked password, `/etc/machine-id` is
  empty or absent, `/lib/modules/` and `/lib/firmware/updates/` are empty, `/etc/fstab`
  lists `/` as a read-only bind, the base ships its migrate list, and the tools
  `glassine-deploy receive` needs are installed.
- **FR-020**: On the export, outside any stage: no file left by the build environment
  (`/etc/resolv.conf`; an `/etc/hosts` no package owns or that differs from its
  package's), the base manifest's `base` equals the subvolume's name, and the base and
  kernel fit: the select record's kernel, the one release under `modules/` and the boot
  record's kernel are the same release, the initramfs's commit is the pinned `boot`
  commit, and the base's and initramfs's `needs` are covered by the kernel's `provides`.
  That last check always runs; empty lists pass, as boot defines.

### Artifacts

- **FR-021**: The artifacts folder's layout is defined in `docs/artifacts.md`: per target,
  bases by id and build records by build id; per kernel release its modules stream; boot
  images, device trees and initramfs by their content ids. Every file is written under a
  temporary name and renamed when complete, so a cut build leaves nothing that looks
  complete. Full streams of earlier bases are kept, as later bases' parents.

### No drift

- **FR-022**: A base carries nothing the build regenerates with the run's time or
  randomness: no font cache (the device builds it at boot), no package manager log, no
  machine id, no build day in account rows. Two builds of the same inputs, on different
  days, give the same tree.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| Bases, modules, `glassine-deploy receive`, base names | consumed (`boot`) | `boot` at the pinned commit | `docs/deployments.md` |
| Kernel, device-tree, initramfs, boot and select records; base manifest | consumed (`boot`) | `format=1` | `docs/kernel-artifacts.md` |
| The artifacts folder, the build manifest, the content manifest | owned; read by the workspace's `dev` (has, next, live, send) and the hub | `format=1` | `docs/artifacts.md` |

## Device scope and risk

Device-neutral: every target with a stage chain. The command writes only to the host's
artifacts folder and never touches a device. No device risk.

## Acceptance

- Host tests, without a full build: materialization of a small fixture tree holding one
  entry of each kind of FR-005, with and without a parent; FR-009's comparisons; the id
  from a known manifest; a reused base with a second build record; a cut stream not
  taken as complete; the build record's keys.
- The same fixture passed through the build tool's tar export itself, compared with the
  fixture: what the export keeps (FR-005).
- A full build of the reference target from a clean checkout passes every check; a
  second build with one changed file in the device stage writes a delta of that file; a
  build of the same inputs without cache reuses the base. A drift check compares two
  no-cache builds made on different days, or with the build's clock moved.
- Product level: receiving the streams on a device and booting the base are the
  workspace's and the acceptance suite's (a device and the person's go).

## Out of scope

- Sending streams to a device, and asking a device which bases it holds (workspace `dev`).
- Deltas from more than one earlier base.
- Publishing stages or streams to a registry, and signing.
- Removing old artifacts (a retention rule for the artifacts tool).
- Building on the device.

## Success criteria

- **SC-001**: A cached build of a target whose device stage changed, through
  materialization, finishes in under two minutes on a stock computer; the time of each
  step is reported.
- **SC-002**: A one-file change in the device stage gives a delta under 100 KiB
  compressed.
- **SC-003**: Two builds of the same inputs into one artifacts folder, the second without
  cache and on another day, give the same base id.
- **SC-004**: Every comparison of FR-009 passes on every build; none is skippable.
