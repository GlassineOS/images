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
 *     and temperature range count (byte 0x26 < 62), as the engine reads it;
 *   - a signed Qualcomm image: an ELF with a hash segment, a program header whose
 *     flags carry the segment type 2 in bits 24-26, as signed modem, DSP, Wi-Fi and
 *     GPU zap images have (whole or split: the .mdt holds the headers).
 * By name, for the pieces of split images that carry no headers: *.mdt, *.mbn,
 * *.bNN next to an .mdt of the same stem, *.wbf.
 * By place: any file under /lib/firmware or /usr/lib/firmware. A base carries no
 * firmware: the kernel's goes with the kernel (modules/<release>/firmware), the
 * device's comes from the device seed. That also covers unsigned blobs (GPU
 * microcode, camera firmware) that no content marks as a device's.
 * It stays on ROOT's file system (in a build step: not the kernel's /proc, /sys and
 * /dev, nor bind mounts), skips anything under ROOT/proc, /sys and /dev too, and
 * doesn't follow symlinks. */
#define _XOPEN_SOURCE 700
#include <ftw.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *root;
static size_t rootlen;
static int found;

static void report(const char *path, const char *why)
{
    printf("%s: %s\n", path + rootlen, why);
    found = 1;
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
    return a >= b && !strcmp(s + a - b, suf);
}

/* NAME.bNN with NAME.mdt in the same directory */
static int is_split_segment(const char *path)
{
    size_t n = strlen(path);
    if (n < 5 || path[n - 4] != '.' || path[n - 3] != 'b' || path[n - 2] < '0' || path[n - 2] > '9' ||
        path[n - 1] < '0' || path[n - 1] > '9')
        return 0;
    char mdt[4096];
    if (n >= sizeof mdt) return 0;
    memcpy(mdt, path, n - 3);
    strcpy(mdt + n - 3, "mdt");
    struct stat st;
    return !lstat(mdt, &st);
}

static int visit(const char *path, const struct stat *st, int type, struct FTW *ftw)
{
    const char *rel = path + rootlen;
    if (!strncmp(rel, "/proc/", 6) || !strncmp(rel, "/sys/", 5) || !strncmp(rel, "/dev/", 5)) return 0;
    if (type != FTW_F || !S_ISREG(st->st_mode)) return 0;
    if (!strncmp(rel, "/lib/firmware/", 14) || !strncmp(rel, "/usr/lib/firmware/", 18)) {
        report(path, "firmware in the base (it goes with the kernel or comes from the device seed)");
        return 0;
    }
    const char *base = path + ftw->base;
    if (has_suffix(base, ".wbf")) { report(path, "a waveform file name (.wbf)"); return 0; }
    if (has_suffix(base, ".mdt") || has_suffix(base, ".mbn")) { report(path, "a firmware image name (.mdt/.mbn)"); return 0; }
    if (is_split_segment(path)) { report(path, "a segment of a split firmware image (next to its .mdt)"); return 0; }
    if (st->st_size < 52) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    unsigned char h[64];
    size_t n = fread(h, 1, sizeof h, f);
    if (is_wbf(h, n, st->st_size)) report(path, "an E Ink waveform (WBF header)");
    else if (is_qcom_signed(f, h, n)) report(path, "a signed Qualcomm image (ELF hash segment)");
    fclose(f);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: device-files ROOT\n"); return 2; }
    root = argv[1];
    rootlen = strcmp(root, "/") ? strlen(root) : 0;
    if (nftw(root, visit, 64, FTW_PHYS | FTW_MOUNT) < 0) { perror(root); return 2; }
    return found;
}
