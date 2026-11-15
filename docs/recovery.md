# The recovery

The GlassineOS recovery (GlassineOS/boot `specs/008-recovery`) runs from RAM when
GlassineOS doesn't start, or when someone asks for it. It repairs the system with
`glassine-deploy`, the tool the running system uses: start another deployment, roll back,
reset, delete a deployment, and collect what went wrong.

The recovery is the [RAM environment](ramenv.md) plus deployments, resets, diagnostics and a
console. Spec 008 says "the RAM environment is the recovery without its screen, deployments
and resets". So it is built here from the same sources:

- the same kernel, device tree and packer;
- the same daemon, `glassine-ramread`, compiled with `-DGLASSINE_RECOVERY`;
- the same init;
- the same device config.

Status: built and tested in QEMU (below). It has not run on a device.

**This slice has no screen.** FR-006 (e-ink, touch and the power key) is the next slice.
There, the screen becomes a third client of the same core. Until then, a person reaches
the recovery through the text menu on the USB serial function, and a computer reaches it
over the vendor interface.

    docker buildx build --platform linux/arm64 --target recovery-export \
        --build-arg DEVICE=onyx-noteair -o type=local,dest=out .

```
alpine → recovery (+ boot-src at BOOT_COMMIT) ──────────────┐
kernel-export + dtb-export + boot-src ───────────────────────┴→ recovery-boot → recovery-export
                                                                 recovery/<id>.img, <id>.manifest
```

| Part | What it is |
|---|---|
| `ramenv/glassine-ramread.c` with `-DGLASSINE_RECOVERY` | the core: protocol version 3, the local socket, the deploy partitions' write window |
| `ramenv/init` | the RAM environment's init; with `/etc/glassine/recovery.version` it also does the recovery's part (below) |
| `ramenv/recovery/status`, `describe`, `deploy`, `diag` | the tools the core runs (busybox `sh`): glassine-deploy's state, what an action does, the action, the diagnostics |
| `ramenv/recovery/menu`, `glassine-rcall.c` | the console: a text menu, and its client of the core |
| `ramenv/build.sh --recovery BOOT COMMIT` | the initramfs: the RAM environment's, plus the above, plus glassine-deploy |
| `scripts/ramenv-bootimg.sh` (`ROLE=recovery`) | the boot image, packed like the RAM environment's, into `recovery/` |
| `stages/recovery/packages`, `lock` | the locked build tools and the binaries copied in (e2fsprogs, btrfs-progs) |

`glassine-deploy` and its libraries come from GlassineOS/boot at `BOOT_COMMIT`. That is the
pin the boot initramfs uses, so the recovery never runs a glassine-deploy other than the
one the system's boot was built with. The image holds:

- `/sbin/glassine-deploy`;
- `/usr/lib/glassine-boot/glassine-{state,root,accounts}.sh`;
- e2fsck, debugfs, dumpe2fs and btrfs, with their libraries and musl's loader.

`/etc/glassine/recovery.version` names the boot commit, the device and a build hash.

The manifest adds `role=recovery`, `boot_commit=` and `protocol=3`. The image has to fit
the same limits as the RAM environment's: `RAMENV_IMAGE_MAX` and `RAMENV_RECOVERY_SIZE`.
On the Note Air the initramfs is about 2.8 MB, against 0.7 MB for the RAM
environment's, and the boot image is 15.6 MB, well inside the 64 MiB `recovery`
partition.

Like the RAM environment, it loads no module. The system kernel at the pinned commit
has everything the recovery uses built in: USB gadget, FunctionFS and the ACM function,
btrfs, ext4, overlayfs, the qcom watchdog, ramoops (checked in that kernel's
`modules.builtin`).

## One image for install and recovery

The recovery serves the installer's `ram-environment` role unchanged:

- the USB interface is the same (vendor class `ff/47/52`, interface 0, the same
  descriptors);
- versions 1 and 2 of the protocol are answered byte for byte as the RAM environment
  answers them. The unit test `unit.c` passes against both builds, and the QEMU usb run
  replays the RAM environment's whole read and write plan against the recovery.

Two things differ:

- the recovery adds a USB serial function as interface 1 and up (`RECOVERY_USB_SERIAL`);
- its product string is "GlassineOS recovery".

The installer finds the interface by its class, not by its number or name, so neither
change matters to it.

The installer's install writes `abl`, then `recovery`, then starts `recovery` to make the
partition table and write the system. Its `recovery` image can be this image. Its last step,
write-recovery, then has nothing left to write: the recovery is already in place, and is
what an installation is complete with (spec 008, Summary). The installer's
`ram-environment` role and its `recovery` role become one artifact. That change is the
installer's and the release's (`release.json` today names `ram-environment`, and
`recovery` as missing). It isn't made here. `scripts/pool-image --ramenv DIR` reads
`DIR/ramenv/`, the RAM environment's export; publishing the recovery under that role
needs it to read `recovery-export`'s `DIR/recovery/` as well.

## The recovery's start

`ramenv/init` does what the RAM environment's init does. When the image holds
`/etc/glassine/recovery.version`, it also:

1. finds the partitions named by `RECOVERY_SYSTEM_LABEL` and `RECOVERY_USERDATA_LABEL`.
   There is no udev, so it reads `PARTNAME=` in `/sys/class/block/*/uevent`. It waits up
   to `RAMENV_DISK_WAIT` for a disk to appear, then 5 s more for the labels. A disk
   without them (the stock table, during an install) doesn't hold the start up: the
   recovery serves without `--deploy-part`, STATUS says there is no deployment, and a
   DEPLOY is refused by the tools before any partition is made writable;
2. writes `/etc/glassine/deploy.conf` for glassine-deploy. It names the devices
   themselves (`SYSTEM_DEV=/dev/mmcblk0p50`), `USERDATA_PREFIX` and the mount points under
   `/run/glassine`;
3. starts the daemon with:
   - `--tools /lib/glassine-recovery`;
   - `--socket /run/glassine-recovery.sock`;
   - `--deploy-part` for each partition it found;
   - `--idle` and `--connect-wait` set to `RECOVERY_IDLE`;
   - `--tool-limit RECOVERY_TOOL_LIMIT`;
4. with `RECOVERY_USB_SERIAL=yes`, links an `acm` function into the gadget after the
   vendor function, which stays interface 0 because its Microsoft OS descriptor names
   interface 0;
5. runs the menu on each terminal in `RECOVERY_TTYS` (`ttyGS0`, `console` for
   `/dev/console`, ...), and starts it again when it ends.

Device config keys, in `ramenv/targets/<device>.conf` next to the `RAMENV_*` keys:

| Key | Meaning |
|---|---|
| `RECOVERY_SYSTEM_LABEL`, `RECOVERY_USERDATA_LABEL` | the GPT names of the system partition and userdata (the Note Air: `system_b`, `userdata`, as in boot's `deploy.conf`) |
| `RECOVERY_USERDATA_PREFIX` | glassine-deploy's `USERDATA_PREFIX` (`media/glassine`) |
| `RECOVERY_IDLE` | seconds with no request from any client before the normal start (600) |
| `RECOVERY_TOOL_LIMIT` | seconds a glassine-deploy run may take (900) |
| `RECOVERY_USB_SERIAL` | `yes`: the menu's USB serial function |
| `RECOVERY_TTYS` | the terminals the menu runs on (the Note Air: `ttyGS0`; it has no other text console) |

How the recovery is started (FR-002) is the RAM environment's way. On the Note Air that
is `fastboot oem reboot-recovery`, a one-shot reboot reason. Two other ways in aren't
built:

- a start from the running system (`reboot recovery`);
- the fallback when the boot's tries run out.

Both belong to the boot loader and the board (see "Left for later").

## Protocol version 3

Version 3 is version 2 plus three operations. The request and response formats are the
RAM environment's ([ramenv.md](ramenv.md#protocol-a-vendor-bulk-interface-not-mass-storage)).
The response carries the request's version.

| Op | Name | Host sends after the request | Payload |
|---|---|---|---|
| 1–7 | as in version 2 | | LIST's first line is `glassine-ramread 3` |
| 8 | STATUS | nothing | text (below) |
| 9 | DEPLOY | `length` bytes of text (≤ 4096): the request (below) | text: `exit N`, then glassine-deploy's output; or, with status 9, `confirm TOKEN` and what the action does |
| 10 | DIAG | nothing | the diagnostics file (a gzip'ed tar, ≤ 16 MiB), its sha256 in the header |

New statuses:

- 9: the operation needs a confirmation;
- 10: the tool failed. The payload is `exit N` and its output.

Every other status means what it means in version 2.

- 1 is a DEPLOY text that doesn't parse, or an action this glassine-deploy doesn't
  offer (the payload starts `not offered: `).
- 8 is a DEPLOY while ranges are armed.

Requests of versions 1 and 2 never see operations 8–10: they are unknown operations
there. A version-4 request is refused with status 1, answered as version 1.

**STATUS** payload, one item per line:

```
glassine-recovery 3
connection computer|local
[writes armed]
recovery boot=<boot commit> device=<device> build=<hash16>
kernel <uname -r>
machine <device tree model>
compatible <first compatible>
serial <device tree serial-number, or unknown>
emmc-cid <the eMMC's CID, or none>
system <SYSTEM_DEV>
userdata <USERDATA_DEV>
actions select rollback reset reset-full [remove]
status-exit N
<glassine-deploy status --porcelain>
list-exit N
<glassine-deploy list --porcelain>
```

The porcelain is glassine-deploy's own (format 1, GlassineOS/boot `docs/deployments.md`).
The recovery adds no second format. `actions` lists what this glassine-deploy offers: its
usage names the verb.

**DEPLOY** text. Lines are `KEY VALUE`, with one space between key and value. Each key
appears at most once, in any order.

| Key | Value |
|---|---|
| `action` | `select`, `rollback`, `reset`, `reset-full`, `remove`, `pin` |
| `id` | the deployment (`select`, `remove`, `pin` only): `[A-Za-z0-9._-]+`, not starting with a dot |
| `discard-hibernation` | `yes`: discard a hibernated session on userdata, which glassine-deploy otherwise refuses with exit 4 |
| `confirm` | the token |

The token is the action, then the id, then `discard-hibernation` when that is asked, one
space apart: `select 20261101-120000`, `reset-full`, `rollback discard-hibernation`.

The core runs `describe` (read-only) for every DEPLOY. It answers like this:

- an action describe says isn't offered: status 1;
- a describe that fails (no such deployment, no previous one): status 10;
- no token, or a token that isn't exactly the one expected: status 9. The payload is
  `confirm TOKEN` followed by what the action does: what starts next, what is deleted,
  what stays.

Every client shows that text and asks for that token before it resends the request with
`confirm`. That covers FR-012 for USB and the console alike.

With the token, `deploy` runs glassine-deploy's own verb with `--yes`:

| Action | glassine-deploy |
|---|---|
| `select ID` | `select ID --yes` |
| `rollback` | `rollback --yes` |
| `reset` | `reset --now --yes` |
| `reset-full` | `reset --full --now --yes` |
| `remove ID` | `remove ID --yes` (it refuses the current, the previous and the candidate) |
| `pin ID` | none: glassine-deploy has no pin verb, so it is never offered |

`--discard-hibernation` is added with `discard-hibernation yes`. The answer is status 0 for
exit 0, and status 10 otherwise. glassine-deploy's exit codes (3 format, 4 hibernated,
5 space, 6 busy, 8 kernel candidate) are in the payload's first line.

**DIAG** returns one gzip'ed tar. The tool writes it into the recovery's RAM, and the core
answers with it and its sha256. Its contents:

| File | What it is |
|---|---|
| `identity.txt` | STATUS's text |
| `dmesg.txt` | this start's kernel log |
| `pstore/` | the kernel's crash log of the last start (ramoops), from pstore mounted read-only |
| `logs/<id>/` | `/var/log` of the current, candidate, failed and previous deployments, from their switch layers on userdata, read with `debugfs` (no mount) |
| `system.txt` | the command line, the partitions with their names, the kernel's read-only flag of every block device, the mounts |
| `cut.txt` | the files cut to their last 1 MiB, if any |
| `SHA256SUMS` | the sha256 of every file above |

**Pinned bytes.** `unit-recovery.c` pins two requests and one response header, for the
installer's client to pin the same way:

- the version 3 STATUS request, tag 5: `47525251 0300 0800 05000000 00000000 0000000000000000 0000000000000000`;
- its response header, for 42 bytes of text with status 0: `47525253 0300 0800 05000000 0000 0000 2a00000000000000 0000000000000000` followed by 32 zero bytes;
- the DEPLOY request, tag 7, 42 bytes of text: `47525251 0300 0900 07000000 00000000 0000000000000000 2a00000000000000`.

## Clients: the core holds every operation

All three clients send the core the same requests:

- the computer over USB, the vendor interface, protocol version 3;
- the console;
- later, the screen.

The console is `menu`, a busybox `sh` script that sends each request through
`glassine-rcall` on the local socket. `glassine-rcall` is built from the daemon's source.
So the menu offers exactly the core's operations: STATUS, DEPLOY with the confirmation
the core names, DIAG and REBOOT (FR-004). It asks nothing of the core before the first key,
so a terminal nobody uses doesn't hold the recovery back from its idle restart.

The local socket serves versions 1–3 with one exception: ARM, WRITE and DISARM are refused
there with status 2. Their bytes are read and dropped. Writes to disks are USB's only
(FR-011).

The daemon serves one request at a time, whichever connection it came on. Each connection
has its own thread, and one lock covers each request.

## Read-only, and the deploy partitions' window

Everything [the RAM environment guarantees](ramenv.md#read-only-until-armed) holds:

- every disk and partition is read-only in the kernel from the start;
- nothing is mounted from the disks;
- writes happen only in armed ranges, and never on a boot area.

The recovery adds one window, for a confirmed DEPLOY only. The partitions given with
`--deploy-part` are the system partition and userdata. While `deploy` runs:

- each of them gets `BLKROSET 0`. Its disk gets `force_ro 0` and `BLKROSET 0` on the
  whole-disk device too, because the kernel counts every partition of a read-only disk
  as read-only (`get_disk_ro`). Nothing in the recovery opens a whole-disk device for
  writing;
- every other partition keeps its own read-only flag, and every other disk stays
  read-only. This is checked before the tool runs.

The writes that happen go through the file systems glassine-deploy mounts itself:

- `select`, `rollback`: the state on the system partition;
- `reset`, `remove`: userdata too.

When it ends, or is stopped:

- whatever is still mounted from those partitions is unmounted;
- `BLKROSET 1` and `force_ro 1` are set again;
- each disk's cache is dropped, so READ and HASH see what the file systems wrote;
- every disk and partition is checked read-only again, and the check is logged.

STATUS, `describe` and DIAG open no window: glassine-deploy reads the system partition
through its own `ro,rescue=nologreplay` mount, and userdata with `debugfs`.

DEPLOY is refused (status 8) once ARM was taken in this start, armed or disarmed: after
an install's writes the partition table may have changed, and the deploy partitions found
at the start may not be what is on the disk now. A restart finds them again. ARM can't
come while a DEPLOY runs because requests are serialized. So the two kinds of writes
never overlap.

## Idle, watchdog, limits

These are the RAM environment's rules, with these additions:

- **Idle.** With no request from any client for `RECOVERY_IDLE` (600 s), the recovery
  reboots into the normal start. The boot then picks as always: the candidate if it has
  tries, else current (FR-013, SC-004). Nothing is changed on the way.
- **The tool limit.** A tool runs in its own process group, with phase "tool": the
  watchdog keeps being petted, and the idle time doesn't count.
  - Past `RECOVERY_TOOL_LIMIT` (900 s) it gets SIGTERM, then SIGKILL 20 s later.
  - A tool that still hasn't ended 30 s after that is stuck in the kernel. The petting
    stops, and the hardware resets the device.
- **The write window** (`BLKROSET`, `force_ro`, unmount) runs under the disk phase and its
  120 s operation limit, like ARM.

## Tests

    scripts/test-recovery.sh                 # unit, the stage build, the QEMU runs
    scripts/test-recovery.sh --unit-only

- `ramenv/test/unit.c`, compiled for the recovery, passes unchanged. That covers
  versions 1 and 2, including the pinned bytes, all 65536 operation codes under each
  version, and every ARM and WRITE refusal. `scripts/test-ramenv.sh` still builds it
  without the flag.
- `ramenv/test/unit-recovery.c` checks version 3 with stand-in tools:
  - the pinned bytes;
  - LIST;
  - operations 8–10 refused under versions 1 and 2;
  - STATUS;
  - every refusal of a DEPLOY text (too long, NUL, no action, unknown action, missing,
    extra or bad id, unknown or repeated key), each running no tool;
  - status 9 without or with a wrong token (also another id's, another action's, and a
    token missing `discard-hibernation`), with the token and describe's text;
  - pin not offered;
  - each confirmed action reaching `deploy` with exactly its arguments, once;
  - a failing tool (status 10, its exit code);
  - DEPLOY refused while armed and after DISARM (an unconfirmed one still says what it
    does);
  - DIAG and its sha256;
  - on the local connection: ARM, WRITE (versions 2 and 3) and DISARM refused and kept in
    step, while STATUS, DEPLOY, READ and REBOOT work;
  - a tool stopped at the limit.
- QEMU (`ramenv/test/qemu-recovery.sh`, arm64 virt, the RAM environment test's Debian
  kernel). A pool disk is made without privileges: a GPT with `system_b`
  (btrfs from `mkfs.btrfs --rootdir`, `bases/base1` a read-only subvolume, `state/` naming
  A current and B previous) and `userdata` (ext4 from `mke2fs -d`, deployments A, B and C,
  with a log in A). It is driven by the real glassine-deploy at the pinned boot commit.
  - `usb`: the install case, without the pool (no `system_b`, no `userdata`); the
    composite gadget on `dummy_hcd`.
    - The recovery says there are no such partitions and serves at once.
    - The vendor interface is interface 0.
    - The menu answers over the host's `/dev/ttyACM0` and lists no deployment.
    - A confirmed rollback through `glassine-rcall` is refused (status 10).
    - `client-usb` runs the RAM environment test's whole plan: every disk read whole and
      compared, then the version 2 writes, including a new partition table. The images
      must be the originals plus exactly those bytes.
  - `deploy`: the pool on QEMU's emulated eMMC (`mmcblk0`, with two boot areas), so the
    write window goes through the eMMC's `force_ro` too; version 3 over virtio-serial.
    - STATUS: A current, B previous, C kept, base present.
    - select C: status 9 without the confirmation and with another id's token, then
      done, and STATUS shows C as the candidate with 2 tries.
    - rollback: B is the candidate. select A: no candidate.
    - pin: not offered. select of a missing deployment: status 10.
    - DIAG: sha256, SHA256SUMS, A's log read from userdata, and every disk and partition
      read-only in the kernel after the operations.
    - HASH before and after: vda, vdb and the boot areas unchanged, and the pool disk
      unchanged outside its system partition.
    - remove: A (current) refused by the tool (status 10); C: status 9 without the
      confirmation, then done, and the list holds A and B.
    - The idle restart.
  - `console`: the pool as a virtio disk; the menu on a virtio console.
    - rollback: a wrong token cancels, the right one does it.
    - reset: `reset --now` makes a new deployment, the candidate.
    - diagnostics.
    - The idle restart.
  - Every run checks the kernel's read-only state of every disk and partition, and that a
    write to each fails.

Not covered:

- the device's kernel, its UDC, eMMC host and watchdog, the boot loader's recovery
  path, a device's real pool and logs, Windows' binding of the composite device;
- the installer's client against version 3 (only the pinned bytes tie them);
- `reset-full` and `discard-hibernation` against the real glassine-deploy (the unit test
  checks their arguments only), and a hibernated pool;
- pstore contents in DIAG (QEMU has no ramoops);
- the real glassine-deploy stopped at the tool limit (the unit test stops a stand-in);
- a client that stalls mid-request: a request holds the lock while it reads its payload and answers,
  so a stalled client holds up the other connection until its operation limit;
- CI: `scripts/test-ramenv.sh` and `scripts/test-recovery.sh` run by hand, no workflow
  runs them.

## Left for later

- **The screen (FR-006).** An e-ink client of the same core: the deployment list, the
  same confirmations, touch and the power key.
- **Pin (FR-007).** glassine-deploy has no pin verb. `pin` is reserved in DEPLOY and
  answered "not offered" until boot defines it.
- **Repair the boot (FR-009)** and **the hand-over to another system's recovery (Scenario 5)**.
- **Starting it (FR-002)**:
  - `reboot recovery` from the running system;
  - the fallback when the boot's tries run out. The Note Air's boot loader starts
    `recovery` only on `oem reboot-recovery`.
- **Encrypted storage (FR-015).** No unlock yet.
- **The recovery's own kernel configuration (FR-014).** It uses the system kernel, as the
  RAM environment does.
