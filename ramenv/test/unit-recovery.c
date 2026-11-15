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
 *     before any tool runs (also an id starting with a dash); without the confirmation
 *     or with a wrong one: status 9, the token (with the hash of what describe said)
 *     and what describe said, and deploy never runs; a token from another state (describe
 *     says something else now) is refused; pin (describe exit 64) is not offered; the
 *     right token runs deploy with exactly the action's arguments, by position (an id
 *     named discard-hibernation stays an id); discard-hibernation is its own
 *     confirmation; a failing tool is status 10 with its exit code; DEPLOY is refused
 *     (8) once ARM was taken in this start, also after DISARM, and ARM once a DEPLOY
 *     ran; after a window that didn't close, DEPLOY is refused (5);
 *   - the tools' end: nothing of a tool outlives it (a background child, a setsid'ed
 *     one), a child holding the output doesn't keep a finished tool's answer, a tool
 *     that closes its output and goes on is stopped at the limit; a tool's output above
 *     256 KiB is cut, what is kept intact;
 *   - a request with a bad magic under version 2: the RAM environment's text;
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

/* the token of a ST_CONFIRM answer (its first line, `confirm TOKEN`) */
static const char *token_of(const struct rsp *r)
{
	static char t[256];
	t[0] = 0;
	if (r->status == ST_CONFIRM && !strncmp(r->data, "confirm ", 8)) sscanf(r->data + 8, "%255[^\n]", t);
	return t;
}

/* TEXT without a confirmation, then again with the token the answer named */
static struct rsp confirmed(uint32_t tag, const char *text)
{
	struct rsp r = deploy(tag, text);
	if (r.status != ST_CONFIRM) return r;
	char t[1024];
	snprintf(t, sizeof t, "%sconfirm %s\n", text, token_of(&r));
	return deploy(tag, t);
}

/* the token the daemon names for ACTION-TEXT given describe's output */
static void want_token(char *out, size_t n, const char *head, const char *described)
{
	struct sha256 s;
	uint8_t d[32];
	sha256_init(&s);
	sha256_update(&s, (const uint8_t *)described, strlen(described));
	sha256_final(&s, d);
	snprintf(out, n, "%s %02x%02x%02x%02x", head, d[0], d[1], d[2], d[3]);
}

/* the size of a file, -1 = none */
static long fsize(const char *p) { struct stat st; return stat(p, &st) < 0 ? -1 : (long)st.st_size; }

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
		{ "an id starting with a dash", "action select\nid -x\n", ST_BAD_REQUEST },
		{ "an id that is an option", "action remove\nid --full\n", ST_BAD_REQUEST },
		{ "an id that is a dash", "action remove\nid -\n", ST_BAD_REQUEST },
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
	char want[128], text[1024];
	r = deploy(320, "action select\nid A\n");
	want_token(want, sizeof want, "select A", "describe select A no\n");
	snprintf(text, sizeof text, "confirm %s\ndescribe select A no\n", want);
	CHECK(r.status == ST_CONFIRM && !strcmp(r.data, text),
	      "DEPLOY without the confirmation: the token's line (the hash of what describe says), then what describe says (%s)", token_of(&r));
	r = deploy(321, "action rollback\ndiscard-hibernation yes\n");
	want_token(want, sizeof want, "rollback discard-hibernation", "describe rollback - yes\n");
	CHECK(r.status == ST_CONFIRM && !strcmp(token_of(&r), want), "discard-hibernation is part of the token");
	r = deploy(325, "action select\nid discard-hibernation\n");
	CHECK(r.status == ST_CONFIRM && strstr(r.data, "\ndescribe select discard-hibernation no\n"),
	      "an id named discard-hibernation reaches describe as the id, not the flag");
	{	/* a token for another state: describe says something else now */
		r = deploy(326, "action rollback\n");
		char old[256];
		snprintf(old, sizeof old, "%s", token_of(&r));
		tool("describe", "echo \"describe $* (the state moved on)\"\n");
		snprintf(text, sizeof text, "action rollback\nconfirm %s\n", old);
		r = deploy(327, text);
		CHECK(r.status == ST_CONFIRM && strcmp(token_of(&r), old), "a token from before the state changed: status 9, a new token (%s, was %s)", token_of(&r), old);
		tool("describe", "case $1 in pin) echo 'glassine-deploy has no pin'; exit 64 ;; broken) exit 3 ;; esac\n"
				 "echo \"describe $*\"\n");
	}
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
	r = confirmed(330, "action select\nid 20261101-120000\n");
	CHECK(r.status == 0 && !strcmp(r.data, "exit 0\ndone select 20261101-120000 no\n"), "DEPLOY select, confirmed: deploy runs, exit 0 and its output");
	{
		r = deploy(331, "action rollback\n");
		snprintf(text, sizeof text, "confirm %s\naction rollback\n", token_of(&r));
		r = deploy(331, text);
		CHECK(r.status == 0, "DEPLOY rollback, confirmed (the lines in any order)");
	}
	r = confirmed(332, "action reset-full\n");
	CHECK(r.status == 0, "DEPLOY reset-full, confirmed");
	r = confirmed(333, "action rollback\ndiscard-hibernation yes\n");
	CHECK(r.status == 0, "DEPLOY rollback discarding the hibernation, confirmed");
	r = confirmed(334, "action remove\nid A\n");
	CHECK(r.status == ST_TOOL && !strcmp(r.data, "exit 4\nboom\n"), "a failing tool: status 10, its exit code and output");
	CHECK(!strcmp(slurp(logf), "select 20261101-120000 no\nrollback - no\nreset-full - no\nrollback - yes\nremove A no\n"),
	      "deploy ran with exactly the actions' arguments (ACTION ID|- yes|no), once each");
	/* the recovery runs as root and gets one; here it needs unprivileged user
	 * namespaces, which some hosts turn off */
	printf("info the tools ran %s\n", g_tool_ns == 1 ? "in a PID namespace of their own" : "in a process group (no PID namespace here)");

	/* nothing of a tool outlives it */
	{
		char bg[1200], bg2[1200], body[8192];
		snprintf(bg, sizeof bg, "%s/bg", dir);
		snprintf(bg2, sizeof bg2, "%s/bg2", dir);
		snprintf(body, sizeof body,
			 "( while [ -d '%s' ]; do echo x >> '%s'; sleep 0.1; done ) &\n"
			 "setsid sh -c 'while [ -d \"%s\" ]; do echo x >> \"%s\"; sleep 0.1; done' > /dev/null 2>&1 < /dev/null &\n"
			 "sleep 0.5; echo started\n", dir, bg, dir, bg2);
		tool("deploy", body);
		long t0 = now_s();
		r = confirmed(336, "action rollback\n");
		CHECK(r.status == 0 && now_s() - t0 < 10, "a tool that leaves a child behind: answered when it ends (%ld s)", now_s() - t0);
		long a = fsize(bg), a2 = fsize(bg2);
		sleep(1);
		CHECK(a > 0 && fsize(bg) == a, "its background child is gone when the answer comes (%ld then %ld bytes)", a, fsize(bg));
		if (g_tool_ns == 1) CHECK(a2 > 0 && fsize(bg2) == a2, "a setsid'ed child too (%ld then %ld bytes)", a2, fsize(bg2));
		else printf("info a setsid'ed child: not checked without a PID namespace\n");
		tool("deploy", "sleep 60 &\necho quick\n");
		t0 = now_s();
		r = confirmed(337, "action rollback\n");
		CHECK(r.status == 0 && !strcmp(r.data, "exit 0\nquick\n") && now_s() - t0 < 10,
		      "a child that holds the output doesn't hold a finished tool's answer (status %u, %ld s)", r.status, now_s() - t0);
		long lim = g_tool_limit;
		g_tool_limit = 3;
		tool("deploy", "echo before\nexec > /dev/null 2>&1\nsleep 60\n");
		t0 = now_s();
		r = confirmed(338, "action rollback\n");
		CHECK(r.status == ST_TOOL && !strcmp(r.data, "exit 124\nbefore\n") && now_s() - t0 < 30,
		      "a tool that closes its output and goes on is stopped at the limit (%ld s)", now_s() - t0);
		g_tool_limit = lim;
		tool("deploy", "echo \"$*\" >> \"$LOG\"\ncase $1 in remove) echo 'boom' >&2; exit 4 ;; esac\necho \"done $*\"\n");
	}
	/* output above the limit: cut, what is kept intact (the buffer grows past 4 KiB
	 * several times) */
	tool("status", "i=0; while [ $i -lt 5000 ]; do printf '%063d\\n' $i; i=$((i + 1)); done\n");
	send_req(3, OP_STATUS, 339, 0, 0, 0);
	r = get_rsp();
	{
		const char *p = strstr(r.data, "\n0000");
		int good = p != NULL;
		for (int i = 0; good && i < 4000; i++) {
			char line[80];
			snprintf(line, sizeof line, "%063d\n", i);
			if (strncmp(p + 1 + 64 * i, line, 64)) good = 0;
		}
		CHECK(r.status == 0 && good && strstr(r.data, "[output cut at 262144 bytes]") && r.length < 263000,
		      "a tool's output above 256 KiB: cut, the first 4000 lines intact (%llu bytes)", (unsigned long long)r.length);
	}
	tool("status", "printf 'machine test\\nglassine-deploy 1\\ntype=status\\tcurrent=A\\n'\n");

	/* ARM after a DEPLOY in this start: refused */
	send_req(3, OP_ARM, 339, 0, 0, 17);
	send_bytes("range 0 0 512\n\n\n\n", 17);
	r = get_rsp();
	CHECK(r.status == ST_ARMED && strstr(r.data, "DEPLOY"), "ARM after a DEPLOY in this start: refused (8: %s)", r.data);
	/* a window that didn't close: DEPLOY refused, STATUS says so */
	g_window_broken = 1;
	r = confirmed(339, "action rollback\n");
	CHECK(r.status == ST_IO, "after a window that didn't close, a confirmed DEPLOY is refused (5)");
	send_req(3, OP_STATUS, 339, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == 0 && strstr(r.data, "\ndeploy partitions held: restart\n"), "STATUS says the partitions are held");
	g_window_broken = 0;
	g_deployed = 0; /* as a new start, for the ARM checks below */
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
	r = confirmed(342, "action rollback\n");
	CHECK(r.status == ST_ARMED, "DEPLOY while armed: refused (8)");
	send_req(3, OP_DISARM, 343, 0, 0, 0);
	r = get_rsp();
	CHECK(r.status == 0, "DISARM");
	r = confirmed(344, "action rollback\n");
	CHECK(r.status == ST_ARMED, "DEPLOY after DISARM: refused (8): the partition table may have changed");
	r = deploy(345, "action rollback\n");
	CHECK(r.status == ST_CONFIRM, "after ARM, an unconfirmed DEPLOY still says what it does");
	CHECK(!strcmp(slurp(logf), "select 20261101-120000 no\nrollback - no\nreset-full - no\nrollback - yes\nremove A no\n"), "deploy did not run once ARM was taken");

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
	r = confirmed(406, "action rollback\n");
	CHECK(r.status == ST_ARMED, "local: DEPLOY refused too once ARM was taken (on the other connection)");
	{	/* a write's payload above any real one ends the local connection (it is
		 * dropped under the lock) */
		int lp[2];
		socketpair(AF_UNIX, SOCK_STREAM, 0, lp);
		pthread_t tx;
		int ax[2] = { lp[1], 1 };
		pthread_create(&tx, NULL, server, ax);
		int keep = c;
		c = lp[0];
		send_req(3, OP_WRITE, 408, 0, 0, (uint64_t)1 << 40);
		void *ret;
		pthread_join(tx, &ret);
		CHECK((long)ret == -1, "local: a WRITE of 1 TiB ends the connection at once");
		close(lp[1]);
		close(lp[0]);
		c = keep;
	}
	{	/* a bad magic under version 2: the RAM environment's words */
		uint8_t b[REQ_SIZE] = { 'X', 'X', 'X', 'X', 2, 0, 1, 0 };
		send_bytes(b, REQ_SIZE);
		r = get_rsp();
		CHECK(r.status == ST_BAD_REQUEST && !strcmp(r.data, "not a request of protocol version 1 or 2"), "a bad version 2 request: the RAM environment's text (%s)", r.data);
	}
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

	{	/* a client that sends a WRITE header and part of its payload, then stalls
		 * without going away: it holds the request lock, so the idle reboot can't
		 * take it; past twice the idle time it reboots anyway, nothing written */
		uint8_t before[32], after[32];
		char *img = slurp(disk); /* the first 8 KiB are enough to see a write */
		struct sha256 hs;
		sha256_init(&hs); sha256_update(&hs, (uint8_t *)img, 8191); sha256_final(&hs, before);
		g_armed = ARM_NEVER; g_deployed = 0;
		c = usb[0];
		send_req(3, OP_ARM, 430, 0, 0, 17);
		send_bytes("range 0 0 4096\n\n\n", 17);
		r = get_rsp();
		CHECK(r.status == 0, "ARM for the stalled WRITE (%u %s)", r.status, r.data);
		rebooted = -1;
		g_idle = 2; g_connect_wait = 2; g_wd_timeout = 3;
		pthread_t wd;
		pthread_create(&wd, NULL, watchdog_thread, NULL);
		uint8_t z[100];
		memset(z, 0xee, sizeof z);
		send_req(2, OP_WRITE, 431, 0, 0, 4096);
		send_bytes(z, sizeof z);
		long t0 = now_s();
		while (rebooted < 0 && now_s() - t0 < 30) usleep(100000);
		CHECK(rebooted == 0 && now_s() - t0 >= 4, "a WRITE whose payload stalls: the idle reboot comes anyway, after twice the idle time (%ld s)", now_s() - t0);
		img = slurp(disk);
		sha256_init(&hs); sha256_update(&hs, (uint8_t *)img, 8191); sha256_final(&hs, after);
		CHECK(!memcmp(before, after, 32), "nothing of the stalled WRITE was written");
	}

	char cmd[PATH_MAX + 16];
	snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
	if (system(cmd)) {}
	printf("%s: %d failed\n", fails ? "FAIL" : "ok", fails);
	return fails != 0;
}
