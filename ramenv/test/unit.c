/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Unit test of glassine-ramread, on the build computer, without privileges: the
 * protocol over a socket pair, served from a regular file standing in for a disk.
 *   - sha256 against the FIPS 180-4 examples;
 *   - read-only: the disk is open O_RDONLY, a write through its descriptor fails,
 *     disk_add refuses a non-block device in production mode, and every one of the
 *     65536 operation codes but the four is refused; after all of it the file's bytes
 *     and mtime are unchanged;
 *   - list, a whole read in chunks (each chunk's sha256 checked), hash, and every
 *     malformed request answered with its status; reboot reaches the reboot hook.
 * BLKROSET itself needs a block device: the QEMU test (test/qemu-inner.sh) checks it.
 *   cc -O2 -pthread -o unit ramenv/test/unit.c && ./unit
 */
#define RAMREAD_NO_MAIN
#include "../glassine-ramread.c"

#include <sys/socket.h>

static int fails;
#define CHECK(c, ...) do { if (c) printf("ok   " __VA_ARGS__); else { printf("FAIL " __VA_ARGS__); fails++; } printf("\n"); } while (0)

static int rebooted = -1;
static void fake_reboot(int target) { rebooted = target; }

static void hex(const uint8_t *s, char out[65]) { for (int i = 0; i < 32; i++) sprintf(out + 2 * i, "%02x", s[i]); }

static void sha_of(const void *p, size_t n, char out[65])
{
	struct sha256 s;
	uint8_t d[32];
	sha256_init(&s);
	sha256_update(&s, p, n);
	sha256_final(&s, d);
	hex(d, out);
}

static int c;	/* the client's end */

static void send_req(uint16_t version, uint16_t op, uint32_t tag, uint32_t index, uint64_t off, uint64_t len)
{
	uint8_t b[REQ_SIZE];
	memcpy(b, REQ_MAGIC, 4);
	st16(b + 4, version); st16(b + 6, op); st32(b + 8, tag); st32(b + 12, index);
	st64(b + 16, off); st64(b + 24, len);
	if (write(c, b, REQ_SIZE) != REQ_SIZE) { perror("send"); exit(1); }
}

struct rsp { uint16_t op, status; uint32_t tag; uint64_t length, offset; uint8_t sha[32]; uint8_t *data; };

static struct rsp get_rsp(void)
{
	uint8_t h[RSP_SIZE];
	struct rsp r = { 0 };
	if (read_full(c, h, RSP_SIZE) != 1 || memcmp(h, RSP_MAGIC, 4) || ld16(h + 4) != PROTO_VERSION) {
		printf("FAIL a response header\n"); exit(1);
	}
	r.op = ld16(h + 6); r.tag = ld32(h + 8); r.status = ld16(h + 12);
	r.length = ld64(h + 16); r.offset = ld64(h + 24);
	memcpy(r.sha, h + 32, 32);
	r.data = malloc(r.length + 1);
	if (r.length && read_full(c, r.data, (size_t)r.length) != 1) { printf("FAIL a response payload\n"); exit(1); }
	r.data[r.length] = 0;
	return r;
}

static void *server(void *arg)
{
	int fd = *(int *)arg;
	long r = serve(fd, fd);
	return (void *)r;
}

int main(void)
{
	char got[65];
	sha_of("abc", 3, got);
	CHECK(!strcmp(got, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "sha256(abc)");
	sha_of("", 0, got);
	CHECK(!strcmp(got, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), "sha256()");
	const char *m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
	sha_of(m, strlen(m), got);
	CHECK(!strcmp(got, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"), "sha256(448 bits)");
	/* the same input fed in uneven pieces */
	{
		static uint8_t big[1000003];
		for (size_t i = 0; i < sizeof big; i++) big[i] = (uint8_t)(i * 31 + (i >> 9));
		char one[65], parts[65];
		sha_of(big, sizeof big, one);
		struct sha256 s; uint8_t d[32];
		sha256_init(&s);
		for (size_t o = 0, k = 1; o < sizeof big; o += k, k = k * 3 % 4099 + 1)
			sha256_update(&s, big + o, o + k > sizeof big ? sizeof big - o : k);
		sha256_final(&s, d); hex(d, parts);
		CHECK(!strcmp(one, parts), "sha256 in pieces = in one piece");
	}

	/* a disk image: 3 MiB + 512 bytes of a pattern */
	char path[] = "/tmp/ramread-unit-XXXXXX";
	int w = mkstemp(path);
	size_t size = (3u << 20) + 512;
	uint8_t *img = malloc(size);
	for (size_t i = 0; i < size; i++) img[i] = (uint8_t)(i ^ (i >> 8) ^ (i >> 16));
	if (w < 0 || write(w, img, size) != (ssize_t)size) { perror("image"); return 1; }
	close(w);
	struct stat st0, st1;
	stat(path, &st0);
	char want[65];
	sha_of(img, size, want);

	g_reboot = fake_reboot;
	g_buf = aligned_alloc(4096, MAX_READ);
	CHECK(disk_add("file", path, 1) < 0 && g_ndisks == 0, "a regular file is refused where only block devices may be offered");
	CHECK(disk_add("file", path, 0) == 0 && g_ndisks == 1, "the image as disk 0");
	CHECK((fcntl(g_disk[0].fd, F_GETFL) & O_ACCMODE) == O_RDONLY, "the disk is open O_RDONLY");
	errno = 0;
	CHECK(write(g_disk[0].fd, "x", 1) < 0 && errno == EBADF, "a write through the disk's descriptor fails (EBADF)");
	CHECK(pwrite(g_disk[0].fd, "x", 1, 0) < 0 && errno == EBADF, "a pwrite through the disk's descriptor fails (EBADF)");

	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return 1; }
	c = sv[0];
	pthread_t t;
	pthread_create(&t, NULL, server, &sv[1]);

	send_req(1, OP_LIST, 7, 0, 0, 0);
	struct rsp r = get_rsp();
	char line[128];
	snprintf(line, sizeof line, "disk 0 file %zu 512\n", size);
	CHECK(r.status == ST_OK && r.tag == 7 && strstr((char *)r.data, "glassine-ramread 1\n") && strstr((char *)r.data, line),
	      "list: version and the disk");

	/* the whole disk, in reads of 1 MiB, each answer's sha256 = its payload's */
	struct sha256 all; uint8_t d[32];
	sha256_init(&all);
	int chunks_ok = 1;
	for (uint64_t off = 0; off < size; off += 1u << 20) {
		uint64_t len = size - off < (1u << 20) ? size - off : (1u << 20);
		send_req(1, OP_READ, (uint32_t)(off >> 20), 0, off, len);
		r = get_rsp();
		char s1[65], s2[65];
		sha_of(r.data, (size_t)r.length, s1); hex(r.sha, s2);
		if (r.status || r.length != len || r.offset != off || strcmp(s1, s2) || memcmp(r.data, img + off, len)) chunks_ok = 0;
		sha256_update(&all, r.data, (size_t)r.length);
		free(r.data);
	}
	sha256_final(&all, d); hex(d, got);
	CHECK(chunks_ok, "read: every chunk is the image's bytes, with its sha256");
	CHECK(!strcmp(got, want), "read: the whole disk's sha256 is the image's");

	send_req(1, OP_HASH, 9, 0, 0, size);
	r = get_rsp(); hex(r.sha, got);
	CHECK(r.status == ST_OK && r.length == 0 && !strcmp(got, want), "hash of the whole disk");
	send_req(1, OP_HASH, 9, 0, 512, 1024);
	r = get_rsp(); hex(r.sha, got);
	sha_of(img + 512, 1024, line);
	CHECK(r.status == ST_OK && !strcmp(got, line), "hash of a range");

	struct { const char *what; uint16_t ver, op; uint32_t index; uint64_t off, len; uint16_t want; } bad[] = {
		{ "protocol version 2", 2, OP_READ, 0, 0, 512, ST_BAD_REQUEST },
		{ "no such disk", 1, OP_READ, 1, 0, 512, ST_NO_DISK },
		{ "past the end", 1, OP_READ, 0, size, 512, ST_RANGE },
		{ "end past the end", 1, OP_READ, 0, size - 512, 1024, ST_RANGE },
		{ "offset+length overflows", 1, OP_READ, 0, UINT64_MAX - 511, 1024, ST_RANGE },
		{ "unaligned offset", 1, OP_READ, 0, 100, 512, ST_RANGE },
		{ "unaligned length", 1, OP_READ, 0, 0, 100, ST_RANGE },
		{ "empty read", 1, OP_READ, 0, 0, 0, ST_RANGE },
		{ "read above the limit", 1, OP_READ, 0, 0, MAX_READ + 512, ST_RANGE },
		{ "hash above the limit", 1, OP_HASH, 0, 0, MAX_HASH + 512, ST_RANGE },
		{ "reboot target 2", 1, OP_REBOOT, 2, 0, 0, ST_BAD_REQUEST },
	};
	for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
		send_req(bad[i].ver, bad[i].op, 100 + (uint32_t)i, bad[i].index, bad[i].off, bad[i].len);
		r = get_rsp();
		CHECK(r.status == bad[i].want && r.tag == 100 + i, "refused: %s (status %u)", bad[i].what, r.status);
	}
	{	/* bad magic */
		uint8_t b[REQ_SIZE] = "XXXX";
		if (write(c, b, REQ_SIZE) != REQ_SIZE) return 1;
		r = get_rsp();
		CHECK(r.status == ST_BAD_REQUEST, "refused: a request without the magic");
	}
	/* every operation code but the four: refused, and nothing else happens */
	int refused = 1;
	for (uint32_t op = 0; op <= 0xffff; op++) {
		if (op >= OP_LIST && op <= OP_REBOOT) continue;
		send_req(1, (uint16_t)op, op, 0, 0, 512);
		r = get_rsp();
		if (r.status != ST_UNKNOWN_OP || r.length == 0) refused = 0;
		free(r.data);
	}
	CHECK(refused, "every operation code but list, read, hash and reboot is refused (65532 codes)");

	send_req(1, OP_REBOOT, 5, REBOOT_BOOTLOADER, 0, 0);
	r = get_rsp();
	void *sr;
	pthread_join(t, &sr);
	CHECK(r.status == ST_OK && rebooted == REBOOT_BOOTLOADER && (long)sr == 2, "reboot: answered, then the reboot hook, then the server stops");

	stat(path, &st1);
	uint8_t *after = malloc(size);
	int fd = open(path, O_RDONLY);
	CHECK(fd >= 0 && read_full(fd, after, size) == 1 && !memcmp(after, img, size), "the image's bytes are unchanged");
	CHECK(st0.st_mtim.tv_sec == st1.st_mtim.tv_sec && st0.st_mtim.tv_nsec == st1.st_mtim.tv_nsec && st0.st_size == st1.st_size,
	      "the image's size and mtime are unchanged");
	unlink(path);
	printf("%s: %d failed\n", fails ? "FAIL" : "ok", fails);
	return fails ? 1 : 0;
}
