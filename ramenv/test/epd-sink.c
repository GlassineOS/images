/* SPDX-License-Identifier: GPL-2.0-or-later */
/* epd-sink: a stand-in for glassine-epdd in the recovery's QEMU screen run
 * (test/qemu-recovery.sh), which has no panel. It takes glassine-epdd's command line,
 * checks that the waveform the adapter names is in place (the screen's start script
 * read it from the device data seed) and serves the frame protocol
 * (glassine-epd-proto.h) as the daemon does: HELLO, BUF (the memfd mapped), FRAME
 * answered with DONE. It counts the frames and keeps the last one at /run/epd-last.pgm
 * (grey, as the daemon ingests it).
 *
 *   glassine-epdd -c CONFIG -s SOCKET       (installed under that name in the test)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <glassine/glassine-epd-proto.h>

static FILE *con;

int main(int argc, char **argv)
{
	const char *conf = "/etc/glassine/epd.conf", *sock = "/dev/socket/glassine-epd";
	for (int o; (o = getopt(argc, argv, "c:s:")) != -1;) {
		if (o == 'c') conf = optarg;
		else if (o == 's') sock = optarg;
		else return 2;
	}
	con = fopen("/dev/console", "w");
	if (!con) con = stderr;
	setvbuf(con, NULL, _IOLBF, 0);
	char w[512] = "", l[512];
	FILE *f = fopen(conf, "r");
	while (f && fgets(l, sizeof l, f))
		if (!strncmp(l, "waveform=", 9)) { snprintf(w, sizeof w, "%s", l + 9); w[strcspn(w, "\r\n#")] = 0; }
	if (f) fclose(f);
	struct stat st;
	uint32_t len = 0;
	int wf = open(w, O_RDONLY);
	if (wf < 0 || fstat(wf, &st) || pread(wf, &len, 4, 4) != 4 || len != st.st_size || st.st_size < 256) {
		fprintf(con, "QTEST FAIL screen: the waveform %s isn't in place\n", w);
		return 1;
	}
	close(wf);
	fprintf(con, "QTEST ok   screen: the panel daemon found the waveform %s (%ld bytes)\n", w, (long)st.st_size);
	int s = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	struct sockaddr_un a = { .sun_family = AF_UNIX };
	snprintf(a.sun_path, sizeof a.sun_path, "%s", sock);
	unlink(sock);
	if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 1)) { perror("epd-sink"); return 1; }
	unsigned frames = 0;
	for (;;) {
		int c = accept4(s, NULL, NULL, SOCK_CLOEXEC);
		if (c < 0) { if (errno == EINTR) continue; return 1; }
		fprintf(con, "QTEST info epd-sink: a client\n");
		uint8_t *map = NULL;
		struct glassine_epd_msg b = { 0 };
		size_t mlen = 0;
		for (;;) {
			struct glassine_epd_msg m;
			char cb[CMSG_SPACE(sizeof(int))];
			struct iovec iov = { &m, sizeof m };
			struct msghdr h = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cb, .msg_controllen = sizeof cb };
			memset(&m, 0, sizeof m);
			ssize_t n = recvmsg(c, &h, MSG_CMSG_CLOEXEC);
			if (n <= 0) break;
			int fd = -1;
			for (struct cmsghdr *cm = CMSG_FIRSTHDR(&h); cm; cm = CMSG_NXTHDR(&h, cm))
				if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) memcpy(&fd, CMSG_DATA(cm), sizeof fd);
			if (m.type == GLASSINE_EPD_HELLO) {
				struct glassine_epd_msg r = { .type = GLASSINE_EPD_HELLO, .id = GLASSINE_EPD_PROTO_VERSION };
				send(c, &r, sizeof r, MSG_NOSIGNAL);
			} else if (m.type == GLASSINE_EPD_BUF && fd >= 0) {
				if (map) munmap(map, mlen);
				b = m;
				mlen = (size_t)m.offset + (size_t)m.stride * m.height;
				map = mmap(NULL, mlen, PROT_READ, MAP_SHARED, fd, 0);
				if (map == MAP_FAILED) map = NULL;
				fprintf(con, "QTEST info epd-sink: BUF %ux%u\n", m.width, m.height);
			} else if (m.type == GLASSINE_EPD_FRAME) {
				frames++;
				if (map) {
					FILE *o = fopen("/run/epd-last.pgm.tmp", "wb");
					if (o) {
						fprintf(o, "P5\n%u %u\n255\n", b.width, b.height);
						for (uint32_t y = 0; y < b.height; y++)
							for (uint32_t x = 0; x < b.width; x++) fputc(map[b.offset + y * b.stride + x * 4], o);
						fclose(o);
						rename("/run/epd-last.pgm.tmp", "/run/epd-last.pgm");
					}
				}
				FILE *o = fopen("/run/epd-sink.frames", "w");
				if (o) { fprintf(o, "%u\n", frames); fclose(o); }
				struct glassine_epd_msg d = { .type = GLASSINE_EPD_DONE, .id = m.id, .seq = m.seq };
				send(c, &d, sizeof d, MSG_NOSIGNAL);
			}
			if (fd >= 0) close(fd);
		}
		if (map) munmap(map, mlen);
		close(c);
	}
}
