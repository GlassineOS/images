# Feature Specification: The PC installer drive

**Feature branch:** `installer-drive`
**Created:** 2026-11-27 · **Status:** Draft
**Builds on:** the PC's release (`scripts/pc-release`, [docs/artifacts.md](../../docs/artifacts.md)
"Releases", "Published PC releases") · **Interfaces consumed:** GlassineOS/boot
[docs/boot-partition.md](https://github.com/GlassineOS/boot/blob/main/docs/boot-partition.md)
(the layout, the recovery image, a kernel set's `initrd` and `set.rec`) and
[docs/boot.md](https://github.com/GlassineOS/boot/blob/main/docs/boot.md) (the boot-modules
archive) at the release's boot commit; GlassineOS/loader (the release's `boot-loader`);
GlassineOS/installer `glassine-install` and `devices/uefi-pc.toml` at the pinned
`INSTALLER_COMMIT` · **Interface owned:** the drive image and its entry in a published
PC release (below) · **Decisions:**
[0014](https://docs.glassine.org/decisions/0014-installation-and-provisioning/),
[0015](https://docs.glassine.org/decisions/0015-installer-stack/)

## Context

On a PC, GlassineOS is installed from removable media started on that PC: the installer
runs inside a GlassineOS live session, which also lets a person try GlassineOS before
installing it (decision 0015; installer spec 001, Scenario 5 and FR-017). The installer
drive is that medium: one disk image a person writes to a USB stick or another removable
disk as it is. It holds a PC release, the session that runs it and the installer, so an
install needs no network.

The drive has no settings of its own and nothing to prepare before it starts. Everything
an installation needs to know (the language, the keyboard, a network, the disk to install
on, whether another system is kept) is asked by the installer in the session, on the PC,
under the installer's own rules (installer spec 001).

The session is a release's base, read-only, with every change kept in memory: nothing it
does while it runs changes the system the drive carries. The installer in it is the
command line of GlassineOS/installer; a graphical front end is not part of the drive yet.

## User scenarios

### Scenario 1 – Try GlassineOS (P1)

**Given** a PC that starts from UEFI with Secure Boot off, and the drive image written to
a USB stick,
**When** the person starts the PC from the stick (the firmware's boot menu, or the
stick first in the boot order),
**Then** the firmware starts the GlassineOS loader from the stick's removable-media path,
the loader starts the session, and the first console shows a shell with what the drive
holds (the release, the installer) and how to install. No disk of the PC is written, and
nothing on the drive changes while the session runs.

### Scenario 2 – Install from the session (P1)

**Given** the running session,
**When** the person starts the install and answers the installer,
**Then** the installer installs the drive's release from the drive's own release folder
(no network), keeps its installation record and backup on the drive, and the PC then
starts GlassineOS from the disk it was installed on alone.

### Scenario 3 – The drive is never a target (P1)

**Given** the running session,
**When** the installer inspects the PC,
**Then** it names the drive as the disk it runs from, and a plan that would write to the
drive is refused.

### Scenario 4 – Secure Boot on (P2)

**Given** a PC whose firmware enforces Secure Boot,
**When** the person starts it from the drive,
**Then** the firmware doesn't start the drive's loader (it isn't signed), so no GlassineOS
code runs and nothing on the PC changes; the firmware says why in its own words, or goes
on to its next boot entry. Where the drive is offered (its release's notes, a download
page), it says that the drive starts only with Secure Boot off and that it is switched
off in the firmware's set-up.

### Scenario 5 – Find and check the newest drive (P2)

**Given** a web page or a tool that knows only this repository,
**When** it lists the published PC releases,
**Then** the newest one carries the drive image as an asset of its own, whose size and
SHA-256 the release's listing gives (and, for tools, its `release.json`), so the page can
offer it and the download can be checked before it is written to a stick.

## Requirements

### The image

- **FR-001**: One command makes the drive from a finished PC release folder (the folder
  `scripts/pc-release` makes, or a published PC release unpacked) and the installer at
  the pinned commit. It never builds or changes the base, and it checks every file of
  the release against `release.json` before it uses it.
- **FR-002**: The result is a raw disk image with a GUID partition table and 512-byte
  sectors, and a `SHA256SUMS` file beside it naming the image. Its partitions, in this
  order:
  1. `glassine-drive-esp`: type EFI system partition, FAT32, 128 MiB, laid out as boot's
     `boot-partition.md` gives a boot partition: the release's loader at the
     removable-media path, the session as the partition's only recovery image, the
     release's default splash, and no loader record (FR-004).
  2. `glassine-drive-data`: type Linux file system, ext4, label `glassine-drive`. It
     holds the release folder byte for byte under `release/<name>/`, the static
     `glassine-install`, the installer's `uefi-pc.toml` and its commit under
     `installer/`, and an empty `records/` for the installer's records and backups, with
     at least 1 GiB free.
- **FR-003**: No partition of the drive carries a name GlassineOS gives its own
  installation (`glassine-boot`, `glassine-system`, `glassine-userdata`), so no tool takes
  the drive for an installation. The disk's, the partitions' and the file systems'
  identities are derived from the release's `release.json`, so drives made from one
  release carry the same identities.

### The session

- **FR-004**: The drive's boot partition has no loader record, so the loader starts the
  recovery image it finds by itself and writes nothing to the drive (loader spec 001
  FR-008, FR-013, FR-019). That recovery image is the session: the release's kernel, and
  an `initrd` of the release's microcode archives, its initramfs, its boot-modules
  archive and the drive's own start archive, last. Its command line is the board's
  `CMDLINE`, `glassine.drive=UUID=<the data file system's UUID>`, the identity keys with
  the nil identity (`glassine.system=PARTUUID=00000000-0000-0000-0000-000000000000`, the
  same for `glassine.userdata=`) and `glassine.img=<id>`: no boot tool in the session
  finds a system partition or a userdata on any disk.
- **FR-005**: The start archive mounts the data partition read-only, the release's pool
  image read-only through a read-only loop device, and makes the root an overlay of the
  release's base with its upper layer in memory; the kernel's modules and firmware come
  from the pool's modules subvolume, as on an installed system. The drive's mounts are
  under `/run/glassine-drive/`. Nothing is written to the drive while the session runs,
  except by the install (FR-008) and the kernel's replay of the data file system's
  journal when an install was cut off. A start that fails says why on the console and stays
  in a shell there.
- **FR-006**: In the session none of GlassineOS's boot, deployment, update, hibernation
  or restart services runs: every OpenRC service of the base whose name starts with
  `glassine-` is taken out of the runlevels in the memory layer, save
  `glassine-font-cache`, and the drive's own service `glassine-drive` is added. A service
  the base adds later stays out until this list names it. The base's file system table
  line that locks a deployment's root read-only is left out in the memory layer: the
  session's root stays writable, its changes in memory.
- **FR-007**: The first console logs in as root by itself and greets the person with the
  release, the installer and the command `glassine-drive`, whose subcommands are
  `status`, `inspect` and `plan` (the installer's read-only commands on this PC) and
  `install`, and how a disk is chosen. Their options go to `glassine-install` unchanged.
  The first console shows the cursor.

### The install

- **FR-008**: `glassine-drive install` runs `glassine-install install --pc` from the
  drive's data partition (so the installer knows the disk it runs from by its program),
  with the drive's release folder and the installer's `uefi-pc.toml`. For that command
  only, the data partition is mounted read-write, and the installation record (with its
  inputs and kept files) and the backup go to `records/<time>/` on it; afterwards it is
  read-only again. What the installer asks, plans, refuses and needs confirmed is its
  own (installer spec 001); the session adds no answer and no default of its own. A
  backup larger than the drive's free space is the installer's case of a backup that
  doesn't fit where the person chose.
- **FR-009**: The installer refuses the drive as a target and as the place of a backup of
  a disk it writes (installer spec 001, edge cases; its inspection names the disk holding
  the running program). The session adds no way around it.

### Publishing

- **FR-010**: Where a PC release is published (docs/artifacts.md, "Published PC
  releases"), the drive made from that release folder is published with it, after it
  passed the test of FR-011: the image packed with xz, which common image writers read as
  it is, as its own asset `glassine-drive-<base-id>.img.xz` (the release's base id), listed
  in the release's `SHA256SUMS`; the release's notes give its unpacked size and sha256. The published
  `release.json` is the folder's with one more top-level key, `installer_drive`: the
  asset's `file`, `size` and `sha256`, the image's `image_size` and `image_sha256`, and
  `compression` (`xz`). The release folder's own `release.json` doesn't name the drive
  (the drive carries the folder).

### Testing

- **FR-011**: A QEMU test (OVMF, no Secure Boot) starts the drive image as a USB stick
  with a second, blank NVMe disk, has the session install on the blank disk, then starts
  the machine from that disk alone through its new firmware boot entry, and sees the
  first start select the first deployment and the next start boot it. In the session it
  also checks that the installer names the drive as the disk it runs from and refuses a
  plan onto it, and afterwards that the drive's boot partition is byte for byte as made
  and the record is on the data partition.
- **FR-012**: The test hook, for the test only: the kernel command-line word
  `glassine.drive.test=install:<serial>` makes the session, at its start, run the checks
  of FR-011 (the first console's shell, the greeting, the plan) and install on the disk with that serial number with `--developer`,
  answering the installer's confirmation itself, print the outcome on the console and
  power the machine off. It acts only on a disk whose serial number begins with
  `glassine-ci-` (QEMU's disks in the test). The word is on no drive as made: the test
  writes it into the session's `set.rec` (with its check line), as it adds the serial
  console.

## Contracts

| Contract | Owned / consumed | Version | Spec location |
|---|---|---|---|
| The drive image (partitions, names, contents) | owned | this spec | FR-002 |
| `installer_drive` in a published `release.json` | owned | this spec | FR-010 |
| Boot partition layout, recovery image, kernel set | consumed (`boot`) | the release's `layout_boot_commit` | `docs/boot-partition.md` |
| The loader | consumed (`loader`) | the release's `boot-loader` | loader spec 001 |
| `glassine-install install --pc`, `inspect`, `plan`, `uefi-pc.toml` | consumed (`installer`) | `INSTALLER_COMMIT` | installer spec 001, README |

## Device scope and risk

PCs only, x86-64, UEFI with Secure Boot off. Tested in QEMU with OVMF only, never on a
real PC. The session writes to a disk of the PC only through `glassine-install install`,
after the installer's confirmation. The drive's loader record is never written; a
firmware that refuses to start the loader leaves the PC as it was.

## Out of scope

- A graphical session and the installer's browser screens in a kiosk on the drive.
- Settings or answers on the drive made before it starts; unattended installs.
- Growing the data partition to the size of the stick.
- Downloading a newer release in the session; arm64 PCs.

## Success criteria

- **SC-001**: A drive made from a PC release passes the test of FR-011 before it is
  published.
- **SC-002**: A drive made twice from the same release carries the same identities
  (FR-003).
