/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The QEMU test's USB client (test/qemu-inner.sh): inside the guest, it talks to the
 * RAM environment's gadget through the dummy host controller (dummy_hcd) with usbfs,
 * as the installer does over a real cable: list, every disk read whole (each chunk's
 * sha256 checked), each disk's hash compared with what was read, an unknown operation
 * refused, then reboot. Prints QTEST lines; the disks' sha256 go to the host, which
 * compares them with the disk images.
 *
 *   client-usb /dev/bus/usb/BBB/DDD IFNUM EP_IN EP_OUT
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
	struct usbdevfs_bulktransfer b = { .ep = ep, .len = len, .timeout = 20000, .data = p };
	return ioctl(fd, USBDEVFS_BULK, &b);
}

static void send_req(uint16_t op, uint32_t tag, uint32_t index, uint64_t off, uint64_t len)
{
	uint8_t b[REQ_SIZE];
	memcpy(b, REQ_MAGIC, 4);
	st16(b + 4, PROTO_VERSION); st16(b + 6, op); st32(b + 8, tag); st32(b + 12, index);
	st64(b + 16, off); st64(b + 24, len);
	if (bulk(ep_out, b, REQ_SIZE) != REQ_SIZE) { QT(0, "send a request: %s", strerror(errno)); exit(1); }
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

int main(int argc, char **argv)
{
	if (argc != 5) { fprintf(stderr, "usage: client-usb DEV IFNUM EP_IN EP_OUT\n"); return 2; }
	fd = open(argv[1], O_RDWR);
	unsigned ifn = (unsigned)strtoul(argv[2], NULL, 0);
	ep_in = (unsigned)strtoul(argv[3], NULL, 0);
	ep_out = (unsigned)strtoul(argv[4], NULL, 0);
	QT(fd >= 0 && ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifn) == 0, "claim the vendor interface %u (in 0x%02x, out 0x%02x)", ifn, ep_in, ep_out);
	uint8_t *buf = malloc(MAX_READ);

	send_req(OP_LIST, 1, 0, 0, 0);
	struct rsp r = get_rsp(buf, 4096);
	buf[r.length] = 0;
	QT(r.status == ST_OK && strstr((char *)buf, "glassine-ramread 1\n"), "list");
	char name[MAX_DISKS][64];
	unsigned long long size[MAX_DISKS];
	int n = 0;
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
