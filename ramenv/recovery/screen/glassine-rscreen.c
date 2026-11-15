/* SPDX-License-Identifier: GPL-2.0-or-later */
/* glassine-rscreen: the recovery's screen (docs/recovery.md, "The screen"), the third
 * client of the core next to the computer over USB and the console's menu. It offers
 * exactly the menu's operations, through the same requests on the local socket, from
 * the same source (glassine-ramread.c): STATUS, DEPLOY with the confirmation the core
 * names, DIAG, REBOOT. The core decides; this program only asks and shows. A DEPLOY
 * is resent with "confirm TOKEN" only after the person chose the confirming button on
 * a page that showed the core's text whole, and TOKEN is the one the core's status-9
 * answer named, copied, never made here.
 *
 *   glassine-rscreen [--core SOCKET] [--epd SOCKET] [--conf EPD.CONF] [--idle S]
 *                    [--state FILE] [--shot DIR] [--events FILE]
 *
 *   --core    the core's local socket (/run/glassine-recovery.sock)
 *   --epd     glassine-epdd's frame socket (/run/glassine-epd.sock); frames go there
 *             (glassine-epd-proto.h: the surface is a memfd sent once, FRAME per page
 *             or highlight, then DONE). No daemon: frames stay off-screen and the next
 *             one connects again
 *   --conf    the panel's adapter (/etc/glassine/epd.conf): panel_width, panel_height,
 *             rotation (the surface is portrait unless rotation=none) and touch (parts
 *             of the touchscreen's evdev name), read as glassine-epdd reads them
 *   --idle    the core's idle time in seconds (RECOVERY_IDLE): the screen says when the
 *             restart is near, from its own last request (it never asks on a timer)
 *   --state   tests: after each frame, the page, whether it takes input (ready 1: from
 *             0.3 s on) and its buttons
 *   --shot    tests: "shot NAME" in --events writes the surface to DIR/NAME.pgm
 *   --events  tests: input from a script instead of evdev (tap LABEL, short, long,
 *             await PAGE, sleep MS, shot NAME, quit; glyphs draws every glyph in each
 *             face, for a shot)
 *
 * Input: the touchscreen (a tap on a button chooses it) and the power key alone (a
 * short press moves to the next button, a press held 0.8 s chooses it). Input that
 * comes before a new page is on the panel (its DONE, then 0.3 s) is dropped, and so
 * is a touch or press that started then: a tap or hold can't carry from one page into
 * the next. E-ink: black on white, no animation, a page is one frame (glassine-epdd
 * drives more than half the panel as a full refresh), a highlight is a frame of the
 * two buttons that changed.
 */
#define RAMREAD_NO_MAIN
#include "../../glassine-ramread.c"

#include <dirent.h>
#include <linux/input.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <glassine/glassine-epd-proto.h>

struct rs_glyph { int cp, x, y, w, h, adv; long off; };
struct rs_font { int size, asc, desc, n; const struct rs_glyph *g; const uint8_t *bits; };
#include "rs-font.h"

#define F_TITLE (&rs_font_title)
#define F_BODY (&rs_font_body)
#define F_BOLD (&rs_font_bold)
#define F_SMALL (&rs_font_small)
#define F_LABEL (&rs_font_label)

/* ---- settings ------------------------------------------------------------------- */

static const char *o_core = "/run/glassine-recovery.sock", *o_epd = "/run/glassine-epd.sock",
		  *o_conf = "/etc/glassine/epd.conf", *o_state, *o_shot, *o_events;
static long o_idle = 600;
static int pw = 1872, ph = 1404, rot = 1;	/* the panel; rot 0 none, 1 ccw, 2 cw */
static char touchname[4][64] = { "cyttsp5" };
static int SW, SH;				/* the surface */
static uint8_t *cv;				/* the surface, grey, 255 = white */

#define LONG_MS 800
#define SETTLE_MS 300
#define M 72					/* the side margin */

static void rs_say(const char *f, ...) __attribute__((format(printf, 1, 2)));
static void rs_say(const char *f, ...)
{
	va_list a;
	va_start(a, f);
	fprintf(stderr, "glassine-rscreen: ");
	vfprintf(stderr, f, a);
	fprintf(stderr, "\n");
	va_end(a);
}

static long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* the adapter's keys this program uses, read as epd-adapter.h reads them (the last
 * line of a scalar wins; a list key's first line replaces its default) */
static void read_conf(void)
{
	FILE *f = fopen(o_conf, "r");
	if (!f) { rs_say("%s: %s (the panel's defaults)", o_conf, strerror(errno)); return; }
	char l[512];
	int nt = -1;
	while (fgets(l, sizeof l, f)) {
		char *v = strchr(l, '=');
		if (*l == '#' || !v) continue;
		*v++ = 0;
		v[strcspn(v, "\r\n#")] = 0;
		for (char *e = v + strlen(v); e > v && (e[-1] == ' ' || e[-1] == '\t');) *--e = 0;
		if (!strcmp(l, "panel_width")) pw = atoi(v);
		else if (!strcmp(l, "panel_height")) ph = atoi(v);
		else if (!strcmp(l, "rotation")) rot = !strcmp(v, "cw") ? 2 : !strcmp(v, "none") ? 0 : 1;
		else if (!strcmp(l, "touch")) {
			if (nt < 0) { memset(touchname, 0, sizeof touchname); nt = 0; }
			if (*v && nt < 4 && strlen(v) < sizeof touchname[0]) snprintf(touchname[nt++], sizeof touchname[0], "%s", v);
		}
	}
	fclose(f);
}

/* ---- drawing -------------------------------------------------------------------- */

static void fill(int x, int y, int w, int h, uint8_t v)
{
	for (int j = y < 0 ? 0 : y; j < y + h && j < SH; j++)
		for (int i = x < 0 ? 0 : x; i < x + w && i < SW; i++) cv[(size_t)j * SW + i] = v;
}

/* is (i, j) inside the rounded rectangle x, y, w, h with corner radius r */
static int in_rr(int i, int j, int x, int y, int w, int h, int r)
{
	if (i < x || j < y || i >= x + w || j >= y + h) return 0;
	int cx = i < x + r ? x + r : i >= x + w - r ? x + w - r - 1 : i;
	int cy = j < y + r ? y + r : j >= y + h - r ? y + h - r - 1 : j;
	long dx = i - cx, dy = j - cy;
	return dx * dx + dy * dy <= (long)r * r;
}

/* a ring t wide inside the rounded rectangle, in grey v */
static void ring(int x, int y, int w, int h, int r, int t, uint8_t v)
{
	int ri = r > t ? r - t : 0;
	for (int j = y; j < y + h; j++)
		for (int i = x; i < x + w; i++)
			if (j >= 0 && j < SH && i >= 0 && i < SW && in_rr(i, j, x, y, w, h, r)
			    && !in_rr(i, j, x + t, y + t, w - 2 * t, h - 2 * t, ri)) cv[(size_t)j * SW + i] = v;
}

static void fill_rr(int x, int y, int w, int h, int r, uint8_t v)
{
	for (int j = y; j < y + h; j++)
		for (int i = x; i < x + w; i++)
			if (j >= 0 && j < SH && i >= 0 && i < SW && in_rr(i, j, x, y, w, h, r)) cv[(size_t)j * SW + i] = v;
}

/* the next code point of UTF-8 text (an invalid byte reads as '?') */
static unsigned utf8(const char **s)
{
	const unsigned char *p = (const unsigned char *)*s;
	unsigned c = *p++;
	int n = c < 0x80 ? 0 : (c & 0xe0) == 0xc0 ? 1 : (c & 0xf0) == 0xe0 ? 2 : (c & 0xf8) == 0xf0 ? 3 : -1;
	if (n < 0) { *s = (const char *)p; return '?'; }
	if (n) c &= 0x3f >> n;
	for (int i = 0; i < n; i++, p++) {
		if ((*p & 0xc0) != 0x80) { *s = (const char *)p; return '?'; }
		c = c << 6 | (*p & 0x3f);
	}
	*s = (const char *)p;
	return c;
}

static const struct rs_glyph *glyph(const struct rs_font *f, unsigned c)
{
	int lo = 0, hi = f->n - 1;
	if (c == '\t') c = ' ';
	while (lo <= hi) {
		int m = (lo + hi) / 2;
		if ((unsigned)f->g[m].cp == c) return &f->g[m];
		if ((unsigned)f->g[m].cp < c) lo = m + 1;
		else hi = m - 1;
	}
	return c == '?' ? &f->g[0] : glyph(f, '?');
}

/* the width of n bytes of s */
static int measure(const struct rs_font *f, const char *s, size_t n)
{
	int w = 0;
	for (const char *e = s + n; s < e && *s;) w += glyph(f, utf8(&s))->adv;
	return w;
}

/* n bytes of s with the baseline at y, in grey ink (0 black, 255 white); the width */
static int text_n(const struct rs_font *f, int x, int y, const char *s, size_t n, uint8_t ink)
{
	int x0 = x;
	for (const char *e = s + n; s < e && *s;) {
		const struct rs_glyph *g = glyph(f, utf8(&s));
		const uint8_t *b = f->bits + g->off;
		int stride = (g->w + 1) / 2;
		for (int j = 0; j < g->h; j++) {
			int py = y - g->y + j;
			if (py < 0 || py >= SH) continue;
			for (int i = 0; i < g->w; i++) {
				int px = x + g->x + i;
				if (px < 0 || px >= SW) continue;
				int a = b[j * stride + i / 2] >> (i & 1 ? 0 : 4) & 15;
				if (!a) continue;
				uint8_t *d = &cv[(size_t)py * SW + px];
				*d = (uint8_t)(*d + ((int)ink - *d) * a / 15);
			}
		}
		x += g->adv;
	}
	return x - x0;
}

static int text(const struct rs_font *f, int x, int y, const char *s, uint8_t ink)
{
	return text_n(f, x, y, s, strlen(s), ink);
}

static int line_h(const struct rs_font *f) { return f->asc + f->desc + f->size / 5; }

/* s wrapped into width w from the top y (draw 0: only measured); its height. Lines
 * break at spaces, a word wider than w at any character; "\n" ends a line */
static int wrap(const struct rs_font *f, int x, int y, int w, const char *s, uint8_t ink, int draw)
{
	int lh = line_h(f), h = 0;
	while (*s) {
		const char *e = s, *brk = NULL;
		int lw = 0;
		while (*e && *e != '\n') {
			const char *q = e;
			int gw = glyph(f, utf8(&q))->adv;
			if (lw + gw > w && e > s) break;
			if (*e == ' ') brk = e;
			lw += gw;
			e = q;
		}
		const char *end = e;
		if (*e && *e != '\n' && brk) end = brk;
		if (draw) text_n(f, x, y + h + f->asc, s, (size_t)(end - s), ink);
		h += lh;
		s = end;
		while (*s == ' ') s++;
		if (*s == '\n') s++;
	}
	return h;
}

/* ---- the page: what is drawn, its buttons --------------------------------------- */

enum { A_NONE, A_DEPS, A_RESET, A_DIAG, A_RESTART, A_RETRY, A_BACK, A_DEP, A_SELECT, A_REMOVE,
       A_ROLLBACK, A_MORE, A_CANCEL, A_CONFIRM, A_RESET_SYS, A_RESET_FULL, A_NORMAL, A_LOADER, A_DISCARD };

#define NBTN 16
struct button { int x, y, w, h, act, arg; char label[96]; };
static struct button btn[NBTN];
static int nbtn, focus, py;			/* py: the layout's next free line */
static char page[32];

static void new_page(const char *name)
{
	snprintf(page, sizeof page, "%s", name);
	memset(cv, 255, (size_t)SW * SH);
	nbtn = 0;
	focus = 0;
	py = 0;
}

static void focus_ring(int i, int on)
{
	struct button *b = &btn[i];
	ring(b->x, b->y, b->w, b->h, 20, 10, 255);
	ring(b->x, b->y, b->w, b->h, 20, on ? 10 : 4, 0);
}

/* a button row: title (bold) and an optional line below; height from its text */
static int row_reserve;		/* room kept free right of the next row's title (its tags) */
static struct button *row(int act, int arg, const char *title, const char *sub)
{
	if (nbtn == NBTN) return NULL;
	struct button *b = &btn[nbtn++];
	int pad = 30, w = SW - 2 * M, tw = w - 2 * pad, ttw = tw - row_reserve;
	row_reserve = 0;
	int h = pad * 2 + wrap(F_BOLD, 0, 0, ttw, title, 0, 0) + (sub ? wrap(F_SMALL, 0, 0, tw, sub, 0, 0) + 6 : 0);
	*b = (struct button){ M, py, w, h, act, arg, "" };
	snprintf(b->label, sizeof b->label, "%s", title);
	int y = py + pad;
	y += wrap(F_BOLD, M + pad, y, ttw, title, 0, 1);
	if (sub) wrap(F_SMALL, M + pad, y + 6, tw, sub, 0x30, 1);
	ring(b->x, b->y, b->w, b->h, 20, 4, 0);
	py += h + 24;
	return b;
}

/* two buttons side by side at the foot of the page */
static void foot_buttons(int a1, const char *l1, int a2, const char *l2)
{
	int gap = 36, h = 150, w = (SW - 2 * M - gap) / 2, y = SH - 150 - h;
	const char *l[2] = { l1, l2 };
	int a[2] = { a1, a2 };
	for (int k = 0; k < 2 && l[k]; k++) {
		struct button *b = &btn[nbtn++];
		int x = M + k * (w + gap);
		*b = (struct button){ x, y, w, h, a[k], 0, "" };
		snprintf(b->label, sizeof b->label, "%s", l[k]);
		ring(x, y, w, h, 20, 4, 0);
		int tw = measure(F_BOLD, l[k], strlen(l[k])), th = wrap(F_SMALL, 0, 0, w - 40, l[k], 0, 0);
		if (tw <= w - 40) text(F_BOLD, x + (w - tw) / 2, y + (h + F_BOLD->asc - F_BOLD->desc) / 2, l[k], 0);
		else if (th <= h - 30) wrap(F_SMALL, x + 20, y + (h - th) / 2, w - 40, l[k], 0, 1);
		else {	/* never past the button: as much as fits, then "…" (callers keep labels short) */
			size_t n = strlen(l[k]);
			int ew = measure(F_BOLD, "…", strlen("…"));
			while (n && ((l[k][n] & 0xc0) == 0x80 || measure(F_BOLD, l[k], n) + ew > w - 40)) n--;
			int x1 = x + 20 + text_n(F_BOLD, x + 20, y + (h + F_BOLD->asc - F_BOLD->desc) / 2, l[k], n, 0);
			text(F_BOLD, x1, y + (h + F_BOLD->asc - F_BOLD->desc) / 2, "…", 0);
		}
	}
}

/* a label in capitals, mono */
static void label(int x, int y, const char *s, uint8_t ink) { text(F_LABEL, x, y, s, ink); }

/* a tag: a pill around a capitals label, filled (fill) or outlined; its width */
static int tag(int x, int y, const char *s, int filled)
{
	int w = measure(F_LABEL, s, strlen(s)) + 36, h = 48;
	if (filled) fill_rr(x, y, w, h, 24, 0);
	else ring(x, y, w, h, 24, 3, 0);
	label(x + 18, y + (h + F_LABEL->asc - F_LABEL->desc) / 2, s, filled ? 255 : 0);
	return w;
}

static void para(const struct rs_font *f, const char *s, uint8_t ink)
{
	py += wrap(f, M, py, SW - 2 * M, s, ink, 1);
}

/* ---- the core ------------------------------------------------------------------- */

static long last_req;				/* the last answered request, ms */
static int idle_passed;				/* the idle time ran out without a restart */

/* one request to the core; the status (100: no answer), the payload in *out
 * (NUL-terminated, freed by the caller), the header's sha256 in sha */
static int rq(uint16_t op, uint32_t index, const char *text, size_t tn, char **out, size_t *on, uint8_t *sha)
{
	*out = NULL;
	if (on) *on = 0;
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", o_core);
	int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (s < 0 || connect(s, (struct sockaddr *)&sa, sizeof sa) < 0) {
		if (s >= 0) close(s);
		*out = strdup("cannot connect to the recovery's socket");
		return 100;
	}
	uint8_t q[REQ_SIZE] = { 0 }, h[RSP_SIZE];
	memcpy(q, REQ_MAGIC, 4);
	st16(q + 4, PROTO_V3);
	st16(q + 6, op);
	st32(q + 8, (uint32_t)getpid());
	st32(q + 12, index);
	st64(q + 24, tn);
	int status = 100;
	if (write_full(s, q, REQ_SIZE) < 0 || (tn && write_full(s, (const uint8_t *)text, tn) < 0)) {
		*out = strdup("cannot send the request");
	} else if (read_full(s, h, RSP_SIZE) != 1 || memcmp(h, RSP_MAGIC, 4)) {
		*out = strdup("no answer");
	} else {
		uint64_t n = ld64(h + 16);
		char *p = n <= MAX_READ ? malloc(n + 1) : NULL;
		if (!p || (n && read_full(s, (uint8_t *)p, (size_t)n) != 1)) {
			free(p);
			*out = strdup("a cut answer");
		} else {
			p[n] = 0;
			*out = p;
			if (on) *on = (size_t)n;
			if (sha) memcpy(sha, h + 32, 32);
			status = ld16(h + 12);
			last_req = now_ms();
			idle_passed = 0;
		}
	}
	close(s);
	return status;
}

/* a request whose answer isn't looked at: input keeps the core from its idle restart */
static void keepalive(void)
{
	char *o;
	rq(OP_LIST, 0, NULL, 0, &o, NULL, NULL);
	free(o);
}

/* ---- STATUS, parsed -------------------------------------------------------------- */

#define NDEP 64
/* an id never reaches the core cut: a record whose id doesn't fit is left out (dep_cut) */
#define IDLEN 256
struct dep { char id[IDLEN], state[16], base[128], present[8], created[40], size[24]; };
static struct dep deps[NDEP];
static int ndep, dep_cut, st_status = -1;
static char st_raw[4096], st_raw_full[16384], rec_boot[48], rec_build[24], rec_device[48], machine[96], kernel[96],
	    actions[128], cur[IDLEN], prev[IDLEN], cand[IDLEN], tries[8], failedid[IDLEN];

/* the value of KEY=... in a tab-separated porcelain record; -1 when it was cut to fit */
static int pfield(const char *rec, const char *key, char *out, size_t n)
{
	size_t k = strlen(key);
	*out = 0;
	for (const char *p = rec; p && *p;) {
		if (!strncmp(p, key, k) && p[k] == '=') {
			const char *v = p + k + 1;
			size_t l = strcspn(v, "\t\n");
			snprintf(out, n, "%.*s", (int)(l < n ? l : n - 1), v);
			return l < n ? 0 : -1;
		}
		p = strpbrk(p, "\t\n");
		if (p && *p == '\n') return 0;
		if (p) p++;
	}
	return 0;
}

/* the value after "KEY " on its own line of STATUS */
static void sline(const char *s, const char *key, char *out, size_t n)
{
	size_t k = strlen(key);
	*out = 0;
	for (const char *p = s; p && *p; p = strchr(p, '\n'), p = p ? p + 1 : NULL)
		if (!strncmp(p, key, k) && p[k] == ' ') {
			size_t l = strcspn(p + k + 1, "\n");
			snprintf(out, n, "%.*s", (int)(l < n ? l : n - 1), p + k + 1);
			return;
		}
}

static void word(const char *s, const char *key, char *out, size_t n)
{
	size_t k = strlen(key);
	*out = 0;
	for (const char *p = s; p && *p; p = strchr(p, ' '), p = p ? p + 1 : NULL)
		if (!strncmp(p, key, k) && p[k] == '=') {
			size_t l = strcspn(p + k + 1, " \n");
			snprintf(out, n, "%.*s", (int)(l < n ? l : n - 1), p + k + 1);
			return;
		}
}

static int status(void)
{
	char *s;
	st_status = rq(OP_STATUS, 0, NULL, 0, &s, NULL, NULL);
	snprintf(st_raw, sizeof st_raw, "%s", s);
	snprintf(st_raw_full, sizeof st_raw_full, "%s", s);
	ndep = dep_cut = 0;
	*cur = *prev = *cand = *tries = *failedid = *actions = 0;
	if (st_status == ST_OK) {
		char r[256];
		sline(s, "recovery", r, sizeof r);
		word(r, "boot", rec_boot, sizeof rec_boot);
		word(r, "build", rec_build, sizeof rec_build);
		word(r, "device", rec_device, sizeof rec_device);
		sline(s, "machine", machine, sizeof machine);
		sline(s, "kernel", kernel, sizeof kernel);
		snprintf(actions, sizeof actions, " ");
		sline(s, "actions", actions + 1, sizeof actions - 2);
		strcat(actions, " ");
		for (char *p = s; p && *p; p = strchr(p, '\n'), p = p ? p + 1 : NULL) {
			if (!strncmp(p, "type=status\t", 12)) {
				pfield(p, "current", cur, sizeof cur);
				pfield(p, "previous", prev, sizeof prev);
				pfield(p, "candidate", cand, sizeof cand);
				pfield(p, "tries", tries, sizeof tries);
				pfield(p, "failed", failedid, sizeof failedid);
			} else if (!strncmp(p, "type=deployment\t", 16) && ndep < NDEP) {
				struct dep *d = &deps[ndep++];
				if (pfield(p, "id", d->id, sizeof d->id)) { ndep--; dep_cut++; continue; }
				pfield(p, "state", d->state, sizeof d->state);
				pfield(p, "base", d->base, sizeof d->base);
				pfield(p, "base_present", d->present, sizeof d->present);
				pfield(p, "created", d->created, sizeof d->created);
				pfield(p, "size_kib", d->size, sizeof d->size);
				if (!*d->id) ndep--;
			}
		}
	}
	free(s);
	return st_status;
}

static int offered(const char *a)
{
	char k[40];
	snprintf(k, sizeof k, " %s ", a);
	return strstr(actions, k) != NULL;
}

/* ---- the panel ------------------------------------------------------------------ */

static int epd = -1, memfd = -1;
static uint8_t *surf;				/* the memfd: XBGR (bytes R G B X) */
static uint32_t seq;

static void epd_close(void)
{
	if (epd >= 0) close(epd);
	epd = -1;
}

static int epd_open(void)
{
	if (epd >= 0) return 0;
	if (!o_epd || !*o_epd) return -1;
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	snprintf(sa.sun_path, sizeof sa.sun_path, "%s", o_epd);
	int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (s < 0 || connect(s, (struct sockaddr *)&sa, sizeof sa) < 0) {
		if (s >= 0) close(s);
		return -1;
	}
	struct timeval tv = { 5, 0 };
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	struct glassine_epd_msg m = { .type = GLASSINE_EPD_HELLO, .id = GLASSINE_EPD_PROTO_VERSION };
	if (send(s, &m, sizeof m, MSG_NOSIGNAL) < 0 || recv(s, &m, sizeof m, 0) <= 0
	    || m.type != GLASSINE_EPD_HELLO || m.id != GLASSINE_EPD_PROTO_VERSION) {
		rs_say("the panel daemon doesn't speak protocol %d", GLASSINE_EPD_PROTO_VERSION);
		close(s);
		return -1;
	}
	struct glassine_epd_msg b = { .type = GLASSINE_EPD_BUF, .id = 0, .width = (uint32_t)SW, .height = (uint32_t)SH,
				      .stride = (uint32_t)SW * 4, .format = 0x34324258 /* XB24 */, .offset = 0 };
	char cb[CMSG_SPACE(sizeof(int))] = { 0 };
	struct iovec iov = { &b, sizeof b };
	struct msghdr h = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cb, .msg_controllen = sizeof cb };
	struct cmsghdr *c = CMSG_FIRSTHDR(&h);
	c->cmsg_level = SOL_SOCKET;
	c->cmsg_type = SCM_RIGHTS;
	c->cmsg_len = CMSG_LEN(sizeof(int));
	memcpy(CMSG_DATA(c), &memfd, sizeof memfd);
	if (sendmsg(s, &h, MSG_NOSIGNAL) < 0) { close(s); return -1; }
	epd = s;
	rs_say("panel daemon connected");
	return 0;
}

static void write_state(int ready)
{
	if (!o_state) return;
	char tmp[256];
	snprintf(tmp, sizeof tmp, "%s.tmp", o_state);
	FILE *f = fopen(tmp, "w");
	if (!f) return;
	fprintf(f, "page %s\nready %d\nfocus %d\nseq %u\n", page, ready, focus, seq);
	for (int i = 0; i < nbtn; i++)
		fprintf(f, "button %d %d %d %d %d %s\n", i, btn[i].x, btn[i].y, btn[i].w, btn[i].h, btn[i].label);
	fclose(f);
	rename(tmp, o_state);
}

/* the surface, or the rectangles r (n of them; 0 = all), to the panel; returns once
 * the daemon read it (DONE) or after 5 s */
static void push(const struct glassine_epd_rect *r, int n)
{
	write_state(0);
	int fresh = epd < 0;
	if (epd_open() == 0) {
		struct glassine_epd_rect all = { 0, 0, SW, SH };
		if (fresh || !n) { r = &all; n = 1; }
		for (int k = 0; k < n; k++)
			for (int j = r[k].y; j < r[k].y + r[k].h; j++)
				for (int i = r[k].x; i < r[k].x + r[k].w; i++) {
					uint8_t g = cv[(size_t)j * SW + i], *d = surf + ((size_t)j * SW + i) * 4;
					d[0] = d[1] = d[2] = g;
					d[3] = 255;
				}
		struct glassine_epd_msg m = { .type = GLASSINE_EPD_FRAME, .id = 0, .seq = ++seq,
					      .nrect = r == &all ? 0 : (uint32_t)n };
		for (int k = 0; k < n && k < GLASSINE_EPD_MAXRECT && r != &all; k++) m.rect[k] = r[k];
		if (send(epd, &m, sizeof m, MSG_NOSIGNAL) < 0) epd_close();
		else
			for (;;) {
				struct glassine_epd_msg d;
				ssize_t k = recv(epd, &d, sizeof d, 0);
				if (k <= 0) { rs_say("no DONE from the panel daemon"); epd_close(); break; }
				if (d.type == GLASSINE_EPD_DONE && d.seq == seq) break;
			}
	} else seq++;
}

static void shot(const char *name)
{
	if (!o_shot) return;
	char p[512];
	snprintf(p, sizeof p, "%s/%s.pgm", o_shot, name);
	FILE *f = fopen(p, "wb");
	if (!f) { rs_say("%s: %s", p, strerror(errno)); return; }
	fprintf(f, "P5\n%d %d\n255\n", SW, SH);
	fwrite(cv, 1, (size_t)SW * SH, f);
	fclose(f);
}

/* ---- input ---------------------------------------------------------------------- */

struct tdev { int fd, touch, ax[4]; };	/* ax: min x, max x, min y, max y */
static struct tdev in[8];
static int nin;
static long last_scan;
static FILE *script;

static int has_bit(const unsigned long *b, int n) { return b[n / (8 * sizeof *b)] >> (n % (8 * sizeof *b)) & 1; }

/* the touchscreen (by its adapter name) and every device with a power key */
static void scan_input(void)
{
	last_scan = now_ms();
	int want_touch = 1, want_key = 1;
	for (int i = 0; i < nin; i++) {
		if (in[i].touch) want_touch = 0;
		else want_key = 0;
	}
	if (!want_touch && !want_key) return;
	DIR *d = opendir("/dev/input");
	if (!d) return;
	for (struct dirent *e; (e = readdir(d)) && nin < 8;) {
		if (strncmp(e->d_name, "event", 5)) continue;
		char p[300], name[128] = "";
		snprintf(p, sizeof p, "/dev/input/%s", e->d_name);
		int fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) continue;
		struct stat st;
		int dup = 0;
		fstat(fd, &st);
		for (int i = 0; i < nin; i++) {
			struct stat s2;
			if (!fstat(in[i].fd, &s2) && s2.st_rdev == st.st_rdev) dup = 1;
		}
		ioctl(fd, EVIOCGNAME(sizeof name - 1), name);
		unsigned long keys[KEY_MAX / (8 * sizeof(long)) + 1] = { 0 }, abs[ABS_MAX / (8 * sizeof(long)) + 1] = { 0 };
		ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keys), keys);
		ioctl(fd, EVIOCGBIT(EV_ABS, sizeof abs), abs);
		int touch = 0;
		for (int i = 0; i < 4 && *touchname[i]; i++)
			if (strstr(name, touchname[i])) touch = 1;
		struct tdev t = { fd, 0, { 0, 0, 0, 0 } };
		if (!dup && touch && want_touch) {
			int mt = has_bit(abs, ABS_MT_POSITION_X);
			struct input_absinfo ax, ay;
			if (!ioctl(fd, EVIOCGABS(mt ? ABS_MT_POSITION_X : ABS_X), &ax) && !ioctl(fd, EVIOCGABS(mt ? ABS_MT_POSITION_Y : ABS_Y), &ay)
			    && ax.maximum > ax.minimum && ay.maximum > ay.minimum) {
				t.touch = mt ? 2 : 1;
				t.ax[0] = ax.minimum; t.ax[1] = ax.maximum; t.ax[2] = ay.minimum; t.ax[3] = ay.maximum;
				in[nin++] = t;
				rs_say("touch: %s (%s)", p, name);
				continue;
			}
		}
		if (!dup && has_bit(keys, KEY_POWER)) {
			in[nin++] = t;
			rs_say("power key: %s (%s)", p, name);
			continue;
		}
		close(fd);
	}
	closedir(d);
}

/* the panel's pixel (x, y) on the surface: the inverse of glassine-epdd's to_panel */
static void to_surface(int x, int y, int *u, int *v)
{
	*u = rot == 1 ? y : rot == 2 ? ph - 1 - y : x;
	*v = rot == 1 ? pw - 1 - x : rot == 2 ? x : y;
}

enum { IN_NONE, IN_TAP, IN_SHORT, IN_LONG, IN_PICK };
struct ev { int kind, u, v, idx; };

static int t_down, t_ignore, t_x, t_y, t_su, t_sv;	/* the touch: down, started too early, last position */
static int k_down, k_ignore, k_long;		/* the power key */
static long k_t;
static long ready_at;			/* input counts from this time on (ms) */
static int g_quit;

static int hit(int u, int v)
{
	for (int i = 0; i < nbtn; i++)
		if (u >= btn[i].x && u < btn[i].x + btn[i].w && v >= btn[i].y && v < btn[i].y + btn[i].h) return i;
	return -1;
}

/* tests: every glyph the pages use, in each face and size (the golden "glyphs") */
static void glyph_sweep(void)
{
	static const struct { const struct rs_font *f; const char *name; } faces[] = {
		{ &rs_font_title, "TITLE · SANS 600 · 64" }, { &rs_font_body, "BODY · SANS 400 · 40" },
		{ &rs_font_bold, "BOLD · SANS 600 · 40" }, { &rs_font_small, "SMALL · SANS 400 · 32" },
		{ &rs_font_label, "LABEL · MONO 500 · 28" } };
	char all[400] = "";
	for (int c = 33; c < 127; c++) { size_t n = strlen(all); all[n] = (char)c; all[n + 1] = 0; }
	strcat(all, " · – — ‘ ’ “ ” • … → é ü ß Ä Ö Ü ©");
	new_page("glyphs");
	py = 40;
	for (size_t i = 0; i < sizeof faces / sizeof *faces; i++) {
		label(M, py + F_LABEL->asc, faces[i].name, 0x60);
		py += line_h(F_LABEL) + 4;
		py += wrap(faces[i].f, M, py, SW - 2 * M, all, 0, 1);
		py += wrap(faces[i].f, M, py, SW - 2 * M, "Full reset · Flatpak · Wi-Fi · 20261112-0930", 0, 1) + 20;
	}
}

/* the next script line in --events mode, once the page takes input */
static int script_event(struct ev *e)
{
	static long sleep_until;
	if (now_ms() < sleep_until || now_ms() < ready_at) return 0;
	char l[256];
	for (;;) {
		long pos = ftell(script);
		if (!fgets(l, sizeof l, script)) { g_quit = 1; return 0; }
		l[strcspn(l, "\n")] = 0;
		if (!*l || *l == '#') continue;
		rs_say("script: %s", l);
		if (!strncmp(l, "await ", 6)) {
			if (strcmp(page, l + 6)) { fseek(script, pos, SEEK_SET); return 0; }
			continue;
		}
		if (!strncmp(l, "shot ", 5)) { shot(l + 5); continue; }
		if (!strcmp(l, "glyphs")) { glyph_sweep(); continue; }
		if (!strncmp(l, "sleep ", 6)) { sleep_until = now_ms() + atol(l + 6); return 0; }
		if (!strcmp(l, "quit")) { g_quit = 1; return 0; }
		if (!strcmp(l, "short")) { e->kind = IN_SHORT; return 1; }
		if (!strcmp(l, "long")) { e->kind = IN_LONG; return 1; }
		if (!strncmp(l, "tap ", 4)) {
			for (int i = 0; i < nbtn; i++)
				if (!strncmp(btn[i].label, l + 4, strlen(l + 4))) { e->kind = IN_PICK; e->idx = i; return 1; }
			rs_say("script: no button %s on page %s", l + 4, page);
			g_quit = 1;
			return 0;
		}
		rs_say("script: unknown line %s", l);
		g_quit = 1;
		return 0;
	}
}

/* waits up to ms for one input; 1 = *e holds it */
static int next_event(struct ev *e, long ms)
{
	e->kind = IN_NONE;
	if (script) {
		if (script_event(e)) return 1;
		usleep((useconds_t)(ms < 50 ? ms : 50) * 1000);
		return 0;
	}
	if (now_ms() - last_scan > 2000) scan_input();
	struct pollfd p[8];
	for (int i = 0; i < nin; i++) p[i] = (struct pollfd){ in[i].fd, POLLIN, 0 };
	if (k_down && !k_ignore && !k_long) {
		long left = k_t + LONG_MS - now_ms();
		if (left <= 0) { k_long = 1; e->kind = IN_LONG; return 1; }
		if (left < ms) ms = left;
	}
	if (ms > 2000) ms = 2000;
	if (poll(p, (nfds_t)nin, (int)ms) <= 0) return 0;
	for (int i = 0; i < nin; i++) {
		if (!(p[i].revents & (POLLIN | POLLERR | POLLHUP))) continue;
		struct input_event v[64];
		ssize_t n = read(in[i].fd, v, sizeof v);
		if (n <= 0) {
			if (n < 0 && errno == EAGAIN) continue;
			close(in[i].fd);
			in[i] = in[--nin];
			return 0;
		}
		int early = now_ms() < ready_at;
		for (size_t k = 0; k < (size_t)n / sizeof *v; k++) {
			struct input_event *x = &v[k];
			if (!in[i].touch) {
				if (x->type != EV_KEY || x->code != KEY_POWER || x->value == 2) continue;
				if (x->value == 1) { k_down = 1; k_ignore = early; k_long = 0; k_t = now_ms(); continue; }
				int was_short = k_down && !k_ignore && !k_long;
				k_down = 0;
				if (was_short) e->kind = IN_SHORT;
				continue;
			}
			struct tdev *t = &in[i];
			if (x->type == EV_ABS) {
				if (x->code == (t->touch == 2 ? ABS_MT_POSITION_X : ABS_X)) t_x = x->value;
				else if (x->code == (t->touch == 2 ? ABS_MT_POSITION_Y : ABS_Y)) t_y = x->value;
				else if (t->touch == 2 && x->code == ABS_MT_TRACKING_ID) {
					if (x->value < 0 && t_down) t_down = 2;	/* lifted; reported at the next SYN */
					else if (x->value >= 0 && !t_down) { t_down = 3; t_ignore = early; }
				}
			} else if (x->type == EV_KEY && x->code == BTN_TOUCH) {
				if (x->value) { if (!t_down) { t_down = 3; t_ignore = early; } }
				else if (t_down) t_down = 2;
			} else if (x->type == EV_SYN && x->code == SYN_REPORT) {
				int px = (int)((long)(t_x - t->ax[0]) * (pw - 1) / (t->ax[1] - t->ax[0]));
				int qy = (int)((long)(t_y - t->ax[2]) * (ph - 1) / (t->ax[3] - t->ax[2]));
				int u, w;
				to_surface(px, qy, &u, &w);
				if (t_down == 3) { t_down = 1; t_su = u; t_sv = w; }
				else if (t_down == 2) {
					t_down = 0;
					/* a tap: down and up on the same button, both after the page took input */
					if (!t_ignore && !early && hit(t_su, t_sv) == hit(u, w)) {
						e->kind = IN_TAP; e->u = u; e->v = w;
					}
				}
			}
		}
		if (e->kind != IN_NONE) return 1;
	}
	return 0;
}

/* ---- the page shown, its choice ------------------------------------------------- */

static void page_idle(long left_s);
static void page_restarting(const char *why);

/* shows the page drawn on the surface and waits for a button to be chosen; its index.
 * Watches the idle time meanwhile: near its end it says so (no request), and the
 * page comes back with the next input */
static int choose(void)
{
	static uint8_t *saved;
	if (!saved) saved = malloc((size_t)SW * SH);
	if (nbtn) focus_ring(focus, 1);	/* where the power key is */
	push(NULL, 0);
	ready_at = now_ms() + SETTLE_MS;
	write_state(1);
	rs_say("page %s", page);
	for (;;) {
		if (g_quit) exit(0);
		long lead = o_idle / 3 < 60 ? o_idle / 3 : 60;
		long idle_at = last_req + (o_idle - lead) * 1000L, end_at = last_req + o_idle * 1000L;
		struct ev e;
		long wait = idle_passed ? 2000 : idle_at - now_ms();
		if (!idle_passed && wait <= 0) {
			/* the idle notice, then the restart's; the page is kept aside */
			struct button sb[NBTN];
			int sn = nbtn, sf = focus;
			char sp[32];
			memcpy(saved, cv, (size_t)SW * SH);
			memcpy(sb, btn, sizeof sb);
			snprintf(sp, sizeof sp, "%s", page);
			int restarting = 0, woke = 0;
			page_idle((end_at - now_ms() + 999) / 1000);
			write_state(1);	/* input wakes it */
			while (!woke) {
				if (g_quit) exit(0);
				long t = restarting ? end_at + 30000 - now_ms() : end_at - now_ms();
				if (t <= 0) {
					if (restarting) { idle_passed = 1; break; }	/* another client keeps it up */
					page_restarting("Nobody has used the recovery for a while.");
					write_state(1);
					restarting = 1;
					continue;
				}
				if (next_event(&e, t) && e.kind != IN_NONE) woke = 1;
			}
			if (woke) keepalive();
			memcpy(cv, saved, (size_t)SW * SH);
			memcpy(btn, sb, sizeof sb);
			nbtn = sn;
			focus = sf;
			snprintf(page, sizeof page, "%s", sp);
			push(NULL, 0);
			ready_at = now_ms() + SETTLE_MS;
			write_state(1);
			rs_say("page %s", page);
			continue;
		}
		if (!next_event(&e, wait > 0 ? wait : 1)) continue;
		int pick = -1;
		if (e.kind == IN_TAP) pick = hit(e.u, e.v);
		else if (e.kind == IN_PICK) pick = e.idx;
		else if (e.kind == IN_LONG && nbtn) pick = focus;
		else if (e.kind == IN_SHORT && nbtn > 1) {
			int old = focus;
			focus = (focus + 1) % nbtn;
			focus_ring(old, 0);
			focus_ring(focus, 1);
			struct glassine_epd_rect r[2] = { { btn[old].x, btn[old].y, btn[old].w, btn[old].h },
							  { btn[focus].x, btn[focus].y, btn[focus].w, btn[focus].h } };
			push(r, 2);
			write_state(1);
			keepalive();
			continue;
		}
		if (pick < 0) continue;
		keepalive();
		rs_say("chose %s on %s", btn[pick].label, page);
		return pick;
	}
}

/* a page without buttons, shown once (no input taken) */
static void show(void)
{
	char n[48];
	push(NULL, 0);
	rs_say("page %s", page);
	snprintf(n, sizeof n, "shown-%s", page);
	shot(n);	/* tests: a page without input can't be shot from the script */
}

/* ---- the pages ------------------------------------------------------------------ */

static void header(const char *title)
{
	py = 64;
	label(M, py + F_LABEL->asc, "GLASSINEOS RECOVERY", 0);
	py += line_h(F_LABEL) + 8;
	char id[256];
	if (*rec_boot || *machine)
		snprintf(id, sizeof id, "%s · boot %.7s · build %.8s", *machine ? machine : rec_device,
			 *rec_boot ? rec_boot : "?", *rec_build ? rec_build : "?");
	else snprintf(id, sizeof id, "The device’s identity isn’t known yet.");
	py += wrap(F_SMALL, M, py, SW - 2 * M, id, 0x30, 1);
	py += 24;
	fill(M, py, SW - 2 * M, 4, 0);
	py += 4 + 56;
	if (title) {
		py += wrap(F_TITLE, M, py, SW - 2 * M, title, 0, 1);
		py += 24;
	}
}

static void footer(int hint)
{
	if (!hint) return;
	label(M, SH - 64, "TAP TO CHOOSE · POWER KEY: PRESS TO MOVE, HOLD TO CHOOSE", 0x30);
}

static void page_idle(long left_s)
{
	new_page("idle");
	header("Nobody is using the recovery");
	char t[256];
	snprintf(t, sizeof t, "In about %ld seconds it restarts into the normal start. Nothing on the device changes.", left_s);
	para(F_BODY, t, 0);
	py += 30;
	para(F_BODY, "Touch the screen or press the power key to stay.", 0);
	show();
}

static void page_restarting(const char *why)
{
	new_page("restarting");
	header("Restarting");
	para(F_BODY, why, 0);
	py += 30;
	para(F_BODY, "The device starts normally now.", 0);
	show();
}

static void kv(const char *k, const char *v)
{
	label(M + 36, py + F_BODY->asc, k, 0x30);
	py += wrap(F_BOLD, M + 360, py, SW - 2 * M - 396, v, 0, 1) + 8;
}

/* the result of an operation: its title, the text, a button back */
static void page_result(const char *name, const char *title, const char *body, const char *note)
{
	new_page(name);
	header(title);
	int avail = SH - 150 - 150 - 60 - py;
	const char *b = body ? body : "";
	if (wrap(F_BODY, M, py, SW - 2 * M, b, 0, 0) <= avail) para(F_BODY, b, 0);
	else if (wrap(F_SMALL, M, py, SW - 2 * M, b, 0, 0) <= avail) para(F_SMALL, b, 0);
	else {
		/* the lines that fit, and how many don't */
		char *c = strdup(b);
		size_t n = strlen(c);
		while (n && wrap(F_SMALL, M, py, SW - 2 * M, c, 0, 0) > avail - line_h(F_SMALL)) {
			while (n && c[n - 1] != '\n') n--;
			if (n) c[--n] = 0;
			else break;
		}
		if (!n) c[0] = 0;
		para(F_SMALL, c, 0);
		para(F_LABEL, "(MORE OUTPUT FOLLOWS, NOT SHOWN HERE)", 0x30);
		free(c);
	}
	if (note) { py += 20; para(F_BODY, note, 0); }
	foot_buttons(A_BACK, "Back to the start", A_NONE, NULL);
	footer(1);
	choose();
}

/* what an action is called on its confirming button and page */
static void names(const char *act, const char *id, char *title, size_t tn, char *button, size_t bn)
{
	if (!strcmp(act, "select")) { snprintf(title, tn, "Start %s next?", id); snprintf(button, bn, "Start %s", id); }
	else if (!strcmp(act, "rollback")) { snprintf(title, tn, "Roll back?"); snprintf(button, bn, "Roll back"); }
	else if (!strcmp(act, "reset")) { snprintf(title, tn, "Reset the system?"); snprintf(button, bn, "Reset system"); }
	else if (!strcmp(act, "reset-full")) { snprintf(title, tn, "Full reset?"); snprintf(button, bn, "Full reset"); }
	else if (!strcmp(act, "remove")) { snprintf(title, tn, "Delete %s?", id); snprintf(button, bn, "Delete %s", id); }
	else { snprintf(title, tn, "%s?", act); snprintf(button, bn, "%s", act); }
}

/* the confirmation page: the core's text whole; 1 = the person chose the action's
 * button, 0 = cancel. A text that doesn't fit isn't confirmable here */
static int page_confirm(const char *act, const char *id, const char *what)
{
	char title[IDLEN + 40], button[IDLEN + 20];
	names(act, id, title, sizeof title, button, sizeof button);
	/* a long id stays in the title; its button then says "it" */
	if (id && measure(F_BOLD, button, strlen(button)) > (SW - 2 * M - 36) / 2 - 40)
		snprintf(button, sizeof button, "%s", !strcmp(act, "select") ? "Start it" : !strcmp(act, "remove") ? "Delete it" : act);
	new_page(!strcmp(act, "reset-full") ? "confirm-reset-full" : !strcmp(act, "reset") ? "confirm-reset"
		 : !strcmp(act, "rollback") ? "confirm-rollback" : !strcmp(act, "select") ? "confirm-select" : "confirm-remove");
	header(title);
	label(M, py + F_LABEL->asc, "WHAT THIS DOES", 0x30);
	py += line_h(F_LABEL) + 12;
	int avail = SH - 150 - 150 - 40 - py;
	const struct rs_font *f = wrap(F_BODY, M, py, SW - 2 * M, what, 0, 0) <= avail ? F_BODY : F_SMALL;
	int fits = wrap(f, M, py, SW - 2 * M, what, 0, 0) <= avail;
	if (fits) {
		para(f, what, 0);
		foot_buttons(A_CANCEL, "Cancel", A_CONFIRM, button);
	} else {
		para(F_BODY, "What this does is too long for this screen. Use the console or the installer for it.", 0);
		foot_buttons(A_CANCEL, "Cancel", A_NONE, NULL);
	}
	footer(1);
	return btn[choose()].act == A_CONFIRM;
}

static void page_working(const char *title, const char *what)
{
	new_page("working");
	header(title);
	para(F_BODY, what, 0);
	py += 30;
	para(F_BODY, "Don’t switch the device off. This can take a few minutes.", 0);
	show();
}

/* a DEPLOY action, as the menu's deploy(): ask the core, show what it does, ask for
 * the confirmation it named, then send it with that token */
static void deploy(const char *act, const char *id)
{
	char base[IDLEN + 64], req[IDLEN * 3], tok[IDLEN + 64] = "";
	int disc = 0;
	snprintf(base, sizeof base, "action %s\n%s%s%s", act, id ? "id " : "", id ? id : "", id ? "\n" : "");
	for (;;) {
		snprintf(req, sizeof req, "%s%s%s%s%s", base, disc ? "discard-hibernation yes\n" : "",
			 *tok ? "confirm " : "", tok, *tok ? "\n" : "");
		if (*tok) rs_say("deploy %s: sending the confirmation", act);
		char *a;
		int st = rq(OP_DEPLOY, 0, req, strlen(req), &a, NULL, NULL);
		*tok = 0;
		if (st == ST_CONFIRM) {
			if (strncmp(a, "confirm ", 8)) { page_result("refused", "The recovery’s answer can’t be read", a, NULL); free(a); return; }
			size_t l = strcspn(a + 8, "\n");
			char t[IDLEN + 64];
			/* the token goes back whole or not at all */
			if (l >= sizeof t) { page_result("refused", "The recovery’s answer can’t be read", "Its confirmation is longer than this screen takes.", NULL); free(a); return; }
			snprintf(t, sizeof t, "%.*s", (int)l, a + 8);
			const char *what = a[8 + l] ? a + 8 + l + 1 : "";
			int yes = page_confirm(act, id, what);
			free(a);
			if (!yes) { page_result("cancelled", "Cancelled", "Nothing changed.", NULL); return; }
			snprintf(tok, sizeof tok, "%s", t);
			char title[IDLEN + 40], button[IDLEN + 20];
			names(act, id, title, sizeof title, button, sizeof button);
			page_working("Working", button);
			continue;
		}
		if (st == ST_TOOL) {
			int hib = !strncmp(a, "exit 4\n", 7) || !strcmp(a, "exit 4");
			if (hib && !disc) {
				new_page("hibernated");
				header("Userdata holds a hibernated session");
				para(F_BODY, "To go on, it has to be discarded: whatever was open in it is lost. What this does is shown again before anything happens.", 0);
				foot_buttons(A_CANCEL, "Cancel", A_DISCARD, "Discard it and go on");
				footer(1);
				if (btn[choose()].act == A_DISCARD) { disc = 1; free(a); continue; }
				page_result("cancelled", "Cancelled", "Nothing changed.", NULL);
				free(a);
				return;
			}
			page_result("failed", "It didn’t work", a, NULL);
			free(a);
			return;
		}
		if (st == ST_OK) {
			const char *out = strchr(a, '\n');
			page_result("done", "Done", out ? out + 1 : "", NULL);
			free(a);
			return;
		}
		char note[64];
		snprintf(note, sizeof note, "(refused, status %d)", st);
		page_result("refused", "Refused", a, note);
		free(a);
		return;
	}
}

/* the core gives no STATUS: say so, try again */
static int core_down(void)
{
	new_page("no-core");
	header("The recovery’s core does not answer");
	char t[64];
	snprintf(t, sizeof t, "Status %d:", st_status);
	para(F_BODY, t, 0);
	para(F_SMALL, st_raw, 0);
	foot_buttons(A_RETRY, "Try again", A_NONE, NULL);
	footer(1);
	return choose();
}

static void tags_of(const struct dep *d, int x, int y)
{
	int nx = x;
	if (!strcmp(d->state, "current")) {
		nx += tag(nx, y, "LAST GOOD", 1) + 14;
		if (!*cand) nx += tag(nx, y, "STARTS NEXT", 0) + 14;
	} else if (!strcmp(d->state, "candidate")) {
		char t[48];
		snprintf(t, sizeof t, "STARTS NEXT · %s TRIES", *tries ? tries : "?");
		nx += tag(nx, y, t, 0) + 14;
	} else if (!strcmp(d->state, "failed")) nx += tag(nx, y, "FAILED", 1) + 14;
	else if (!strcmp(d->state, "previous")) nx += tag(nx, y, "PREVIOUS", 0) + 14;
	else if (!strcmp(d->state, "staged")) nx += tag(nx, y, "STAGED", 0) + 14;
	else if (!strcmp(d->state, "kept")) nx += tag(nx, y, "KEPT", 0) + 14;
	if (strcmp(d->state, "failed") && *failedid && !strcmp(d->id, failedid)) nx += tag(nx, y, "FAILED", 1) + 14;
	if (!strcmp(d->present, "no")) tag(nx, y, "BASE MISSING", 0);
}

static void dep_page(int i)
{
	for (;;) {
		struct dep d = deps[i];
		new_page("deployment");
		header(d.id);
		tags_of(&d, M, py);
		py += 48 + 40;
		char sz[48] = "";
		if (*d.size) snprintf(sz, sizeof sz, "%ld MB", atol(d.size) / 1024);
		kv("STATE", d.state);
		kv("BASE", *d.base ? d.base : "unknown");
		if (*d.created) kv("CREATED", d.created);
		if (*sz) kv("SIZE", sz);
		py += 40;
		row(A_SELECT, i, "Start this one next", "It gets 2 tries; if it does not start, the last good one starts again.");
		if (offered("remove")) row(A_REMOVE, i, "Delete this deployment", NULL);
		row(A_BACK, 0, "Back", NULL);
		footer(1);
		int c = btn[choose()].act;
		if (c == A_BACK) return;
		deploy(c == A_SELECT ? "select" : "remove", d.id);
		return;
	}
}

/* 1 = an operation ran (back to the start) */
static int deps_page(void)
{
	int off = 0;
	for (;;) {
		if (status() != ST_OK) return 0;
		new_page("deployments");
		header("Deployments");
		if (!ndep && !dep_cut) para(F_BODY, "There is no GlassineOS deployment on this device.", 0);
		if (dep_cut) {
			char t[160];
			snprintf(t, sizeof t, "%d deployment%s with a name too long for this screen %s left out: use the console or the installer for %s.",
				 dep_cut, dep_cut == 1 ? "" : "s", dep_cut == 1 ? "is" : "are", dep_cut == 1 ? "it" : "them");
			para(F_SMALL, t, 0x30);
			py += 16;
		}
		/* room for the rows that always come: roll back, more, back */
		int reserve = 3 * 150, shown = 0;
		if (off >= ndep) off = 0;
		for (int i = off; i < ndep; i++) {
			struct dep *d = &deps[i];
			char sub[200];
			snprintf(sub, sizeof sub, "base %s%s%s", *d->base ? d->base : "unknown", *d->created ? " · " : "", d->created);
			if (py + 230 > SH - 150 - reserve) break;
			int y0 = py;
			/* the tags at the right of the title line */
			int tw = 0, n = 0;
			const char *t[3];
			int fl[3];
			if (!strcmp(d->state, "current")) { t[n] = "LAST GOOD"; fl[n++] = 1; }
			else if (!strcmp(d->state, "candidate")) { t[n] = "STARTS NEXT"; fl[n++] = 0; }
			else if (!strcmp(d->state, "failed")) { t[n] = "FAILED"; fl[n++] = 1; }
			else if (*d->state) {
				static char up[8][16];
				snprintf(up[n], sizeof up[n], "%s", d->state);
				for (char *p = up[n]; *p; p++) *p = (char)(*p >= 'a' && *p <= 'z' ? *p - 32 : *p);
				t[n] = up[n]; fl[n++] = 0;
			}
			if (strcmp(d->state, "failed") && *failedid && !strcmp(d->id, failedid)) { t[n] = "FAILED"; fl[n++] = 1; }
			for (int k = 0; k < n; k++) tw += measure(F_LABEL, t[k], strlen(t[k])) + 36 + 14;
			row_reserve = tw + 10;
			struct button *b = row(A_DEP, i, d->id, sub);
			if (!b) break;
			int x = M + (SW - 2 * M) - 30 - tw + 14;
			for (int k = 0; k < n; k++) x += tag(x, y0 + 30, t[k], fl[k]) + 14;
			shown++;
		}
		if (*prev) {
			char t[IDLEN + 20];
			snprintf(t, sizeof t, "Roll back to %s", prev);
			row(A_ROLLBACK, 0, t, "The previous deployment starts next.");
		}
		if (off + shown < ndep || off > 0) row(A_MORE, 0, off + shown < ndep ? "More deployments" : "First deployments", NULL);
		row(A_BACK, 0, "Back", NULL);
		footer(1);
		struct button *c = &btn[choose()];
		if (c->act == A_BACK) return 0;
		if (c->act == A_MORE) { off = off + shown < ndep ? off + shown : 0; continue; }
		if (c->act == A_ROLLBACK) { deploy("rollback", NULL); return 1; }
		if (c->act == A_DEP) { dep_page(c->arg); return 1; }
	}
}

static void reset_page(void)
{
	new_page("reset");
	header("Reset");
	para(F_BODY, "A reset makes a new deployment and starts it next. The current one stays on the device to go back to. What each one does is shown before anything happens.", 0);
	py += 40;
	row(A_RESET_SYS, 0, "Reset system", "Your home stays.");
	row(A_RESET_FULL, 0, "Full reset", "Your home stays.");
	row(A_BACK, 0, "Back", NULL);
	footer(1);
	int c = btn[choose()].act;
	if (c == A_RESET_SYS) deploy("reset", NULL);
	else if (c == A_RESET_FULL) deploy("reset-full", NULL);
}

static void diag_page(void)
{
	page_working("Collecting diagnostics", "The logs of the last starts, the kernel’s crash log, the deployment state and the device’s identity, into one file.");
	char *a;
	size_t n;
	uint8_t sha[32], sum[32];
	int st = rq(OP_DIAG, 0, NULL, 0, &a, &n, sha);
	if (st != ST_OK) {
		char note[64];
		snprintf(note, sizeof note, "(status %d)", st);
		page_result("diag-failed", "Diagnostics failed", a, note);
		free(a);
		return;
	}
	struct sha256 c;
	sha256_init(&c);
	sha256_update(&c, (uint8_t *)a, n);
	sha256_final(&c, sum);
	char list[2048] = "", line[160];
	if (memcmp(sum, sha, 32)) snprintf(list, sizeof list, "The file doesn’t match its checksum.");
	else {
		const char *tmp = "/tmp/glassine-rscreen-diag.tar.gz";
		int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
		if (fd >= 0 && write_full(fd, (uint8_t *)a, n) == 0 && close(fd) == 0) {
			FILE *p = popen("tar -tzf /tmp/glassine-rscreen-diag.tar.gz 2>/dev/null", "r");
			while (p && fgets(line, sizeof line, p))
				if (strlen(list) + strlen(line) + 1 < sizeof list) strcat(list, line);
			if (p) pclose(p);
		}
		unlink(tmp);
	}
	free(a);
	new_page("diag");
	header("Diagnostics are ready");
	para(F_BODY, "They are in the recovery’s memory only. A computer reads them over USB with the GlassineOS installer.", 0);
	py += 30;
	char hex[65];
	for (int i = 0; i < 32; i++) sprintf(hex + 2 * i, "%02x", sum[i]);
	snprintf(line, sizeof line, "%zu BYTES · SHA256 %.16s…", n, hex);
	label(M, py + F_LABEL->asc, line, 0);
	py += line_h(F_LABEL) + 24;
	if (*list) {
		para(F_SMALL, "They hold:", 0);
		int avail = SH - 150 - 150 - 40 - py;
		if (wrap(F_SMALL, M + 36, py, SW - 2 * M - 36, list, 0, 0) > avail) {
			/* the files at the top level and how many more */
			char top[1024] = "";
			int more = 0;
			for (char *p = list, *e; *p; p = e + 1) {
				e = strchr(p, '\n');
				if (!e) break;
				*e = 0;
				char *s = strchr(p, '/');
				if ((!s || !s[1]) && strlen(top) + strlen(p) + 2 < sizeof top) { strcat(top, p); strcat(top, "\n"); }
				else more++;
			}
			snprintf(line, sizeof line, "and %d more files", more);
			strcat(top, line);
			py += wrap(F_SMALL, M + 36, py, SW - 2 * M - 36, top, 0, 1);
		} else py += wrap(F_SMALL, M + 36, py, SW - 2 * M - 36, list, 0, 1);
	}
	foot_buttons(A_BACK, "Back to the start", A_NONE, NULL);
	footer(1);
	choose();
}

static void restart_page(void)
{
	new_page("restart");
	header("Restart");
	row(A_NORMAL, 0, "Normal start", "The device starts as it does without the recovery.");
	row(A_LOADER, 0, "Boot loader", "The device restarts into its boot loader.");
	row(A_BACK, 0, "Back", NULL);
	footer(1);
	int c = btn[choose()].act;
	if (c == A_BACK) return;
	new_page(c == A_NORMAL ? "confirm-restart" : "confirm-loader");
	header(c == A_NORMAL ? "Restart now into the normal start?" : "Restart to the boot loader?");
	para(F_BODY, "Nothing on the device changes.", 0);
	foot_buttons(A_CANCEL, "Cancel", A_CONFIRM, "Restart");
	footer(1);
	if (btn[choose()].act != A_CONFIRM) return;
	page_restarting(c == A_NORMAL ? "You asked for the normal start." : "You asked for the boot loader.");
	char *a;
	int st = rq(OP_REBOOT, c == A_NORMAL ? REBOOT_NORMAL : REBOOT_BOOTLOADER, NULL, 0, &a, NULL, NULL);
	if (st == ST_OK) sleep(30);
	char note[64];
	snprintf(note, sizeof note, "(status %d)", st);
	page_result("restart-failed", "The device didn’t restart", a, note);
	free(a);
}

static void home(void)
{
	if (status() != ST_OK) { core_down(); return; }
	new_page("home");
	header("This device");
	int y0 = py, h = 0;
	py += 32;
	if (!ndep && !*cur) {
		/* inside the card, as its key-value lines */
		py += wrap(F_BODY, M + 36, py, SW - 2 * M - 72, "There is no GlassineOS deployment here.", 0, 1);
		char why[600];
		sline(st_raw_full, "status-exit", why, sizeof why);
		if (*why && strcmp(why, "0")) {
			/* glassine-deploy's own words, the line after status-exit */
			const char *p = strstr(st_raw_full, "\nstatus-exit ");
			p = p ? strchr(p + 1, '\n') : NULL;
			if (p) { snprintf(why, sizeof why, "%.*s", (int)strcspn(p + 1, "\n"), p + 1); py += 8; py += wrap(F_SMALL, M + 36, py, SW - 2 * M - 72, why, 0x30, 1); }
		}
	} else {
		char t[IDLEN + 40];
		if (*cand) {
			snprintf(t, sizeof t, "%s, on trial (%s tries left)", cand, *tries ? tries : "?");
			kv("STARTS NEXT", t);
			kv("THEN", *cur ? cur : "nothing");
		} else kv("STARTS NEXT", *cur ? cur : "nothing");
		kv("LAST GOOD", *cur ? cur : "none");
		if (*failedid) kv("FAILED", failedid);
	}
	py += 24;
	h = py - y0;
	ring(M, y0, SW - 2 * M, h, 20, 4, 0);
	py += 40;
	row(A_DEPS, 0, "Deployments", "Start another one next, roll back, delete one.");
	row(A_RESET, 0, "Reset", "A clean system. Your home stays.");
	row(A_DIAG, 0, "Diagnostics", "Collect what went wrong, for a computer.");
	row(A_RESTART, 0, "Restart", "The normal start, or the boot loader.");
	char t[200];
	if (o_idle >= 120) snprintf(t, sizeof t, "Without use, the recovery restarts into the normal start after %ld minutes.", o_idle / 60);
	else snprintf(t, sizeof t, "Without use, the recovery restarts into the normal start after %ld seconds.", o_idle);
	py += 8;
	para(F_SMALL, t, 0x30);
	footer(1);
	int c = btn[choose()].act;
	if (c == A_DEPS) deps_page();
	else if (c == A_RESET) reset_page();
	else if (c == A_DIAG) diag_page();
	else if (c == A_RESTART) restart_page();
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!v) { fprintf(stderr, "usage: glassine-rscreen [--core S] [--epd S] [--conf F] [--idle S] [--state F] [--shot D] [--events F]\n"); return 2; }
		if (!strcmp(a, "--core")) o_core = v;
		else if (!strcmp(a, "--epd")) o_epd = v;
		else if (!strcmp(a, "--conf")) o_conf = v;
		else if (!strcmp(a, "--idle")) o_idle = atol(v) > 3 ? atol(v) : 3;
		else if (!strcmp(a, "--state")) o_state = v;
		else if (!strcmp(a, "--shot")) o_shot = v;
		else if (!strcmp(a, "--events")) o_events = v;
		else { fprintf(stderr, "glassine-rscreen: unknown option %s\n", a); return 2; }
		i++;
	}
	signal(SIGPIPE, SIG_IGN);
	read_conf();
	if (pw < 64 || ph < 64 || pw > 8192 || ph > 8192) { rs_say("panel %dx%d: not a panel", pw, ph); return 1; }
	SW = rot ? ph : pw;
	SH = rot ? pw : ph;
	cv = malloc((size_t)SW * SH);
	memfd = memfd_create("glassine-rscreen", MFD_CLOEXEC);
	if (!cv || memfd < 0 || ftruncate(memfd, (off_t)SW * SH * 4) < 0) { rs_say("no memory for the surface"); return 1; }
	surf = mmap(NULL, (size_t)SW * SH * 4, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, 0);
	if (surf == MAP_FAILED) { rs_say("cannot map the surface"); return 1; }
	if (o_events && !(script = fopen(o_events, "r"))) { rs_say("%s: %s", o_events, strerror(errno)); return 1; }
	if (!script) scan_input();
	last_req = now_ms();
	rs_say("surface %dx%d, panel %dx%d rotation %d, idle %ld s", SW, SH, pw, ph, rot, o_idle);
	for (;;) home();
}
