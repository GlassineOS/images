/* SPDX-License-Identifier: GPL-2.0-or-later */
/* screen-drive: the person at the recovery's screen in its QEMU run
 * (test/qemu-recovery.sh): a touchscreen and a power key made with uinput, as the
 * kernel's drivers report them, and a script of what to do with them. It reads the
 * page and its buttons from the state file glassine-rscreen writes (--state) and the
 * panel's geometry from the adapter, so a tap lands where the button is drawn.
 *
 *   screen-drive SCRIPT STATE EPD.CONF
 *
 * Script lines (QTEST lines on stdout):
 *   wait PAGE [S]          until the page is PAGE and takes input (default 120 s)
 *   tap LABEL              a tap on the button whose label starts with LABEL
 *   remember LABEL         keep that button's place (for tapearly, holdearly)
 *   tapearly PAGE          taps the remembered place every 40 ms until PAGE takes input:
 *                          each one before it did
 *   holdearly PAGE MS      a finger down on the remembered place now, lifted MS after
 *                          PAGE took input
 *   keyearly PAGE MS       the power key down now, up MS after PAGE took input
 *   short | long           the power key, 0.1 s or 1.5 s
 *   focus LABEL            short presses until the focused button's label starts with LABEL
 *   page PAGE              the page is PAGE now (no wait)
 *   sh COMMAND...          COMMAND through sh -c; exit 0 = ok
 *   sleep MS
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static int tfd, kfd, fails, pw = 1872, ph = 1404, rot = 1, tid;
static const char *statep;
static char page[64];
static int ready, focus, nb;
static unsigned seq;
static struct { int x, y, w, h; char label[96]; } b[16];
static int rx = -1, ry;

static long now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

static void qt(int ok, const char *f, const char *a)
{
	printf(ok ? "QTEST ok   screen: " : "QTEST FAIL screen: ");
	printf(f, a);
	printf("\n");
	fflush(stdout);
	fails += !ok;
}

static void emit(int fd, int type, int code, int val)
{
	struct input_event e = { .type = (unsigned short)type, .code = (unsigned short)code, .value = val };
	if (write(fd, &e, sizeof e) != sizeof e) perror("screen-drive: write");
}

static int mkdev(const char *name, int touch)
{
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0) { perror("screen-drive: /dev/uinput"); exit(1); }
	if (touch) {
		ioctl(fd, UI_SET_EVBIT, EV_KEY);
		ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
		ioctl(fd, UI_SET_EVBIT, EV_ABS);
		ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
		int codes[] = { ABS_MT_SLOT, ABS_MT_TRACKING_ID, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_X, ABS_Y };
		int max[] = { 9, 65535, pw - 1, ph - 1, pw - 1, ph - 1 };
		for (int i = 0; i < 6; i++) {
			ioctl(fd, UI_SET_ABSBIT, codes[i]);
			struct uinput_abs_setup a = { .code = (unsigned short)codes[i], .absinfo = { .minimum = 0, .maximum = max[i] } };
			ioctl(fd, UI_ABS_SETUP, &a);
		}
	} else {
		ioctl(fd, UI_SET_EVBIT, EV_KEY);
		ioctl(fd, UI_SET_KEYBIT, KEY_POWER);
	}
	struct uinput_setup s = { .id = { .bustype = BUS_VIRTUAL, .vendor = 0x1d6b, .product = touch ? 1 : 2 } };
	snprintf(s.name, sizeof s.name, "%s", name);
	if (ioctl(fd, UI_DEV_SETUP, &s) || ioctl(fd, UI_DEV_CREATE)) { perror("screen-drive: uinput"); exit(1); }
	return fd;
}

static void read_state(void)
{
	FILE *f = fopen(statep, "r");
	char l[256];
	nb = 0;
	*page = 0;
	ready = 0;
	if (!f) return;
	while (fgets(l, sizeof l, f)) {
		l[strcspn(l, "\n")] = 0;
		int i, x, y, w, h, n;
		if (!strncmp(l, "page ", 5)) snprintf(page, sizeof page, "%.63s", l + 5);
		else if (!strncmp(l, "ready ", 6)) ready = atoi(l + 6);
		else if (!strncmp(l, "focus ", 6)) focus = atoi(l + 6);
		else if (!strncmp(l, "seq ", 4)) seq = (unsigned)atol(l + 4);
		else if (sscanf(l, "button %d %d %d %d %d %n", &i, &x, &y, &w, &h, &n) == 5 && nb < 16) {
			b[nb].x = x; b[nb].y = y; b[nb].w = w; b[nb].h = h;
			snprintf(b[nb].label, sizeof b[nb].label, "%.95s", l + n);
			nb++;
		}
	}
	fclose(f);
}

/* the surface's (u, v) on the panel, as glassine-epdd's to_panel */
static void to_panel(int u, int v, int *x, int *y)
{
	*x = rot == 1 ? pw - 1 - v : rot == 2 ? v : u;
	*y = rot == 1 ? u : rot == 2 ? ph - 1 - u : v;
}

static void down(int u, int v)
{
	int x, y;
	to_panel(u, v, &x, &y);
	emit(tfd, EV_ABS, ABS_MT_SLOT, 0);
	emit(tfd, EV_ABS, ABS_MT_TRACKING_ID, ++tid);
	emit(tfd, EV_ABS, ABS_MT_POSITION_X, x);
	emit(tfd, EV_ABS, ABS_MT_POSITION_Y, y);
	emit(tfd, EV_KEY, BTN_TOUCH, 1);
	emit(tfd, EV_ABS, ABS_X, x);
	emit(tfd, EV_ABS, ABS_Y, y);
	emit(tfd, EV_SYN, SYN_REPORT, 0);
}

static void up(void)
{
	emit(tfd, EV_ABS, ABS_MT_SLOT, 0);
	emit(tfd, EV_ABS, ABS_MT_TRACKING_ID, -1);
	emit(tfd, EV_KEY, BTN_TOUCH, 0);
	emit(tfd, EV_SYN, SYN_REPORT, 0);
}

static void key(int ms)
{
	emit(kfd, EV_KEY, KEY_POWER, 1);
	emit(kfd, EV_SYN, SYN_REPORT, 0);
	usleep((useconds_t)ms * 1000);
	emit(kfd, EV_KEY, KEY_POWER, 0);
	emit(kfd, EV_SYN, SYN_REPORT, 0);
}

static int find(const char *label)
{
	read_state();
	for (int i = 0; i < nb; i++)
		if (!strncmp(b[i].label, label, strlen(label))) return i;
	return -1;
}

/* until PAGE takes input; 1 = it did */
static int until_ready(const char *pg, long limit_ms)
{
	long end = now_ms() + limit_ms;
	for (;;) {
		read_state();
		if (!strcmp(page, pg) && ready) return 1;
		if (now_ms() > end) return 0;
		usleep(20000);
	}
}

int main(int argc, char **argv)
{
	if (argc != 4) { fprintf(stderr, "usage: screen-drive SCRIPT STATE EPD.CONF\n"); return 2; }
	statep = argv[2];
	FILE *c = fopen(argv[3], "r");
	char l[512];
	while (c && fgets(l, sizeof l, c)) {
		if (!strncmp(l, "panel_width=", 12)) pw = atoi(l + 12);
		else if (!strncmp(l, "panel_height=", 13)) ph = atoi(l + 13);
		else if (!strncmp(l, "rotation=", 9)) rot = !strncmp(l + 9, "cw", 2) ? 2 : !strncmp(l + 9, "none", 4) ? 0 : 1;
	}
	if (c) fclose(c);
	tfd = mkdev("cyttsp5_mt (uinput)", 1);
	kfd = mkdev("pm8941_pwrkey (uinput)", 0);
	printf("QTEST info screen-drive: a touchscreen and a power key\n");
	fflush(stdout);
	FILE *s = fopen(argv[1], "r");
	if (!s) { perror(argv[1]); return 1; }
	while (fgets(l, sizeof l, s)) {
		l[strcspn(l, "\n")] = 0;
		if (!*l || *l == '#') continue;
		printf("QTEST info screen-drive: %s\n", l);
		fflush(stdout);
		char a[256] = "";
		int n = 0;
		if (sscanf(l, "wait %63s %d", a, &n) >= 1 && !strncmp(l, "wait ", 5)) {
			long end = now_ms() + (n ? n : 120) * 1000L;
			do { read_state(); if (!strcmp(page, a) && ready) break; usleep(100000); } while (now_ms() < end);
			qt(!strcmp(page, a) && ready, "the page %s", a);
			if (strcmp(page, a)) { printf("QTEST info screen-drive: the page is %s\n", page); break; }
			usleep(400000);		/* past the page's settling time */
		} else if (!strncmp(l, "tap ", 4) || !strncmp(l, "remember ", 9)) {
			const char *lb = strchr(l, ' ') + 1;
			int i = find(lb);
			if (i < 0) { qt(0, "no button %s", lb); break; }
			int u = b[i].x + b[i].w / 2, v = b[i].y + b[i].h / 2;
			if (*l == 'r') { rx = u; ry = v; continue; }
			down(u, v);
			usleep(80000);
			up();
		} else if (sscanf(l, "tapearly %63s", a) == 1) {
			int k = 0, got = 0;
			for (; k < 3000; k++) {
				down(rx, ry); usleep(15000); up(); usleep(25000);
				read_state();
				if ((got = !strcmp(page, a) && ready)) break;
			}
			qt(got && k > 0, "the page %s came while it was being tapped", a);
			printf("QTEST info screen-drive: %d taps before %s took input\n", k + 1, a);
		} else if (sscanf(l, "holdearly %63s %d", a, &n) == 2) {
			down(rx, ry);
			qt(until_ready(a, 300000), "the page %s came while a finger was down", a);
			usleep((useconds_t)n * 1000);
			up();
		} else if (sscanf(l, "keyearly %63s %d", a, &n) == 2) {
			emit(kfd, EV_KEY, KEY_POWER, 1);
			emit(kfd, EV_SYN, SYN_REPORT, 0);
			qt(until_ready(a, 300000), "the page %s came while the power key was down", a);
			usleep((useconds_t)n * 1000);
			emit(kfd, EV_KEY, KEY_POWER, 0);
			emit(kfd, EV_SYN, SYN_REPORT, 0);
		} else if (!strcmp(l, "short")) {
			key(100);
			usleep(500000);
		} else if (!strcmp(l, "long")) {
			key(1500);
		} else if (!strncmp(l, "focus ", 6)) {
			int i, k = 0;
			while ((i = find(l + 6)) >= 0 && focus != i && k++ < 16) { key(100); usleep(700000); }
			qt(i >= 0 && focus == i, "the power key moved to %s", l + 6);
		} else if (sscanf(l, "page %63s", a) == 1) {
			read_state();
			qt(!strcmp(page, a), "still on the page %s", a);
		} else if (!strncmp(l, "sh ", 3)) {
			int r = system(l + 3);
			qt(r == 0, "%s", l + 3);
		} else if (sscanf(l, "sleep %d", &n) == 1) {
			usleep((useconds_t)n * 1000);
		} else qt(0, "an unknown line: %s", l);
	}
	printf("QTEST info screen-drive: the script ended (%d failed)\n", fails);
	fflush(stdout);
	pause();
	return 0;
}
