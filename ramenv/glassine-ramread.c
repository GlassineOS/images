/* SPDX-License-Identifier: GPL-2.0-or-later */
/* glassine-ramread: the RAM environment's reader (docs/ramenv.md). It offers the
 * device's whole disks to the computer, read-only, over one vendor-specific USB
 * interface (FunctionFS), or over a byte stream (a character device: the QEMU test's
 * virtio-serial port). The protocol has four operations: list, read a range, sha256
 * of a range, reboot. None of them writes.
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
 * Read-only by construction: every disk and each of its partitions is set read-only in
 * the kernel (BLKROSET, and force_ro where the kernel offers it) and checked with
 * BLKROGET before the first request is served; the disks are opened O_RDONLY; the
 * protocol has no operation that writes, and an unknown operation is refused. Exit
 * status: 0 never (it serves until it reboots), 1 setup failed, 2 usage.
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

/* ---- the protocol (docs/ramenv.md) ------------------------------------------------ */

#define PROTO_VERSION 1
#define REQ_SIZE 32
#define RSP_SIZE 64
#define REQ_MAGIC "GRRQ"
#define RSP_MAGIC "GRRS"

enum { OP_LIST = 1, OP_READ = 2, OP_HASH = 3, OP_REBOOT = 4 };
enum {
	ST_OK = 0,
	ST_BAD_REQUEST = 1, /* wrong magic, version or fields */
	ST_UNKNOWN_OP = 2,  /* not one of the four */
	ST_NO_DISK = 3,
	ST_RANGE = 4,       /* outside the disk, unaligned, empty or too long */
	ST_IO = 5,          /* the disk returned an error */
};
enum { REBOOT_NORMAL = 0, REBOOT_BOOTLOADER = 1 };

#define ALIGN 512u
#define MAX_READ (16u << 20)
#define MAX_HASH (64u << 20)
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
	return r->version == PROTO_VERSION ? 0 : -1;
}

static void put_response(uint8_t b[RSP_SIZE], uint16_t op, uint32_t tag, uint16_t status,
			 uint64_t length, uint64_t offset, const uint8_t *sha)
{
	memset(b, 0, RSP_SIZE);
	memcpy(b, RSP_MAGIC, 4);
	st16(b + 4, PROTO_VERSION);
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
	int fd;           /* O_RDONLY */
	uint64_t size;    /* bytes */
	uint32_t sector;  /* logical block size */
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
enum { PH_WAIT = 0, PH_DISK = 1, PH_SEND = 2 };
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

static uint8_t *g_buf; /* MAX_READ */

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
	put_response(h, r->op, r->tag, status, n, r->offset, NULL);
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
			 PROTO_VERSION, MAX_READ, MAX_HASH, ALIGN);
	for (int i = 0; i < g_ndisks && n < (int)sizeof t - 128; i++)
		n += snprintf(t + n, sizeof t - (size_t)n, "disk %d %s %llu %u\n", i, g_disk[i].name,
			      (unsigned long long)g_disk[i].size, g_disk[i].sector);
	uint8_t h[RSP_SIZE];
	put_response(h, r->op, r->tag, ST_OK, (uint64_t)n, 0, NULL);
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
	put_response(h, r->op, r->tag, ST_OK, r->length, r->offset, sum);
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
	put_response(h, r->op, r->tag, ST_OK, 0, r->offset, sum);
	phase(PH_SEND);
	int rc = write_full(out, h, RSP_SIZE);
	phase(PH_WAIT);
	return rc;
}

/* One request. Returns 1 to go on, 0 when the request was a reboot (already answered),
 * -1 when the connection failed. */
static int handle(int out, const uint8_t b[REQ_SIZE])
{
	struct request r = { 0 };
	atomic_store(&g_last_request, now_s());
	atomic_fetch_add(&g_requests, 1);
	if (parse_request(b, &r) < 0) {
		r.op = ld16(b + 6);
		r.tag = ld32(b + 8);
		r.offset = 0;
		return reply(out, &r, ST_BAD_REQUEST, "not a request of protocol version 1") < 0 ? -1 : 1;
	}
	switch (r.op) {
	case OP_LIST: return op_list(out, &r) < 0 ? -1 : 1;
	case OP_READ: return op_read(out, &r) < 0 ? -1 : 1;
	case OP_HASH: return op_hash(out, &r) < 0 ? -1 : 1;
	case OP_REBOOT:
		if (r.index != REBOOT_NORMAL && r.index != REBOOT_BOOTLOADER)
			return reply(out, &r, ST_BAD_REQUEST, "reboot target is 0 (normal) or 1 (boot loader)") < 0 ? -1 : 1;
		if (reply(out, &r, ST_OK, NULL) < 0) return -1;
		say("reboot (%s) asked by the computer", r.index ? "boot loader" : "normal");
		usleep(300000); /* let the answer leave */
		g_reboot((int)r.index);
		return 0;
	default:
		return reply(out, &r, ST_UNKNOWN_OP, "unknown operation") < 0 ? -1 : 1;
	}
}

/* Serves requests from in until it ends (0: end of stream, -1: error, 2: reboot) */
static int serve(int in, int out)
{
	uint8_t b[REQ_SIZE];
	for (;;) {
		phase(PH_WAIT);
		int r = read_full(in, b, REQ_SIZE);
		if (r <= 0) return r;
		r = handle(out, b);
		if (r <= 0) return r < 0 ? -1 : 2;
	}
}

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
		if (stopped) continue;
		if (ph != PH_DISK && quiet > limit) {
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

#define IFACE_NAME "GlassineOS read-only disk reader"
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
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!v) usage();
		if (!strcmp(a, "--disk") && npat < MAX_DISKS) pat[npat++] = argv[++i];
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
