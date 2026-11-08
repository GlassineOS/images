# Feature Specification: Building a base

**Feature branch:** `materialize`
**Created:** 2026-11-08 · **Status:** Draft
**Builds on:** the stage chain in `Dockerfile` · **Interfaces consumed:** GlassineOS/boot
[docs/deployments.md](https://github.com/GlassineOS/boot/blob/main/docs/deployments.md)
(bases, modules, `glassine-deploy receive`),
[docs/kernel-artifacts.md](https://github.com/GlassineOS/boot/blob/main/docs/kernel-artifacts.md)
(kernel, device tree, initramfs and boot records, the base manifest) · **Ticket:**
[hub#8](https://github.com/GlassineOS/hub/issues/8)

## Context

A device runs a base: a read-only btrfs subvolume holding a complete system, received
from a send stream. Kernel modules arrive the same way as their own subvolume. This
repository's stages produce the base's tree, the kernel's artifacts and the boot image.
This feature turns those exports into what a device receives (subvolumes and streams),
gives each base its identity, checks that the base and the kernel fit, and records how
each build was made, so that a build can be traced, compared with a commit and promoted.

One command does all of it for one target. Sending the result to a device is the
workspace's job (`dev`), which reads the records defined here.

## User scenarios

### Scenario 1 – Build a target from a clean checkout (P1)

**Given** a stock Linux computer with Docker and this repository at a commit,
**When** the developer runs the build command for a target,
**Then** it checks the host first, builds every export the target needs, runs the
kernel, boot and base checks, and leaves in the artifacts folder a base with its id, the
full stream, the modules stream for the kernel release, the boot image and select record,
and one build manifest. Any failed check fails the command and leaves no base behind.

### Scenario 2 – A small change gives a small delta (P1)

**Given** a base built earlier for the same target, with its full stream in the
artifacts folder,
**When** the developer changes one configuration file and builds again with that base as
the parent,
**Then** the command also writes a delta stream against the parent, and the delta
carries only what changed. Receiving the parent and then the delta gives the same tree
and the same received UUID as receiving the new full stream.

### Scenario 3 – Rebuilding the same inputs (P1)

**Given** a base built from some inputs,
**When** the same inputs are built again without any cache,
**Then** the tree is the same, so its id is the same, and the command reports that the
base exists rather than making a second one.

### Scenario 4 – A trial with an unmerged commit (P2)

**Given** a local checkout of the kernel fork or of `boot` at a commit not on main,
**When** the developer builds with that checkout in place of the pinned source,
**Then** the build uses that checkout's commit, and the manifest records the commit, its
tree, that it came from a local checkout and that the base is a trial. Such a base can
be sent to a device but can never be promoted.

### Scenario 5 – Promoting a base (P2)

**Given** a base built from pins that are on main (no local checkout),
**When** the maintainer promotes it at a commit of this repository,
**Then** the promotion succeeds only if each input's git tree in the manifest matches
that input's tree at main, and the base's manifest is committed under `promoted/`.

### Scenario 6 – A host that can't build (P2)

**Given** a host without arm64 emulation, without loop devices, short of disk space, or
unable to reach a pinned commit,
**When** the developer runs the build command,
**Then** it fails within seconds, naming what is missing, before any stage builds.

## Requirements

### The command

- **FR-001**: One command builds one target: preflight, the base export, the kernel,
  device-tree, initramfs and boot exports, their checks, materialization, the base and
  kernel fit check, and the build manifest, in that order. It writes into the artifacts
  folder (FR-020) and nowhere else.
- **FR-002**: It runs on a stock Linux computer with Docker. Materialization runs in a
  privileged container with loop devices on a temporary file system; it never touches a
  block device of the host or any device.
- **FR-003**: Only one materialization runs on a host at a time (a host lock).

### Preflight

- **FR-004**: Before any stage builds, the command checks, and fails within seconds
  naming the cause: arm64 emulation for the build, privileged containers and loop
  devices, free space for the build and the artifacts, every pinned commit reachable,
  the builder images pullable, each stage's lock present, a named parent's full stream
  and manifest present, and a clean checkout of this repository unless the build is a
  trial.

### Materialization

- **FR-005**: The base's tree is taken from a tar export of the last stage. The tar
  export keeps contents, file types, owners, modes, setuid and sticky bits, symlinks
  (dangling ones too), hardlinks, device nodes and FIFOs, extended attributes and file
  capabilities. A registry image is never the source of a base's tree.
- **FR-006**: The base becomes a read-only subvolume named by its id (FR-010), and the
  base manifest (FR-012) is written into it before it is made read-only. Its full send
  stream is written, compressed.
- **FR-007**: With a parent, the new base is a snapshot of the parent's subvolume
  (received from the parent's full stream) with the new tree synced in by content, so
  unchanged files stay shared even when their timestamps changed; a delta stream against
  the parent is written beside the full stream. Without a parent, only the full stream is
  written. The parent is named by the developer, or defaults to the last base built for
  the same target.
- **FR-008**: The kernel's `modules/<release>/` becomes a read-only subvolume named by
  the release, with its own full stream. It is skipped when the artifacts folder already
  holds a stream for that release.
- **FR-009**: Every subvolume made, and every tree received back from its streams (the
  full stream; the parent plus the delta), has the same content manifest as the tar
  export extracted onto a plain directory (with the base manifest added). The full
  stream and the parent plus delta give the same received UUID.

### Identity

- **FR-010**: A base's id is `<yyyymmdd>-<tree16>`: the build's date, and the first 16
  hex digits of the sha256 of the tree's content manifest. The content manifest lists
  every entry with its type, owner, mode, size, content hash or link target, hardlink
  group and extended attributes, and no timestamps; the base manifest is not part of it.
  Ids use only the characters a base name allows in `glassine-deploy`.
- **FR-011**: One tree is materialized once. When the artifacts folder holds a base with
  the same `tree16`, the command names that base and makes no new one: a second
  materialization would be a different subvolume, and a delta applies only to the exact
  subvolume it was made against.

### Records

- **FR-012**: The base manifest (`/usr/share/glassine/base.manifest`, defined by `boot`)
  holds `format`, `base` (the id), `locks`, `needs` and `features`. `locks` is computed
  as `boot` defines it from the locks of the target's stage chain.
- **FR-013**: The build manifest never enters the base. It is a `key=value` record with
  `format=1` and holds: the base id, target, tree hash, parent id, the subvolume's UUID
  and received UUID, the build time, this repository's commit and whether the checkout
  was clean, every build argument in effect (defaults and overrides), each git input's
  commit and tree and whether it came from a local checkout, each stage lock's sha256,
  the kernel release, the boot image id, the `boot` commit, the builder image digests,
  and `trial` and `unmerged` (the inputs whose commits are not on their main).
- **FR-014**: Beside the build manifest: the installed package list, the content
  manifest, and copies of the kernel manifest, the boot record and the select record.
- **FR-015**: The pins are the build arguments' defaults in `Dockerfile` and the stage
  locks. A change of pins is a change to those files. The manifest's view of the pins is
  derived from them and the overrides in effect.

### Trials and promotion

- **FR-016**: A source input (the kernel fork, `boot`) can be replaced for one build by
  a local checkout. The checkout must be clean; the build uses its commit; the manifest
  records `local` for that input and marks the base a trial.
- **FR-017**: Promotion takes a build manifest and a commit of this repository. It
  refuses a base with any `local` input, and it accepts the base only if each git
  input's tree in the manifest equals that input's tree at its main. It then commits
  the build manifest under `promoted/<target>/<id>/`.

### Validation

- **FR-018**: Inside the last stages, where the package manager is available: the
  package database is consistent (no changed or unowned files that a package claims, and
  installing the world again changes nothing), there is no font cache, `/etc/machine-id`
  is empty or absent, `/lib/modules/` and `/lib/firmware/updates/` are empty, `/etc/fstab`
  lists `/` as a read-only bind, the migrate list exists, and the tools `glassine-deploy
  receive` needs are installed.
- **FR-019**: On the export, outside any stage: no file left by the build environment
  (`/etc/resolv.conf`, a build host's `/etc/hosts`), the base manifest's `base` equals
  the subvolume's name, and the base and kernel fit: the select record's kernel, the one
  release under `modules/` and the boot record's kernel are the same release, and the
  initramfs's and base's `needs` are covered by the kernel's `provides` once the
  feature table exists.

### Artifacts

- **FR-020**: The artifacts folder holds, per target and base id, the build manifest and
  the files of FR-014, the base's full stream and any delta (named with its parent),
  and per kernel release its modules stream, with the boot image and its records. Full
  streams of earlier bases are kept so they can serve as parents.

### No drift

- **FR-021**: A base carries no cache or log the build regenerates on every run: no
  font cache (the device builds it at first boot), no package manager log, no
  machine id. Two builds of the same inputs give the same tree.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| Bases, modules, `glassine-deploy receive`, base names | consumed (`boot`) | `boot` at the pinned commit | `docs/deployments.md` |
| Kernel, device-tree, initramfs, boot and select records; base manifest | consumed (`boot`) | `format=1` | `docs/kernel-artifacts.md` |
| Build manifest and the artifacts folder layout | owned; read by the workspace's `dev` (has, next, live, send) and the hub | `format=1` | this spec, FR-013, FR-014, FR-020 |

## Device scope and risk

Device-neutral: every target with a stage chain. The command writes only to the host's
artifacts folder and never touches a device. No device risk.

## Acceptance

- Host tests, without a full build: materialization of a small fixture tree that holds
  one entry of each kind of FR-005, with and without a parent; FR-009's comparisons;
  FR-010's id from a known manifest; FR-011's refusal; the build manifest's fields.
- A full build of `onyx-noteair` from a clean checkout passes every check and writes the
  artifacts of FR-020; a second build with one changed file in the device stage writes a
  delta of that file; a third build of the same inputs without cache reports the
  existing base.
- Product level: receiving the streams on a device and booting the base are the
  workspace's and the acceptance suite's (a device and the person's go).

## Out of scope

- Sending streams to a device, and asking a device which bases it holds (workspace `dev`).
- Publishing stages or streams to a registry, and signing (later steps of hub#8).
- Removing old artifacts (a retention rule for the artifacts tool).
- Building on the device.

## Success criteria

- **SC-001**: A cached build of a target whose device stage changed, through
  materialization, finishes in under two minutes on a stock computer; the time of each
  step is reported.
- **SC-002**: A one-file change in the device stage gives a delta under 100 KiB
  compressed.
- **SC-003**: Two builds of the same inputs, the second without cache, give the same id.
- **SC-004**: Every comparison of FR-009 passes on every build; none is skippable.
