# Feature Specification: Kernel outputs from the registry

**Feature branch:** `kernel-registry`
**Created:** 2026-11-08 · **Status:** Draft
**Builds on:** [001-base-build](../001-base-build/spec.md) (the build command, preflight,
records, trials) · **Interface owned:** [docs/registry.md](../../docs/registry.md) (what
is published, under which keys) · **Ticket:** [hub#8](https://github.com/GlassineOS/hub/issues/8)
(GHCR, the kernel part of step 8)

## Context

A build makes four exports besides the base: the kernel (with its modules and the
firmware that goes with the kernel release), the device tree, the initramfs and the boot
image. They depend only on pinned inputs: the kernel and device-tree commits, the stage
files and scripts that build them, the builder image, the firmware checksums and the
`boot` commit. Building the kernel needs the kernel's source, a large repository, and a
long compile. Most builds keep the kernel as it is and change only the base.

CI on `main` already builds these exports for every pin. It publishes them to the
registry, with its layer cache, and a build on any computer whose inputs match uses what
was published instead of fetching the source and compiling. The registry is transport
and cache only: a base is still defined as a btrfs subvolume, and losing what the
registry holds costs time, never correctness.

## User scenarios

### Scenario 1 – A base build with an unchanged kernel (P1)

**Given** a clean checkout at a commit of `main` whose kernel-side inputs CI has
published, on a stock Linux computer with an empty layer cache,
**When** the person builds a target,
**Then** the four exports come from the registry, the kernel's source is never fetched
and nothing is compiled, the kernel and boot checks run on what was pulled, the build
record names the published outputs it used, and the result is byte for byte what a build
from source gives.

### Scenario 2 – The kernel's repository doesn't answer (P1)

**Given** the situation of Scenario 1,
**When** the host of the kernel's repository is slow or doesn't serve it,
**Then** the build succeeds as in Scenario 1.

### Scenario 3 – Nothing published for these inputs (P1)

**Given** a checkout whose kernel-side inputs have no published outputs (a pin moved and
CI hasn't finished, or the registry can't be reached),
**When** the person builds,
**Then** the preflight says so and why, the exports are built from source, each fetch of
the source has a time limit and retries, a failure names the repository and the step,
and the build record says the outputs were built on this computer.

### Scenario 4 – A trial (P2)

**Given** a kernel or `boot` trial (a local checkout, a changed build argument, or a
dirty tree, as in spec 001),
**When** the person builds,
**Then** published outputs are used only for exports whose inputs the trial doesn't
change, the changed ones are built on this computer, and nothing is published.

### Scenario 5 – A pull request (P2)

**Given** a pull request, from the project or from outside,
**When** CI builds it,
**Then** it may read the published outputs and cache, and it never publishes and has no
publishing credentials.

### Scenario 6 – Fetching the source again (P3)

**Given** a computer that fetched the kernel's source for an earlier build,
**When** a later build needs the source at another commit,
**Then** only what that commit adds is transferred.

## Requirements

### Keys

- **FR-001**: Each export has a key derived from every input that can change its bytes:
  for the kernel, the kernel commit, its stage files, the kernel build script, the
  builder image digest and the firmware checksums; for the device tree, the device-tree
  commit, the target's files and the builder image digest; for the initramfs and the
  boot image, the `boot` commit, their stage files and scripts, and the keys of the
  exports they take in. Inputs that don't affect an export are not in its key.
- **FR-002**: Equal keys mean equal bytes. The reproduce check in CI is what makes this
  hold, and an export whose rebuild differs is not published.

### Publishing

- **FR-003**: CI on `main` publishes each export it built under its key, after the
  kernel and boot checks and the device-file check pass, and the layer cache under a
  separate reference. A key that is already published is not published again.
- **FR-004**: Published exports stay available while any commit on `main` pins their
  inputs. The cache may be dropped at any time.
- **FR-005**: Published exports and the cache can be read without logging in.
- **FR-006**: Nothing vendor-derived is ever published (hub#8's firmware rule);
  `linux-firmware` files go with the kernel release.
- **FR-007**: Pull requests and trials never publish, and builds of pull requests have
  no publishing credentials.

### Using them

- **FR-008**: The build computes each export's key and uses the published export when
  one exists under that key; otherwise it builds the export from source. A pulled export
  is checked against the digest the registry gives for its key, and the kernel and boot
  checks run on it as on a local one.
- **FR-009**: The build record states for each export its key and either the published
  digest it used or that it was built on this computer.
- **FR-010**: The preflight finds out for each export whether it is published, and
  requires the kernel's source to be reachable only when an export that needs it will be
  built here. `--preflight-only` prints which exports will be pulled and which built.
- **FR-011**: A build can be told to ignore the registry and build everything from
  source; the result is the same bytes.

### Building from source

- **FR-012**: Every fetch of a git input has a time limit, and a fetch that times out or
  fails for a network reason is retried a few times with a growing pause. The final
  failure names the repository, the commit and the step.
- **FR-013**: The kernel's source is kept between builds on one computer, so a later
  fetch transfers only new objects (Scenario 6). Removing it costs time only.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| Published exports and their keys | owned | `format=1` | `docs/registry.md` |
| Artifacts folder, build record | owned (extended by FR-009) | `format=1` | `docs/artifacts.md` |
| Kernel, device tree, initramfs and boot records | consumed (`boot`) | as pinned | boot `docs/kernel-artifacts.md` |

## Device scope and risk

None: this changes where the exports come from, not what they are. The bytes a device
gets are the same.

## Acceptance

- A build of the first device from a clean checkout of `main`, on a computer with an
  empty layer cache and the kernel's repository blocked, passes and pulls all four
  exports.
- The same build with the registry blocked fails in the preflight with a message naming
  both (no registry, no source) and builds nothing.
- A `boot` trial (a local checkout of `boot`) builds the initramfs and the boot image
  here and still pulls the kernel and the device tree.
- A pull request's CI run publishes nothing.

## Out of scope

- Publishing the userspace stages and starting builds from them (the rest of hub#8 step
  8).
- Hosting bases or streams: a device still gets its stream from the person's computer.
- Mirrors of the registry.

## Success criteria

- **SC-001**: In Scenario 1 the four exports are ready in under 3 minutes on a stock
  computer with an ordinary home connection.
- **SC-002**: Pulled exports and exports built from source at the same inputs are byte
  for byte equal.
- **SC-003**: Scenario 2 passes with the kernel's repository unreachable.
