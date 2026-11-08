# Feature Specification: The first device runs a base from this repository

**Feature branch:** `device-complete`
**Created:** 2026-11-08 · **Status:** Draft
**Builds on:** [001-base-build](../001-base-build/spec.md),
[002-base-boot-acceptance](../002-base-boot-acceptance/spec.md) · **Interfaces
consumed:** GlassineOS/boot
[docs/kernel-artifacts.md](https://github.com/GlassineOS/boot/blob/main/docs/kernel-artifacts.md)
("Device data": the seed, `firmware_class.path`),
[docs/deployments.md](https://github.com/GlassineOS/boot/blob/main/docs/deployments.md)
(userdata, the migrate list), boot's developer mode (`glassine.devmode=usb`);
GlassineOS/packages `device-onyx-noteair` · **Ticket:**
[hub#8](https://github.com/GlassineOS/hub/issues/8) (Migration: the overlay sort, the
group that blocks a working boot; cutover step 1)

## Context

The Onyx Boox Note Air needs device-specific work at run time: firmware from its own
partitions, the modem's userspace, the sound routing, and storage for the person's files
on userdata; a developer also needs a way in. The base carries no firmware and nothing
personal, and vendor files are only ever read from the device itself, so all of this
comes from the products, never from the base's own files.

The products (the stages here, `boot` and `device-onyx-noteair`) provide what the device
needs, so that a base built here runs the device with its display, input, radios, sound
and storage working, and a developer can still reach it.

## User scenarios

### Scenario 1 – The device boots a base built here (P1)

**Given** a base and its kernel built here from a clean checkout, on a device whose
storage still holds its stock partitions,
**When** the device boots a deployment on that base,
**Then** the panel shows the session, touch and pen work, the GPU runs with the pinned
microcode, WiFi connects to a saved network, Bluetooth pairs, the speaker plays and the
microphone records, and the boot-success step accepts the deployment.

### Scenario 2 – The person's files are there (P1)

**Given** a device with `/home` and `/root` on userdata from an earlier base,
**When** it boots a deployment on a base built here,
**Then** the same `/home` and `/root` are mounted, Flatpak apps and their data are
there, and Flatpak apps can use the shared `/var/tmp`.

### Scenario 3 – A developer reaches the device (P1)

**Given** a kernel command line with `glassine.devmode=usb` and a public key in
`/root/.ssh/authorized_keys` on userdata,
**When** the device has booted,
**Then** a computer on the USB cable gets an address and logs in over SSH with that key,
and the device's host key is the same across deployments.
**And given** a command line without it, nothing listens on USB.

### Scenario 4 – A fresh seed (P2)

**Given** a device with no seed yet, or a seed missing a file,
**When** it boots,
**Then** the seed is filled from the device's own partitions, read-only, before the
drivers ask for their firmware, and the radios come up in that same boot.

### Scenario 5 – A modem that keeps crashing (P2)

**Given** a modem whose WiFi firmware crashes again right after each recovery,
**When** it has crashed three times within a minute,
**Then** WiFi is stopped and the modem stays up, the event is logged, and the display
and the rest of the system are not affected.

## Requirements

### Device firmware (owner: `boot` contract, `device-onyx-noteair` list)

- **FR-001**: A seed entry may name a path under `firmware/` and a name that differs from
  the source file's; names stay relative, without `..`. The seed format record in boot's
  `docs/kernel-artifacts.md` says so.
- **FR-002**: An entry may name every file of a split image (a `.mdt` and its numbered
  parts) by one pattern, which is resolved against the source when the seed is filled,
  and every resolved file is in the manifest.
- **FR-003**: The device's list covers what its kernel and daemons request: the modem
  and ADSP images, the WLAN DSP image and the WLAN board file, the Bluetooth firmware and
  its NV file, the speaker amplifier's three tuning files, the GPU zap shader, and the
  sensor registry. The sources are the device's `modem`, `bluetooth`, `vendor` and
  `persist` partitions, read read-only. The modem's file systems (`modemst1`,
  `modemst2`, `fsc`, `fsg`) are never seeded.
- **FR-004**: The kernel searches the seed's `firmware/` before its own paths: the
  board's command line sets `firmware_class.path`, and when a running kernel's command
  line lacks it, the seed service sets it before the device manager's coldplug.
- **FR-005**: Names the kernel requests carry no device abbreviation (the speaker
  amplifier's tuning files are fixed in the kernel's device tree).

### Kernel firmware (owner: this repository)

- **FR-006**: Redistributable firmware the radios need from `linux-firmware` (the WLAN
  firmware for WCN3990) goes with the kernel release, next to the GPU microcode, with a
  pinned checksum.

### Modem, radios and sound (owner: `device-onyx-noteair`, recipes in `packages`)

- **FR-007**: The modem userspace (`qrtr`, `rmtfs`, `tqftpserv`) comes from Alpine's
  packages; the modem's file systems are served from copies in memory and never written.
- **FR-008**: The DIAG-over-QRTR sink, without which the WLAN firmware takes the modem
  down, is a package of its own, named for what it does.
- **FR-009**: A device service brings up the modem, the ADSP, WiFi, Bluetooth and the
  sound card in order, routes the speaker and the microphone, and runs the crash-loop
  breaker of Scenario 5. Each step that fails is logged and does not stop the others.
- **FR-010**: A workaround for the sound server missing a card that appears late is
  documented where it is applied, with the condition that triggers it.

### Storage (owner: `boot`)

- **FR-011**: In the deployments layout, `/home` and `/root` are directories on userdata
  under the userdata prefix, outside the deployments, mounted before any service that
  uses them, the same for every deployment.
- **FR-012**: Flatpak's system data (`/var/lib/flatpak`) is on userdata the same way,
  and `/var/tmp` is a shared mount.

### Developer access (owner: `boot`)

- **FR-013**: With `glassine.devmode=usb` on the command line, the booted system keeps
  USB networking at the board's developer address and runs an SSH server that accepts
  only keys from `/root/.ssh/authorized_keys`. Without it, neither runs.
- **FR-014**: The SSH host keys are carried by the migrate list, so they stay the same
  across deployments; a deployment without them makes new ones.
- **FR-015**: No board configuration in this repository puts `glassine.devmode` on its
  command line.

### Checks (owner: this repository)

- **FR-016**: The base check refuses a base that holds any of the device's vendor files,
  by contents and by name (the existing device-file check covers the new names).
- **FR-017**: QEMU acceptance (spec 002) also checks the storage mounts of FR-011 and
  FR-012, and that developer access is off without `glassine.devmode`.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| Seed format, `firmware_class.path` | consumed (`boot`, extended by FR-001, FR-002, FR-004) | `format=1` | boot `docs/kernel-artifacts.md` |
| Deployments layout, migrate list | consumed (`boot`, extended by FR-011, FR-012) | `format=1` | boot `docs/deployments.md` |
| Developer mode | consumed (`boot`, extended by FR-013) | — | boot `README.md` |
| Device services and the seed list | consumed (`device-onyx-noteair`) | its package version | packages `device/device-onyx-noteair` |
| Kernel firmware in the modules subvolume | owned | `format=1` | `docs/artifacts.md` |

## Device scope and risk

The packages and stages change no partition. Putting the result on the device is a
separate run with the person's go: the device's current boot image is saved, the boot
image built here is written to `boot_b` once (kernel updates afterwards wait for the
block-list hand-off, hub#53), its modules are received, and the base is staged as a
candidate. Escape: the candidate falls back on its own after its tries; if the kernel
doesn't boot, closing the cover while powering on boots the recovery on its own
partition, from where the saved boot image is written back. The first seed fill writes
`glassine/` on `vendor_b` only; its stock files and every source partition stay
untouched.

## Acceptance

- Scenarios 1–3 pass on the device, and Scenario 4 after removing the seed.
- QEMU acceptance passes with FR-017's checks.
- The base check passes on the base and fails on one with a seeded file copied into it.

## Out of scope

The rest of the overlay sort, each with its disposition:
- touch long-press as right click: dropped (an X-era need);
- pen fix-ups, rotation from the accelerometer, the power daemon (sleep, power modes,
  lid), the Bluetooth address fix: device services, next group;
- the X session and its configuration, Firefox's phone UI files, themes and icons from
  the old overlay: dropped or moved to their own packages, next group;
- the container service: a package of its own, next group.

## Success criteria

- **SC-001**: On the device, every hardware function of Scenario 1 works within two
  minutes of power-on.
- **SC-002**: A base built here holds none of the device's vendor files (FR-016).
- **SC-003**: The device's own partitions read the same before and after a boot,
  except `glassine/` on `vendor_b`.
