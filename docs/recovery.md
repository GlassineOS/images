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

A person reaches the recovery on its screen (e-ink, touch and the power key; FR-006,
[below](#the-screen)) or through the text menu on the USB serial function; a computer
reaches it over the vendor interface. The screen has run in QEMU only (no panel there).

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
| `ramenv/recovery/screen/` | the screen: `glassine-rscreen.c` (its client), `font-gen.c` (its type, at build time), `start` (modules, waveform, programs) |
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
On the Note Air the initramfs is about 3.4 MB with the screen (2.8 MB without), against
0.7 MB for the RAM environment's; the boot image stays well inside the 64 MiB `recovery`
partition.

The system kernel at the pinned commit has everything the core uses built in: USB
gadget, FunctionFS and the ACM function, btrfs, ext4, overlayfs, the qcom watchdog,
ramoops (checked in that kernel's `modules.builtin`). Only the screen needs modules: the
panel link and the touchscreen are modules in that kernel. `scripts/ramenv-bootimg.sh`
packs the device's `RECOVERY_SCREEN_MODULES` and what they depend on (from the kernel
export's `modules.dep`) into the image, under `/lib/modules/<release>/` with their load
order in `recovery-screen.list`, and names them and their sha256 in the manifest
(`screen_modules=`, `screen_modules_sha256=`). The screen's start script loads them; the
core loads none. The RAM environment still loads no module.

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
`ram-environment` role and its `recovery` role can become one artifact.
`scripts/pool-image --recovery DIR` takes `recovery-export`'s `DIR/recovery/` as the
release's `recovery` role. Using the same image as `ram-environment` too is the
installer's and the release's change; it isn't made here.

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
- 8 is a DEPLOY once ARM was taken in this start, or an ARM once a DEPLOY ran.

Requests of versions 1 and 2 never see operations 8–10: they are unknown operations
there. A version-4 request is refused with status 1, answered as version 1.

**STATUS** payload, one item per line:

```
glassine-recovery 3
connection computer|local
[writes armed]
[deploy partitions held: restart]
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
| `id` | the deployment (`select`, `remove`, `pin` only): `[A-Za-z0-9._-]+`, not starting with a dot or a dash |
| `discard-hibernation` | `yes`: discard a hibernated session on userdata, which glassine-deploy otherwise refuses with exit 4 |
| `confirm` | the token |

The token is the action, then the id, then `discard-hibernation` when that is asked, then
the first 8 hex digits of the sha256 of what `describe` said, one space apart:
`select 20261101-120000 3fa01c2e`, `reset-full 9b0e51d7`, `rollback discard-hibernation
1db382ab`. The hash ties the confirmation to the state the person was shown. If the
state changed in between (another client selected a deployment, say), describe says
something else, the token is another, and the request gets status 9 again with the new
text.

The core runs `describe` (read-only) for every DEPLOY. Both tools get their arguments by
position, `ACTION ID|- yes|no` (`-` for no id, `yes` to discard the hibernation), so an
id can't be taken for a flag. It answers like this:

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
- the screen.

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

## The screen

The third client (FR-006), for a person at the device: `glassine-rscreen`, a static C
program that draws its pages itself and sends each request to the core on the local
socket, as the menu does through `glassine-rcall` (it is built from the daemon's source
too). It offers exactly the menu's operations with the menu's confirmations (FR-004):

| Page | What it does |
|---|---|
| home | the device's identity (machine, the recovery's boot commit and build), the deployment state (starts next, then, last good, failed), or glassine-deploy's own line when there is no deployment |
| deployments | each deployment with its state (LAST GOOD and FAILED filled, STARTS NEXT, PREVIOUS, KEPT), roll back to the previous one, paged when they don't fit |
| deployment | its state, base, date and size; start it next; delete it (when the core offers `remove`) |
| reset | reset system and full reset |
| confirm | the core's text, whole, under WHAT THIS DOES; Cancel first (and focused), then the button that names the action ("Start ID", "Roll back", "Reset system", "Full reset", "Delete ID"). A text that doesn't fit offers Cancel only |
| hibernated | when glassine-deploy says userdata holds a hibernated session (exit 4): discard it and go on (the core describes it again, with its own confirmation) or cancel |
| working, done, failed, refused, cancelled | the operation's result in glassine-deploy's words |
| diagnostics | collected by the core (DIAG), its sha256 checked, the files listed; the person is told the file is in the recovery's memory and that a computer reads it over USB with the GlassineOS installer |
| restart | the normal start or the boot loader, confirmed; REBOOT |
| idle, restarting | before the core's idle restart: when, and that touching the screen or the power key keeps it up |
| no core | the core doesn't answer; try again |

The core decides. The client never makes a confirmation: on status 9 it shows the text of
that answer and sends back the token from its first line, unchanged, only when the
person chose the confirm button on that page. A tap or a power key press that started
before a page took input (0.3 s after its frame) counts for nothing, so input can't
carry from one page into the next and a confirmation can't be skipped.

Input:

- touch: a tap chooses the button it began and ended on;
- the power key alone: a short press moves to the next button, a hold of 0.8 s chooses
  it (the focused button has a second ring).

The e-ink rules: black on white, IBM Plex (the GlassineOS shell's type, rasterized at build
time by `font-gen` into the program, 16 grey levels: 64 px titles, 40 px text, 32 px
notes, 28 px mono labels; Latin-1 and the marks the texts use), no animation. Every text
wraps to the content width; a word longer than a line breaks anywhere. Each page is one whole frame; moving the focus sends only the two
buttons' rectangles. Whether the panel daemon refreshes in full or in part follows from
the area (glassine-epdd does a full GC16 refresh when a frame changes more than half the
panel); the protocol has no flag to ask for a full refresh.

Idle: the core restarts the device `RECOVERY_IDLE` seconds after the last request, from
any client. The screen sends no request on a timer: it keeps the time of its own last
answer, shows the idle page a minute before the end (a third of the idle time when that
is shorter), and the restarting page at the end. Input there sends one LIST, which keeps
the recovery up, and brings the page back. When another client kept the core busy, the
screen brings its page back 30 s after its estimate passed.

The panel: the screen uses glassine-epdd, the system's panel daemon, from the
`glassine-epdd` package, with the device package's adapter `/etc/glassine/epd.conf`
(`RECOVERY_SCREEN_ADAPTER`, fetched at build time; its version and the file's sha256 go
into the manifest). It hands the daemon one memfd frame buffer (BUF), sends FRAME and
waits for DONE (5 s); when the daemon ends it connects again and sends the whole page.
The adapter names the panel's geometry and rotation (the touch coordinates are turned
back by it) and the touchscreen's evdev name.

The waveform: the panel needs the device's own waveform file. It is not in the image
(FR-014: no vendor firmware in the image). The start script reads it from the device data
seed on the partition `RECOVERY_DEVICE_LABEL` (`vendor_b` on the Note Air; GlassineOS/boot
`docs/kernel-artifacts.md`, "Device data") with debugfs, nothing mounted (FR-001): one
partition by that name, no journal waiting for a replay, `glassine/manifest` in format 1,
the file's sha256 as the manifest names it, and the shape of a waveform (its length at
offset 4). It goes into RAM at the adapter's path under `/run/glassine/device/`. Without
the seed (a stock partition table, while installing), a matching waveform or the modules
there is no screen; the core, USB and the console go on.

`ramenv/init` starts `/lib/glassine-recovery/screen` once the core serves, when the
device's config sets `RECOVERY_SCREEN=epd`. It loads the modules, reads the waveform and
runs glassine-epdd and glassine-rscreen, each again when it ends.

The device config:

| Key | Note Air |
|---|---|
| `RECOVERY_SCREEN` | `epd` |
| `RECOVERY_SCREEN_ADAPTER` | `device-onyx-noteair` (the package with `etc/glassine/epd.conf`) |
| `RECOVERY_SCREEN_MODULES` | `panel_onyx_na1_link cyttsp5` (cyttsp5 pulls in crc-itu-t) |
| `RECOVERY_DEVICE_LABEL` | `vendor_b` (checked against the board's `DEVICE_PART`) |

No board in GlassineOS/ui covers the recovery yet. The pages follow the shell's white
e-ink voice (Plex, ink on white, outlined cards, mono labels, pill tags); each needs a
board.

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

The window's real exposure is the whole disk that holds those partitions, not just them:
its whole-disk flags are off while the tool runs, so a writer that opened the whole-disk
device then could write anywhere on it. Nothing in the recovery does, and the tools are
the recovery's own.

The flags alone don't end the window. The kernel checks them when a device is opened or
mounted, so a file system still mounted rw would keep writing after them. So the close,
when the tool ends or is stopped, goes in this order:

1. nothing of the tool is left. It runs as the first process of its own PID namespace,
   so when it ends the kernel kills every process it started, also backgrounded,
   daemonised and `setsid` ones, before its end is reported. Without PID namespaces it
   runs in its own process group, which is killed and waited for. That covers fewer
   cases: a `setsid` child escapes the group.
2. every mount made since the window opened (file systems, overlays, binds, wherever
   they are) and every mount of a deploy partition is unmounted, the newest first. A
   lazy unmount (`MNT_DETACH`) is never used: it would hide a file system that is still
   alive.
3. each deploy partition and its disk are proven free: an exclusive open (`O_EXCL`)
   must succeed. It fails while anything holds them (a mounted file system in any mount
   namespace, detached or not, a swap area, a device mapper target).
4. on every served disk, whatever happened above: `BLKROSET 1` on the whole-disk device
   and on every partition, and `force_ro 1`. Each disk's cache is dropped, so READ and
   HASH see what the file systems wrote. Every disk and partition is checked read-only
   again, and the check is logged.

Edges, each failing safe:

- a process of the namespace stuck in the kernel (D state) keeps PID 1's exit from
  completing. The tool then runs into its limit, and the watchdog stops being petted,
  which resets the device;
- mounts are told apart by their mount id. If the tool unmounts one of the baseline
  mounts and the kernel gives its id to a new mount, that mount is taken for a baseline
  one and stays. If it is on a deploy partition, it is unmounted anyway, by device. If
  it holds one some other way (an overlay), the exclusive open in step 3 fails, and the
  close counts as held;
- the baseline keeps at most 512 mounts (the recovery has about a dozen). Mounts past
  that would count as the tool's and be unmounted too. One that can't be unmounted
  makes the close count as held.

If step 2, 3 or 4 fails, the answer says so (status 5 for a tool that exited 0, with a
warning). STATUS says `deploy partitions held: restart`, and DEPLOY and ARM are refused
until a restart.

STATUS, `describe` and DIAG open no window: glassine-deploy reads the system partition
through its own `ro,rescue=nologreplay` mount, and userdata with `debugfs`.

DEPLOY is refused (status 8) once ARM was taken in this start, armed or disarmed: after
an install's writes the partition table may have changed, and the deploy partitions found
at the start may not be what is on the disk now. A restart finds them again. The other
way round, ARM is refused (status 8) once a DEPLOY opened the window in this start,
however that window closed: raw writes and file systems the tool used never meet in one
start. Requests are serialized, so the two kinds of writes never overlap.

The deploy partitions are the partitions with those names on a served disk
(`RAMENV_DISKS`). When two partitions share a name, neither is used. Each must be a
partition of a served disk, not of a boot area, or the window doesn't open.

## Idle, watchdog, limits

These are the RAM environment's rules, with these additions:

- **Idle.** With no request from any client for `RECOVERY_IDLE` (600 s), the recovery
  reboots into the normal start. The boot then picks as always: the candidate if it has
  tries, else current (FR-013, SC-004). Nothing is changed on the way. The idle time
  starts again when a tool ends, and the idle reboot doesn't cut into a request that is
  running (it takes the request lock). A request that waits for its client instead
  holds that lock: a payload that stops coming (a USB host paused mid-WRITE, a hung
  local client), or an answer nobody reads. So past twice the idle time, with no tool
  or disk operation running, the recovery reboots anyway. Nothing is written from a
  payload that didn't arrive whole, and the reboot ends any armed range. The RAM
  environment's build has no request lock and is unchanged.
- **The tool limit.** A tool runs in its own PID namespace, with phase "tool": the
  watchdog keeps being petted, and the idle time doesn't count.
  - The tool ends when its first process has ended and its output is closed. Past
    `RECOVERY_TOOL_LIMIT` (900 s from its start, whatever it does with its output) it
    gets SIGTERM, then SIGKILL 20 s later.
  - A tool that still hasn't ended 30 s after that is stuck in the kernel. So is a tool
    whose processes can't all be killed. The petting stops, and the hardware resets the
    device.
- **The local socket.** An ARM, WRITE or DISARM there with a payload above 16 MiB ends
  that connection; a smaller one is read and dropped.
- **The write window** (`BLKROSET`, `force_ro`, unmount) runs under the disk phase and its
  120 s operation limit, like ARM.

## Tests

    scripts/test-recovery.sh                 # unit, the stage build, the screen, the QEMU runs
    scripts/test-recovery.sh --unit-only
    UPDATE=1 scripts/test-recovery.sh        # the screen's pages written over its goldens

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
    extra or bad id, an id starting with a dash, unknown or repeated key), each running
    no tool;
  - status 9 without or with a wrong token (also another id's, another action's, and a
    token missing `discard-hibernation`), with the token (its hash computed in the
    test) and describe's text;
  - a token from before the state changed (describe now says something else): status
    9 and a new token;
  - an id named `discard-hibernation` reaching describe as the id;
  - pin not offered;
  - each confirmed action reaching `deploy` with exactly its positional arguments, once;
  - a failing tool (status 10, its exit code);
  - nothing of a tool outlives it: a background child and a `setsid` child stop
    writing when the answer comes; a child that holds the output doesn't hold a
    finished tool's answer; a tool that closes its output and goes on is stopped at the
    limit; output above 256 KiB is cut, the rest intact;
  - ARM refused after a DEPLOY; DEPLOY refused after a window that didn't close, and
    STATUS saying so;
  - DEPLOY refused while armed and after DISARM (an unconfirmed one still says what it
    does);
  - DIAG and its sha256;
  - on the local connection: ARM, WRITE (versions 2 and 3) and DISARM refused and kept in
    step, a 1 TiB WRITE ending the connection, while STATUS, DEPLOY, READ and REBOOT
    work;
  - a bad request under version 2 answered with the RAM environment's text;
  - a WRITE whose payload stalls after 100 bytes, with ranges armed: the idle reboot
    comes after twice the idle time, and nothing was written;
  - a tool stopped at the limit.

  The tools run in a PID namespace there too when the host allows unprivileged user
  namespaces. Without them the `setsid` check is skipped, and the test says so.
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
  - `window`: the pool as a virtio disk, with stand-in `describe` and `deploy` tools
    and a 5 s tool limit, against the real daemon and kernel. Each stand-in mounts
    `system_b` or userdata and writes and syncs on: one ignores SIGTERM, one leaves a
    writer in the background and exits, one closes its output first, and one leaves
    an overlay on userdata with a bind, at a mount point with a space. After each answer
    the pool image (hashed on the host) doesn't change for 8 s. The window closed
    cleanly: every mount was unmounted by name, and STATUS doesn't say held. ARM is
    refused after the first DEPLOY. The last stand-in makes userdata a swap area, an
    exclusive holder no unmount ends: status 5 with a warning, STATUS says held, and
    the next DEPLOY is refused until a restart.
  - `console`: the pool as a virtio disk; the menu on a virtio console.
    - rollback: a wrong token cancels, the right one does it.
    - reset: `reset --now` makes a new deployment, the candidate.
    - diagnostics.
    - The idle restart.
  - `screen`: the pool as a virtio disk and a device data seed (a GPT with `vendor_b`:
    ext4 with `glassine/manifest` and a made-up waveform). The production start script
    and client; glassine-epdd replaced by `epd-sink`, which checks the waveform is in
    place and answers FRAME with DONE. `screen-drive` makes a touchscreen and a power key
    with uinput and goes through `ramenv/test/screen/qemu.events`, reading the page and
    its buttons from the client's state file and tapping where they are drawn (the
    adapter's rotation applied):
    - select C cancelled; then three tries to skip its confirmation: taps on the confirm
      button from before the page took input, a finger and the power key held from
      before it until after it: the page stays;
    - select C, rollback to B and reset system confirmed by touch;
    - full reset with the power key alone (moved to, chosen, cancelled);
    - diagnostics; restart cancelled;
    - the idle page, the power key bringing the page back, then the idle restart.
    The host checks: the waveform read from the seed, the whole script ran, exactly three
    operations confirmed (`deploy: … confirmed (local connection)`), no reboot asked, the
    idle restart, the seed disk and vda/vdb unchanged.
  - Every run checks the kernel's read-only state of every disk and partition, and that a
    write to each fails.
- The screen, headless (`ramenv/test/screen-headless.sh`, arm64 Alpine with the
  GlassineOS repository): glassine-rscreen built as the image builds it, its pages drawn
  through `--events` scripts (`ramenv/test/screen/*.events`) against `screen-core.py`, a
  stand-in core that speaks version 3 with describe's texts and checks that every
  confirmed DEPLOY carried the token of its status-9 answer. Each page is compared pixel
  for pixel with its golden image `ramenv/test/screen/NAME.png`: every page, the
  hibernation question, the empty device, no core, the idle notice, the power key's
  focus, a deployment id longer than a line (wrapped, clear of its tags; the confirm
  button then says "Start it") and one longer than the screen takes (left out with a
  note, never sent cut), and `glyphs`: every glyph the pages use in each face and size. The goldens depend on the FreeType and font package versions in that container.

Not covered:

- the device's kernel, its UDC, eMMC host and watchdog, the boot loader's recovery
  path, a device's real pool and logs, Windows' binding of the composite device;
- the installer's client against version 3 (only the pinned bytes tie them);
- `reset-full` and `discard-hibernation` against the real glassine-deploy (the unit test
  checks their arguments only), and a hibernated pool;
- pstore contents in DIAG (QEMU has no ramoops);
- the real glassine-deploy stopped at the tool limit (the unit test stops a stand-in);
- a client that stalls mid-request: a request holds the lock while it reads its
  payload and answers, so a stalled client holds up the other connection until the
  idle reboot, at twice the idle time (a local write payload above 16 MiB ends its
  connection at once);
- CI: `scripts/test-ramenv.sh` and `scripts/test-recovery.sh` run by hand, no workflow
  runs them;
- the screen on the device: the panel, glassine-epdd with the real waveform, the panel
  link and touchscreen modules loading in the recovery, the touch coordinates' rotation,
  the power key's driver, how the pages look on e-ink, and the frontlight (not loaded:
  the page is lit by the room);
- a device data seed made by glassine-deploy (the QEMU seed is made by the test).

## Left for later

- **The screen's boards.** Designs for its pages in GlassineOS/ui.
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
