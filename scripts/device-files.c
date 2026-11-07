/* SPDX-License-Identifier: GPL-2.0-or-later */
/* device-files: fails when a tree holds files that only a device may supply
 * (GlassineOS/hub#8: "a build check enforces that none is in a stage or stream,
 * by contents and not only by name"). Those files are read from the device at
 * run time (the panel's waveform, signed firmware) and never ship in a base.
 *
 *   device-files ROOT     exit 0 = none found, 1 = found (each printed), 2 = error
 *
 * By contents:
 *   - an E Ink waveform (WBF): at least 256 bytes, the 32-bit little-endian length
 *     at offset 4 equal to the file size, a plausible mode count (byte 0x25 < 16)
 *     and temperature range count (byte 0x26 < 62). None of these offsets is
 *     checked here against a real waveform. The mode and temperature bytes and
 *     their bounds agree with what the panel engine reads (compared by hand with
 *     its source, not by a test); the engine doesn't read the length at offset 4,
 *     which rests only on one real waveform looked at by hand, not in this
 *     repository. The test writes its waveform with the same offsets, so it shows
 *     that the code agrees with itself, not with the format. A waveform whose length
 *     field isn't its size (trailing bytes) is caught only by its name (*.wbf), and
 *     a file of zeros but for its size at offset 4 is a false positive;
 *   - a signed Qualcomm image: an ELF with a hash segment, a program header whose
 *     flags carry the segment type 2 in bits 24-26, as signed modem, DSP, Wi-Fi and
 *     GPU zap images have (whole or split: the .mdt holds the headers).
 * By name, for the pieces of split images that carry no headers: *.mdt, *.mbn,
 * *.bNN next to an .mdt of the same stem, *.wbf: the suffixes in any case, the .mdt
 * beside a .bNN in lower or upper case (.B02 next to .MDT).
 * By place: any file under /lib/firmware or /usr/lib/firmware. A base carries no
 * firmware: the kernel's goes with the kernel (modules/<release>/firmware), the
 * device's comes from the device seed. That also covers unsigned blobs (GPU
 * microcode, camera firmware) that no content marks as a device's.
 * It stays on ROOT's file system (in a build step: not the kernel's /proc, /sys and
 * /dev, nor bind mounts), and skips anything under ROOT/proc, /sys and /dev too.
 * It doesn't follow symlinks. A symlink counts by place and by name, as a file
 * would (one under /lib/firmware, or named *.wbf, *.mdt, *.mbn or a *.bNN next to an
 * .mdt, is reported, whether or not its target is in the tree), but not by
 * contents: what it points to is checked where it lies, if that is in the tree.
 * What it can't read (a directory it can't list, an entry it can't stat, a file it
 * can't open or whose header it can't read whole) is an error, printed to stderr:
 * the exit status is then 2, whatever was found, never "none found". */
#define _XOPEN_SOURCE 700
#include <errno.h>
#include <ftw.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *root;
static size_t rootlen;
static int found, err;

static void report(const char *path, const char *why, int link)
{
    printf("%s: %s%s\n", path + rootlen, why, link ? " (a symlink)" : "");
    found = 1;
}

static void unread(const char *path, const char *why)
{
    fprintf(stderr, "device-files: %s: %s\n", path, why);
    err = 1;
}

static uint32_t le32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t le64(const unsigned char *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }
static uint16_t le16(const unsigned char *p) { return p[0] | p[1] << 8; }

static int is_wbf(const unsigned char *h, size_t n, off_t size)
{
    return size >= 256 && n >= 0x27 && le32(h + 4) == (uint64_t)size && h[0x25] < 16 && h[0x26] < 62;
}

/* an ELF (32 or 64-bit, little-endian) with a Qualcomm hash segment */
static int is_qcom_signed(FILE *f, const unsigned char *h, size_t n)
{
    if (n < 52 || memcmp(h, "\177ELF", 4) || h[5] != 1) return 0;
    int is64 = h[4] == 2;
    if (!is64 && h[4] != 1) return 0;
    uint64_t phoff = is64 ? le64(h + 32) : le32(h + 28);
    unsigned phentsize = le16(h + (is64 ? 54 : 42)), phnum = le16(h + (is64 ? 56 : 44));
    if (n < (is64 ? 64u : 52u) || phnum == 0 || phnum > 512 || phentsize < (is64 ? 56u : 32u)) return 0;
    unsigned char ph[64];
    for (unsigned i = 0; i < phnum; i++) {
        if (fseeko(f, (off_t)(phoff + (uint64_t)i * phentsize), SEEK_SET) ||
            fread(ph, 1, is64 ? 56 : 32, f) != (is64 ? 56u : 32u))
            return 0;
        uint32_t flags = is64 ? le32(ph + 4) : le32(ph + 24);
        if (((flags >> 24) & 7) == 2) return 1;
    }
    return 0;
}

static int has_suffix(const char *s, const char *suf)
{
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && !strcasecmp(s + a - b, suf);
}

/* NAME.bNN or NAME.BNN with NAME.mdt or NAME.MDT in the same directory */
static int is_split_segment(const char *path)
{
    size_t n = strlen(path);
    if (n < 5 || path[n - 4] != '.' || (path[n - 3] != 'b' && path[n - 3] != 'B') || path[n - 2] < '0' || path[n - 2] > '9' ||
        path[n - 1] < '0' || path[n - 1] > '9')
        return 0;
    char mdt[4096];
    if (n >= sizeof mdt) return 0;
    memcpy(mdt, path, n - 3);
    struct stat st;
    strcpy(mdt + n - 3, "mdt");
    if (!lstat(mdt, &st)) return 1;
    strcpy(mdt + n - 3, "MDT");
    return !lstat(mdt, &st);
}

static int visit(const char *path, const struct stat *st, int type, struct FTW *ftw)
{
    const char *rel = path + rootlen;
    if (!strncmp(rel, "/proc/", 6) || !strncmp(rel, "/sys/", 5) || !strncmp(rel, "/dev/", 5)) return 0;
    if (type == FTW_DNR) { unread(path, "can't read the directory"); return 0; }
    if (type == FTW_NS) { unread(path, "can't stat it"); return 0; }
    int link = type == FTW_SL;
    if (!link && (type != FTW_F || !S_ISREG(st->st_mode))) return 0;
    if (!strncmp(rel, "/lib/firmware/", 14) || !strncmp(rel, "/usr/lib/firmware/", 18)) {
        report(path, "firmware in the base (it goes with the kernel or comes from the device seed)", link);
        return 0;
    }
    const char *base = path + ftw->base;
    if (has_suffix(base, ".wbf")) { report(path, "a waveform file name (.wbf)", link); return 0; }
    if (has_suffix(base, ".mdt") || has_suffix(base, ".mbn")) { report(path, "a firmware image name (.mdt/.mbn)", link); return 0; }
    if (is_split_segment(path)) { report(path, "a segment of a split firmware image (next to its .mdt)", link); return 0; }
    if (link || st->st_size < 52) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) { unread(path, strerror(errno)); return 0; }
    unsigned char h[64];
    size_t n = fread(h, 1, sizeof h, f);
    if (n < (st->st_size < (off_t)sizeof h ? (size_t)st->st_size : sizeof h)) {
        unread(path, "can't read its header");
        fclose(f);
        return 0;
    }
    if (is_wbf(h, n, st->st_size)) report(path, "an E Ink waveform (WBF header)", 0);
    else if (is_qcom_signed(f, h, n)) report(path, "a signed Qualcomm image (ELF hash segment)", 0);
    fclose(f);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: device-files ROOT\n"); return 2; }
    /* without trailing slashes, so that path + rootlen starts with "/" and the
     * place rules (firmware, /proc, /sys, /dev) match whatever ROOT was given as */
    char *r = argv[1];
    size_t len = strlen(r);
    while (len > 1 && r[len - 1] == '/') r[--len] = 0;
    root = r;
    rootlen = strcmp(root, "/") ? len : 0;
    if (nftw(root, visit, 64, FTW_PHYS | FTW_MOUNT) < 0) { perror(root); return 2; }
    return err ? 2 : found;
}
