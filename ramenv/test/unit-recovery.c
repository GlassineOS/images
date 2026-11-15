/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Unit test of the recovery's protocol version 3 (docs/recovery.md), on the build
 * computer, without privileges: glassine-ramread built with -DGLASSINE_RECOVERY over
 * a socket pair (the USB side) and a second socket pair served as the local socket,
 * with stand-in tools (shell scripts written here) in place of the recovery's status,
 * describe, deploy and diag. unit.c, built the same way, checks that versions 1 and 2
 * did not change.
 *   - the wire format: a version 3 STATUS request and its response header, and a
 *     version 3 DEPLOY request, pinned as bytes (for the installer's client);
 *   - LIST under version 3; versions 1 and 2 still refuse 8, 9, 10;
 *   - STATUS: the identity lines and the tool's output; a failing tool is status 10;
 *   - DEPLOY: every refusal of the text (too long, read and dropped; NUL; no action; an
 *     unknown action; a missing, extra or bad id; an unknown or repeated key), each
 *     before any tool runs; without the confirmation or with a wrong one: status 9,
 *     the token and what describe said, and deploy never runs; pin (describe exit 64)
 *     is not offered; the right token runs deploy with exactly the action's arguments,
 *     discard-hibernation is its own confirmation; a failing tool is status 10 with its
 *     exit code; DEPLOY while armed is refused (8);
 *   - DIAG: the file the tool wrote, with its sha256 in the header;
 *   - the local connection: ARM, WRITE, DISARM refused, their bytes read and dropped,
 *     the next request in step; STATUS, DEPLOY, DIAG served there too;
 *   - a tool past the tool limit is stopped (exit 124, status 10).
 *   cc -DGLASSINE_RECOVERY -O2 -pthread -o unit-recovery ramenv/test/unit-recovery.c
 */
#define RAMREAD_NO_MAIN
#ifndef GLASSINE_RECOVERY
#define GLASSINE_RECOVERY
#endif
#include "../glassine-ramread.c"

#include <sys/socket.h>

static int fails;
#define CHECK(c, ...) do { if (c) printf("ok   " __VA_ARGS__); else { printf("FAIL " __VA_ARGS__); fails++; } printf("\n"); } while (0)

static int rebooted = -1;
static void fake_reboot(int target) { rebooted = target; }

static int c;	/* the client's end of the connection in use */
static char dir[1024], logf[1100];

static void send_req(uint16_t version, uint16_t op, uint32_t tag, uint32_t index, uint64_t off, uint64_t len)
{
	uint8_t b[REQ_SIZE];
	memcpy(b, REQ_MAGIC, 4);
	st16(b + 4, version); st16(b + 6, op); st32(b + 8, tag); st32(b + 12, index);
	st64(b + 16, off); st64(b + 24, len);
	if (write(c, b, REQ_SIZE) != REQ_SIZE) { perror("send"); exit(1); }
}

static void send_bytes(const void *p, size_t n) { if (write_full(c, p, n) < 0) { perror("send"); exit(1); } }

struct rsp { uint16_t version, op, status; uint32_t tag; uint64_t length, offset; uint8_t sha[32]; char *data; };

static struct rsp get_rsp(void)
{
	uint8_t h[RSP_SIZE];
	struct rsp r = { 0 };
	if (read_full(c, h, RSP_SIZE) != 1 || memcmp(h, RSP_MAGIC, 4)) { printf("FAIL a response header\n"); exit(1); }
	r.version = ld16(h + 4); r.op = ld16(h + 6); r.tag = ld32(h + 8); r.status = ld16(h + 12);
	r.length = ld64(h + 16); r.offset = ld64(h + 24);
	memcpy(r.sha, h + 32, 32);
	r.data = malloc(r.length + 1);
	if (r.length && read_full(c, (uint8_t *)r.data, (size_t)r.length) != 1) { printf("FAIL a response payload\n"); exit(1); }
	r.data[r.length] = 0;
	return r;
}

static struct rsp deploy(uint32_t tag, const char *text)
{
	send_req(3, OP_DEPLOY, tag, 0, 0, strlen(text));
	send_bytes(text, strlen(text));
	return get_rsp();
}

/* the stand-in tools' log: one line per deploy run */
static char *slurp(const char *p)
{
	static char b[8192];
	FILE *f = fopen(p, "r");
	size_t n = f ? fread(b, 1, sizeof b - 1, f) : 0;
	if (f) fclose(f);
	b[n] = 0;
	return b;
}

static void tool(const char *name, const char *body)
{
	char p[1200];
	snprintf(p, sizeof p, "%s/%s", dir, name);
	FILE *f = fopen(p, "w");
	fprintf(f, "#!/bin/sh\nLOG='%s'\n%s", logf, body);
	fclose(f);
	chmod(p, 0755);
}

static void *server(void *arg)
{
	int fd = ((int *)arg)[0];
	t_local = ((int *)arg)[1];
	long r = serve(fd, fd);
	return (void *)r;
}

static void hex(const uint8_t *s, char out[65]) { for (int i = 0; i < 32; i++) sprintf(out + 2 * i, "%02x", s[i]); }

int main(void)
{
	const char *tmp = getenv("TMPDIR") && *getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
	snprintf(dir, sizeof dir, "%s/recovery-unit-XXXXXX", tmp);
	if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
	snprintf(logf, sizeof logf, "%s/log", dir);
	tool("status", "printf 'machine test\\nglassine-deploy 1\\ntype=status\\tcurrent=A\\n'\n");
	tool("describe", "case $1 in pin) echo 'glassine-deploy has no pin'; exit 64 ;; broken) exit 3 ;; esac\n"
			 "echo \"describe $*\"\n");
	tool("deploy", "echo \"$*\" >> \"$LOG\"\ncase $1 in remove) echo 'boom' >&2; exit 4 ;; esac\necho \"done $*\"\n");
	tool("diag", "printf 'diagnostics' > \"$1\"\n");
	g_tools = dir;
	g_reboot = fake_reboot;

	/* the wire format, pinned (the installer's client pins the same bytes) */
	{
		static const char *rq = "4752525103000800050000000000000000000000000000000000000000000000";
		static const char *rs = "47525253030008000500000000000000"
			"2a000000000000000000000000000000"
			"0000000000000000000000000000000000000000000000000000000000000000";
		uint8_t b[REQ_SIZE], o[RSP_SIZE];
		for (int i = 0; i < REQ_SIZE; i++) sscanf(rq + 2 * i, "%2hhx", &b[i]);
		struct request r;
		CHECK(parse_request(b, &r) == 0 && r.version == 3 && r.op == OP_STATUS && r.tag == 5 && r.length == 0,
		      "the pinned v3 STATUS request parses");
		put_response(o, 3, OP_STATUS, 5, 0, 42, 0, NULL);
		char h[2 * RSP_SIZE + 1];
		for (int i = 0; i < RSP_SIZE; i++) sprintf(h + 2 * i, "%02x", o[i]);
		CHECK(!strcmp(h, rs), "the v3 STATUS response header (42 bytes of text, status 0) is the pinned bytes");
		static const char *dq = "4752525103000900070000000000000000000000000000002a00000000000000";
		for (int i = 0; i < REQ_SIZE; i++) sscanf(dq + 2 * i, "%2hhx", &b[i]);
		CHECK(parse_request(b, &r) == 0 && r.version == 3 && r.op == OP_DEPLOY && r.tag == 7 && r.length == 42,
		      "the pinned v3 DEPLOY request (42 bytes of text follow) parses");
		b[4] = 4;
		CHECK(parse_request(b, &r) < 0, "a version 4 request doesn't parse");
	}

	/* one disk (a file), so that ARM can be taken */
	char disk[1100];
	snprintf(disk, sizeof disk, "%s/disk", dir);
	{
		FILE *f = fopen(disk, "w");
		for (int i = 0; i < 65536; i++) fputc(i & 0xff, f);
		fclose(f);
	}
	CHECK(disk_add("file", disk, 0) == 0, "the disk file is served");
	g_buf = aligned_alloc(4096, MAX_READ);

	int usb[2], loc[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, usb) < 0 || socketpair(AF_UNIX, SOCK_STREAM, 0, loc) < 0) return 1;
	pthread_t tu, tl;
	int au[2] = { usb[1], 0 }, al[2] = { loc[1], 1 };
	pthread_create(&tu, NULL, server, au);
	pthread_create(&tl, NULL, server, al);
	c = usb[0];
	struct rsp r;

	send_req(3, OP_LIST, 1, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == 0 && r.version == 3 && !strncmp(r.data, "glassine-ramread 3\nmax-read 16777216\nmax-hash 67108864\nalign 512\nwrites off\ndisk 0 file 65536 512\n", r.length),
	      "LIST under version 3: the version 2 text with 3 in its first line");
	for (uint16_t v = 1; v <= 2; v++)
		for (uint16_t op = OP_STATUS; op <= OP_DIAG; op++) {
			send_req(v, op, op, 0, 0, 0);
			r = get_rsp();
			CHECK(r.status == ST_UNKNOWN_OP && r.version == v, "version %u: operation %u is unknown", v, op);
		}

	send_req(3, OP_STATUS, 2, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == 0 && r.version == 3 && r.op == OP_STATUS
	      && !strcmp(r.data, "glassine-recovery 3\nconnection computer\nmachine test\nglassine-deploy 1\ntype=status\tcurrent=A\n"),
	      "STATUS: identity, connection, the status tool's output");

	/* DEPLOY refusals: nothing runs */
	unlink(logf);
	struct { const char *what, *text; uint16_t want; } bad[] = {
		{ "no action", "id A\n", ST_BAD_REQUEST },
		{ "an unknown action", "action format\n", ST_BAD_REQUEST },
		{ "select without an id", "action select\nconfirm select\n", ST_BAD_REQUEST },
		{ "an id starting with a dot", "action select\nid .A\nconfirm select .A\n", ST_BAD_REQUEST },
		{ "an id with a slash", "action select\nid ../A\n", ST_BAD_REQUEST },
		{ "an id with a space", "action select\nid A B\n", ST_BAD_REQUEST },
		{ "rollback with an id", "action rollback\nid A\nconfirm rollback A\n", ST_BAD_REQUEST },
		{ "an unknown key", "action rollback\nforce yes\nconfirm rollback\n", ST_BAD_REQUEST },
		{ "a repeated key", "action rollback\naction reset\nconfirm rollback\n", ST_BAD_REQUEST },
		{ "a line without a value", "action rollback\nconfirm\n", ST_BAD_REQUEST },
		{ "discard-hibernation other than yes", "action rollback\ndiscard-hibernation no\n", ST_BAD_REQUEST },
		{ "no confirmation", "action rollback\n", ST_CONFIRM },
		{ "a wrong confirmation", "action select\nid A\nconfirm select B\n", ST_CONFIRM },
		{ "the confirmation of another action", "action reset-full\nconfirm reset\n", ST_CONFIRM },
		{ "discard-hibernation not confirmed", "action rollback\ndiscard-hibernation yes\nconfirm rollback\n", ST_CONFIRM },
		{ "pin: not offered (glassine-deploy has no such verb)", "action pin\nid A\nconfirm pin A\n", ST_BAD_REQUEST },
	};
	for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
		r = deploy(300 + (uint32_t)i, bad[i].text);
		CHECK(r.status == bad[i].want && r.tag == 300 + i && r.length, "DEPLOY refused: %s (status %u)", bad[i].what, r.status);
	}
	CHECK(access(logf, F_OK) != 0, "none of the refused DEPLOYs ran the deploy tool");
	r = deploy(320, "action select\nid A\n");
	CHECK(r.status == ST_CONFIRM && !strcmp(r.data, "confirm select A\ndescribe select A\n"),
	      "DEPLOY without the confirmation: the token's line, then what describe says");
	r = deploy(321, "action rollback\ndiscard-hibernation yes\n");
	CHECK(r.status == ST_CONFIRM && !strncmp(r.data, "confirm rollback discard-hibernation\n", 37),
	      "discard-hibernation is part of the token");
	{	/* NUL in the text */
		static const char t[] = "action rollback\0\nconfirm rollback\n";
		send_req(3, OP_DEPLOY, 322, 0, 0, sizeof t - 1);
		send_bytes(t, sizeof t - 1);
		r = get_rsp();
		CHECK(r.status == ST_BAD_REQUEST, "DEPLOY refused: a NUL byte");
	}
	{	/* above the limit: all of it is read, the next request is in step */
		char *big = malloc(MAX_DEPLOY_TEXT + 100);
		memset(big, 'x', MAX_DEPLOY_TEXT + 100);
		send_req(3, OP_DEPLOY, 323, 0, 0, MAX_DEPLOY_TEXT + 100);
		send_bytes(big, MAX_DEPLOY_TEXT + 100);
		r = get_rsp();
		CHECK(r.status == ST_BAD_REQUEST && r.tag == 323, "DEPLOY refused: a text above 4096 bytes");
		send_req(3, OP_LIST, 324, 0, 0, 0);
		r = get_rsp();
		CHECK(r.status == 0 && r.tag == 324, "the next request is answered in step");
		free(big);
	}
	CHECK(access(logf, F_OK) != 0, "still nothing ran");

	/* confirmed */
	r = deploy(330, "action select\nid 20261101-120000\nconfirm select 20261101-120000\n");
	CHECK(r.status == 0 && !strcmp(r.data, "exit 0\ndone select 20261101-120000\n"), "DEPLOY select, confirmed: deploy runs, exit 0 and its output");
	r = deploy(331, "confirm rollback\naction rollback\n");
	CHECK(r.status == 0, "DEPLOY rollback, confirmed (the lines in any order)");
	r = deploy(332, "action reset-full\nconfirm reset-full\n");
	CHECK(r.status == 0, "DEPLOY reset-full, confirmed");
	r = deploy(333, "action rollback\ndiscard-hibernation yes\nconfirm rollback discard-hibernation\n");
	CHECK(r.status == 0, "DEPLOY rollback discarding the hibernation, confirmed");
	r = deploy(334, "action remove\nid A\nconfirm remove A\n");
	CHECK(r.status == ST_TOOL && !strcmp(r.data, "exit 4\nboom\n"), "a failing tool: status 10, its exit code and output");
	CHECK(!strcmp(slurp(logf), "select 20261101-120000\nrollback\nreset-full\nrollback discard-hibernation\nremove A\n"),
	      "deploy ran with exactly the actions' arguments, once each");
	r = deploy(335, "action broken\nconfirm broken\n");
	CHECK(r.status == ST_BAD_REQUEST, "an action outside the list never reaches a tool");

	/* armed: DEPLOY refused */
	send_req(3, OP_ARM, 340, 0, 0, 17);
	send_bytes("range 0 0 512\n\n\n\n", 17);
	r = get_rsp();
	CHECK(r.status == 0 && !strcmp(r.data, "armed 1"), "ARM under version 3 (%u %s)", r.status, r.data);
	send_req(3, OP_STATUS, 341, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == 0 && strstr(r.data, "\nwrites armed\n"), "STATUS says writes are armed");
	r = deploy(342, "action rollback\nconfirm rollback\n");
	CHECK(r.status == ST_ARMED, "DEPLOY while armed: refused (8)");
	send_req(3, OP_DISARM, 343, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == 0, "DISARM");
	CHECK(!strcmp(slurp(logf), "select 20261101-120000\nrollback\nreset-full\nrollback discard-hibernation\nremove A\n"), "deploy did not run while armed");

	/* DIAG */
	send_req(3, OP_DIAG, 350, 0, 0, 0);
	r = get_rsp();
	{
		struct sha256 s; uint8_t d[32]; char a[65], b[65];
		sha256_init(&s); sha256_update(&s, (uint8_t *)"diagnostics", 11); sha256_final(&s, d);
		hex(d, a); hex(r.sha, b);
		CHECK(r.status == 0 && r.length == 11 && !memcmp(r.data, "diagnostics", 11) && !strcmp(a, b), "DIAG: the file, with its sha256 in the header");
	}

	/* the local connection */
	c = loc[0];
	send_req(3, OP_ARM, 400, 0, 0, 13);
	send_bytes("range 0 0 512\n", 13);
	r = get_rsp();
	CHECK(r.status == ST_UNKNOWN_OP && r.tag == 400, "local: ARM refused");
	{
		uint8_t z[512 + 32] = { 0 };
		send_req(3, OP_WRITE, 401, 0, 0, 512);
		send_bytes(z, sizeof z);
		r = get_rsp();
		CHECK(r.status == ST_UNKNOWN_OP && r.tag == 401, "local: WRITE refused");
		send_req(2, OP_WRITE, 402, 0, 0, 512);
		send_bytes(z, sizeof z);
		r = get_rsp();
		CHECK(r.status == ST_UNKNOWN_OP && r.tag == 402, "local: a version 2 WRITE refused");
	}
	send_req(3, OP_DISARM, 403, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == ST_UNKNOWN_OP && r.tag == 403, "local: DISARM refused");
	send_req(3, OP_STATUS, 404, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == 0 && r.tag == 404 && !strncmp(r.data, "glassine-recovery 3\nconnection local\n", 37), "local: STATUS in step, connection local");
	r = deploy(405, "action rollback\n");
	CHECK(r.status == ST_CONFIRM, "local: DEPLOY needs the same confirmation");
	r = deploy(406, "action rollback\nconfirm rollback\n");
	CHECK(r.status == 0, "local: DEPLOY confirmed");
	send_req(3, OP_READ, 407, 0, 0, 512);
	r = get_rsp();
	CHECK(r.status == 0 && r.length == 512, "local: READ served");

	/* a tool past the limit */
	tool("status", "sleep 30\n");
	g_tool_limit = 2;
	long t0 = now_s();
	send_req(3, OP_STATUS, 410, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == ST_TOOL && !strncmp(r.data, "exit 124\n", 9) && now_s() - t0 < 15, "a tool past the limit is stopped: status 10, exit 124 (%ld s)", now_s() - t0);

	send_req(3, OP_REBOOT, 420, 0, 0, 0);
	r = get_rsp();
	usleep(800000); /* the answer leaves first, then the reboot */
	CHECK(r.status == 0 && rebooted == 0, "local: REBOOT reaches the reboot hook");

	char cmd[PATH_MAX + 16];
	snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
	if (system(cmd)) {}
	printf("%s: %d failed\n", fails ? "FAIL" : "ok", fails);
	return fails != 0;
}
