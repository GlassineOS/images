/* SPDX-License-Identifier: GPL-2.0-or-later */
/* glassine-rcall: one request of protocol version 3 to the recovery's local socket
 * (docs/recovery.md), for the console's menu. It speaks the same protocol as the
 * computer over USB, from the same source (glassine-ramread.c), so the menu can offer
 * nothing the core doesn't.
 *
 *   glassine-rcall SOCKET list
 *   glassine-rcall SOCKET status
 *   glassine-rcall SOCKET deploy FILE      (the DEPLOY text; - = stdin)
 *   glassine-rcall SOCKET diag OUT         (the diagnostics file to OUT, its sha256 checked)
 *   glassine-rcall SOCKET reboot 0|1       (0 normal, 1 the boot loader)
 *
 * Prints the answer's payload (diag: its size and sha256) and exits with the answer's
 * status (0 ok, 9 the operation needs a confirmation, 10 the tool failed, ...); 100 =
 * no answer (no socket, a broken answer, a sha256 that doesn't match).
 */
#define RAMREAD_NO_MAIN
#include "../glassine-ramread.c"

#include <sys/socket.h>
#include <sys/un.h>

static int fail(const char *m)
{
	fprintf(stderr, "glassine-rcall: %s\n", m);
	return 100;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: glassine-rcall SOCKET list|status|deploy FILE|diag OUT|reboot 0|1\n");
		return 2;
	}
	const char *op = argv[2], *arg = argc > 3 ? argv[3] : NULL;
	uint16_t code;
	uint32_t index = 0;
	char *text = NULL;
	size_t tn = 0;
	if (!strcmp(op, "list")) code = OP_LIST;
	else if (!strcmp(op, "status")) code = OP_STATUS;
	else if (!strcmp(op, "deploy") && arg) {
		code = OP_DEPLOY;
		FILE *f = strcmp(arg, "-") ? fopen(arg, "r") : stdin;
		if (!f) return fail("cannot read the DEPLOY text");
		text = malloc(8192);
		tn = fread(text, 1, 8192, f);
		if (f != stdin) fclose(f);
	} else if (!strcmp(op, "diag") && arg) code = OP_DIAG;
	else if (!strcmp(op, "reboot") && arg && (!strcmp(arg, "0") || !strcmp(arg, "1"))) { code = OP_REBOOT; index = (uint32_t)(*arg - '0'); }
	else {
		fprintf(stderr, "glassine-rcall: unknown operation %s\n", op);
		return 2;
	}

	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", argv[1]);
	int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (s < 0 || connect(s, (struct sockaddr *)&sa, sizeof sa) < 0) return fail("cannot connect to the recovery's socket");
	signal(SIGPIPE, SIG_IGN);

	uint8_t q[REQ_SIZE] = { 0 }, h[RSP_SIZE];
	memcpy(q, REQ_MAGIC, 4);
	st16(q + 4, PROTO_V3);
	st16(q + 6, code);
	st32(q + 8, (uint32_t)getpid());
	st32(q + 12, index);
	st64(q + 24, tn);
	if (write_full(s, q, REQ_SIZE) < 0 || (tn && write_full(s, (uint8_t *)text, tn) < 0)) return fail("cannot send the request");
	if (read_full(s, h, RSP_SIZE) != 1 || memcmp(h, RSP_MAGIC, 4)) return fail("no answer");
	uint16_t status = ld16(h + 12);
	uint64_t n = ld64(h + 16);
	if (n > MAX_READ) return fail("an answer above 16 MiB");
	uint8_t *p = malloc(n + 1);
	if (!p || (n && read_full(s, p, (size_t)n) != 1)) return fail("a cut answer");
	if (code == OP_DIAG && status == ST_OK) {
		struct sha256 c;
		uint8_t sum[32];
		sha256_init(&c);
		sha256_update(&c, p, (size_t)n);
		sha256_final(&c, sum);
		if (memcmp(sum, h + 32, 32)) return fail("the diagnostics' sha256 doesn't match its header");
		int fd = open(arg, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
		if (fd < 0 || write_full(fd, p, (size_t)n) < 0 || close(fd) < 0) return fail("cannot write the diagnostics file");
		printf("%llu ", (unsigned long long)n);
		for (int i = 0; i < 32; i++) printf("%02x", sum[i]);
		printf("\n");
	} else if (n && fwrite(p, 1, (size_t)n, stdout) != n) return fail("cannot print the answer");
	fflush(stdout);
	return status;
}
