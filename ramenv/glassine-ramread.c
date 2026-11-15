/* SPDX-License-Identifier: GPL-2.0-or-later */
/* glassine-ramread: the RAM environment's reader (docs/ramenv.md). It offers the
 * device's whole disks to the computer over one vendor-specific USB interface
 * (FunctionFS), or over a byte stream (a character device: the QEMU test's
 * virtio-serial port). Protocol version 1 has four operations: list, read a range,
 * sha256 of a range, reboot; none of them writes. Version 2 adds three: arm ranges for
 * writing (once per start), write inside an armed range, disarm.
 *
 *   glassine-ramread [options] --disk PATTERN [--disk PATTERN]...
 *     --disk PATTERN      a glob over /sys/block names (mmcblk[0-9], mmcblk[0-9]boot[0-9]);
 *                         every match is offered, in name order
 *     --disk-wait S       wait up to S seconds for a first match, and for the stream
 *                         device to appear (default 60)
 *     --ffs DIR           serve on the FunctionFS instance mounted at DIR
 *     --stream DEV        serve on DEV (a character device), instead of --ffs
 *     --ready FILE        created once the descriptors are written (--ffs) or the stream is
 *                         open; the init binds the USB controller after it appears
 *     --watchdog DEV      arm DEV (a hardware watchdog) and pet it while all is well
 *     --watchdog-timeout S  (default 30)
 *     --connect-wait S    reboot if no request arrives S seconds after start (default 300)
 *     --idle S            reboot S seconds after the last request (default 600)
 *     --op-limit S        a disk read or hash running longer than S seconds stops the
 *                         petting: the watchdog resets the device (default 120)
 *
 * Read-only until armed: every disk and each of its partitions is set read-only in
 * the kernel (BLKROSET, and force_ro where the kernel offers it) and checked with
 * BLKROGET before the first request is served; the disks are opened O_RDONLY; an
 * unknown operation is refused. Only ARM changes that, and only for the whole-disk
 * device of a disk it names: that one is made writable (force_ro 0, BLKROSET 0) and
 * opened for writing, its partitions and every other disk stay read-only (checked),
 * and a WRITE must lie inside one armed range. The mmc boot areas (mmcblk*boot*) are
 * never armed. DISARM (and a reboot) makes every disk read-only again. Exit status:
 * 0 never (it serves until it reboots), 1 setup failed, 2 usage.
 *
 * Built with -DGLASSINE_RECOVERY (the recovery, docs/recovery.md), it also speaks
 * protocol version 3: version 2 plus STATUS, DEPLOY and DIAG, which run the programs in
 * a tools directory (glassine-deploy's status and operations, the diagnostics), and it
 * serves a local socket too, for the console's menu (the same operations, without
 * ARM, WRITE and DISARM). Requests of versions 1 and 2 are answered exactly as without
 * it. Its extra options:
 *     --tools DIR         the recovery's programs: status, describe, deploy, diag
 *     --socket PATH       the local socket (a unix stream socket) the console uses
 *     --deploy-part NAME  a partition (a /sys/block name) DEPLOY's operations may
 *                         write through the file systems on it; repeatable
 *     --tool-limit S      a tool running longer is stopped (default 900)
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include <linux/fs.h>
#include <linux/reboot.h>
#include <linux/usb/ch9.h>
#include <linux/usb/functionfs.h>
#include <linux/watchdog.h>
#ifdef GLASSINE_RECOVERY
#include <poll.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#endif

/* ---- the protocol (docs/ramenv.md) ------------------------------------------------ */

#define PROTO_V1 1
#define PROTO_V2 2
#define PROTO_V3 3
#ifdef GLASSINE_RECOVERY
#define PROTO_MAX PROTO_V3
#else
#define PROTO_MAX PROTO_V2
#endif
#define REQ_SIZE 32
#define RSP_SIZE 64
#define REQ_MAGIC "GRRQ"
#define RSP_MAGIC "GRRS"

/* version 1: LIST, READ, HASH, REBOOT; version 2 adds ARM, WRITE, DISARM; version 3
 * (the recovery only) adds STATUS, DEPLOY, DIAG */
enum { OP_LIST = 1, OP_READ = 2, OP_HASH = 3, OP_REBOOT = 4, OP_ARM = 5, OP_WRITE = 6, OP_DISARM = 7,
       OP_STATUS = 8, OP_DEPLOY = 9, OP_DIAG = 10 };
enum {
	ST_OK = 0,
	ST_BAD_REQUEST = 1, /* wrong magic, version or fields; ARM text that doesn't parse */
	ST_UNKNOWN_OP = 2,  /* not an operation of the request's version */
	ST_NO_DISK = 3,
	ST_RANGE = 4,       /* outside the disk or the armed ranges, unaligned, empty or too long */
	ST_IO = 5,          /* the disk returned an error */
	ST_NOT_ARMED = 6,   /* (v2) WRITE without ARM, or after DISARM */
	ST_BAD_DATA = 7,    /* (v2) the WRITE's bytes don't have the sha256 sent with them */
	ST_ARMED = 8,       /* (v2) ARM a second time in this start; (v3) DEPLOY while armed */
	ST_CONFIRM = 9,     /* (v3) DEPLOY without the confirmation it needs: the payload
			     * names it and what the operation does */
	ST_TOOL = 10,       /* (v3) the tool failed: the payload is its exit code and output */
};
enum { REBOOT_NORMAL = 0, REBOOT_BOOTLOADER = 1 };

#define ALIGN 512u
#define MAX_READ (16u << 20)
#define MAX_HASH (64u << 20)
#define MAX_WRITE (16u << 20)
#define MAX_ARM_TEXT 16384u
#define MAX_RANGES 64
#define RECV_CHUNK (1u << 20)
_Static_assert(MAX_WRITE <= MAX_READ, "a WRITE is received into the read buffer");
#define MAX_DISKS 16
#define SEND_CHUNK (1u << 20)

/* The interface the computer looks for: vendor class, 'G', 'R'. */
#define RR_CLASS 0xff
#define RR_SUBCLASS 0x47
#define RR_PROTOCOL 0x52

struct request {
	uint16_t version, op;
	uint32_t tag, index;
	uint64_t offset, length;
};

static uint16_t ld16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t ld32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t ld64(const uint8_t *p) { return (uint64_t)ld32(p) | (uint64_t)ld32(p + 4) << 32; }
static void st16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void st32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void st64(uint8_t *p, uint64_t v) { st32(p, (uint32_t)v); st32(p + 4, (uint32_t)(v >> 32)); }

/* 0 = a well-formed request (its fields not yet checked against the disks) */
static int parse_request(const uint8_t b[REQ_SIZE], struct request *r)
{
	if (memcmp(b, REQ_MAGIC, 4)) return -1;
	r->version = ld16(b + 4);
	r->op = ld16(b + 6);
	r->tag = ld32(b + 8);
	r->index = ld32(b + 12);
	r->offset = ld64(b + 16);
	r->length = ld64(b + 24);
	return r->version >= PROTO_V1 && r->version <= PROTO_MAX ? 0 : -1;
}

/* the response carries the request's version (1 for a request that didn't parse) */
static void put_response(uint8_t b[RSP_SIZE], uint16_t version, uint16_t op, uint32_t tag, uint16_t status,
			 uint64_t length, uint64_t offset, const uint8_t *sha)
{
	memset(b, 0, RSP_SIZE);
	memcpy(b, RSP_MAGIC, 4);
	st16(b + 4, version);
	st16(b + 6, op);
	st32(b + 8, tag);
	st16(b + 12, status);
	st64(b + 16, length);
	st64(b + 24, offset);
	if (sha) memcpy(b + 32, sha, 32);
}

/* ---- sha256 (FIPS 180-4) ------------------------------------------------------------ */

struct sha256 { uint32_t h[8]; uint64_t n; uint8_t buf[64]; size_t used; };

static const uint32_t K256[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) ((x) >> (n) | (x) << (32 - (n)))

static void sha256_block(struct sha256 *s, const uint8_t *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, h;
	for (int i = 0; i < 16; i++) w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
	for (int i = 16; i < 64; i++) {
		uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
		uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
	for (int i = 0; i < 64; i++) {
		uint32_t t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
		uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

static void sha256_init(struct sha256 *s)
{
	static const uint32_t iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
	memcpy(s->h, iv, sizeof iv);
	s->n = 0;
	s->used = 0;
}

static void sha256_update(struct sha256 *s, const uint8_t *p, size_t len)
{
	s->n += len;
	if (s->used) {
		size_t k = 64 - s->used < len ? 64 - s->used : len;
		memcpy(s->buf + s->used, p, k);
		s->used += k; p += k; len -= k;
		if (s->used < 64) return;
		sha256_block(s, s->buf);
		s->used = 0;
	}
	for (; len >= 64; p += 64, len -= 64) sha256_block(s, p);
	memcpy(s->buf, p, len);
	s->used = len;
}

static void sha256_final(struct sha256 *s, uint8_t out[32])
{
	uint64_t bits = s->n * 8;
	uint8_t pad[72] = { 0x80 };
	size_t k = (s->used < 56 ? 56 : 120) - s->used;
	for (int i = 0; i < 8; i++) pad[k + i] = (uint8_t)(bits >> (56 - 8 * i));
	sha256_update(s, pad, k + 8);
	for (int i = 0; i < 8; i++) for (int j = 0; j < 4; j++) out[4 * i + j] = (uint8_t)(s->h[i] >> (24 - 8 * j));
}

/* ---- logging, time ------------------------------------------------------------------ */

static int g_kmsg = -1;

static void say(const char *fmt, ...)
{
	char m[512];
	int n = snprintf(m, sizeof m, "<5>glassine-ramread: ");
	va_list ap;
	va_start(ap, fmt);
	n += vsnprintf(m + n, sizeof m - (size_t)n - 1, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof m - 2) n = (int)sizeof m - 2;
	m[n++] = '\n';
	if (g_kmsg < 0 || write(g_kmsg, m, (size_t)n) < 0) {
		if (write(2, m + 3, (size_t)n - 3) < 0) { /* nowhere to say it */ }
	}
}

static long now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (long)t.tv_sec;
}

/* ---- disks -------------------------------------------------------------------------- */

struct disk {
	char name[64];
	char path[PATH_MAX];
	int fd;           /* O_RDONLY */
	uint64_t size;    /* bytes */
	uint32_t sector;  /* logical block size */
	int block;        /* a block device (else a regular file: the unit test) */
	int armed;        /* named by the ARM in force */
	int wfd, rfd;     /* while armed: the write descriptor (O_DIRECT on a block device)
			   * and the read-back one (O_DIRECT; -1 for a file: its fd reads back) */
};

static struct disk g_disk[MAX_DISKS];
static int g_ndisks;

static int write_file(const char *path, const char *s)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	ssize_t n = write(fd, s, strlen(s));
	close(fd);
	return n == (ssize_t)strlen(s) ? 0 : -1;
}

/* BLKROSET on an open block device, then BLKROGET must say read-only */
static int set_ro(int fd)
{
	int one = 1, ro = 0;
	if (ioctl(fd, BLKROSET, &one) < 0) return -1;
	if (ioctl(fd, BLKROGET, &ro) < 0) return -1;
	return ro ? 0 : (errno = EPERM, -1);
}

/* The partitions of /sys/block/NAME (entries with a "partition" file): each set
 * read-only, so that nothing can write through a partition either. */
static int set_partitions_ro(const char *name)
{
	char path[PATH_MAX];
	snprintf(path, sizeof path, "/sys/block/%s", name);
	DIR *d = opendir(path);
	if (!d) return -1;
	int bad = 0;
	struct dirent *e;
	while ((e = readdir(d))) {
		struct stat st;
		if (e->d_name[0] == '.') continue;
		snprintf(path, sizeof path, "/sys/block/%s/%s/partition", name, e->d_name);
		if (stat(path, &st) < 0) continue;
		snprintf(path, sizeof path, "/dev/%s", e->d_name);
		int fd = open(path, O_RDONLY | O_CLOEXEC);
		if (fd < 0 || set_ro(fd) < 0) {
			say("%s: cannot set read-only: %s", e->d_name, strerror(errno));
			bad = 1;
		}
		if (fd >= 0) close(fd);
	}
	closedir(d);
	return bad ? -1 : 0;
}

/* Adds PATH as disk NAME. A block device must end up read-only in the kernel, with all
 * its partitions; a regular file (the unit test) is only opened O_RDONLY. */
static int disk_add(const char *name, const char *path, int block_only)
{
	if (g_ndisks >= MAX_DISKS) return -1;
	struct disk *d = &g_disk[g_ndisks];
	struct stat st;
	int fd = open(path, O_RDONLY | O_CLOEXEC | O_LARGEFILE);
	if (fd < 0 || fstat(fd, &st) < 0) { say("%s: %s", path, strerror(errno)); goto fail; }
	snprintf(d->name, sizeof d->name, "%.63s", name);
	snprintf(d->path, sizeof d->path, "%s", path);
	d->wfd = d->rfd = -1;
	d->block = S_ISBLK(st.st_mode);
	if (S_ISBLK(st.st_mode)) {
		char fro[PATH_MAX];
		/* the mmc boot areas: the kernel's own switch, read-only already by default */
		snprintf(fro, sizeof fro, "/sys/block/%s/force_ro", name);
		if (access(fro, F_OK) == 0 && write_file(fro, "1") < 0) { say("%s: force_ro: %s", name, strerror(errno)); goto fail; }
		if (set_ro(fd) < 0) { say("%s: cannot set read-only: %s", name, strerror(errno)); goto fail; }
		if (set_partitions_ro(name) < 0) goto fail;
		if (ioctl(fd, BLKGETSIZE64, &d->size) < 0) goto fail;
		int ss = 0;
		if (ioctl(fd, BLKSSZGET, &ss) < 0 || ss <= 0) goto fail;
		d->sector = (uint32_t)ss;
	} else if (!block_only && S_ISREG(st.st_mode)) {
		d->size = (uint64_t)st.st_size;
		d->sector = ALIGN;
	} else {
		say("%s: not a block device", path);
		goto fail;
	}
	if ((fcntl(fd, F_GETFL) & O_ACCMODE) != O_RDONLY) goto fail;
	d->fd = fd;
	g_ndisks++;
	return 0;
fail:
	if (fd >= 0) close(fd);
	return -1;
}

static int cmp_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

/* The /sys/block names matching any pattern, sorted; returns the count */
static int match_disks(char **pat, int npat, char names[MAX_DISKS][64])
{
	DIR *d = opendir("/sys/block");
	if (!d) return 0;
	char *list[256];
	int n = 0;
	struct dirent *e;
	while ((e = readdir(d)) && n < 256) {
		for (int i = 0; i < npat; i++)
			if (!fnmatch(pat[i], e->d_name, 0)) { list[n++] = strdup(e->d_name); break; }
	}
	closedir(d);
	qsort(list, (size_t)n, sizeof *list, cmp_str);
	int k = 0;
	for (int i = 0; i < n; i++) {
		if (k < MAX_DISKS) snprintf(names[k++], 64, "%.63s", list[i]);
		free(list[i]);
	}
	return k;
}

/* ---- I/O ------------------------------------------------------------------------- */

/* the watchdog's view of what the server does */
enum { PH_WAIT = 0, PH_DISK = 1, PH_SEND = 2, PH_TOOL = 3 /* (recovery) a tool runs, with its own limit */ };
static atomic_int g_phase;
static atomic_long g_phase_since;
static atomic_long g_last_request;
static atomic_int g_requests;

static void phase(int p) { atomic_store(&g_phase_since, now_s()); atomic_store(&g_phase, p); }

static int read_full(int fd, uint8_t *b, size_t n)
{
	size_t got = 0;
	while (got < n) {
		ssize_t r = read(fd, b + got, n - got);
		if (r < 0 && errno == EINTR) continue;
		if (r <= 0) return r == 0 ? 0 : -1;
		got += (size_t)r;
	}
	return 1;
}

static int write_full(int fd, const uint8_t *b, size_t n)
{
	while (n) {
		size_t k = n < SEND_CHUNK ? n : SEND_CHUNK;
		ssize_t w = write(fd, b, k);
		if (w < 0 && errno == EINTR) continue;
		if (w <= 0) return -1;
		b += w;
		n -= (size_t)w;
	}
	return 0;
}

static int pread_full(int fd, uint8_t *b, size_t n, uint64_t off)
{
	while (n) {
		ssize_t r = pread(fd, b, n, (off_t)off);
		if (r < 0 && errno == EINTR) continue;
		if (r <= 0) return -1;
		b += r;
		n -= (size_t)r;
		off += (uint64_t)r;
	}
	return 0;
}

static int pwrite_full(int fd, const uint8_t *b, size_t n, uint64_t off)
{
	while (n) {
		ssize_t w = pwrite(fd, b, n, (off_t)off);
		if (w < 0 && errno == EINTR) continue;
		if (w <= 0) return -1;
		b += w;
		n -= (size_t)w;
		off += (uint64_t)w;
	}
	return 0;
}

static uint8_t *g_buf; /* MAX_READ (= MAX_WRITE) */

/* n bytes the computer sends after a request, in reads of at most RECV_CHUNK (a
 * FunctionFS endpoint takes no more per read); b == NULL: read and dropped */
static int recv_bytes(int in, uint8_t *b, uint64_t n)
{
	while (n) {
		size_t k = n < RECV_CHUNK ? (size_t)n : RECV_CHUNK;
		if (read_full(in, b ? b : g_buf, k) != 1) return -1;
		if (b) b += k;
		n -= k;
	}
	return 0;
}

/* ---- the armed state (protocol version 2) ----------------------------------------- */

/* ARM is taken once per start: NEVER → ARMED → DONE (after DISARM or a reboot request) */
enum { ARM_NEVER = 0, ARM_ARMED = 1, ARM_DONE = 2 };
static int g_armed; /* changed only by the serving thread */

struct range { uint32_t disk; uint64_t offset, length; };
static struct range g_range[MAX_RANGES];
static int g_nranges;

/* the mmc boot areas (and their partitions): never armed, whatever the request */
static int is_boot_area(const char *name) { return !fnmatch("mmcblk*boot*", name, 0); }

static int set_force_ro(const char *name, int on)
{
	char p[PATH_MAX];
	snprintf(p, sizeof p, "/sys/block/%s/force_ro", name);
	if (access(p, F_OK)) return 0;
	return write_file(p, on ? "1" : "0");
}

/* 0 when every partition of /sys/block/NAME is read-only in the kernel (BLKROGET) */
static int partitions_ro(const char *name)
{
	char path[PATH_MAX];
	snprintf(path, sizeof path, "/sys/block/%s", name);
	DIR *dir = opendir(path);
	if (!dir) return -1;
	int bad = 0;
	struct dirent *e;
	while ((e = readdir(dir))) {
		struct stat st;
		int ro = 0;
		if (e->d_name[0] == '.') continue;
		snprintf(path, sizeof path, "/sys/block/%s/%s/partition", name, e->d_name);
		if (stat(path, &st) < 0) continue;
		snprintf(path, sizeof path, "/dev/%s", e->d_name);
		int fd = open(path, O_RDONLY | O_CLOEXEC);
		if (fd < 0 || ioctl(fd, BLKROGET, &ro) < 0 || !ro) {
			say("%s: not read-only (partition of %s)", e->d_name, name);
			bad = 1;
		}
		if (fd >= 0) close(fd);
	}
	closedir(dir);
	return bad ? -1 : 0;
}

/* The whole-disk device of d writable (force_ro 0, BLKROSET 0), its partitions still
 * read-only, and the write and read-back descriptors open. A file (the unit test) only
 * gets its write descriptor. */
static int disk_writable(struct disk *d)
{
	d->armed = 1;
	if (d->block) {
		int zero = 0, ro = 1;
		if (set_force_ro(d->name, 0) < 0) { say("%s: force_ro 0: %s", d->name, strerror(errno)); return -1; }
		if (ioctl(d->fd, BLKROSET, &zero) < 0 || ioctl(d->fd, BLKROGET, &ro) < 0 || ro) {
			say("%s: cannot be made writable: %s", d->name, ro ? "still read-only" : strerror(errno));
			return -1;
		}
		if (partitions_ro(d->name) < 0) return -1;
		d->wfd = open(d->path, O_RDWR | O_DIRECT | O_CLOEXEC | O_LARGEFILE);
		d->rfd = open(d->path, O_RDONLY | O_DIRECT | O_CLOEXEC | O_LARGEFILE);
		if (d->wfd < 0 || d->rfd < 0) { say("%s: open for writing: %s", d->path, strerror(errno)); return -1; }
	} else {
		d->wfd = open(d->path, O_RDWR | O_CLOEXEC | O_LARGEFILE);
		if (d->wfd < 0) { say("%s: open for writing: %s", d->path, strerror(errno)); return -1; }
	}
	return 0;
}

/* back to read-only: descriptors flushed and closed, BLKROSET 1, force_ro 1, the cache
 * dropped, and checked; 0 = read-only again */
static int disk_readonly(struct disk *d)
{
	int bad = 0;
	if (d->wfd >= 0) {
		if (fsync(d->wfd) < 0) bad = 1;
		close(d->wfd);
		d->wfd = -1;
	}
	if (d->rfd >= 0) { close(d->rfd); d->rfd = -1; }
	if (d->block) {
		if (set_ro(d->fd) < 0) { say("%s: cannot set read-only again: %s", d->name, strerror(errno)); bad = 1; }
		if (set_force_ro(d->name, 1) < 0) { say("%s: force_ro 1: %s", d->name, strerror(errno)); bad = 1; }
		if (ioctl(d->fd, BLKFLSBUF, 0) < 0) bad = 1;
		if (partitions_ro(d->name) < 0) bad = 1;
	}
	d->armed = 0;
	return bad ? -1 : 0;
}

/* every armed disk read-only again; ARM can't be taken again in this start */
static int disarm_all(void)
{
	int bad = 0;
	for (int i = 0; i < g_ndisks; i++)
		if (g_disk[i].armed && disk_readonly(&g_disk[i]) < 0) bad = 1;
	if (g_armed == ARM_ARMED) { g_armed = ARM_DONE; say("disarmed: every disk read-only again%s", bad ? " (FAILED for one)" : ""); }
	g_nranges = 0;
	return bad ? -1 : 0;
}

/* a decimal number of at most 20 digits that fits in 64 bits */
static int parse_u64(const char *s, uint64_t *v)
{
	if (!*s || strlen(s) > 20) return -1;
	uint64_t x = 0;
	for (; *s; s++) {
		if (*s < '0' || *s > '9') return -1;
		if (x > (UINT64_MAX - (uint64_t)(*s - '0')) / 10) return -1;
		x = x * 10 + (uint64_t)(*s - '0');
	}
	*v = x;
	return 0;
}

/* The ARM text: lines `range DISK OFFSET LENGTH` (DISK = the index LIST gives, or the
 * disk's name; numbers decimal; fields separated by one space; empty lines ignored).
 * Status 0 and the ranges, or a status and why. */
static uint16_t parse_ranges(char *t, size_t len, struct range *rg, int *n, char *why, size_t wn)
{
	*n = 0;
	if (memchr(t, 0, len)) { snprintf(why, wn, "the ARM text has a NUL byte"); return ST_BAD_REQUEST; }
	int line = 0;
	for (char *l = t, *e; l < t + len; l = e + 1) {
		e = memchr(l, '\n', (size_t)(t + len - l));
		if (!e) e = t + len;
		*e = 0;
		line++;
		if (!*l) continue;
		char *f[5];
		int nf = 0;
		for (char *p = l; nf < 5;) {
			f[nf++] = p;
			p = strchr(p, ' ');
			if (!p) break;
			*p++ = 0;
		}
		uint64_t idx = UINT64_MAX, off, ln;
		if (nf != 4 || strcmp(f[0], "range") || parse_u64(f[2], &off) < 0 || parse_u64(f[3], &ln) < 0) {
			snprintf(why, wn, "line %d is not `range DISK OFFSET LENGTH`", line);
			return ST_BAD_REQUEST;
		}
		if (*n >= MAX_RANGES) { snprintf(why, wn, "more than %d ranges", MAX_RANGES); return ST_BAD_REQUEST; }
		if (parse_u64(f[1], &idx) < 0)
			for (int i = 0; i < g_ndisks; i++)
				if (!strcmp(g_disk[i].name, f[1])) idx = (uint64_t)i;
		if (idx >= (uint64_t)g_ndisks) { snprintf(why, wn, "line %d: no disk %.40s", line, f[1]); return ST_NO_DISK; }
		const struct disk *d = &g_disk[idx];
		if (is_boot_area(d->name)) { snprintf(why, wn, "line %d: %s is a boot area, never written", line, d->name); return ST_RANGE; }
		if (!ln || off % ALIGN || ln % ALIGN || off % d->sector || ln % d->sector) {
			snprintf(why, wn, "line %d: empty, or not a multiple of 512 and the disk's sector", line);
			return ST_RANGE;
		}
		if (off > d->size || ln > d->size - off) { snprintf(why, wn, "line %d: past the end of %s", line, d->name); return ST_RANGE; }
		for (int k = 0; k < *n; k++)
			if (rg[k].disk == idx && off < rg[k].offset + rg[k].length && rg[k].offset < off + ln) {
				snprintf(why, wn, "line %d overlaps another range", line);
				return ST_RANGE;
			}
		rg[*n].disk = (uint32_t)idx;
		rg[*n].offset = off;
		rg[*n].length = ln;
		(*n)++;
	}
	if (!*n) { snprintf(why, wn, "no range"); return ST_BAD_REQUEST; }
	return ST_OK;
}

/* the reboot itself; the unit test replaces it */
static void (*g_reboot)(int target);

static void do_reboot(int target)
{
	sync();
	if (target == REBOOT_BOOTLOADER)
		syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART2, "bootloader");
	reboot(RB_AUTOBOOT);
}

static int reply(int out, const struct request *r, uint16_t status, const char *why)
{
	uint8_t h[RSP_SIZE];
	size_t n = why ? strlen(why) : 0;
	put_response(h, r->version, r->op, r->tag, status, n, r->offset, NULL);
	phase(PH_SEND);
	int rc = write_full(out, h, RSP_SIZE) < 0 || (n && write_full(out, (const uint8_t *)why, n) < 0) ? -1 : 0;
	phase(PH_WAIT);
	return rc;
}

/* 0 if [offset, offset+length) is a valid range of disk i for an operation of at most max */
static uint16_t check_range(const struct request *r, uint64_t max, const char **why)
{
	if (r->index >= (uint32_t)g_ndisks) { *why = "no such disk"; return ST_NO_DISK; }
	const struct disk *d = &g_disk[r->index];
	if (r->length == 0 || r->length > max) { *why = "length is 0 or above the limit"; return ST_RANGE; }
	if (r->offset % ALIGN || r->length % ALIGN) { *why = "offset or length not a multiple of 512"; return ST_RANGE; }
	if (r->offset > d->size || r->length > d->size - r->offset) { *why = "past the end of the disk"; return ST_RANGE; }
	return ST_OK;
}

static int op_list(int out, const struct request *r)
{
	char t[2048];
	int n = snprintf(t, sizeof t, "glassine-ramread %d\nmax-read %u\nmax-hash %u\nalign %u\n",
			 r->version, MAX_READ, MAX_HASH, ALIGN);
	if (r->version >= PROTO_V2)
		n += g_armed == ARM_ARMED ? snprintf(t + n, sizeof t - (size_t)n, "writes armed %d\n", g_nranges)
					  : snprintf(t + n, sizeof t - (size_t)n, "writes off\n");
	for (int i = 0; i < g_ndisks && n < (int)sizeof t - 128; i++)
		n += snprintf(t + n, sizeof t - (size_t)n, "disk %d %s %llu %u\n", i, g_disk[i].name,
			      (unsigned long long)g_disk[i].size, g_disk[i].sector);
	uint8_t h[RSP_SIZE];
	put_response(h, r->version, r->op, r->tag, ST_OK, (uint64_t)n, 0, NULL);
	phase(PH_SEND);
	int rc = write_full(out, h, RSP_SIZE) < 0 || write_full(out, (uint8_t *)t, (size_t)n) < 0 ? -1 : 0;
	phase(PH_WAIT);
	return rc;
}

static int op_read(int out, const struct request *r)
{
	const char *why = NULL;
	uint16_t st = check_range(r, MAX_READ, &why);
	if (st) return reply(out, r, st, why);
	phase(PH_DISK);
	if (pread_full(g_disk[r->index].fd, g_buf, (size_t)r->length, r->offset) < 0) {
		say("%s: read at %llu: %s", g_disk[r->index].name, (unsigned long long)r->offset, strerror(errno));
		phase(PH_WAIT);
		return reply(out, r, ST_IO, "the disk returned an error");
	}
	struct sha256 s;
	uint8_t sum[32], h[RSP_SIZE];
	sha256_init(&s);
	sha256_update(&s, g_buf, (size_t)r->length);
	sha256_final(&s, sum);
	put_response(h, r->version, r->op, r->tag, ST_OK, r->length, r->offset, sum);
	phase(PH_SEND);
	int rc = write_full(out, h, RSP_SIZE) < 0 || write_full(out, g_buf, (size_t)r->length) < 0 ? -1 : 0;
	phase(PH_WAIT);
	return rc;
}

static int op_hash(int out, const struct request *r)
{
	const char *why = NULL;
	uint16_t st = check_range(r, MAX_HASH, &why);
	if (st) return reply(out, r, st, why);
	struct sha256 s;
	sha256_init(&s);
	phase(PH_DISK);
	for (uint64_t done = 0; done < r->length;) {
		size_t k = r->length - done < MAX_READ ? (size_t)(r->length - done) : MAX_READ;
		if (pread_full(g_disk[r->index].fd, g_buf, k, r->offset + done) < 0) {
			phase(PH_WAIT);
			return reply(out, r, ST_IO, "the disk returned an error");
		}
		sha256_update(&s, g_buf, k);
		done += k;
	}
	uint8_t sum[32], h[RSP_SIZE];
	sha256_final(&s, sum);
	put_response(h, r->version, r->op, r->tag, ST_OK, 0, r->offset, sum);
	phase(PH_SEND);
	int rc = write_full(out, h, RSP_SIZE);
	phase(PH_WAIT);
	return rc;
}

/* ARM (v2): the text of `length` bytes names the ranges; once per start, all or nothing */
static int op_arm(int in, int out, const struct request *r)
{
	static char t[MAX_ARM_TEXT + 1];
	char why[160];
	if (r->length > MAX_ARM_TEXT) {
		if (recv_bytes(in, NULL, r->length) < 0) return -1;
		snprintf(why, sizeof why, "ARM text above %u bytes", MAX_ARM_TEXT);
		return reply(out, r, ST_BAD_REQUEST, why);
	}
	if (recv_bytes(in, (uint8_t *)t, r->length) < 0) return -1;
	t[r->length] = 0;
	if (g_armed != ARM_NEVER) return reply(out, r, ST_ARMED, "ARM was taken already in this start");
	struct range rg[MAX_RANGES];
	int n = 0;
	uint16_t st = parse_ranges(t, (size_t)r->length, rg, &n, why, sizeof why);
	if (st) return reply(out, r, st, why);
	phase(PH_DISK);
	int bad = 0;
	for (int i = 0; i < g_ndisks && !bad; i++)
		for (int k = 0; k < n; k++)
			if (rg[k].disk == (uint32_t)i) { bad = disk_writable(&g_disk[i]) < 0; break; }
	if (bad) {
		int still = disarm_all() < 0;
		phase(PH_WAIT);
		return reply(out, r, ST_IO, still ? "a disk could not be made writable, and not read-only again either"
						  : "a disk could not be made writable; every disk is read-only");
	}
	memcpy(g_range, rg, sizeof rg[0] * (size_t)n);
	g_nranges = n;
	g_armed = ARM_ARMED;
	for (int k = 0; k < n; k++)
		say("armed: %s [%llu, +%llu)", g_disk[rg[k].disk].name, (unsigned long long)rg[k].offset,
		    (unsigned long long)rg[k].length);
	phase(PH_WAIT);
	snprintf(why, sizeof why, "armed %d", n);
	return reply(out, r, ST_OK, why);
}

/* WRITE (v2): `length` bytes, then their sha256; written inside one armed range, then
 * read back from the disk; the answer is the read-back's sha256 */
static int op_write(int in, int out, const struct request *r)
{
	uint8_t want[32], got[32], h[RSP_SIZE], hs[32];
	char why[160];
	if (r->length > MAX_WRITE) {
		if (recv_bytes(in, NULL, r->length) < 0 || recv_bytes(in, want, 32) < 0) return -1;
		return reply(out, r, ST_RANGE, "length above the limit");
	}
	if (recv_bytes(in, g_buf, r->length) < 0 || recv_bytes(in, want, 32) < 0) return -1;
	if (g_armed != ARM_ARMED) return reply(out, r, ST_NOT_ARMED, g_armed == ARM_DONE ? "disarmed" : "not armed");
	const char *w = NULL;
	uint16_t st = check_range(r, MAX_WRITE, &w);
	if (st) return reply(out, r, st, w);
	struct disk *d = &g_disk[r->index];
	if (r->offset % d->sector || r->length % d->sector) return reply(out, r, ST_RANGE, "not a multiple of the disk's sector");
	int inside = 0;
	for (int k = 0; k < g_nranges; k++)
		if (g_range[k].disk == r->index && r->offset >= g_range[k].offset
		    && r->offset + r->length <= g_range[k].offset + g_range[k].length) inside = 1;
	if (!inside) return reply(out, r, ST_RANGE, "not inside one armed range");
	struct sha256 s;
	sha256_init(&s);
	sha256_update(&s, g_buf, (size_t)r->length);
	sha256_final(&s, got);
	if (memcmp(got, want, 32)) return reply(out, r, ST_BAD_DATA, "the bytes don't have the sha256 sent with them; nothing written");

	phase(PH_DISK);
	const char *fail = NULL;
	if (pwrite_full(d->wfd, g_buf, (size_t)r->length, r->offset) < 0) fail = "the write failed";
	else if (fdatasync(d->wfd) < 0) fail = "the flush to the disk failed";
	else if (d->block && ioctl(d->wfd, BLKFLSBUF, 0) < 0) fail = "dropping the disk's cache failed";
	else {
		memset(g_buf, 0, (size_t)r->length);
		if (pread_full(d->rfd >= 0 ? d->rfd : d->fd, g_buf, (size_t)r->length, r->offset) < 0) fail = "the read-back failed";
	}
	if (fail) {
		say("%s: %s at %llu: %s", d->name, fail, (unsigned long long)r->offset, strerror(errno));
		phase(PH_WAIT);
		snprintf(why, sizeof why, "%s (the range may be partly written)", fail);
		return reply(out, r, ST_IO, why);
	}
	sha256_init(&s);
	sha256_update(&s, g_buf, (size_t)r->length);
	sha256_final(&s, got);
	if (memcmp(got, want, 32))
		say("%s: the read-back at %llu differs from what was written", d->name, (unsigned long long)r->offset);
	/* the header's sha256 is the payload's, as for every payload */
	sha256_init(&s);
	sha256_update(&s, got, 32);
	sha256_final(&s, hs);
	put_response(h, r->version, r->op, r->tag, ST_OK, 32, r->offset, hs);
	phase(PH_SEND);
	int rc = write_full(out, h, RSP_SIZE) < 0 || write_full(out, got, 32) < 0 ? -1 : 0;
	phase(PH_WAIT);
	return rc;
}

/* DISARM (v2): every disk read-only again (a no-op when nothing is armed) */
static int op_disarm(int out, const struct request *r)
{
	phase(PH_DISK);
	int bad = disarm_all() < 0;
	phase(PH_WAIT);
	return bad ? reply(out, r, ST_IO, "a disk could not be made read-only again")
		   : reply(out, r, ST_OK, NULL);
}

#ifdef GLASSINE_RECOVERY
/* ---- the recovery (protocol version 3, docs/recovery.md) ---------------------------- */

#define MAX_DEPLOY_TEXT 4096u
#define MAX_TOOL_OUTPUT (256u << 10)
#define MAX_DIAG MAX_READ
#define MAX_DEPLOY_PARTS 8
#define TOOL_NOT_OFFERED 64 /* describe/deploy: the action isn't offered (glassine-deploy has no such verb) */

static const char *g_tools;              /* --tools DIR */
static long g_tool_limit = 900;
static char g_dpart[MAX_DEPLOY_PARTS][64]; /* --deploy-part */
static int g_ndparts;
static atomic_int g_wd_stop;             /* a tool that can't be stopped: no more petting */
static __thread int t_local;             /* this thread serves the local socket */

/* Runs TOOLS/argv[0] with argv, stdin /dev/null, stdout and stderr into *out (at most
 * MAX_TOOL_OUTPUT bytes kept; more is cut, and the cut is said). Its own process
 * group; past --tool-limit it gets SIGTERM, 20 s later SIGKILL; one that doesn't end
 * 30 s after that stops the watchdog's petting (a process stuck in the kernel).
 * Returns its exit status (0-255), 124 timed out, -1 not started. */
static int run_tool(char *const argv[], char **out, size_t *outn)
{
	char path[PATH_MAX];
	int p[2];
	*out = NULL; *outn = 0;
	snprintf(path, sizeof path, "%s/%s", g_tools ? g_tools : "", argv[0]);
	if (pipe2(p, O_CLOEXEC) < 0) return -1;
	pid_t pid = fork();
	if (pid < 0) { close(p[0]); close(p[1]); return -1; }
	if (pid == 0) {
		setpgid(0, 0);
		int nul = open("/dev/null", O_RDONLY);
		if (nul >= 0) dup2(nul, 0);
		dup2(p[1], 1);
		dup2(p[1], 2);
		setenv("RECOVERY_TRANSPORT", t_local ? "local" : "usb", 1);
		execv(path, argv);
		dprintf(2, "cannot run %s: %s\n", path, strerror(errno));
		_exit(127);
	}
	close(p[1]);
	size_t cap = 4096, n = 0;
	char *b = malloc(cap + 64);
	int cut = 0, timed = 0;
	long t0 = now_s();
	for (;;) {
		long left = g_tool_limit - (now_s() - t0);
		if (left <= 0) { timed = 1; break; }
		struct pollfd pf = { .fd = p[0], .events = POLLIN };
		int r = poll(&pf, 1, (int)(left > 1 ? 1000 : left * 1000));
		if (r < 0 && errno == EINTR) continue;
		if (r <= 0) continue;
		char tmp[4096];
		ssize_t k = read(p[0], tmp, sizeof tmp);
		if (k < 0 && errno == EINTR) continue;
		if (k <= 0) break;
		if (b && n + (size_t)k > cap && cap < MAX_TOOL_OUTPUT) {
			while (cap < n + (size_t)k && cap < MAX_TOOL_OUTPUT) cap *= 2;
			if (cap > MAX_TOOL_OUTPUT) cap = MAX_TOOL_OUTPUT;
			char *nb = realloc(b, cap + 64);
			if (nb) b = nb;
		}
		size_t keep = b && n < cap ? (cap - n < (size_t)k ? cap - n : (size_t)k) : 0;
		if (keep) { memcpy(b + n, tmp, keep); n += keep; }
		if (keep < (size_t)k) cut = 1;
	}
	close(p[0]);
	int st = 0, done = 0;
	if (timed) {
		say("%s: still running after %ld s: stopping it", argv[0], g_tool_limit);
		kill(-pid, SIGTERM);
		for (int i = 0; i < 20 && !done; i++) { if (waitpid(pid, &st, WNOHANG) == pid) done = 1; else sleep(1); }
		if (!done) kill(-pid, SIGKILL);
		for (int i = 0; i < 30 && !done; i++) { if (waitpid(pid, &st, WNOHANG) == pid) done = 1; else sleep(1); }
		if (!done) {
			say("%s does not end: no more petting, the watchdog resets the device", argv[0]);
			atomic_store(&g_wd_stop, 1);
		}
	} else {
		while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
		done = 1;
	}
	if (b && cut) n += (size_t)snprintf(b + n, 64, "\n[output cut at %u bytes]\n", MAX_TOOL_OUTPUT);
	*out = b; *outn = b ? n : 0;
	if (timed) return 124;
	return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + (WIFSIGNALED(st) ? WTERMSIG(st) : 0);
}

/* the header, then the text: a text payload (sha256 zero), as every text answer */
static int reply_text(int out, const struct request *r, uint16_t status, const char *a, size_t an,
		      const char *b, size_t bn)
{
	uint8_t h[RSP_SIZE];
	put_response(h, r->version, r->op, r->tag, status, an + bn, r->offset, NULL);
	phase(PH_SEND);
	int rc = write_full(out, h, RSP_SIZE) < 0 || (an && write_full(out, (const uint8_t *)a, an) < 0)
		 || (bn && write_full(out, (const uint8_t *)b, bn) < 0) ? -1 : 0;
	phase(PH_WAIT);
	return rc;
}

/* STATUS (v3): the recovery's identity and glassine-deploy's state, as the status tool
 * prints them (docs/recovery.md); nothing is written */
static int op_status(int out, const struct request *r)
{
	char *argv[] = { "status", NULL }, *o;
	size_t on;
	char head[256];
	phase(PH_TOOL);
	int x = run_tool(argv, &o, &on);
	phase(PH_WAIT);
	int hn = snprintf(head, sizeof head, "glassine-recovery %d\nconnection %s\n%s", PROTO_V3, t_local ? "local" : "usb",
			  g_armed == ARM_ARMED ? "writes armed\n" : "");
	int rc;
	if (x != 0) {
		char e[64];
		int en = snprintf(e, sizeof e, "exit %d\n", x);
		rc = reply_text(out, r, ST_TOOL, e, (size_t)en, o, on);
	} else rc = reply_text(out, r, ST_OK, head, (size_t)hn, o, on);
	free(o);
	return rc;
}

/* a deployment id: [A-Za-z0-9._-]+, not starting with a dot (docs/deployments.md) */
static int valid_id(const char *s)
{
	if (!*s || *s == '.' || strlen(s) > 128) return 0;
	for (; *s; s++)
		if (!((*s >= 'A' && *s <= 'Z') || (*s >= 'a' && *s <= 'z') || (*s >= '0' && *s <= '9') || *s == '.' || *s == '_' || *s == '-')) return 0;
	return 1;
}

/* the actions DEPLOY knows, and whether each names a deployment */
static const struct { const char *name; int id; } g_actions[] = {
	{ "select", 1 }, { "rollback", 0 }, { "pin", 1 }, { "remove", 1 }, { "reset", 0 }, { "reset-full", 0 },
};

/* the parent disk (a /sys/block name) of the partition NAME, or -1 */
static int part_parent(const char *name, char *parent, size_t n)
{
	char p[PATH_MAX], l[PATH_MAX];
	snprintf(p, sizeof p, "/sys/class/block/%s", name);
	ssize_t k = readlink(p, l, sizeof l - 1);
	if (k <= 0) return -1;
	l[k] = 0;
	char *e = strrchr(l, '/');
	if (!e) return -1;
	*e = 0;
	e = strrchr(l, '/');
	if (!e) return -1;
	snprintf(parent, n, "%s", e + 1);
	snprintf(p, sizeof p, "/sys/class/block/%s/partition", name);
	return access(p, F_OK) ? -1 : 0;
}

/* /dev/NAME BLKROSET v, then BLKROGET must say v */
static int part_ro(const char *name, int v)
{
	char p[PATH_MAX];
	int ro = !v;
	snprintf(p, sizeof p, "/dev/%s", name);
	int fd = open(p, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	int rc = ioctl(fd, BLKROSET, &v) < 0 || ioctl(fd, BLKROGET, &ro) < 0 || ro != v ? -1 : 0;
	close(fd);
	return rc;
}

/* every mount of /dev/NAME, unmounted (a tool that died with one left) */
static void unmount_part(const char *name)
{
	char dev[PATH_MAX], line[2048];
	snprintf(dev, sizeof dev, "/dev/%s", name);
	for (int pass = 0; pass < 4; pass++) {
		FILE *f = fopen("/proc/self/mounts", "r");
		if (!f) return;
		char mp[1024] = "";
		while (fgets(line, sizeof line, f)) {
			char src[1024], at[1024];
			if (sscanf(line, "%1023s %1023s", src, at) == 2 && !strcmp(src, dev)) snprintf(mp, sizeof mp, "%s", at);
		}
		fclose(f);
		if (!*mp) return;
		say("%s still mounted on %s after the tool: unmounting", name, mp);
		if (umount2(mp, 0) < 0) umount2(mp, MNT_DETACH);
	}
}

/* The partitions DEPLOY writes through (--deploy-part), writable for one operation:
 * force_ro 0 on their disk and BLKROSET 0 on each, while the whole-disk devices and
 * every other partition stay read-only (checked). on = 0: back, every mount of them
 * gone first, each disk's cache dropped (the whole-disk device has its own cache, and
 * READ and HASH go through it), every served disk and partition read-only again
 * (checked). 0 = done. */
static int deploy_parts_rw(int on)
{
	int bad = 0;
	char parent[64];
	for (int i = 0; i < g_ndparts; i++) {
		if (part_parent(g_dpart[i], parent, sizeof parent) < 0) { if (on) say("%s: not a partition", g_dpart[i]); bad = 1; continue; }
		if (is_boot_area(parent)) { say("%s: on a boot area, never written", g_dpart[i]); bad = 1; continue; }
		if (on) {
			if (set_force_ro(parent, 0) < 0 || part_ro(g_dpart[i], 0) < 0) {
				say("%s: cannot be made writable: %s", g_dpart[i], strerror(errno));
				bad = 1;
			}
		} else {
			unmount_part(g_dpart[i]);
			if (part_ro(g_dpart[i], 1) < 0) { say("%s: cannot set read-only again: %s", g_dpart[i], strerror(errno)); bad = 1; }
			if (set_force_ro(parent, 1) < 0) { say("%s: force_ro 1: %s", parent, strerror(errno)); bad = 1; }
		}
	}
	/* the served disks: whole-disk devices read-only; on: every partition but the
	 * deploy ones read-only; off: every partition read-only */
	for (int i = 0; i < g_ndisks; i++) {
		struct disk *d = &g_disk[i];
		if (!d->block) continue;
		int ro = 0;
		if (!on && ioctl(d->fd, BLKFLSBUF, 0) < 0) bad = 1;
		if (ioctl(d->fd, BLKROGET, &ro) < 0 || !ro) { say("%s: not read-only", d->name); bad = 1; }
		if (!on) { if (partitions_ro(d->name) < 0) bad = 1; continue; }
		char path[PATH_MAX];
		snprintf(path, sizeof path, "/sys/block/%.63s", d->name);
		DIR *dir = opendir(path);
		if (!dir) { bad = 1; continue; }
		struct dirent *e;
		while ((e = readdir(dir))) {
			struct stat st;
			int pro = 0, mine = 0;
			if (e->d_name[0] == '.') continue;
			snprintf(path, sizeof path, "/sys/block/%.63s/%.255s/partition", d->name, e->d_name);
			if (stat(path, &st) < 0) continue;
			for (int k = 0; k < g_ndparts; k++) if (!strcmp(g_dpart[k], e->d_name)) mine = 1;
			if (mine) continue;
			snprintf(path, sizeof path, "/dev/%s", e->d_name);
			int fd = open(path, O_RDONLY | O_CLOEXEC);
			if (fd < 0 || ioctl(fd, BLKROGET, &pro) < 0 || !pro) { say("%s: not read-only while deploying", e->d_name); bad = 1; }
			if (fd >= 0) close(fd);
		}
		closedir(dir);
	}
	if (!on) say("deploy: every disk read-only again%s", bad ? " (FAILED for one)" : "");
	return bad ? -1 : 0;
}

/* DEPLOY (v3): `length` bytes of text, lines `KEY VALUE`: `action A` (select, rollback,
 * pin, remove, reset, reset-full), `id ID` (select, pin, remove), `discard-hibernation
 * yes` (optional), `confirm TOKEN`. The token is the action, its id and
 * `discard-hibernation` when asked, one space apart (`select 20261101-120000`); without
 * it the answer is ST_CONFIRM, the token's line and what the operation does. With it,
 * the deploy partitions are writable for the run of the tool, then read-only again. */
static int op_deploy(int in, int out, const struct request *r)
{
	static char t[MAX_DEPLOY_TEXT + 1];
	if (r->length > MAX_DEPLOY_TEXT) {
		if (recv_bytes(in, NULL, r->length) < 0) return -1;
		return reply(out, r, ST_BAD_REQUEST, "DEPLOY text above 4096 bytes");
	}
	if (recv_bytes(in, (uint8_t *)t, r->length) < 0) return -1;
	t[r->length] = 0;
	if (memchr(t, 0, (size_t)r->length)) return reply(out, r, ST_BAD_REQUEST, "the DEPLOY text has a NUL byte");
	char action[32] = "", id[160] = "", confirm[256] = "", discard[8] = "";
	int seen_a = 0, seen_i = 0, seen_c = 0, seen_d = 0;
	for (char *l = t, *e; *l; l = e + 1) {
		e = strchr(l, '\n');
		if (!e) e = l + strlen(l);
		char save = *e;
		*e = 0;
		if (*l) {
			char *v = strchr(l, ' ');
			if (!v) return reply(out, r, ST_BAD_REQUEST, "a line is not `KEY VALUE`");
			*v++ = 0;
			if (!strcmp(l, "action") && !seen_a++ && strlen(v) < sizeof action) strcpy(action, v);
			else if (!strcmp(l, "id") && !seen_i++ && strlen(v) < sizeof id) strcpy(id, v);
			else if (!strcmp(l, "confirm") && !seen_c++ && strlen(v) < sizeof confirm) strcpy(confirm, v);
			else if (!strcmp(l, "discard-hibernation") && !seen_d++ && !strcmp(v, "yes")) strcpy(discard, v);
			else return reply(out, r, ST_BAD_REQUEST, "an unknown, repeated or too long line (keys: action, id, confirm, discard-hibernation yes)");
		}
		if (!save) break;
	}
	int a = -1;
	for (size_t i = 0; i < sizeof g_actions / sizeof g_actions[0]; i++) if (!strcmp(action, g_actions[i].name)) a = (int)i;
	if (a < 0) return reply(out, r, ST_BAD_REQUEST, "no action, or not one of select, rollback, pin, remove, reset, reset-full");
	if (g_actions[a].id ? !valid_id(id) : seen_i) return reply(out, r, ST_BAD_REQUEST, g_actions[a].id ? "the action needs `id ID` ([A-Za-z0-9._-], not starting with a dot)" : "the action takes no id");
	char token[256];
	snprintf(token, sizeof token, "%s%s%s%s", action, *id ? " " : "", id, *discard ? " discard-hibernation" : "");
	char *argv[6] = { "describe", action, NULL, NULL, NULL, NULL };
	int k = 2;
	if (*id) argv[k++] = id;
	if (*discard) argv[k++] = "discard-hibernation";
	char *o;
	size_t on;
	phase(PH_TOOL);
	int x = run_tool(argv, &o, &on);
	phase(PH_WAIT);
	int rc;
	char head[400];
	int hn;
	if (x == TOOL_NOT_OFFERED) {
		hn = snprintf(head, sizeof head, "not offered: ");
		rc = reply_text(out, r, ST_BAD_REQUEST, head, (size_t)hn, o, on);
		free(o);
		return rc;
	}
	if (x != 0) {
		hn = snprintf(head, sizeof head, "exit %d\n", x);
		rc = reply_text(out, r, ST_TOOL, head, (size_t)hn, o, on);
		free(o);
		return rc;
	}
	if (!seen_c || strcmp(confirm, token)) {
		hn = snprintf(head, sizeof head, "confirm %s\n", token);
		rc = reply_text(out, r, ST_CONFIRM, head, (size_t)hn, o, on);
		free(o);
		return rc;
	}
	free(o);
	if (g_armed == ARM_ARMED) return reply(out, r, ST_ARMED, "ranges are armed for writing: DISARM first");
	say("deploy: %s confirmed (%s connection)", token, t_local ? "local" : "usb");
	phase(PH_DISK);
	if (deploy_parts_rw(1) < 0) {
		int still = deploy_parts_rw(0) < 0;
		phase(PH_WAIT);
		return reply(out, r, ST_IO, still ? "a partition could not be made writable, and not read-only again either"
						  : "a partition could not be made writable; every disk is read-only");
	}
	argv[0] = "deploy";
	phase(PH_TOOL);
	x = run_tool(argv, &o, &on);
	phase(PH_DISK);
	int still = deploy_parts_rw(0) < 0;
	phase(PH_WAIT);
	say("deploy: %s ended, exit %d", token, x);
	hn = snprintf(head, sizeof head, "exit %d\n%s", x, still ? "WARNING: a disk could not be made read-only again\n" : "");
	rc = reply_text(out, r, x == 0 && !still ? ST_OK : x == 0 ? ST_IO : ST_TOOL, head, (size_t)hn, o, on);
	free(o);
	return rc;
}

/* DIAG (v3): the diagnostics file the diag tool writes (a gzip'ed tar, at most
 * MAX_DIAG bytes), as the payload with its sha256 */
static int op_diag(int out, const struct request *r)
{
	char file[] = "/tmp/glassine-diag.XXXXXX";
	int fd = mkstemp(file);
	if (fd < 0) return reply(out, r, ST_IO, "no temporary file");
	close(fd);
	char *argv[] = { "diag", file, NULL }, *o;
	size_t on;
	phase(PH_TOOL);
	int x = run_tool(argv, &o, &on);
	phase(PH_WAIT);
	if (x != 0) {
		char head[64];
		int hn = snprintf(head, sizeof head, "exit %d\n", x);
		unlink(file);
		int rc = reply_text(out, r, ST_TOOL, head, (size_t)hn, o, on);
		free(o);
		return rc;
	}
	free(o);
	fd = open(file, O_RDONLY | O_CLOEXEC);
	unlink(file);
	struct stat st;
	if (fd < 0 || fstat(fd, &st) < 0 || st.st_size <= 0 || (uint64_t)st.st_size > MAX_DIAG) {
		if (fd >= 0) close(fd);
		return reply(out, r, ST_IO, "the diagnostics file is missing, empty or above 16 MiB");
	}
	size_t n = (size_t)st.st_size;
	int bad = pread_full(fd, g_buf, n, 0) < 0;
	close(fd);
	if (bad) return reply(out, r, ST_IO, "cannot read the diagnostics file");
	struct sha256 s;
	uint8_t sum[32], h[RSP_SIZE];
	sha256_init(&s);
	sha256_update(&s, g_buf, n);
	sha256_final(&s, sum);
	put_response(h, r->version, r->op, r->tag, ST_OK, n, r->offset, sum);
	phase(PH_SEND);
	int rc = write_full(out, h, RSP_SIZE) < 0 || write_full(out, g_buf, n) < 0 ? -1 : 0;
	phase(PH_WAIT);
	return rc;
}
#endif

/* One request. Returns 1 to go on, 0 when the request was a reboot (already answered),
 * -1 when the connection failed. */
static int handle(int in, int out, const uint8_t b[REQ_SIZE])
{
	struct request r = { 0 };
	atomic_store(&g_last_request, now_s());
	atomic_fetch_add(&g_requests, 1);
	if (parse_request(b, &r) < 0) {
		uint16_t v = ld16(b + 4);
		r.version = PROTO_V1;
		r.op = ld16(b + 6);
		r.tag = ld32(b + 8);
		r.offset = 0;
		return reply(out, &r, ST_BAD_REQUEST, v <= PROTO_V1 ? "not a request of protocol version 1"
#ifdef GLASSINE_RECOVERY
							      : "not a request of protocol version 1, 2 or 3") < 0 ? -1 : 1;
#else
							      : "not a request of protocol version 1 or 2") < 0 ? -1 : 1;
#endif
	}
	/* a version 1 request knows only the four operations */
	int op = r.version == PROTO_V1 && r.op > OP_REBOOT ? 0 : r.op;
#ifdef GLASSINE_RECOVERY
	/* version 2 knows only the seven; the local socket never writes to a disk (its
	 * payload is read and dropped, so the next request stays in step) */
	if (r.version < PROTO_V3 && op > OP_DISARM) op = 0;
	if (t_local && (op == OP_ARM || op == OP_WRITE || op == OP_DISARM)) {
		if ((op == OP_ARM && recv_bytes(in, NULL, r.length) < 0)
		    || (op == OP_WRITE && (recv_bytes(in, NULL, r.length) < 0 || recv_bytes(in, NULL, 32) < 0))) return -1;
		return reply(out, &r, ST_UNKNOWN_OP, "not offered on the local connection: writes are USB's") < 0 ? -1 : 1;
	}
	switch (op) {
	case OP_STATUS: return op_status(out, &r) < 0 ? -1 : 1;
	case OP_DEPLOY: return op_deploy(in, out, &r) < 0 ? -1 : 1;
	case OP_DIAG: return op_diag(out, &r) < 0 ? -1 : 1;
	default: break;
	}
#endif
	switch (op) {
	case OP_LIST: return op_list(out, &r) < 0 ? -1 : 1;
	case OP_READ: return op_read(out, &r) < 0 ? -1 : 1;
	case OP_HASH: return op_hash(out, &r) < 0 ? -1 : 1;
	case OP_ARM: return op_arm(in, out, &r) < 0 ? -1 : 1;
	case OP_WRITE: return op_write(in, out, &r) < 0 ? -1 : 1;
	case OP_DISARM: return op_disarm(out, &r) < 0 ? -1 : 1;
	case OP_REBOOT:
		if (r.index != REBOOT_NORMAL && r.index != REBOOT_BOOTLOADER)
			return reply(out, &r, ST_BAD_REQUEST, "reboot target is 0 (normal) or 1 (boot loader)") < 0 ? -1 : 1;
		/* nothing stays writable across a reboot, even without DISARM */
		disarm_all();
		if (reply(out, &r, ST_OK, NULL) < 0) return -1;
		say("reboot (%s) asked by the computer", r.index ? "boot loader" : "normal");
		usleep(300000); /* let the answer leave */
		g_reboot((int)r.index);
		return 0;
	default:
		return reply(out, &r, ST_UNKNOWN_OP, "unknown operation") < 0 ? -1 : 1;
	}
}

/* one request at a time, whichever connection it came on (the recovery serves two) */
static pthread_mutex_t g_op_lock = PTHREAD_MUTEX_INITIALIZER;

/* Serves requests from in until it ends (0: end of stream, -1: error, 2: reboot) */
static int serve(int in, int out)
{
	uint8_t b[REQ_SIZE];
	for (;;) {
		/* under the lock: another connection's operation keeps its phase */
		pthread_mutex_lock(&g_op_lock);
		phase(PH_WAIT);
		pthread_mutex_unlock(&g_op_lock);
		int r = read_full(in, b, REQ_SIZE);
		if (r <= 0) return r;
		pthread_mutex_lock(&g_op_lock);
		r = handle(in, out, b);
		pthread_mutex_unlock(&g_op_lock);
		if (r <= 0) return r < 0 ? -1 : 2;
	}
}

#ifdef GLASSINE_RECOVERY
/* the local socket: one thread per connection (each console's menu holds one) */
static void *local_conn(void *arg)
{
	int fd = (int)(intptr_t)arg;
	t_local = 1;
	if (serve(fd, fd) == 2) pause(); /* rebooting */
	close(fd);
	return NULL;
}

static void *local_thread(void *arg)
{
	int ls = (int)(intptr_t)arg;
	for (;;) {
		int fd = accept4(ls, NULL, NULL, SOCK_CLOEXEC);
		if (fd < 0) { if (errno != EINTR) sleep(1); continue; }
		pthread_t t;
		if (pthread_create(&t, NULL, local_conn, (void *)(intptr_t)fd)) close(fd);
		else pthread_detach(t);
	}
	return NULL;
}
#endif

/* ---- the watchdog ----------------------------------------------------------------- */

static int g_wd = -1;
static long g_wd_timeout = 30, g_connect_wait = 300, g_idle = 600, g_op_limit = 120;
static long g_start;

static void *watchdog_thread(void *arg)
{
	(void)arg;
	long every = g_wd_timeout / 3 > 0 ? g_wd_timeout / 3 : 1;
	int stopped = 0;
	for (;;) {
		sleep((unsigned)every);
		long now = now_s(), since = now - atomic_load(&g_phase_since);
		int ph = atomic_load(&g_phase);
		long quiet = atomic_load(&g_requests) ? now - atomic_load(&g_last_request) : now - g_start;
		long limit = atomic_load(&g_requests) ? g_idle : g_connect_wait;
		if (ph == PH_DISK && since > g_op_limit) {
			if (!stopped) say("a disk operation has run %ld s: no more petting, the watchdog resets the device", since);
			stopped = 1;
		}
#ifdef GLASSINE_RECOVERY
		if (atomic_load(&g_wd_stop)) stopped = 1;
		if (stopped) continue;
		if (ph != PH_DISK && ph != PH_TOOL && quiet > limit) {
#else
		if (stopped) continue;
		if (ph != PH_DISK && quiet > limit) {
#endif
			say("no request for %ld s: rebooting into the previous system", quiet);
			g_reboot(REBOOT_NORMAL);
		}
		if (g_wd >= 0) {
			int dummy = 0;
			ioctl(g_wd, WDIOC_KEEPALIVE, &dummy);
		}
	}
	return NULL;
}

static void arm_watchdog(const char *dev)
{
	if (!dev) { say("no watchdog configured"); return; }
	g_wd = open(dev, O_WRONLY | O_CLOEXEC);
	if (g_wd < 0) { say("watchdog %s: %s (serving without it)", dev, strerror(errno)); return; }
	int t = (int)g_wd_timeout;
	if (ioctl(g_wd, WDIOC_SETTIMEOUT, &t) < 0) {
		t = 0;
		ioctl(g_wd, WDIOC_GETTIMEOUT, &t);
		if (t > 0) g_wd_timeout = t;
	} else if (t > 0) g_wd_timeout = t;
	int dummy = 0;
	ioctl(g_wd, WDIOC_KEEPALIVE, &dummy);
	say("watchdog %s armed, %ld s", dev, g_wd_timeout);
}

/* ---- FunctionFS --------------------------------------------------------------------- */

static const struct {
	struct usb_functionfs_descs_head_v2 header;
	__le32 fs_count, hs_count, ss_count, os_count;
	struct {
		struct usb_interface_descriptor intf;
		struct usb_endpoint_descriptor_no_audio in, out;
	} __attribute__((packed)) fs, hs;
	struct {
		struct usb_interface_descriptor intf;
		struct usb_endpoint_descriptor_no_audio in;
		struct usb_ss_ep_comp_descriptor in_comp;
		struct usb_endpoint_descriptor_no_audio out;
		struct usb_ss_ep_comp_descriptor out_comp;
	} __attribute__((packed)) ss;
	struct usb_os_desc_header os_header;
	struct usb_ext_compat_desc os_compat;
} __attribute__((packed)) descriptors = {
	.header = {
		.magic = FUNCTIONFS_DESCRIPTORS_MAGIC_V2,
		.flags = FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC | FUNCTIONFS_HAS_SS_DESC | FUNCTIONFS_HAS_MS_OS_DESC,
		.length = sizeof descriptors,
	},
	.fs_count = 3, .hs_count = 3, .ss_count = 5, .os_count = 1,
#define INTF { .bLength = sizeof(struct usb_interface_descriptor), .bDescriptorType = USB_DT_INTERFACE, \
	.bNumEndpoints = 2, .bInterfaceClass = RR_CLASS, .bInterfaceSubClass = RR_SUBCLASS, \
	.bInterfaceProtocol = RR_PROTOCOL, .iInterface = 1 }
#define EP(addr, mps) { .bLength = USB_DT_ENDPOINT_SIZE, .bDescriptorType = USB_DT_ENDPOINT, \
	.bEndpointAddress = (addr), .bmAttributes = USB_ENDPOINT_XFER_BULK, .wMaxPacketSize = (mps) }
#define COMP { .bLength = USB_DT_SS_EP_COMP_SIZE, .bDescriptorType = USB_DT_SS_ENDPOINT_COMP, .bMaxBurst = 15 }
	.fs = { INTF, EP(1 | USB_DIR_IN, 64), EP(2 | USB_DIR_OUT, 64) },
	.hs = { INTF, EP(1 | USB_DIR_IN, 512), EP(2 | USB_DIR_OUT, 512) },
	.ss = { INTF, EP(1 | USB_DIR_IN, 1024), COMP, EP(2 | USB_DIR_OUT, 1024), COMP },
	/* Windows binds WinUSB to the interface by itself (Microsoft OS 1.0 extended
	 * compat ID); the gadget's os_desc switches the answer on */
	.os_header = { .interface = 0, .dwLength = sizeof(struct usb_os_desc_header) + sizeof(struct usb_ext_compat_desc),
		       .bcdVersion = 1, .wIndex = 4, .bCount = 1 },
	.os_compat = { .bFirstInterfaceNumber = 0, .Reserved1 = 1, .CompatibleID = "WINUSB" },
};

#define IFACE_NAME "GlassineOS disk reader"
static const struct {
	struct usb_functionfs_strings_head header;
	struct { __le16 code; const char str1[sizeof IFACE_NAME]; } __attribute__((packed)) lang0;
} __attribute__((packed)) strings = {
	.header = { .magic = FUNCTIONFS_STRINGS_MAGIC, .length = sizeof strings, .str_count = 1, .lang_count = 1 },
	.lang0 = { 0x0409, IFACE_NAME },
};

static atomic_int g_enabled;

static void *ep0_thread(void *arg)
{
	int ep0 = *(int *)arg;
	struct usb_functionfs_event ev[4];
	for (;;) {
		ssize_t n = read(ep0, ev, sizeof ev);
		if (n < 0) { if (errno == EINTR) continue; say("ep0: %s", strerror(errno)); sleep(1); continue; }
		for (size_t i = 0; i < (size_t)n / sizeof ev[0]; i++) {
			switch (ev[i].type) {
			case FUNCTIONFS_ENABLE:
				atomic_store(&g_enabled, 1);
				say("the computer configured the interface");
				break;
			case FUNCTIONFS_DISABLE:
				atomic_store(&g_enabled, 0);
				say("the interface was disabled");
				break;
			case FUNCTIONFS_SETUP:
				/* no requests of our own: stall them */
				if (ev[i].u.setup.bRequestType & USB_DIR_IN) { if (write(ep0, NULL, 0) < 0) {} }
				else if (read(ep0, NULL, 0) < 0) {}
				break;
			default:
				break;
			}
		}
	}
	return NULL;
}

static int ffs_open(const char *dir, int *in, int *out)
{
	char p[PATH_MAX];
	static int ep0;
	snprintf(p, sizeof p, "%s/ep0", dir);
	ep0 = open(p, O_RDWR | O_CLOEXEC);
	if (ep0 < 0) { say("%s: %s", p, strerror(errno)); return -1; }
	if (write(ep0, &descriptors, sizeof descriptors) != (ssize_t)sizeof descriptors) { say("descriptors: %s", strerror(errno)); return -1; }
	if (write(ep0, &strings, sizeof strings) != (ssize_t)sizeof strings) { say("strings: %s", strerror(errno)); return -1; }
	snprintf(p, sizeof p, "%s/ep1", dir);
	*out = open(p, O_RDWR | O_CLOEXEC); /* bulk IN: to the computer */
	snprintf(p, sizeof p, "%s/ep2", dir);
	*in = open(p, O_RDWR | O_CLOEXEC);  /* bulk OUT: from the computer */
	if (*in < 0 || *out < 0) { say("endpoints: %s", strerror(errno)); return -1; }
	pthread_t t;
	return pthread_create(&t, NULL, ep0_thread, &ep0) ? -1 : 0;
}

/* ---- main --------------------------------------------------------------------------- */

#ifndef RAMREAD_NO_MAIN
static void usage(void)
{
	fprintf(stderr, "usage: glassine-ramread (--ffs DIR | --stream DEV) --disk PATTERN... [--ready FILE] [--watchdog DEV]\n"
			"         [--watchdog-timeout S] [--connect-wait S] [--idle S] [--op-limit S] [--disk-wait S]\n");
#ifdef GLASSINE_RECOVERY
	fprintf(stderr, "         --tools DIR [--socket PATH] [--deploy-part NAME]... [--tool-limit S]\n");
#endif
	exit(2);
}

static long num(const char *s)
{
	char *e;
	long v = strtol(s, &e, 10);
	if (!*s || *e || v <= 0) usage();
	return v;
}

int main(int argc, char **argv)
{
	char *pat[MAX_DISKS];
	int npat = 0;
	const char *ffs = NULL, *stream = NULL, *ready = NULL, *wd = NULL;
	long disk_wait = 60;
#ifdef GLASSINE_RECOVERY
	const char *sock = NULL;
#endif
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!v) usage();
		if (!strcmp(a, "--disk") && npat < MAX_DISKS) pat[npat++] = argv[++i];
#ifdef GLASSINE_RECOVERY
		else if (!strcmp(a, "--tools")) g_tools = argv[++i];
		else if (!strcmp(a, "--socket")) sock = argv[++i];
		else if (!strcmp(a, "--tool-limit")) g_tool_limit = num(argv[++i]);
		else if (!strcmp(a, "--deploy-part") && g_ndparts < MAX_DEPLOY_PARTS && strlen(v) < 64 && !strchr(v, '/'))
			snprintf(g_dpart[g_ndparts++], 64, "%s", argv[++i]);
#endif
		else if (!strcmp(a, "--ffs")) ffs = argv[++i];
		else if (!strcmp(a, "--stream")) stream = argv[++i];
		else if (!strcmp(a, "--ready")) ready = argv[++i];
		else if (!strcmp(a, "--watchdog")) wd = argv[++i];
		else if (!strcmp(a, "--watchdog-timeout")) g_wd_timeout = num(argv[++i]);
		else if (!strcmp(a, "--connect-wait")) g_connect_wait = num(argv[++i]);
		else if (!strcmp(a, "--idle")) g_idle = num(argv[++i]);
		else if (!strcmp(a, "--op-limit")) g_op_limit = num(argv[++i]);
		else if (!strcmp(a, "--disk-wait")) disk_wait = num(argv[++i]);
		else usage();
	}
	if (!npat || !!ffs == !!stream) usage();
#ifdef GLASSINE_RECOVERY
	if (!g_tools) usage();
#endif
	g_kmsg = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	signal(SIGPIPE, SIG_IGN);
	g_reboot = do_reboot;
	g_start = now_s();
	phase(PH_WAIT);
	arm_watchdog(wd);
	pthread_t t;
	if (pthread_create(&t, NULL, watchdog_thread, NULL)) { say("no watchdog thread"); return 1; }

	/* the disks: wait for a first match, then for the set to stay the same for 2 s (the
	 * mmc boot areas appear with the card) */
	char names[MAX_DISKS][64], again[MAX_DISKS][64];
	int n = 0;
	for (long w = 0; (n = match_disks(pat, npat, names)) == 0 && w < disk_wait * 2; w++) usleep(500000);
	if (!n) { say("no disk matches the patterns after %ld s", disk_wait); return 1; }
	for (;;) {
		sleep(2);
		int m = match_disks(pat, npat, again);
		if (m == n && !memcmp(names, again, sizeof names[0] * (size_t)n)) break;
		n = m;
		memcpy(names, again, sizeof names[0] * (size_t)n);
	}
	for (int i = 0; i < n; i++) {
		char dev[PATH_MAX];
		snprintf(dev, sizeof dev, "/dev/%s", names[i]);
		if (disk_add(names[i], dev, 1) < 0) { say("%s: not offered read-only: refusing to serve", names[i]); return 1; }
		say("disk %d: %s, %llu bytes, read-only", i, names[i], (unsigned long long)g_disk[i].size);
	}
	g_buf = aligned_alloc(4096, MAX_READ);
	if (!g_buf) return 1;

	int in = -1, out = -1;
	if (ffs) {
		if (ffs_open(ffs, &in, &out) < 0) return 1;
	} else {
		/* a virtio port appears once the host side has announced it */
		for (long w = 0; (in = open(stream, O_RDWR | O_CLOEXEC | O_NOCTTY)) < 0 && w < disk_wait * 2; w++) usleep(500000);
		if (in < 0) { say("%s: %s", stream, strerror(errno)); return 1; }
		out = in;
	}
#ifdef GLASSINE_RECOVERY
	if (sock) {
		struct sockaddr_un sa = { .sun_family = AF_UNIX };
		int ls = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
		snprintf(sa.sun_path, sizeof sa.sun_path, "%s", sock);
		unlink(sock);
		pthread_t lt;
		if (ls < 0 || bind(ls, (struct sockaddr *)&sa, sizeof sa) < 0 || chmod(sock, 0600) < 0 || listen(ls, 4) < 0
		    || pthread_create(&lt, NULL, local_thread, (void *)(intptr_t)ls)) {
			say("%s: %s", sock, strerror(errno));
			return 1;
		}
		say("the local socket %s is open (version 3, no writes to disks)", sock);
	}
	for (int i = 0; i < g_ndparts; i++) say("deploy partition %s (writable only while a confirmed DEPLOY runs)", g_dpart[i]);
#endif
	if (ready) { int fd = open(ready, O_WRONLY | O_CREAT | O_CLOEXEC, 0644); if (fd >= 0) close(fd); }
	say("serving %d disk%s on %s", g_ndisks, g_ndisks == 1 ? "" : "s", ffs ? ffs : stream);
	for (;;) {
		int r = serve(in, out);
		if (r == 2) pause(); /* rebooting */
		/* a USB disconnect (the endpoint read waits for the next configuration), or a
		 * stream whose other end isn't there yet */
		usleep(200000);
	}
}
#endif
