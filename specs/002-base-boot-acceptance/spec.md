# Feature Specification: A built base boots as a deployment

**Feature branch:** `qemu-accept`
**Created:** 2026-11-08 · **Status:** Draft
**Builds on:** [001-base-build](../001-base-build/spec.md) · **Interfaces consumed:**
GlassineOS/boot [docs/deployments.md](https://github.com/GlassineOS/boot/blob/main/docs/deployments.md)
(the layout, `glassine-deploy`), boot's QEMU test harness (`test/qemu`) at the pinned
`BOOT_COMMIT` · **Ticket:** [hub#8](https://github.com/GlassineOS/hub/issues/8)
(Migration, step 2)

## Context

A base built by this repository is only useful if a device can boot it as a deployment,
live with it, and move away from it again. Before any device is involved, the base is
booted in QEMU on the arm64 virt machine with the same initramfs and the same deployment
tools a device uses, and taken through the deployment lifecycle. The device's kernel
doesn't run on the virt machine, so the guest uses a generic arm64 kernel and its
modules; everything above the kernel is the base as built.

The harness is boot's. This repository supplies the base and owns the scenarios that
say what a built base must survive.

## User scenarios

### Scenario 1 – The base comes up (P1)

**Given** a base built for the generic reference target (`device-example`), received
from its full stream into a test disk's system partition, with a deployment on it,
**When** the guest boots,
**Then** the deployment is the booted one, its root is the read-only overlay of the base
and its layers, the services the base enables (FR-019 of spec 001, and the startup and
shutdown runlevels) are started without error, the machine id is filled in, and the
boot-success step accepts the deployment.

### Scenario 2 – Live changes and the replay (P1)

**Given** the booted deployment,
**When** a package is added live and a file named by the migrate list is changed, and a
second base is received and staged,
**Then** the package list difference of the running deployment names the added package,
the switch at shutdown carries the migrate list and the accounts into the staged
deployment, and the staged deployment boots as the candidate with the change and the
machine id carried, and the added package replayed.

### Scenario 3 – Accept, roll back, reset (P1)

**Given** a candidate that booted,
**When** it is accepted, then a rollback to the previous deployment is selected, then a
reset is made,
**Then** each step boots the deployment it names, a rollback boots the previous one
with its own state, and a reset boots a fresh deployment on the base that keeps only
the migrate list.

### Scenario 4 – A failed candidate (P2)

**Given** a candidate that never reaches the boot-success step,
**When** it runs out of tries,
**Then** the next boot is the current deployment, and the candidate is marked failed.

### Scenario 5 – A clean power-off (P2)

**Given** any of the boots above,
**When** the guest powers off from the running system,
**Then** the next boot finds both file systems clean.

## Requirements

- **FR-001**: The test takes a base as built (its full stream and its build record) and
  never changes the base: whatever the test adds to the guest (its agent, test
  configuration) goes into the deployment's own layer.
- **FR-002**: The guest boots the pinned `boot` commit's initramfs with the board
  configuration of the deployments layout, and runs the `glassine-deploy` the base
  installs, not one from the harness.
- **FR-003**: The kernel and its modules are the generic arm64 kernel the harness
  provides, delivered as a modules subvolume as on a device.
- **FR-004**: Each scenario's outcome is a line per check on the console, and the test
  fails when any check fails or a boot doesn't power off within its time limit.
- **FR-005**: The second base of Scenario 2 is a build of the same target with one
  added file, received as a delta against the first base.
- **FR-006**: The test runs on a stock Linux computer with Docker, with privileged
  containers and arm64 emulation, and touches no device.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| Deployments layout, `glassine-deploy` | consumed (`boot`) | the base's installed version | `docs/deployments.md` |
| QEMU harness taking an outside base | consumed (`boot`) | `BOOT_COMMIT` | boot `test/qemu` |
| Artifacts folder, build record | owned | `format=1` | `docs/artifacts.md` |

## Device scope and risk

QEMU only. No device risk.

## Acceptance

- The test passes on a base built from a clean checkout, for the generic reference
  target.
- A base with a known defect fails it: one without a service the deployment needs, and
  one whose fstab leaves `/` writable.

## Out of scope

- The device's kernel, display, touch and radios; the graphical session (no panel in
  the guest).
- Hibernation (boot's own test covers it with its own base).
- Booting on a device (with the person's go, after this passes).

## Success criteria

- **SC-001**: Every scenario passes in one run, in under 30 minutes on a stock computer
  with arm64 emulation.
- **SC-002**: The test fails on each defect named under Acceptance.
