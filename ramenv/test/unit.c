/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Unit test of glassine-ramread, on the build computer, without privileges: the
 * protocol over a socket pair, served from regular files standing in for disks.
 *   - sha256 against the FIPS 180-4 examples;
 *   - the wire format: one version 1 READ and one version 2 WRITE pinned as bytes;
 *   - read-only (version 1): the disk is open O_RDONLY, a write through its descriptor
 *     fails, disk_add refuses a non-block device in production mode, and every one of
 *     the 65536 operation codes but the four is refused under version 1 (ARM, WRITE
 *     and DISARM too: their payload isn't read); the v1 LIST is the v1 text, byte for
 *     byte;
 *   - list, a whole read in chunks (each chunk's sha256 checked), hash, and every
 *     malformed request answered with its status;
 *   - writes (version 2): WRITE and DISARM before ARM, every ARM refusal (boot area by
 *     name and by index, alignment, the end, overflow, overlap, no disk, syntax, size)
 *     leaves nothing armed; a good ARM; a second ARM; every WRITE refusal (outside,
 *     across two armed ranges, another disk, too long, bad sha256) writes nothing;
 *     good WRITEs answer the read-back's sha256 and change exactly their bytes; after
 *     DISARM nothing is written and ARM is refused;
 *   - reboot reaches the reboot hook; afterwards the image is the original plus the
 *     written ranges, byte for byte, and the other two disks are unchanged (bytes and
 *     mtime).
 * BLKROSET and force_ro need a block device: the QEMU test (test/qemu-inner.sh) checks
 * them, and the O_DIRECT write and read-back.
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

static void send_bytes(const void *p, size_t n)
{
	if (write_full(c, p, n) < 0) { perror("send"); exit(1); }
}

struct rsp { uint16_t version, op, status; uint32_t tag; uint64_t length, offset; uint8_t sha[32]; uint8_t *data; };

static struct rsp get_rsp(void)
{
	uint8_t h[RSP_SIZE];
	struct rsp r = { 0 };
	if (read_full(c, h, RSP_SIZE) != 1 || memcmp(h, RSP_MAGIC, 4) || (ld16(h + 4) != PROTO_V1 && ld16(h + 4) != PROTO_V2)) {
		printf("FAIL a response header\n"); exit(1);
	}
	r.version = ld16(h + 4);
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

	/* the wire format, pinned: the same bytes are in the installer's tests
	 * (core/tests/glassine_read.rs, wire_format_pinned), so the two sides agree */
	{
		static const char *rq = "4752525101000200040302010200000000100000000000000002000000000000";
		static const char *rs = "475252530100020004030201000000000002000000000000001000000000000"
			"0000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
		uint8_t b[REQ_SIZE], o[RSP_SIZE], sha[32];
		for (int i = 0; i < REQ_SIZE; i++) sscanf(rq + 2 * i, "%2hhx", &b[i]);
		struct request r;
		CHECK(parse_request(b, &r) == 0 && r.version == 1 && r.op == 2 && r.tag == 0x01020304 && r.index == 2
		      && r.offset == 0x1000 && r.length == 0x200, "the pinned READ request parses");
		for (int i = 0; i < 32; i++) sha[i] = (uint8_t)i;
		put_response(o, 1, 2, 0x01020304, 0, 0x200, 0x1000, sha);
		char h[2 * RSP_SIZE + 1];
		for (int i = 0; i < RSP_SIZE; i++) sprintf(h + 2 * i, "%02x", o[i]);
		CHECK(!strcmp(h, rs), "the response header is the pinned bytes");
	}
	/* version 2: a WRITE of 512 bytes at 0x4400 of disk 0 and its answer (32 bytes, the
	 * read-back's sha256; the header carries the sha256 of those 32 bytes) */
	{
		static const char *rq = "4752525102000600040302010000000000440000000000000002000000000000";
		static const char *rs = "475252530200060004030201000000002000000000000000004400000000000"
			"0000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
		uint8_t b[REQ_SIZE], o[RSP_SIZE], sha[32];
		for (int i = 0; i < REQ_SIZE; i++) sscanf(rq + 2 * i, "%2hhx", &b[i]);
		struct request r;
		CHECK(parse_request(b, &r) == 0 && r.version == 2 && r.op == OP_WRITE && r.tag == 0x01020304 && r.index == 0
		      && r.offset == 0x4400 && r.length == 0x200, "the pinned v2 WRITE request parses");
		for (int i = 0; i < 32; i++) sha[i] = (uint8_t)i;
		put_response(o, 2, OP_WRITE, 0x01020304, 0, 0x20, 0x4400, sha);
		char h[2 * RSP_SIZE + 1];
		for (int i = 0; i < RSP_SIZE; i++) sprintf(h + 2 * i, "%02x", o[i]);
		CHECK(!strcmp(h, rs), "the v2 WRITE response header is the pinned bytes");
		b[4] = 3;
		CHECK(parse_request(b, &r) < 0, "a version 3 request doesn't parse");
	}

	/* three disk images: disk 0 "file" (3 MiB + 512 bytes of a pattern, the one armed),
	 * disk 1 "other" (64 KiB, never armed), disk 2 "mmcblk0boot0" (64 KiB, a boot
	 * area by its name: never armed) */
	size_t size = (3u << 20) + 512, osize = 65536;
	uint8_t *img = malloc(size), *oimg = malloc(osize);
	for (size_t i = 0; i < size; i++) img[i] = (uint8_t)(i ^ (i >> 8) ^ (i >> 16));
	for (size_t i = 0; i < osize; i++) oimg[i] = (uint8_t)(i * 7 + 3);
	char path[3][PATH_MAX];
	const char *tmp = getenv("TMPDIR") && *getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
	for (int k = 0; k < 3; k++) {
		snprintf(path[k], sizeof path[k], "%s/ramread-unit-XXXXXX", tmp);
		int w = mkstemp(path[k]);
		if (w < 0 || write(w, k ? oimg : img, k ? osize : size) != (ssize_t)(k ? osize : size)) { perror("image"); return 1; }
		close(w);
	}
	struct stat st0[3], st1;
	for (int k = 0; k < 3; k++) stat(path[k], &st0[k]);
	char want[65];
	sha_of(img, size, want);

	g_reboot = fake_reboot;
	g_buf = aligned_alloc(4096, MAX_READ);
	CHECK(disk_add("file", path[0], 1) < 0 && g_ndisks == 0, "a regular file is refused where only block devices may be offered");
	CHECK(disk_add("file", path[0], 0) == 0 && g_ndisks == 1, "the image as disk 0");
	CHECK(disk_add("other", path[1], 0) == 0 && disk_add("mmcblk0boot0", path[2], 0) == 0 && g_ndisks == 3,
	      "a second disk and a boot area as disks 1 and 2");
	CHECK((fcntl(g_disk[0].fd, F_GETFL) & O_ACCMODE) == O_RDONLY, "the disk is open O_RDONLY");
	errno = 0;
	CHECK(write(g_disk[0].fd, "x", 1) < 0 && errno == EBADF, "a write through the disk's descriptor fails (EBADF)");
	CHECK(pwrite(g_disk[0].fd, "x", 1, 0) < 0 && errno == EBADF, "a pwrite through the disk's descriptor fails (EBADF)");
	CHECK(g_disk[0].wfd < 0 && g_disk[1].wfd < 0 && g_disk[2].wfd < 0, "no disk has a write descriptor before ARM");

	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return 1; }
	c = sv[0];
	pthread_t t;
	pthread_create(&t, NULL, server, &sv[1]);

	send_req(1, OP_LIST, 7, 0, 0, 0);
	struct rsp r = get_rsp();
	char line[512];
	snprintf(line, sizeof line, "glassine-ramread 1\nmax-read 16777216\nmax-hash 67108864\nalign 512\n"
		 "disk 0 file %zu 512\ndisk 1 other %zu 512\ndisk 2 mmcblk0boot0 %zu 512\n", size, osize, osize);
	CHECK(r.status == ST_OK && r.tag == 7 && r.version == 1 && !strcmp((char *)r.data, line),
	      "list (v1): the version 1 text, byte for byte, no writes line");
	send_req(2, OP_LIST, 8, 0, 0, 0);
	r = get_rsp();
	snprintf(line, sizeof line, "glassine-ramread 2\nmax-read 16777216\nmax-hash 67108864\nalign 512\nwrites off\n"
		 "disk 0 file %zu 512\ndisk 1 other %zu 512\ndisk 2 mmcblk0boot0 %zu 512\n", size, osize, osize);
	CHECK(r.status == ST_OK && r.version == 2 && !strcmp((char *)r.data, line), "list (v2): version 2 and `writes off`");

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
		if (r.status || r.version != 1 || r.length != len || r.offset != off || strcmp(s1, s2) || memcmp(r.data, img + off, len)) chunks_ok = 0;
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
	send_req(2, OP_READ, 10, 0, 512, 1024);
	r = get_rsp();
	CHECK(r.status == ST_OK && r.version == 2 && r.length == 1024 && !memcmp(r.data, img + 512, 1024), "a version 2 READ, answered as version 2");

	struct { const char *what; uint16_t ver, op; uint32_t index; uint64_t off, len; uint16_t want; } bad[] = {
		{ "protocol version 3", 3, OP_READ, 0, 0, 512, ST_BAD_REQUEST },
		{ "protocol version 0", 0, OP_READ, 0, 0, 512, ST_BAD_REQUEST },
		{ "no such disk", 1, OP_READ, 3, 0, 512, ST_NO_DISK },
		{ "past the end", 1, OP_READ, 0, size, 512, ST_RANGE },
		{ "end past the end", 1, OP_READ, 0, size - 512, 1024, ST_RANGE },
		{ "offset+length overflows", 1, OP_READ, 0, UINT64_MAX - 511, 1024, ST_RANGE },
		{ "unaligned offset", 1, OP_READ, 0, 100, 512, ST_RANGE },
		{ "unaligned length", 1, OP_READ, 0, 0, 100, ST_RANGE },
		{ "empty read", 1, OP_READ, 0, 0, 0, ST_RANGE },
		{ "read above the limit", 1, OP_READ, 0, 0, MAX_READ + 512, ST_RANGE },
		{ "hash above the limit", 1, OP_HASH, 0, 0, MAX_HASH + 512, ST_RANGE },
		{ "reboot target 2", 1, OP_REBOOT, 2, 0, 0, ST_BAD_REQUEST },
		{ "DISARM under version 1", 1, OP_DISARM, 0, 0, 0, ST_UNKNOWN_OP },
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
		CHECK(r.status == ST_BAD_REQUEST && r.version == 1, "refused: a request without the magic");
	}
	/* every operation code but the four, under version 1: refused, and nothing else
	 * happens (ARM and WRITE too: the 512 bytes their length names are NOT read, since
	 * none are sent; were they read, the next request would be out of step) */
	int refused = 1;
	for (uint32_t op = 0; op <= 0xffff; op++) {
		if (op >= OP_LIST && op <= OP_REBOOT) continue;
		send_req(1, (uint16_t)op, op, 0, 0, 512);
		r = get_rsp();
		if (r.status != ST_UNKNOWN_OP || r.length == 0 || r.tag != op || r.version != 1) refused = 0;
		free(r.data);
	}
	CHECK(refused, "every operation code but list, read, hash and reboot is refused under version 1 (65532 codes)");
	refused = 1;
	for (uint32_t op = 0; op <= 0xffff; op++) {
		if (op >= OP_LIST && op <= OP_DISARM) continue;
		send_req(2, (uint16_t)op, op, 0, 0, 512);
		r = get_rsp();
		if (r.status != ST_UNKNOWN_OP || r.length == 0 || r.tag != op || r.version != 2) refused = 0;
		free(r.data);
	}
	CHECK(refused, "every operation code but the seven is refused under version 2 (65529 codes)");

	/* ---- writes (version 2) ---------------------------------------------------- */
	uint8_t *exp = malloc(size);	/* what disk 0 must hold at the end */
	memcpy(exp, img, size);
	uint8_t *data = malloc(MAX_WRITE + 512);
	for (size_t i = 0; i < MAX_WRITE + 512; i++) data[i] = (uint8_t)(i * 13 + (i >> 10) + 1);
	uint8_t dsha[32];

	/* WRITE N bytes of p at OFF of disk IDX, with p's sha256 (or a wrong one) */
#define WRITE(tag, idx, off, p, n, badsha) do { \
		struct sha256 s_; sha256_init(&s_); sha256_update(&s_, (p), (n)); sha256_final(&s_, dsha); \
		if (badsha) dsha[0] ^= 1; \
		send_req(2, OP_WRITE, (tag), (idx), (off), (n)); send_bytes((p), (n)); send_bytes(dsha, 32); \
		r = get_rsp(); } while (0)
#define ARM(tag, text) do { send_req(2, OP_ARM, (tag), 0, 0, strlen(text)); send_bytes((text), strlen(text)); r = get_rsp(); } while (0)

	WRITE(200, 0, 0, data, 512, 0);
	CHECK(r.status == ST_NOT_ARMED && r.tag == 200, "WRITE before ARM: refused, not armed (status %u)", r.status);
	send_req(2, OP_DISARM, 201, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == ST_OK && r.length == 0, "DISARM with nothing armed: answered, nothing to do");

	char tail[64];
	snprintf(tail, sizeof tail, "range 0 %zu 1024\n", size - 512);
	char big[MAX_ARM_TEXT + 2];
	memset(big, '\n', sizeof big - 1);
	big[sizeof big - 1] = 0;
	memcpy(big, "range 0 0 512", 13);
	struct { const char *what, *text; uint16_t want; } armbad[] = {
		{ "a boot area by its name", "range mmcblk0boot0 0 512\n", ST_RANGE },
		{ "a boot area by its index", "range 2 0 512", ST_RANGE },
		{ "a boot area beside a good range", "range 0 0 512\nrange 2 0 512\n", ST_RANGE },
		{ "an unaligned offset", "range 0 100 512\n", ST_RANGE },
		{ "an unaligned length", "range 0 0 100\n", ST_RANGE },
		{ "an empty range", "range 0 0 0\n", ST_RANGE },
		{ "past the end", tail, ST_RANGE },
		{ "offset+length overflows", "range 0 18446744073709551104 1024\n", ST_RANGE },
		{ "two ranges that overlap", "range 0 0 1024\nrange file 512 512\n", ST_RANGE },
		{ "no such disk (index)", "range 3 0 512\n", ST_NO_DISK },
		{ "no such disk (name)", "range nosuch 0 512\n", ST_NO_DISK },
		{ "a misspelt keyword", "rang 0 0 512\n", ST_BAD_REQUEST },
		{ "a missing field", "range 0 0\n", ST_BAD_REQUEST },
		{ "an extra field", "range 0 0 512 1\n", ST_BAD_REQUEST },
		{ "a negative number", "range 0 -512 512\n", ST_BAD_REQUEST },
		{ "a hex number", "range 0 0x200 512\n", ST_BAD_REQUEST },
		{ "two spaces", "range  0 0 512\n", ST_BAD_REQUEST },
		{ "a number above 64 bits", "range 0 0 18446744073709551616\n", ST_BAD_REQUEST },
		{ "no range at all", "\n\n", ST_BAD_REQUEST },
		{ "text above 16384 bytes (read and dropped)", big, ST_BAD_REQUEST },
	};
	for (size_t i = 0; i < sizeof armbad / sizeof armbad[0]; i++) {
		ARM(300 + (uint32_t)i, armbad[i].text);
		CHECK(r.status == armbad[i].want && r.tag == 300 + i && g_armed == ARM_NEVER,
		      "ARM refused: %s (status %u: %s)", armbad[i].what, r.status, r.data);
	}
	send_req(2, OP_ARM, 330, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == ST_BAD_REQUEST, "ARM refused: an empty text");
	send_req(1, OP_ARM, 331, 0, 0, 64);	/* version 1: unknown, and no text is read */
	r = get_rsp();
	CHECK(r.status == ST_UNKNOWN_OP && r.tag == 331, "ARM under version 1: an unknown operation");
	CHECK(g_disk[0].wfd < 0 && g_disk[1].wfd < 0 && g_disk[2].wfd < 0 && !g_disk[0].armed,
	      "after every refused ARM no disk is armed or open for writing");
	WRITE(332, 0, 0, data, 512, 0);
	CHECK(r.status == ST_NOT_ARMED, "WRITE after the refused ARMs: still not armed");

	/* the good ARM: a primary table (34 sectors), the sector after it, 1 MiB of data
	 * and a backup table (33 sectors) at the end, the data range by the disk's name */
	uint64_t bk = size - 33 * 512;
	char armtext[256];
	snprintf(armtext, sizeof armtext, "range 0 0 17408\nrange 0 17408 512\nrange file 1048576 1048576\nrange 0 %llu 16896",
		 (unsigned long long)bk);
	ARM(400, armtext);
	CHECK(r.status == ST_OK && r.length == 7 && !memcmp(r.data, "armed 4", 7), "ARM: 4 ranges, answered `armed 4`");
	CHECK(g_disk[0].wfd >= 0 && g_disk[1].wfd < 0 && g_disk[2].wfd < 0, "only disk 0 is open for writing");
	CHECK((fcntl(g_disk[0].fd, F_GETFL) & O_ACCMODE) == O_RDONLY, "disk 0's read descriptor is still O_RDONLY");
	send_req(2, OP_LIST, 401, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == ST_OK && strstr((char *)r.data, "\nwrites armed 4\n"), "list (v2): `writes armed 4`");
	send_req(1, OP_LIST, 402, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == ST_OK && !strstr((char *)r.data, "writes"), "list (v1) while armed: still no writes line");
	ARM(403, "range 0 2097152 512\n");
	CHECK(r.status == ST_ARMED, "a second ARM: refused, already armed (status %u)", r.status);

	struct { const char *what; uint32_t idx; uint64_t off, len; int badsha; uint16_t want; } wbad[] = {
		{ "outside every range", 0, 20480, 512, 0, ST_RANGE },
		{ "across two adjacent armed ranges", 0, 16896, 1024, 0, ST_RANGE },
		{ "starting inside, ending past a range", 0, 2097152 - 512, 1024, 0, ST_RANGE },
		{ "a disk that isn't armed", 1, 0, 512, 0, ST_RANGE },
		{ "the boot area", 2, 0, 512, 0, ST_RANGE },
		{ "no such disk", 3, 0, 512, 0, ST_NO_DISK },
		{ "an unaligned offset", 0, 100, 512, 0, ST_RANGE },
		{ "an unaligned length", 0, 0, 100, 0, ST_RANGE },
		{ "an empty write", 0, 0, 0, 0, ST_RANGE },
		{ "past the end of the disk", 0, size, 512, 0, ST_RANGE },
		{ "above 16 MiB (read and dropped)", 0, 0, MAX_WRITE + 512, 0, ST_RANGE },
		{ "a sha256 that isn't the bytes'", 0, 0, 17408, 1, ST_BAD_DATA },
		{ "a bad sha256 and outside", 0, 20480, 512, 1, ST_RANGE },
	};
	for (size_t i = 0; i < sizeof wbad / sizeof wbad[0]; i++) {
		WRITE(500 + (uint32_t)i, wbad[i].idx, wbad[i].off, data, (size_t)wbad[i].len, wbad[i].badsha);
		CHECK(r.status == wbad[i].want && r.tag == 500 + i, "WRITE refused: %s (status %u)", wbad[i].what, r.status);
	}
	{
		uint8_t *now = malloc(size);
		int fd = open(path[0], O_RDONLY);
		CHECK(fd >= 0 && read_full(fd, now, size) == 1 && !memcmp(now, img, size), "after every refused WRITE disk 0 is unchanged");
		close(fd);
		free(now);
	}

	/* the good writes, backup table first, then the primary, the next sector and data;
	 * each answer = the sha256 of the range read back = the bytes' */
	struct { uint64_t off; size_t len; const uint8_t *p; } wok[] = {
		{ bk, 16896, data + 1000 * 512 },
		{ 0, 17408, data },
		{ 17408, 512, data + 99 * 512 },
		{ 1048576, 1048576, data + 2048 * 512 },
	};
	int wgood = 1;
	for (size_t i = 0; i < sizeof wok / sizeof wok[0]; i++) {
		WRITE(600 + (uint32_t)i, 0, wok[i].off, wok[i].p, wok[i].len, 0);
		uint8_t hs[32];
		struct sha256 s; sha256_init(&s); sha256_update(&s, r.data, 32); sha256_final(&s, hs);
		if (r.status || r.length != 32 || r.offset != wok[i].off || memcmp(r.data, dsha, 32) || memcmp(r.sha, hs, 32)) wgood = 0;
		memcpy(exp + wok[i].off, wok[i].p, wok[i].len);
	}
	CHECK(wgood, "4 WRITEs (backup, primary, the next sector, 1 MiB of data): each answered with the read-back's sha256 = the bytes'");
	send_req(2, OP_READ, 610, 0, 0, 17408);
	r = get_rsp();
	CHECK(r.status == ST_OK && !memcmp(r.data, data, 17408), "a READ after the WRITE gives the new bytes");
	send_req(2, OP_HASH, 611, 0, 0, size);
	r = get_rsp();
	{
		uint8_t e[32];
		struct sha256 s; sha256_init(&s); sha256_update(&s, exp, size); sha256_final(&s, e);
		CHECK(r.status == ST_OK && !memcmp(r.sha, e, 32), "HASH of the whole disk = the original plus the writes");
	}

	send_req(2, OP_DISARM, 700, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == ST_OK && r.length == 0 && g_disk[0].wfd < 0 && !g_disk[0].armed, "DISARM: answered, the write descriptor closed");
	send_req(2, OP_LIST, 701, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == ST_OK && strstr((char *)r.data, "\nwrites off\n"), "list (v2) after DISARM: `writes off`");
	WRITE(702, 0, 0, data + 7 * 512, 512, 0);
	CHECK(r.status == ST_NOT_ARMED, "WRITE after DISARM: refused, not armed (status %u)", r.status);
	ARM(703, "range 0 0 512\n");
	CHECK(r.status == ST_ARMED, "ARM after DISARM: refused (once per start, status %u)", r.status);

	send_req(1, OP_REBOOT, 5, REBOOT_BOOTLOADER, 0, 0);
	r = get_rsp();
	void *sr;
	pthread_join(t, &sr);
	CHECK(r.status == ST_OK && rebooted == REBOOT_BOOTLOADER && (long)sr == 2, "reboot: answered, then the reboot hook, then the server stops");

	uint8_t *after = malloc(size);
	int fd = open(path[0], O_RDONLY);
	CHECK(fd >= 0 && read_full(fd, after, size) == 1 && !memcmp(after, exp, size),
	      "disk 0 is the original plus exactly the written ranges, every other byte unchanged");
	close(fd);
	for (int k = 1; k < 3; k++) {
		fd = open(path[k], O_RDONLY);
		stat(path[k], &st1);
		CHECK(fd >= 0 && read_full(fd, after, osize) == 1 && !memcmp(after, oimg, osize) && st1.st_size == st0[k].st_size
		      && st0[k].st_mtim.tv_sec == st1.st_mtim.tv_sec && st0[k].st_mtim.tv_nsec == st1.st_mtim.tv_nsec,
		      "disk %d (%s) is unchanged: bytes, size and mtime", k, g_disk[k].name);
		close(fd);
	}
	for (int k = 0; k < 3; k++) unlink(path[k]);
	printf("%s: %d failed\n", fails ? "FAIL" : "ok", fails);
	return fails ? 1 : 0;
}
