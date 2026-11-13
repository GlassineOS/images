# The RAM environment

A small system that runs from RAM and reads a device's whole internal storage to a
computer over USB. Nothing on the device is written. It is for the full backup that
comes before an install (installer spec 001, FR-009) on devices that start a boot image
from their bootloader over USB (`fastboot boot`). The Onyx Boox Note Air is the first.

    docker buildx build --platform linux/arm64 --target ramenv-export \
        --build-arg DEVICE=onyx-noteair -o type=local,dest=out .

It is built only on request: a build without `--target` still ends at `base-export`.

```
alpine → ramenv ──────────────────────────────┐
kernel-export + dtb-export + boot-src ─────────┴→ ramenv-boot → ramenv-export
                                                   ramenv/<id>.img, <id>.manifest
```

| Part | What it is |
|---|---|
| `ramenv/glassine-ramread.c` | the daemon: serves the disks, holds the watchdog |
| `ramenv/init` | busybox `sh`: mounts, USB gadget, starts the daemon, binds the UDC |
| `ramenv/build.sh` | the initramfs: static busybox, the static daemon, init, the device's config |
| `scripts/ramenv-bootimg.sh` | the boot image, packed by GlassineOS/boot's `lib/glassine-bootimg-pack` |
| `targets/<device>/ramenv.conf` | everything device-specific (below) |
| `stages/ramenv/packages`, `lock` | the locked build tools |

The kernel is the system kernel (`kernel-export`), with the device tree from
`dtb-export`; nothing is loaded as a module. A device needs a kernel with the USB
gadget, configfs, FunctionFS, its UDC, its eMMC host and its watchdog built in.

The image is a boot image for starting once (`fastboot boot`), not an update: the
export has no `select/` record and nothing in `bootimg/`.

## Device config

`targets/<device>/ramenv.conf`, sourced by `init`:

| Key | Meaning |
|---|---|
| `RAMENV_DISKS` | `fnmatch` patterns over `/sys/block` names: the disks served (the Note Air: `mmcblk[0-9] mmcblk[0-9]boot[0-9]`, the user area and both boot areas) |
| `RAMENV_TRANSPORT` | `usb` (FunctionFS); the tests also use `stream` |
| `RAMENV_UDC`, `RAMENV_UDC_WAIT` | the UDC to bind (empty: the first) and how long to wait for one |
| `RAMENV_WATCHDOG`, `RAMENV_WATCHDOG_TIMEOUT` | the watchdog device and its timeout |
| `RAMENV_CMDLINE` | appended to the board's command line |
| `RAMENV_IMAGE_MAX` | the largest image the bootloader takes (`max-download-size`) |

## Protocol: a vendor bulk interface, not mass storage

The installer runs in a browser first (decision 0015), through WebUSB. Chromium refuses
to claim interfaces of protected classes, and mass storage is one of them, so a USB
mass-storage gadget can't be read from a browser at all. A vendor-class interface
(class `ff`, subclass `0x47`, protocol `0x52`) can, and the same code serves the native
installer through nusb. The interface carries a Microsoft OS 1.0 descriptor with the
compatible ID `WINUSB`, so Windows binds WinUSB without a driver package.

Mass storage would also hand the disk to the host's kernel, which may probe, mount or
write to it; a vendor interface is only read by the installer.

Little-endian. The host sends a request, the device answers with a header and a
payload. The host always asks for exactly the bytes still owed, so neither short
packets nor zero-length packets carry meaning.

Request, 32 bytes:

| Offset | Field |
|---|---|
| 0 | `GRRQ` |
| 4 | u16 version (1) |
| 6 | u16 operation |
| 8 | u32 tag, echoed |
| 12 | u32 disk index |
| 16 | u64 offset |
| 24 | u64 length |

Response header, 64 bytes: `GRRS`, u16 version, u16 operation, u32 tag, u16 status,
u16 reserved, u64 payload length, u64 offset (echoed), the payload's sha256 (32 bytes).
Then the payload.

| Op | Name | Payload |
|---|---|---|
| 1 | LIST | text: `glassine-ramread 1`, `max-read N`, `max-hash N`, `align 512`, then `disk INDEX NAME SIZE SECTOR` per disk |
| 2 | READ | the bytes of `[offset, offset+length)`; length ≤ 16 MiB |
| 3 | HASH | the sha256 of the range (32 bytes), read on the device; length ≤ 64 MiB |
| 4 | REBOOT | none; index 0 = normal reboot, 1 = to the bootloader |

Status: 0 ok, 1 bad request, 2 unknown operation, 3 no such disk, 4 bad range, 5 I/O
error; an error's payload is its reason as text. Offsets and lengths are multiples of
512 and lie inside the disk.

Every READ carries the sha256 of its payload, computed on the device, so a transfer
error is found per chunk. After the copy the installer asks for HASH over the whole
disk range by range and compares, which also finds a disk that changed under the read.

## Reads can't become writes

- There is no write operation. Any operation code but the four above is refused.
- Disks are opened `O_RDONLY`, and only block devices are served.
- Before serving, the daemon sets every served disk and each of its partitions
  read-only with `BLKROSET` and checks it with `BLKROGET`; the mmc boot areas also get
  `force_ro=1`. A disk that can't be made read-only isn't served.
- Nothing is mounted from the disks; the system lives in the initramfs.

What the kernel does with a read-only block device: a write through the device file
fails (`EPERM`), and a write open of it fails, so a read-write mount can't happen. A bio
written by the kernel itself only draws a warning (`bio_check_ro`), not a refusal; the
guarantee there is that nothing in the RAM environment writes.

The unit test checks the refusals and that the served file is unchanged afterwards;
the QEMU test checks the kernel's read-only state of every disk and partition and that
writes to them fail.

## Watchdog and ending

A thread in the daemon opens the watchdog, sets its timeout (30 s on the Note Air) and
pets it every third of that. It stops petting, so the hardware resets the device, when
one disk read or hash runs longer than 120 s (a stuck eMMC). The daemon reboots on its
own when no request came within 300 s of start, or none for 600 s after the last one.
`init` reboots when the daemon ends or the gadget can't be set up, and the kernel
command line has `panic=5`.

REBOOT to the bootloader uses the `reboot` system call with the `bootloader` argument
directly: busybox's `reboot` drops it.

## Tests

    scripts/test-ramenv.sh                 # unit test, the stage build, both QEMU runs
    scripts/test-ramenv.sh --unit-only

- `ramenv/test/unit.c`: the daemon over a socket pair: sha256 vectors, the read-only
  open, every request field's bad values, all unknown operation codes, the reboot hook,
  the file unchanged.
- QEMU arm64 (`ramenv/test/qemu-inner.sh`), the production initramfs plus a test shim,
  two disks (one with a GPT and two partitions):
  - `usb`: the real FunctionFS gadget on `dummy_hcd` inside the guest, read by a usbfs
    client; every disk read whole, sha256 compared with the image files.
  - `stream`: the same protocol over virtio-serial to a client on the host.
  - Both check the watchdog was armed, the reboot (by request and when idle), the
    images unchanged, and no write reached the block layer.

The QEMU guest runs Debian's arm64 kernel, because Alpine's kernels have no
`dummy_hcd`; only the test downloads it, nothing ships it.

Not covered by the tests: the device kernel's UDC and watchdog, the bootloader's
`fastboot boot`, Windows' WinUSB binding and a browser's WebUSB.
