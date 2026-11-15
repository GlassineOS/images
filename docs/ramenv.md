# The RAM environment

(The [recovery](recovery.md) is built from the same daemon, init and device config, with
protocol version 3 on top; nothing below changes for the RAM environment.)

A small system that runs from RAM and serves a device's whole internal storage to a
computer over USB. It is read-only until the computer arms ranges for writing. It does
two jobs of an install from stock (installer spec 001): the full backup before the
install (FR-009), read-only, and then the install's writes to the disk: the partition
table and the system's partitions, in ranges the installer arms. The Onyx Boox Note Air
is the first device.

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
| `ramenv/targets/<device>.conf` | everything device-specific (below) |
| `stages/ramenv/packages`, `lock` | the locked build tools |

The kernel is the system kernel (`kernel-export`), with the device tree from
`dtb-export`; nothing is loaded as a module. A device needs a kernel with the USB
gadget, configfs, FunctionFS, its UDC, its eMMC host and its watchdog built in.

The image is not a boot update: the export has no `select/` record and nothing in
`bootimg/`.

## How it is started

On the Note Air the installer writes the image to the `recovery` partition with the
stock boot loader's fastboot (`flash:recovery`), next to the GlassineOS boot loader in
`abl`. The GlassineOS boot loader then starts it on its recovery path (`fastboot oem
reboot-recovery`; a closed cover at power-on enters fastboot, not recovery). That path boots an Android boot image of header version 0 with the
device tree appended to the kernel, which is what `scripts/ramenv-bootimg.sh` makes
(GlassineOS/boot's packer, with the header values of the target's `board.conf`; the
same header the recovery images this boot loader starts carry). The image has to fit
the partition: `RAMENV_RECOVERY_SIZE` (the Note Air's `recovery` is 131072 sectors of
512 bytes, 64 MiB, in the stock and in the A/B table) and the download limit; the
build refuses an image above either. An image of this build is about 13.5 MB.

`oem reboot-recovery` is one-shot (a reboot reason, not a record in `misc`): REBOOT
normal from the RAM environment, and its own reboots, start the normal system again.
The image stays in `recovery` until something else is written there.

A boot loader that can start an image over USB (`fastboot boot`) can also start it once
without writing it anywhere. Started that way, it writes nothing to the disks' contents
until it is armed. On a boot loader that keeps A/B slot
flags (Qualcomm's ABL, from its source: `CmdBoot`, then `LoadImageAndAuth` →
`FindBootableSlot`), it can change the active slot's flags in the partition table:

- the active slot is marked successful and not unbootable: nothing changes;
- it is marked unbootable: `boot` clears that bit, and the GPT is written;
- it isn't marked successful: a normal start lowers its retry count, but an image
  from fastboot skips that (`CmdBoot` sets `BootDevImage` first). With no retries
  left, the boot loader falls back to the other slot instead.

The GPT is written only where an attribute differs from the table on the disk
(`UpdatePartitionAttributes`). The installer reads the flags (`slot-successful:<s>`,
`slot-unbootable:<s>`, `slot-retry-count:<s>`) before it boots the image, and only goes
on unasked in the first case.

### Why the partition table is written from here

Both boot loaders (stock and GlassineOS) implement `flash:partition` (`WriteGpt`) by
erasing the whole eMMC first, so the partition table is never sent over fastboot. The
installer builds every byte of the new table (and of the partitions) itself and writes
it through this environment: the backup copy at the end of the disk first, then the
primary, each WRITE read back from the disk. The environment has no notion of
partitions: it only writes the byte ranges it was armed with.

## Device config

`ramenv/targets/<device>.conf`, sourced by `init`. It lives here, not in
`targets/<device>/`, because the boot stage reads that directory whole: a change to the
RAM environment must not change the system's boot image key.


| Key | Meaning |
|---|---|
| `RAMENV_DISKS` | `fnmatch` patterns over `/sys/block` names: the disks served (the Note Air: `mmcblk[0-9] mmcblk[0-9]boot[0-9]`, the user area and both boot areas) |
| `RAMENV_TRANSPORT` | `usb` (FunctionFS); the tests also use `stream` |
| `RAMENV_UDC`, `RAMENV_UDC_WAIT` | the UDC to bind (empty: the first) and how long to wait for one |
| `RAMENV_WATCHDOG`, `RAMENV_WATCHDOG_TIMEOUT` | the watchdog device and its timeout |
| `RAMENV_CMDLINE` | appended to the board's command line |
| `RAMENV_IMAGE_MAX` | the largest image the bootloader takes (`max-download-size`) |
| `RAMENV_RECOVERY_SIZE` | the size of the partition the image is written to (bytes) |

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
| 4 | u16 version (1 or 2) |
| 6 | u16 operation |
| 8 | u32 tag, echoed |
| 12 | u32 disk index |
| 16 | u64 offset |
| 24 | u64 length |

Response header, 64 bytes: `GRRS`, u16 version (the request's), u16 operation, u32 tag,
u16 status, u16 reserved, u64 payload length, u64 offset (echoed), the payload's sha256
(32 bytes; zero for text payloads; HASH puts its result here with no payload). Then the
payload.

| Op | Name | Host sends after the request | Payload |
|---|---|---|---|
| 1 | LIST | nothing | text: `glassine-ramread V` (the request's version), `max-read N`, `max-hash N`, `align 512`, version 2 only: `writes off` or `writes armed N`, then `disk INDEX NAME SIZE SECTOR` per disk |
| 2 | READ | nothing | the bytes of `[offset, offset+length)`; length ≤ 16 MiB |
| 3 | HASH | nothing | none; the sha256 of the range, read on the device, in the header; length ≤ 64 MiB |
| 4 | REBOOT | nothing | none; index 0 = normal reboot, 1 = to the bootloader |
| 5 | ARM (v2) | `length` bytes of text (≤ 16384): lines `range DISK OFFSET LENGTH` | text `armed N` (no newline) |
| 6 | WRITE (v2) | `length` bytes (≤ 16 MiB), then their sha256 (32 bytes) | 32 bytes: the sha256 of the range read back from the disk after the write reached it |
| 7 | DISARM (v2) | nothing | none |

Status: 0 ok, 1 bad request, 2 unknown operation, 3 no such disk, 4 bad range, 5 I/O
error, and in version 2: 6 not armed, 7 bad data, 8 already armed. An error's payload
is its reason as text. Offsets and lengths are multiples of 512 and lie inside the
disk.

A version 2 device answers version 1 requests exactly as version 1 did: under version 1
the operations are the four, LIST says `glassine-ramread 1` with no `writes` line, and
5, 6, 7 are unknown operations (their payload isn't read). A request of another version
is refused with status 1, answered as version 1.

ARM and WRITE carry bytes after the request. The device always reads all of them
(`length`, and the 32 for WRITE) before it answers, also when it refuses, so the next
request stays in step; a `length` above the limit is read and dropped too.

ARM, in detail:

- `DISK` is the index LIST gives or the disk's name; numbers are decimal; the fields
  are separated by one space; empty lines are ignored; at most 64 ranges.
- Each range is non-empty, a multiple of 512 and of the disk's sector, inside the disk;
  ranges on one disk don't overlap (adjacent is fine).
- Refused, with nothing armed: a text that doesn't parse, no range, more than 64, a text
  above 16384 bytes (status 1); no such disk (3); a range on a boot area
  (`mmcblk*boot*`), unaligned, empty, past the end, or overlapping (4); a disk that
  can't be made writable (5, every disk read-only again).
- ARM is taken once per start: a second one is refused with 8, also after DISARM. A
  refused ARM doesn't count.

WRITE, in the order checked: not armed (6); no such disk (3); empty, above 16 MiB,
unaligned, past the end, or not wholly inside one armed range (4: a write across two
adjacent armed ranges is refused too); the bytes' sha256 isn't the one sent (7, nothing
written). Then the bytes are written, flushed to the disk, and the range is read back
from the disk; the answer is the read-back's sha256, and the installer compares it with
its own. An error while writing is status 5 (the range may be partly written).

The host sends DISARM after its last WRITE, then REBOOT; REBOOT disarms first anyway.
DISARM with nothing armed is answered 0 and changes nothing.

Every READ carries the sha256 of its payload, computed on the device, so a transfer
error is found per chunk. After the copy the installer asks for HASH over the whole
disk range by range and compares, which also finds a disk that changed under the read.

## Read-only until armed

- Until ARM, nothing writes: WRITE is refused, any operation code but the seven is
  refused, and under version 1 there are only the four.
- Disks are opened `O_RDONLY`, and only block devices are served.
- Before serving, the daemon sets every served disk and each of its partitions
  read-only with `BLKROSET` and checks it with `BLKROGET`; every mmc disk (its user
  area and its boot areas) also gets `force_ro=1`. A disk that can't be made read-only
  isn't served.
- Nothing is mounted from the disks; the system lives in the initramfs.
- ARM makes writable only the whole-disk device of each disk it names: `force_ro=0`
  where the kernel has it, `BLKROSET 0`, `BLKROGET` must then say writable, and every
  partition of that disk must still say read-only; otherwise everything goes back and
  the ARM is refused. The partition devices and every other disk stay read-only. The
  boot areas (`mmcblk*boot*`) are never armed.
- Writes go through a second descriptor opened at ARM (`O_DIRECT` on a block device, so
  exactly the armed sectors are written, no page around them), then `fdatasync` (the
  eMMC's cache flush) and `BLKFLSBUF`; the read-back uses another `O_DIRECT`
  descriptor, so it comes from the disk, not from a cache.
- DISARM (and REBOOT) flushes and closes those descriptors, sets `BLKROSET 1` and
  `force_ro=1` again and checks every disk and partition is read-only.
- The partition table is never re-read: new partition devices would come up writable,
  and the device reboots after the install anyway.

What the kernel does with a read-only block device: a write through the device file
fails (`EPERM`), and a write open of it fails, so a read-write mount can't happen. A bio
written by the kernel itself only draws a warning (`bio_check_ro`), not a refusal; the
guarantee there is that nothing in the RAM environment writes.

The unit test checks the refusals and that the served files hold exactly the written
ranges afterwards; the QEMU test checks the kernel's read-only state of every disk and
partition before, while and after armed, and that writes to them fail.

## Watchdog and ending

A thread in the daemon opens the watchdog, sets its timeout (30 s on the Note Air) and
pets it every third of that. It stops petting, so the hardware resets the device, when
one disk read, hash or write (with its flush and read-back, and ARM and DISARM) runs
longer than 120 s (a stuck eMMC). The daemon reboots on its
own when no request came within 300 s of start, or none for 600 s after the last one.
`init` reboots when the daemon ends or the gadget can't be set up, and the kernel
command line has `panic=5`.

REBOOT to the bootloader uses the `reboot` system call with the `bootloader` argument
directly: busybox's `reboot` drops it.

## Tests

    scripts/test-ramenv.sh                 # unit test, the stage build, both QEMU runs
    scripts/test-ramenv.sh --unit-only

- `ramenv/test/unit.c`: the daemon over a socket pair, from three files (one stands in
  for a boot area by its name): sha256 vectors, the read-only open, every request
  field's bad values, all unknown operation codes under version 1 and 2, the v1 LIST
  byte for byte, every ARM and WRITE refusal (before ARM, boot area, alignment, the
  end, overflow, overlap, across two ranges, another disk, too long, bad sha256, a
  second ARM, after DISARM), good WRITEs answered with the read-back's sha256, the
  reboot hook; afterwards the armed file is the original plus exactly the writes and
  the other two are unchanged.
- QEMU arm64 (`ramenv/test/qemu-inner.sh`), the production initramfs plus a test shim,
  two virtio disks (one with a GPT and two partitions) and, in the usb run, QEMU's
  emulated eMMC with two boot areas and a GPT (the kernel's `mmcblk0`, `mmcblk0bootN`
  and `force_ro`):
  - `usb`: the real FunctionFS gadget on `dummy_hcd` inside the guest, read by a usbfs
    client; every disk read whole, sha256 compared with the image files. Then the
    writes: WRITE before ARM and ARM of each boot area refused; ARM by name; while
    armed only the armed whole disks are writable and writes to their partitions, the
    boot areas and the other disk fail; a new partition table for the virtio disk
    (backup copy, then primary), one WRITE of 16 MiB, 1 MiB on the eMMC, each answered
    with the read-back's sha256 and read again over READ; DISARM, after which every
    device is read-only and `force_ro` is 1 again. On the host the images must be the
    originals plus exactly those bytes (`cmp`), and the new table valid (`sgdisk -v`).
  - `stream`: the same protocol over virtio-serial to a client on the host.
  - `connect`: nobody connects; the environment reboots after its connect wait.
  - `wdreset`: a hash over a disk throttled to 64 KiB/s outlasts the operation limit;
    the reader stops petting and the emulated watchdog (i6300esb) resets the guest.
  - All check the kernel's read-only state of every disk and partition and that
    writes fail; the runs after usb leave the images as they were, and no write
    reached a read-only block device.
- Pinned bytes tie the daemon to the installer: a version 1 READ request and its
  response header (also in the installer's tests), and a version 2 WRITE request and
  its response header (for the installer's writer to pin the same way).

The QEMU guest runs Debian's arm64 kernel, because Alpine's kernels have no
`dummy_hcd`; only the test downloads it, nothing ships it.

Not covered by the tests: the device kernel's UDC, eMMC host and watchdog, the boot
loader's recovery path and `fastboot boot`, Windows' WinUSB binding, a browser's WebUSB,
and the installer's reader and writer against the daemon over a real transport (only
the pinned bytes tie them).
