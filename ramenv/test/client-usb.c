/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The QEMU test's USB client (test/qemu-inner.sh): inside the guest, it talks to the
 * RAM environment's gadget through the dummy host controller (dummy_hcd) with usbfs,
 * as the installer does over a real cable: list, every disk read whole (each chunk's
 * sha256 checked), each disk's hash compared with what was read, then (with a PLAN)
 * the version 2 writes, then an unknown operation refused, then reboot. Prints QTEST
 * lines; the disks' sha256 go to the host, which compares them with the disk images,
 * and after the run the images with the original plus the planned writes.
 *
 * PLAN: lines `range NAME OFFSET LENGTH` (sent as the ARM text, by name) and
 * `write NAME OFFSET FILE` (in this order). Around them: WRITE before ARM refused, ARM
 * under version 1 unknown, ARM of each boot area refused, then ARM; while armed the
 * kernel's read-only flags are checked (the armed whole disks writable, every
 * partition, boot area and other disk read-only) and a write to each of those fails; a
 * WRITE with a bad sha256 and one to a disk that isn't armed are refused; each WRITE
 * is answered with the read-back's sha256 = the file's, and READ gives the written
 * bytes; DISARM, after which every disk is read-only again (force_ro 1 where the
 * kernel has it), WRITE is refused and so is a second ARM.
 *
 *   client-usb /dev/bus/usb/BBB/DDD IFNUM EP_IN EP_OUT [PLAN]
 */
#define RAMREAD_NO_MAIN
#include "../glassine-ramread.c"

#include <linux/usbdevice_fs.h>

static int fd;
static unsigned ep_in, ep_out;
static int fails;
#define QT(c, ...) do { printf((c) ? "QTEST ok   " : "QTEST FAIL "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); if (!(c)) fails++; } while (0)

static int bulk(unsigned ep, void *p, unsigned len)
{
	struct usbdevfs_bulktransfer b = { .ep = ep, .len = len, .timeout = 60000, .data = p };
	return ioctl(fd, USBDEVFS_BULK, &b);
}

static void send_reqv(uint16_t version, uint16_t op, uint32_t tag, uint32_t index, uint64_t off, uint64_t len)
{
	uint8_t b[REQ_SIZE];
	memcpy(b, REQ_MAGIC, 4);
	st16(b + 4, version); st16(b + 6, op); st32(b + 8, tag); st32(b + 12, index);
	st64(b + 16, off); st64(b + 24, len);
	if (bulk(ep_out, b, REQ_SIZE) != REQ_SIZE) { QT(0, "send a request: %s", strerror(errno)); exit(1); }
}

static void send_req(uint16_t op, uint32_t tag, uint32_t index, uint64_t off, uint64_t len)
{
	send_reqv(PROTO_V1, op, tag, index, off, len);
}

/* n bytes after a request, in transfers of at most 1 MiB */
static void send_bytes(const uint8_t *p, size_t n)
{
	while (n) {
		unsigned k = n < (1u << 20) ? (unsigned)n : (1u << 20);
		int r = bulk(ep_out, (void *)p, k);
		if (r <= 0) { QT(0, "send: %s", r < 0 ? strerror(errno) : "nothing"); exit(1); }
		p += r;
		n -= (size_t)r;
	}
}

/* exactly n bytes, in transfers of at most 1 MiB, never asking for more than is left */
static void recv_exact(uint8_t *p, size_t n)
{
	while (n) {
		unsigned k = n < (1u << 20) ? (unsigned)n : (1u << 20);
		int r = bulk(ep_in, p, k);
		if (r <= 0) { QT(0, "receive: %s", r < 0 ? strerror(errno) : "nothing"); exit(1); }
		p += r;
		n -= (size_t)r;
	}
}

struct rsp { uint16_t status; uint32_t tag; uint64_t length, offset; uint8_t sha[32]; };

static struct rsp get_rsp(uint8_t *data, size_t max)
{
	uint8_t h[RSP_SIZE];
	struct rsp r;
	recv_exact(h, RSP_SIZE);
	if (memcmp(h, RSP_MAGIC, 4)) { QT(0, "a response header"); exit(1); }
	r.tag = ld32(h + 8); r.status = ld16(h + 12); r.length = ld64(h + 16); r.offset = ld64(h + 24);
	memcpy(r.sha, h + 32, 32);
	if (r.length > max) { QT(0, "a response longer than asked"); exit(1); }
	if (r.length) recv_exact(data, (size_t)r.length);
	return r;
}

static void hex(const uint8_t *s, char out[65]) { for (int i = 0; i < 32; i++) sprintf(out + 2 * i, "%02x", s[i]); }

static char name[MAX_DISKS][64];
static unsigned long long size[MAX_DISKS];
static int n;

static int disk_index(const char *nm)
{
	for (int i = 0; i < n; i++) if (!strcmp(name[i], nm)) return i;
	QT(0, "the plan names %s, which isn't listed", nm);
	exit(1);
}

/* BLKROGET of /dev/NAME: 1 read-only, 0 writable, -1 no answer */
static int getro(const char *nm)
{
	char p[96];
	int ro = -1;
	snprintf(p, sizeof p, "/dev/%s", nm);
	int f = open(p, O_RDONLY | O_CLOEXEC);
	if (f < 0 || ioctl(f, BLKROGET, &ro) < 0) ro = -1;
	if (f >= 0) close(f);
	return ro;
}

/* every vd* and mmcblk* block device of the kernel (disks and partitions) with its
 * read-only flag, as one line; *bad counts those whose flag isn't the one wanted
 * (writable for the disks marked in armed, read-only for everything else) */
static void ro_states(const char armed[MAX_DISKS], int *bad, char *out, size_t on)
{
	FILE *f = fopen("/proc/partitions", "r");
	char l[256], nm[64];
	unsigned a, b;
	unsigned long long blocks;
	size_t used = 0;
	*bad = 0;
	out[0] = 0;
	while (f && fgets(l, sizeof l, f)) {
		if (sscanf(l, "%u %u %llu %63s", &a, &b, &blocks, nm) != 4) continue;
		if (strncmp(nm, "vd", 2) && strncmp(nm, "mmcblk", 6)) continue;
		int want = 1;
		for (int i = 0; i < n; i++) if (armed[i] && !strcmp(name[i], nm)) want = 0;
		int ro = getro(nm);
		if (ro != want) (*bad)++;
		if (used < on - 1) used += (size_t)snprintf(out + used, on - used, "%s%s=%d", used ? " " : "", nm, ro);
	}
	if (f) fclose(f);
}

static uint8_t *read_file(const char *p, size_t *len)
{
	int f = open(p, O_RDONLY);
	struct stat st;
	if (f < 0 || fstat(f, &st) < 0) { QT(0, "%s: %s", p, strerror(errno)); exit(1); }
	uint8_t *b = malloc((size_t)st.st_size + 1);
	if (st.st_size && read_full(f, b, (size_t)st.st_size) != 1) { QT(0, "%s: short read", p); exit(1); }
	close(f);
	*len = (size_t)st.st_size;
	return b;
}

static void sha_of(const uint8_t *p, size_t len, uint8_t out[32])
{
	struct sha256 s;
	sha256_init(&s); sha256_update(&s, p, len); sha256_final(&s, out);
}

static struct rsp write_op(uint8_t *buf, uint32_t tag, int idx, uint64_t off, const uint8_t *p, size_t len, int badsha)
{
	uint8_t sha[32];
	sha_of(p, len, sha);
	if (badsha) sha[31] ^= 0x80;
	send_reqv(PROTO_V2, OP_WRITE, tag, (uint32_t)idx, off, len);
	send_bytes(p, len);
	send_bytes(sha, 32);
	return get_rsp(buf, 4096);
}

static struct rsp arm_op(uint8_t *buf, uint32_t tag, const char *text)
{
	send_reqv(PROTO_V2, OP_ARM, tag, 0, 0, strlen(text));
	send_bytes((const uint8_t *)text, strlen(text));
	struct rsp r = get_rsp(buf, 4096);
	buf[r.length] = 0;
	return r;
}

static void writes(const char *plan, uint8_t *buf)
{
	size_t plen, len;
	char *text = (char *)read_file(plan, &plen);
	text[plen] = 0;
	char arm[4096] = "";
	struct { int idx; unsigned long long off; char file[200]; } w[16];
	int nw = 0;
	char armed[MAX_DISKS] = { 0 }, none[MAX_DISKS] = { 0 };
	for (char *l = strtok(text, "\n"); l; l = strtok(NULL, "\n")) {
		char nm[64], f[200];
		unsigned long long off, ln;
		if (sscanf(l, "range %63s %llu %llu", nm, &off, &ln) == 3) {
			armed[disk_index(nm)] = 1;
			strncat(arm, l, sizeof arm - strlen(arm) - 2);
			strcat(arm, "\n");
		} else if (sscanf(l, "write %63s %llu %199s", nm, &off, f) == 3 && nw < 16) {
			w[nw].idx = disk_index(nm); w[nw].off = off; snprintf(w[nw].file, sizeof w[nw].file, "%s", f); nw++;
		}
	}
	if (!nw || !arm[0]) { QT(0, "the plan %s has no range or no write", plan); return; }
	struct rsp r;
	uint8_t z[512] = { 0 };

	r = write_op(buf, 2000, w[0].idx, w[0].off, z, 512, 0);
	QT(r.status == ST_NOT_ARMED, "WRITE before ARM refused, not armed (status %u)", r.status);
	send_reqv(PROTO_V1, OP_ARM, 2001, 0, 0, 0);
	r = get_rsp(buf, 4096);
	QT(r.status == ST_UNKNOWN_OP, "ARM under version 1 refused as unknown (status %u)", r.status);
	int boots = 0;
	for (int i = 0; i < n; i++) {
		if (fnmatch("mmcblk*boot*", name[i], 0)) continue;
		char t[128];
		snprintf(t, sizeof t, "range %.63s 0 512\n", name[i]);
		r = arm_op(buf, 2002, t);
		QT(r.status == ST_RANGE, "ARM of the boot area %s refused (status %u: %s)", name[i], r.status, (char *)buf);
		boots++;
	}
	QT(boots >= 2, "%d boot areas listed and tried", boots);
	char states[1024];
	int bad;
	ro_states(none, &bad, states, sizeof states);
	QT(bad == 0, "before ARM every disk and partition is read-only (%s)", states);

	r = arm_op(buf, 2003, arm);
	QT(r.status == ST_OK && !strncmp((char *)buf, "armed ", 6), "ARM by name (status %u: %s)", r.status, (char *)buf);
	send_reqv(PROTO_V2, OP_LIST, 2004, 0, 0, 0);
	r = get_rsp(buf, 4096);
	buf[r.length] = 0;
	QT(r.status == ST_OK && strstr((char *)buf, "glassine-ramread 2\n") && strstr((char *)buf, "\nwrites armed "), "list (v2) while armed says `writes armed`");
	ro_states(armed, &bad, states, sizeof states);
	QT(bad == 0, "while armed only the armed whole disks are writable (%s)", states);
	{	/* a write to a partition of an armed disk, a boot area and another disk fails */
		const char *tries[] = { "vda1", "vda2", "vdb", "mmcblk0p1", "mmcblk0boot0", "mmcblk0boot1" };
		for (size_t k = 0; k < sizeof tries / sizeof tries[0]; k++) {
			char p[64];
			snprintf(p, sizeof p, "/dev/%s", tries[k]);
			if (access(p, F_OK)) continue;
			int f = open(p, O_WRONLY | O_CLOEXEC);
			errno = 0;
			ssize_t wr = f < 0 ? -1 : pwrite(f, z, 512, 4096);
			int e = errno;
			if (f >= 0) { if (wr >= 0) fsync(f); close(f); }
			QT(wr < 0, "while armed a write to %s fails (%s: %s)", tries[k], f < 0 ? "open" : "write", strerror(e));
		}
	}
	r = write_op(buf, 2005, w[0].idx, w[0].off, z, 512, 1);
	QT(r.status == ST_BAD_DATA, "WRITE with a bad sha256 refused (status %u)", r.status);
	{
		int other = -1;
		for (int i = 0; i < n; i++) if (!armed[i] && fnmatch("mmcblk*boot*", name[i], 0)) other = i;
		if (other >= 0) {
			r = write_op(buf, 2006, other, 0, z, 512, 0);
			QT(r.status == ST_RANGE, "WRITE to %s, which isn't armed, refused (status %u)", name[other], r.status);
		}
	}

	for (int k = 0; k < nw; k++) {
		uint8_t *p = read_file(w[k].file, &len), sha[32], hs[32];
		sha_of(p, len, sha);
		r = write_op(buf, 2100 + (uint32_t)k, w[k].idx, w[k].off, p, len, 0);
		sha_of(buf, 32, hs);
		QT(r.status == ST_OK && r.length == 32 && r.offset == w[k].off && !memcmp(buf, sha, 32) && !memcmp(r.sha, hs, 32),
		   "WRITE %s at %llu, %zu bytes: answered with the read-back's sha256 = the file's (status %u)",
		   name[w[k].idx], w[k].off, len, r.status);
		int same = 1;
		for (size_t o = 0; o < len; o += MAX_READ) {
			size_t m = len - o < MAX_READ ? len - o : MAX_READ;
			send_reqv(PROTO_V2, OP_READ, 2200 + (uint32_t)k, (uint32_t)w[k].idx, w[k].off + o, m);
			r = get_rsp(buf, MAX_READ);
			if (r.status || memcmp(buf, p + o, m)) same = 0;
		}
		QT(same, "READ of %s at %llu gives the written bytes", name[w[k].idx], w[k].off);
		free(p);
	}

	send_reqv(PROTO_V2, OP_DISARM, 2300, 0, 0, 0);
	r = get_rsp(buf, 4096);
	QT(r.status == ST_OK, "DISARM (status %u)", r.status);
	ro_states(none, &bad, states, sizeof states);
	QT(bad == 0, "after DISARM every disk and partition is read-only again (%s)", states);
	for (int i = 0; i < n; i++) {
		char p[128], v[8] = "";
		snprintf(p, sizeof p, "/sys/block/%.63s/force_ro", name[i]);
		int f = open(p, O_RDONLY);
		if (f < 0) continue;
		ssize_t k = read(f, v, sizeof v - 1);
		close(f);
		QT(k > 0 && v[0] == '1', "after DISARM %s has force_ro 1", name[i]);
	}
	r = write_op(buf, 2301, w[0].idx, w[0].off, z, 512, 0);
	QT(r.status == ST_NOT_ARMED, "WRITE after DISARM refused, not armed (status %u)", r.status);
	r = arm_op(buf, 2302, arm);
	QT(r.status == ST_ARMED, "ARM after DISARM refused (status %u)", r.status);
	free(text);
}

int main(int argc, char **argv)
{
	if (argc != 5 && argc != 6) { fprintf(stderr, "usage: client-usb DEV IFNUM EP_IN EP_OUT [PLAN]\n"); return 2; }
	fd = open(argv[1], O_RDWR);
	unsigned ifn = (unsigned)strtoul(argv[2], NULL, 0);
	ep_in = (unsigned)strtoul(argv[3], NULL, 0);
	ep_out = (unsigned)strtoul(argv[4], NULL, 0);
	QT(fd >= 0 && ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifn) == 0, "claim the vendor interface %u (in 0x%02x, out 0x%02x)", ifn, ep_in, ep_out);
	uint8_t *buf = malloc(MAX_READ + 1);

	send_req(OP_LIST, 1, 0, 0, 0);
	struct rsp r = get_rsp(buf, 4096);
	buf[r.length] = 0;
	QT(r.status == ST_OK && strstr((char *)buf, "glassine-ramread 1\n") && !strstr((char *)buf, "writes"), "list (v1)");
	for (char *l = strtok((char *)buf, "\n"); l && n < MAX_DISKS; l = strtok(NULL, "\n")) {
		int i; unsigned ss;
		if (sscanf(l, "disk %d %63s %llu %u", &i, name[n], &size[n], &ss) == 4 && i == n) n++;
	}
	QT(n > 0, "%d disks listed", n);

	for (int i = 0; i < n; i++) {
		struct sha256 all, part;
		uint8_t d[32], ranges[64][32];
		int nr = 0, chunks = 1;
		sha256_init(&all);
		sha256_init(&part);
		uint64_t in_range = 0;
		for (uint64_t off = 0; off < size[i]; off += MAX_READ) {
			uint64_t len = size[i] - off < MAX_READ ? size[i] - off : MAX_READ;
			send_req(OP_READ, (uint32_t)(off / MAX_READ), (uint32_t)i, off, len);
			r = get_rsp(buf, MAX_READ);
			struct sha256 s;
			sha256_init(&s); sha256_update(&s, buf, (size_t)r.length); sha256_final(&s, d);
			if (r.status || r.length != len || r.offset != off || memcmp(d, r.sha, 32)) chunks = 0;
			sha256_update(&all, buf, (size_t)len);
			/* the digests of each MAX_HASH range, for the hash comparison below */
			sha256_update(&part, buf, (size_t)len);
			in_range += len;
			if (in_range == MAX_HASH || off + len == size[i]) {
				if (nr < 64) sha256_final(&part, ranges[nr++]);
				sha256_init(&part);
				in_range = 0;
			}
		}
		sha256_final(&all, d);
		char h[65];
		hex(d, h);
		QT(chunks, "%s: every chunk arrived with its own sha256", name[i]);
		printf("QTEST disk %s %llu %s\n", name[i], size[i], h);
		int same = 1;
		for (int k = 0; k < nr; k++) {
			uint64_t off = (uint64_t)k * MAX_HASH, len = size[i] - off < MAX_HASH ? size[i] - off : MAX_HASH;
			send_req(OP_HASH, 1000 + (uint32_t)k, (uint32_t)i, off, len);
			r = get_rsp(buf, 0);
			if (r.status || memcmp(r.sha, ranges[k], 32)) same = 0;
		}
		QT(same && nr > 0, "%s: the device's hashes of %d range(s) match what was read", name[i], nr);
	}

	if (argc == 6) writes(argv[5], buf);

	send_req(0x0105, 77, 0, 0, 512);  /* an operation the protocol doesn't have */
	r = get_rsp(buf, 4096);
	QT(r.status == ST_UNKNOWN_OP && r.tag == 77, "an unknown operation is refused");
	send_req(OP_READ, 78, 0, 0, MAX_READ + 512);
	r = get_rsp(buf, 4096);
	QT(r.status == ST_RANGE, "a read above the limit is refused");
	fflush(stdout);
	if (fails) return 1;
	send_req(OP_REBOOT, 79, REBOOT_NORMAL, 0, 0);
	r = get_rsp(buf, 0);
	QT(r.status == ST_OK, "reboot answered");
	return 0;
}
