/*
 * MD - a Markdown editor for the Commander X16  (cc65, target cx16)
 *
 *  - modeless editor with Markdown syntax colouring and soft line wrap
 *  - Ctrl-P / F5 toggles a rendered preview: headings, bold, italic, code,
 *    links, lists, block quotes, rules, fenced code and boxed tables
 *  - Ctrl-G / F4 opens a table-of-contents jump menu; a line containing
 *    [TOC] expands to a contents list in the preview
 *  - bold / italic faces are synthesised from the ISO charset at start-up
 *    and stored in the unused upper half of VERA's character set
 *
 * Draws straight into VERA text memory (ISO mode, so files are plain ASCII).
 */
#include "asciimap.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <cbm.h>
#include <cx16.h>
#include <conio.h>

/* ------------------------------------------------------------------ */
/* configuration                                                       */
/* ------------------------------------------------------------------ */
#ifndef BUFSZ
#define BUFSZ    8000u
#endif
#define MAXL     500u
#define FNLEN    40
#define DEVICE   8
#define SW       80            /* widest text screen */
#define MAXH     100           /* headings tracked for the TOC */
#define MAXC     8             /* table columns */
#define CLSN     240           /* chars coloured per editor line */
#define PV_PER_BANK 51         /* preview rows (2*80 bytes) per 8K bank */
#define PV_BANKS 10
#define PVMAXL   (PV_PER_BANK * PV_BANKS)
#define UNDO_BANK 20

#define RAMBANK  (*(volatile uint8_t *)0x0000)

/* keys (ISO mode) */
#define K_DOWN  0x11
#define K_UP    0x91
#define K_LEFT  0x9D
#define K_RIGHT 0x1D
#define K_HOME  0x13
#define K_END   0x04
#define K_BKSP  0x14
#define K_DEL   0x19
#define K_ESC   0x1B
#define K_F1    0x85
#define K_F2    0x89
#define K_F3    0x86
#define K_F4    0x8A
#define K_F5    0x87
#define K_F6    0x8B
#define K_F7    0x88
#define K_F8    0x8C
#define CTRL(c) ((c) - 'A' + 1)

/* colours (VERA palette indexes) */
#define C_BG     0
#define C_NORM   15
#define C_BOLD   1
#define C_ITAL   14
#define C_CODE   ((11 << 4) | 13)       /* inline code   */
#define C_CODEBLK ((11 << 4) | 1)       /* fenced code   */
#define C_LINK   3
#define C_IMG    10
#define C_STRIKE 12
#define C_MARK   12                     /* markdown punctuation in editor */
#define C_BUL    8
#define C_QBAR   5
#define C_TBL    12
#define C_URL    11
#define C_TOC    7
#define C_LAB    13

/* special glyphs living in otherwise unused charset slots */
#define G_H   27
#define G_V   28
#define G_TL  29
#define G_TR  30
#define G_BL  31
#define G_BR  127
#define G_T   154
#define G_B   155
#define G_L   156
#define G_R   157
#define G_X   158
#define G_BUL 159

/* inline style flags (preview) */
static const uint8_t hcol[7] = { C_NORM, 7, 3, 13, 14, 10, 12 };

/* line kinds */
#define K_BLANK  0
#define K_FENCE  1
#define K_ATX    2
#define K_SETEXT 3
#define K_HR     4
#define K_LIST   5
#define K_TABLE  6
#define K_TOCM   7
#define K_PARA   8

/* ------------------------------------------------------------------ */
/* state                                                               */
/* ------------------------------------------------------------------ */
static char     buf[BUFSZ + 2];
static uint16_t lstart[MAXL + 2];
static uint16_t len, nlines;
static uint16_t cy, cx, want, top;

static uint8_t  scrw, scrh, textrows, pw;
static uint16_t vbase, vstride;

static uint8_t  modified, truncated, quit, warned, typing;
static uint8_t  redraw_all;
static uint16_t prev_cy;
static char     fname[FNLEN + 1];
static char     msg[80];
static char     lastsearch[32];

typedef struct { uint16_t len, cx, cy; } snapmeta;
static snapmeta smeta[2];
static uint8_t  usel, uvalid;

static uint8_t  cls[CLSN];
static uint8_t  iobuf[168];
static char     iobuf2[FNLEN + 12];

/* headings */
static uint16_t hl[MAXH];       /* source line */
static uint8_t  hlv[MAXH];      /* level 1..6  */
static uint16_t hvis[MAXH];     /* preview row */
static uint8_t  hn;
static uint8_t  kind_lvl;       /* set by line_kind(): heading level */

/* "effective line": a source line with block-quote markers removed */
static const char *es;
static uint16_t en;
static uint8_t  eq;

/* list parse results */
static uint16_t L_ind, L_mk, L_mlen, L_txt;
static uint8_t  L_ord;

#ifdef SELFTEST
static void gl_read2(uint8_t c, uint8_t *g);
static const char *selfkeys;
static void selftest_dump(void);
static char *dosname(char *d, const char *src);
#endif

/* ------------------------------------------------------------------ */
/* keyboard / VERA                                                     */
/* ------------------------------------------------------------------ */
static uint8_t getkey(void)
{
    uint8_t k;
#ifdef SELFTEST
    if (*selfkeys) return (uint8_t)*selfkeys++;
    selftest_dump();
    *(volatile uint8_t *)0x9FB5 = 1;
    for (;;) ;
#endif
    do {
        k = cbm_k_getin();
    } while (k == 0);
    return k;
}

static void vera_at(uint16_t x, uint16_t y)
{
    VERA.control &= 0xFE;
    VERA.address = vbase + (uint16_t)y * vstride + (uint16_t)x * 2;
    VERA.address_hi = 0x10 | 1;
}

static void put_cell(uint8_t x, uint8_t y, uint8_t ch, uint8_t col)
{
    vera_at(x, y);
    VERA.data0 = ch;
    VERA.data0 = col;
}

#ifdef SELFTEST
static void selftest_dump(void)
{
    uint8_t y, x;
    cbm_open(3, DEVICE, 3, dosname((char *)iobuf, "@:scr.out,s,w"));
    for (y = 0; y < scrh; ++y) {
        vera_at(0, y);
        for (x = 0; x < scrw; ++x) {
            iobuf[x] = VERA.data0;
            iobuf[x + 80] = "0123456789abcdef"[VERA.data0 & 15];
        }
        cbm_write(3, iobuf, 80);
        cbm_write(3, "\n", 1);
        cbm_write(3, iobuf + 80, 80);
        cbm_write(3, "\n", 1);
    }
    cbm_close(3);
    cbm_open(3, DEVICE, 3, dosname((char *)iobuf, "@:chr.out,s,w"));
    for (y = 0; y < 255; ++y) {
        gl_read2(y, iobuf);
        cbm_write(3, iobuf, 8);
    }
    cbm_close(3);
}
#endif

static void iso_mode(void)
{
    asm("lda #$0f");
    asm("jsr $ffd2");
}

static void init_screen(void)
{
    uint8_t m;
    screensize(&scrw, &scrh);
    textrows = scrh - 2;
    pw = scrw > SW ? SW : scrw;
    VERA.control &= 0xFE;
    m = VERA.layer1.config;
    switch ((m >> 4) & 3) {
        case 0: vstride = 64;  break;
        case 1: vstride = 128; break;
        case 2: vstride = 256; break;
        default: vstride = 512; break;
    }
    vbase = ((uint16_t)(VERA.layer1.mapbase & 0x7F)) << 9;
}

static void clear_screen(void)
{
    uint8_t y, x;
    for (y = 0; y < scrh; ++y) {
        vera_at(0, y);
        for (x = 0; x < scrw; ++x) { VERA.data0 = ' '; VERA.data0 = (C_BG << 4) | C_NORM; }
    }
}

/* ------------------------------------------------------------------ */
/* fonts: bold, italic and box-drawing glyphs built from the ISO set   */
/* ------------------------------------------------------------------ */
static uint16_t tilebase;

static void gl_addr(uint8_t c)
{
    VERA.control &= 0xFE;
    VERA.address = tilebase + (uint16_t)c * 8;
    VERA.address_hi = 0x10 | 1;
}

static void gl_read(uint8_t c, uint8_t *g)
{
    uint8_t i;
    gl_addr(c);
    for (i = 0; i < 8; ++i) g[i] = VERA.data0;
}

#ifdef SELFTEST
static void gl_read2(uint8_t c, uint8_t *g) { gl_read(c, g); }
#endif

static void gl_write(uint8_t c, const uint8_t *g)
{
    uint8_t i;
    gl_addr(c);
    for (i = 0; i < 8; ++i) VERA.data0 = g[i];
}

static void box_glyph(uint8_t idx, uint8_t u, uint8_t d, uint8_t l, uint8_t r)
{
    uint8_t g[8], i;
    for (i = 0; i < 8; ++i) g[i] = 0;
    if (u) for (i = 0; i < 4; ++i) g[i] |= 0x10;
    if (d) for (i = 3; i < 8; ++i) g[i] |= 0x10;
    if (l) g[3] |= 0xF0;
    if (r) g[3] |= 0x1F;
    gl_write(idx, g);
}

static uint8_t bold_glyph(uint8_t c)
{
    return (c > 32 && c < 127) ? c + 128 : c;
}

static uint8_t ital_glyph(uint8_t c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A' + 1;
    if (c >= 'a' && c <= 'z') return c - 'a' + 128;
    return c;
}

static void build_fonts(void)
{
    static const uint8_t bul[8] = { 0, 0, 0x18, 0x3C, 0x3C, 0x18, 0, 0 };
    uint8_t g[8], h[8], c, i;

    tilebase = ((uint16_t)(VERA.layer1.tilebase & 0xFC)) << 9;
    for (c = 33; c < 127; ++c) {
        gl_read(c, g);
        for (i = 0; i < 8; ++i) h[i] = g[i] | (g[i] >> 1);
        gl_write(bold_glyph(c), h);
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
            for (i = 0; i < 8; ++i) h[i] = (i < 4) ? (g[i] >> 1) : g[i];
            gl_write(ital_glyph(c), h);
        }
    }
    box_glyph(G_H, 0, 0, 1, 1);
    box_glyph(G_V, 1, 1, 0, 0);
    box_glyph(G_TL, 0, 1, 0, 1);
    box_glyph(G_TR, 0, 1, 1, 0);
    box_glyph(G_BL, 1, 0, 0, 1);
    box_glyph(G_BR, 1, 0, 1, 0);
    box_glyph(G_T, 0, 1, 1, 1);
    box_glyph(G_B, 1, 0, 1, 1);
    box_glyph(G_L, 1, 1, 0, 1);
    box_glyph(G_R, 1, 1, 1, 0);
    box_glyph(G_X, 1, 1, 1, 1);
    gl_write(G_BUL, bul);
}

/* ------------------------------------------------------------------ */
/* buffer / lines                                                      */
/* ------------------------------------------------------------------ */
static uint16_t linelen(uint16_t l)
{
    return lstart[l + 1] - lstart[l] - 1;
}

static uint16_t find_line(uint16_t pos)
{
    uint16_t lo = 0, hi = nlines, mid;
    while (hi - lo > 1) {
        mid = (lo + hi) >> 1;
        if (lstart[mid] <= pos) lo = mid; else hi = mid;
    }
    return lo;
}

static void rebuild_lines(void)
{
    uint16_t i;
    nlines = 0;
    lstart[0] = 0;
    for (i = 0; i < len; ++i)
        if (buf[i] == '\n') {
            if (nlines >= MAXL) break;
            lstart[++nlines] = i + 1;
        }
}

static void new_buffer(void)
{
    buf[0] = '\n';
    len = 1;
    rebuild_lines();
    cy = cx = want = top = 0;
    modified = 0;
    uvalid = 0;
}

static void setmsg(const char *s)
{
    strncpy(msg, s, sizeof msg - 1);
    msg[sizeof msg - 1] = 0;
}

static uint8_t buf_insert(uint16_t pos, const char *src, uint16_t n)
{
    uint16_t L, k = 0, i, j;
    if (len + n > BUFSZ) { setmsg("Buffer full!"); return 0; }
    for (i = 0; i < n; ++i) if (src[i] == '\n') ++k;
    if (nlines + k > MAXL) { setmsg("Too many lines!"); return 0; }
    L = find_line(pos);
    memmove(buf + pos + n, buf + pos, len - pos);
    memcpy(buf + pos, src, n);
    len += n;
    if (k) {
        memmove(&lstart[L + 1 + k], &lstart[L + 1], (nlines - L) * 2);
        j = L + 1;
        for (i = 0; i < n; ++i)
            if (src[i] == '\n') lstart[j++] = pos + i + 1;
        for (i = L + 1 + k; i <= nlines + k; ++i) lstart[i] += n;
        nlines += k;
    } else {
        for (i = L + 1; i <= nlines; ++i) lstart[i] += n;
    }
    modified = 1;
    redraw_all = 1;
    return 1;
}

static void buf_delete(uint16_t pos, uint16_t n)
{
    uint16_t L, k = 0, i;
    if (pos + n >= len) {                 /* never remove the final newline */
        if (pos >= len - 1) return;
        n = len - 1 - pos;
    }
    if (!n) return;
    L = find_line(pos);
    for (i = pos; i < pos + n; ++i) if (buf[i] == '\n') ++k;
    memmove(buf + pos, buf + pos + n, len - pos - n);
    len -= n;
    if (k) {
        memmove(&lstart[L + 1], &lstart[L + 1 + k], (nlines - L - k + 1) * 2);
        nlines -= k;
    }
    for (i = L + 1; i <= nlines; ++i) lstart[i] -= n;
    modified = 1;
    redraw_all = 1;
}

static uint16_t cur_pos(void) { return lstart[cy] + cx; }

/* ------------------------------------------------------------------ */
/* undo: one level, kept in banked RAM (swap style)                    */
/* ------------------------------------------------------------------ */
static void bank_save(uint8_t set)
{
    uint16_t off = 0, n;
    uint8_t b = UNDO_BANK + set * 2;
    while (off < len) {
        n = len - off; if (n > 0x2000) n = 0x2000;
        RAMBANK = b++;
        memcpy((void *)0xA000, buf + off, n);
        off += n;
    }
    RAMBANK = 0;
}

static void bank_load(uint8_t set, uint16_t total)
{
    uint16_t off = 0, n;
    uint8_t b = UNDO_BANK + set * 2;
    while (off < total) {
        n = total - off; if (n > 0x2000) n = 0x2000;
        RAMBANK = b++;
        memcpy(buf + off, (void *)0xA000, n);
        off += n;
    }
    RAMBANK = 0;
}

static void snap(void)
{
    bank_save(usel);
    smeta[usel].len = len; smeta[usel].cx = cx; smeta[usel].cy = cy;
    uvalid = 1;
}

static void do_undo(void)
{
    uint8_t other = usel ^ 1;
    snapmeta m;
    if (!uvalid) { setmsg("Nothing to undo"); return; }
    bank_save(other);
    smeta[other].len = len; smeta[other].cx = cx; smeta[other].cy = cy;
    m = smeta[usel];
    bank_load(usel, m.len);
    len = m.len;
    rebuild_lines();
    cy = m.cy; cx = m.cx;
    if (cy >= nlines) cy = nlines - 1;
    if (cx > linelen(cy)) cx = linelen(cy);
    usel = other;
    modified = 1;
    redraw_all = 1;
    setmsg("Undo (Ctrl-Z again = redo)");
}

/* ------------------------------------------------------------------ */
/* character helpers                                                   */
/* ------------------------------------------------------------------ */
static uint8_t is_digit(uint8_t c) { return c >= '0' && c <= '9'; }
static uint8_t is_alnum(uint8_t c)
{
    return is_digit(c) || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}
static uint8_t is_punct(uint8_t c) { return c > 32 && c < 127 && !is_alnum(c); }
static uint8_t is_sp(uint8_t c) { return c == ' ' || c == '\t'; }

/* ------------------------------------------------------------------ */
/* markdown line classification                                        */
/* ------------------------------------------------------------------ */
static uint8_t blank_s(const char *s, uint16_t n)
{
    while (n--) if (!is_sp(*s++)) return 0;
    return 1;
}

/* strip leading '>' block-quote markers of line l */
static void eff(uint16_t l, const char **ps, uint16_t *pn, uint8_t *pq)
{
    const char *s = buf + lstart[l];
    uint16_t n = linelen(l);
    uint8_t q = 0, sp;
    for (;;) {
        sp = 0;
        while (n && *s == ' ' && sp < 3) { ++s; --n; ++sp; }
        if (n && *s == '>' && q < 4) {
            ++q; ++s; --n;
            if (n && *s == ' ') { ++s; --n; }
        } else {
            s -= sp; n += sp;
            break;
        }
    }
    *ps = s; *pn = n; *pq = q;
}

static uint8_t fence_s(const char *s, uint16_t n)
{
    uint8_t sp = 0;
    char c;
    while (n && *s == ' ' && sp < 3) { ++s; --n; ++sp; }
    if (n < 3) return 0;
    c = s[0];
    return (c == '`' || c == '~') && s[1] == c && s[2] == c;
}

static uint8_t atx_s(const char *s, uint16_t n, uint8_t *lvl, uint16_t *off)
{
    uint16_t i = 0;
    uint8_t k = 0;
    while (i < n && s[i] == ' ' && i < 3) ++i;
    while (i < n && s[i] == '#' && k < 7) { ++i; ++k; }
    if (k < 1 || k > 6) return 0;
    if (i < n && s[i] != ' ') return 0;
    while (i < n && s[i] == ' ') ++i;
    *lvl = k; *off = i;
    return 1;
}

static uint8_t hr_s(const char *s, uint16_t n)
{
    uint16_t i = 0, cnt = 0;
    char c;
    while (i < n && s[i] == ' ' && i < 3) ++i;
    if (i >= n) return 0;
    c = s[i];
    if (c != '-' && c != '*' && c != '_') return 0;
    for (; i < n; ++i) {
        if (s[i] == c) ++cnt;
        else if (s[i] != ' ') return 0;
    }
    return cnt >= 3;
}

static uint8_t list_s(const char *s, uint16_t n)
{
    uint16_t i = 0, ind = 0, st;
    while (i < n && is_sp(s[i])) { ind += (s[i] == '\t') ? 4 : 1; ++i; }
    if (i >= n) return 0;
    L_ind = ind; L_mk = i;
    if ((s[i] == '-' || s[i] == '*' || s[i] == '+') && (i + 1 >= n || s[i + 1] == ' ')) {
        L_ord = 0; L_mlen = 1; ++i;
    } else if (is_digit(s[i])) {
        st = i;
        while (i < n && is_digit(s[i]) && i - st < 9) ++i;
        if (i >= n || (s[i] != '.' && s[i] != ')') || (i + 1 < n && s[i + 1] != ' ')) return 0;
        ++i;
        L_ord = 1; L_mlen = i - st;
    } else return 0;
    while (i < n && s[i] == ' ') ++i;
    L_txt = i;
    return 1;
}

static uint8_t sep_s(const char *s, uint16_t n)
{
    uint16_t i;
    uint8_t dash = 0, pipe = 0;
    for (i = 0; i < n; ++i) {
        switch (s[i]) {
            case '-': dash = 1; break;
            case '|': pipe = 1; break;
            case ':': case ' ': case '\t': break;
            default: return 0;
        }
    }
    return dash && pipe;
}

static uint8_t setext_s(const char *s, uint16_t n)
{
    uint16_t i = 0, cnt = 0;
    char c;
    while (i < n && s[i] == ' ' && i < 3) ++i;
    if (i >= n) return 0;
    c = s[i];
    if (c != '=' && c != '-') return 0;
    for (; i < n; ++i) {
        if (s[i] == c) ++cnt;
        else if (s[i] != ' ') return 0;
    }
    if (c == '-' && cnt < 2) return 0;
    kind_lvl = (c == '=') ? 1 : 2;
    return 1;
}

static uint8_t toc_s(const char *s, uint16_t n)
{
    while (n && is_sp(s[n - 1])) --n;
    while (n && *s == ' ') { ++s; --n; }
    return n == 5 && s[0] == '[' && s[4] == ']' && (s[1] | 32) == 't' &&
           (s[2] | 32) == 'o' && (s[3] | 32) == 'c';
}

static uint8_t line_kind(uint16_t l)
{
    const char *s, *s2;
    uint16_t n, n2, off;
    uint8_t q, q2, lv;
    eff(l, &s, &n, &q);
    if (blank_s(s, n)) return K_BLANK;
    if (fence_s(s, n)) return K_FENCE;
    if (atx_s(s, n, &lv, &off)) { kind_lvl = lv; return K_ATX; }
    if (toc_s(s, n)) return K_TOCM;
    if (hr_s(s, n)) return K_HR;
    if (list_s(s, n)) return K_LIST;
    if (l + 1 < nlines) {
        eff(l + 1, &s2, &n2, &q2);
        if (q2 == q) {
            if (memchr(s, '|', n) && sep_s(s2, n2)) return K_TABLE;
            if (setext_s(s2, n2)) return K_SETEXT;
        }
    }
    return K_PARA;
}

/* heading text of heading i (without #'s) */
static void heading_text(uint8_t i, const char **ps, uint16_t *pn)
{
    const char *s;
    uint16_t n, off = 0;
    uint8_t q, lv;
    eff(hl[i], &s, &n, &q);
    if (atx_s(s, n, &lv, &off)) {
        s += off; n -= off;
        while (n && s[n - 1] == ' ') --n;
        while (n && s[n - 1] == '#') --n;
        while (n && s[n - 1] == ' ') --n;
    } else {
        while (off < n && s[off] == ' ') ++off;
        s += off; n -= off;
        while (n && s[n - 1] == ' ') --n;
    }
    *ps = s; *pn = n;
}

static void scan_headings(void)
{
    uint16_t l = 0;
    uint8_t infence = 0, k;
    hn = 0;
    while (l < nlines && hn < MAXH) {
        k = line_kind(l);
        if (infence) {
            if (k == K_FENCE) infence = 0;
        } else if (k == K_FENCE) {
            infence = 1;
        } else if (k == K_ATX) {
            hl[hn] = l; hlv[hn] = kind_lvl; ++hn;
        } else if (k == K_SETEXT) {
            hl[hn] = l; hlv[hn] = kind_lvl; ++hn;
            ++l;
        }
        ++l;
    }
}

/* ------------------------------------------------------------------ */
/* inline markup helpers shared by editor colouring and preview        */
/* ------------------------------------------------------------------ */
/* may the emphasis marker run at s[i] (width w) open/close? */
static uint8_t emph_ok(const char *s, uint16_t n, uint16_t i, uint8_t w, uint8_t on)
{
    uint8_t c = s[i];
    uint8_t prev = i ? s[i - 1] : ' ';
    uint8_t next = (i + w < n) ? s[i + w] : ' ';
    if (!on) return next != ' ' && !(c == '_' && is_alnum(prev));
    return prev != ' ' && !(c == '_' && is_alnum(next));
}

/* is there a complete [text](url) starting at s[i]=='['?  gives ']' and ')' */
static uint8_t link_at(const char *s, uint16_t n, uint16_t i, uint16_t *rb, uint16_t *rp)
{
    uint16_t j = i + 1, k;
    while (j < n && s[j] != ']') ++j;
    if (j + 1 >= n || s[j + 1] != '(') return 0;
    k = j + 2;
    while (k < n && s[k] != ')') ++k;
    if (k >= n) return 0;
    *rb = j; *rp = k;
    return 1;
}

/* ------------------------------------------------------------------ */
/* preview renderer -> banked RAM                                      */
/* ------------------------------------------------------------------ */
#define ST_B 1
#define ST_I 2
#define ST_C 4
#define ST_S 8
static uint8_t  prch[SW], prco[SW];     /* row under construction */
static uint8_t  wch[SW], wco[SW];       /* pending word           */
static uint8_t  cch[SW], cco[SW];       /* table cell sink        */
static uint8_t  px, wn, cn, sink, rowdirty, lastblank, pv_full;
static uint8_t  margin, qd;
static uint8_t  bul_pend, bul_x, bul_len;
static uint8_t  bul_buf[12];
static uint16_t pv_n;
static uint8_t  hcur;

static uint8_t  st_b, st_i, st_c, st_s, st_link, st_img, hmode, base_col, prev_sp;
static uint16_t lk_end, lk_close;

static void row_flush(void)
{
    uint8_t *p;
    lastblank = 0;
    if (pv_n >= PVMAXL) { pv_full = 1; return; }
    RAMBANK = 1 + pv_n / PV_PER_BANK;
    p = (uint8_t *)(0xA000u + (uint16_t)(pv_n % PV_PER_BANK) * 160u);
    memcpy(p, prch, SW);
    memcpy(p + 80, prco, SW);
    RAMBANK = 0;
    ++pv_n;
}

static void row_begin(void)
{
    uint8_t i;
    memset(prch, ' ', SW);
    memset(prco, C_NORM, SW);
    for (i = 0; i < qd; ++i) { prch[i * 2] = G_V; prco[i * 2] = C_QBAR; }
    px = margin;
    rowdirty = 0;
    if (bul_pend) {
        for (i = 0; i < bul_len && bul_x + i < pw; ++i) {
            prch[bul_x + i] = bul_buf[i]; prco[bul_x + i] = C_BUL;
        }
        bul_pend = 0;
        rowdirty = 1;
    }
}

static void row_end(void)
{
    if (rowdirty) row_flush();
    rowdirty = 0;
}

static void blank_row(void)
{
    if (lastblank) return;
    row_begin();
    row_flush();
    lastblank = 1;
}

static void wflush(void)
{
    uint8_t i;
    if (!wn) return;
    if (px + wn > pw && px > margin) { row_flush(); row_begin(); }
    for (i = 0; i < wn; ++i) {
        if (px >= pw) { row_flush(); row_begin(); }
        prch[px] = wch[i]; prco[px] = wco[i]; ++px;
    }
    wn = 0;
    rowdirty = 1;
}

static void out_glyph(uint8_t g, uint8_t col, uint8_t sp)
{
    if (sink) {
        if (cn < SW) { cch[cn] = g; cco[cn] = col; ++cn; }
        return;
    }
    if (sp) {
        wflush();
        if (px > margin && px < pw) { prch[px] = ' '; prco[px] = col; ++px; }
    } else {
        if (wn >= SW) wflush();
        wch[wn] = g; wco[wn] = col; ++wn;
    }
}

static void inl_reset(void)
{
    st_b = st_i = st_c = st_s = st_link = st_img = 0;
    prev_sp = 1;
}

static void put_styled(uint8_t c)
{
    uint8_t g = c, col = base_col;
    if (st_c) {
        col = C_CODE;
    } else {
        if (st_link) col = C_LINK;
        else if (st_img) col = C_IMG;
        else if (st_s) col = C_STRIKE;
        else if (!hmode) {
            if (st_b) col = C_BOLD;
            else if (st_i) col = C_ITAL;
        }
        if (st_b || hmode) g = bold_glyph(c);
        else if (st_i) g = ital_glyph(c);
    }
    out_glyph(g, col, c == ' ');
}

static void inline_emit(const char *s, uint16_t n)
{
    uint16_t i = 0, j, k;
    uint8_t c, w, on;
    while (i < n) {
        if ((st_link || st_img) && i == lk_end) {
            if (st_img) put_styled(']');
            st_link = st_img = 0;
            i = lk_close + 1;
            continue;
        }
        c = (uint8_t)s[i];
        if (c == '\t') c = ' ';
        if (c == ' ') {
            if (!prev_sp) put_styled(' ');
            prev_sp = 1; ++i;
            continue;
        }
        prev_sp = 0;
        if (c == '\\' && i + 1 < n && is_punct((uint8_t)s[i + 1])) {
            put_styled((uint8_t)s[i + 1]); i += 2; continue;
        }
        if (c == '`') { st_c = !st_c; ++i; continue; }
        if (st_c) { put_styled(c < 32 || c > 126 ? '?' : c); ++i; continue; }
        if (c == '*' || c == '_') {
            w = (i + 1 < n && (uint8_t)s[i + 1] == c) ? 2 : 1;
            on = (w == 2) ? st_b : st_i;
            if (emph_ok(s, n, i, w, on)) {
                if (w == 2) st_b = !st_b; else st_i = !st_i;
                i += w; continue;
            }
        } else if (c == '~' && i + 1 < n && s[i + 1] == '~') {
            st_s = !st_s; i += 2; continue;
        } else if (c == '[' && !st_link && !st_img && link_at(s, n, i, &j, &k)) {
            st_link = 1; lk_end = j; lk_close = k; ++i; continue;
        } else if (c == '!' && i + 1 < n && s[i + 1] == '[' && !st_link && !st_img &&
                   link_at(s, n, i + 1, &j, &k)) {
            st_img = 1; lk_end = j; lk_close = k;
            put_styled('[');
            i += 2; continue;
        }
        put_styled(c < 32 || c > 126 ? '?' : c);
        ++i;
    }
}

/* paragraph helper: separate consecutive source lines with a space */
static void inline_join(void)
{
    if (!prev_sp) { put_styled(' '); prev_sp = 1; }
}

static void begin_text(uint8_t m, uint8_t col, uint8_t h)
{
    margin = m;
    base_col = col;
    hmode = h;
    inl_reset();
    wn = 0;
    row_begin();
}

static void rule_row(uint8_t col)
{
    uint8_t x;
    row_begin();
    for (x = margin; x < pw; ++x) { prch[x] = G_H; prco[x] = col; }
    row_flush();
}

static void code_row(void)
{
    uint16_t i;
    uint8_t x = margin + 1, c;
    row_begin();
    for (c = margin; c < pw; ++c) prco[c] = C_CODEBLK;
    for (i = 0; i < en && x < pw; ++i) {
        c = (uint8_t)es[i];
        if (c == '\t') { x += 4; continue; }
        if (c < 32 || c > 126) c = '?';
        prch[x] = c;
        ++x;
    }
    row_flush();
}

static void render_heading(uint8_t lvl, const char *s, uint16_t n)
{
    blank_row();
    if (hcur < hn) hvis[hcur] = pv_n;
    ++hcur;
    begin_text(qd * 2, hcol[lvl], 1);
    inline_emit(s, n);
    wflush();
    row_end();
    if (lvl == 1) rule_row(hcol[1]);
    else if (lvl == 2) rule_row(C_TBL);
    blank_row();
}

/* --- tables --- */
static uint16_t tc_s[MAXC], tc_e[MAXC];
static uint8_t  t_w[MAXC], t_al[MAXC], t_nc;

static uint8_t split_row(const char *s, uint16_t n)
{
    uint16_t i = 0, st, e;
    uint8_t c = 0;
    while (i < n && is_sp(s[i])) ++i;
    if (i < n && s[i] == '|') ++i;
    while (i < n && c < MAXC) {
        st = i;
        while (i < n && s[i] != '|') {
            if (s[i] == '\\' && i + 1 < n) ++i;
            ++i;
        }
        e = i;
        while (st < e && is_sp(s[st])) ++st;
        while (e > st && is_sp(s[e - 1])) --e;
        tc_s[c] = st; tc_e[c] = e; ++c;
        if (i < n) ++i;
    }
    return c;
}

static void cell_measure(const char *s, uint8_t c, uint8_t header)
{
    sink = 1; cn = 0;
    base_col = header ? 7 : C_NORM;
    hmode = header;
    inl_reset();
    inline_emit(s + tc_s[c], tc_e[c] - tc_s[c]);
    sink = 0;
}

static void tbl_put(uint8_t *x, uint8_t g, uint8_t col)
{
    if (*x < pw) { prch[*x] = g; prco[*x] = col; ++*x; }
}

static void tbl_border(uint8_t gl, uint8_t gm, uint8_t gr)
{
    uint8_t c, k, x;
    row_begin();
    x = margin;
    tbl_put(&x, gl, C_TBL);
    for (c = 0; c < t_nc; ++c) {
        for (k = 0; k < t_w[c] + 2; ++k) tbl_put(&x, G_H, C_TBL);
        tbl_put(&x, c + 1 < t_nc ? gm : gr, C_TBL);
    }
    row_flush();
}

static void tbl_row(const char *s, uint16_t n, uint8_t header)
{
    uint8_t c, x, shown, pad, lp, k, ncell;
    ncell = split_row(s, n);
    row_begin();
    x = margin;
    tbl_put(&x, G_V, C_TBL);
    for (c = 0; c < t_nc; ++c) {
        if (c < ncell) cell_measure(s, c, header); else cn = 0;
        shown = cn > t_w[c] ? t_w[c] : cn;
        pad = t_w[c] - shown;
        lp = t_al[c] == 2 ? pad : (t_al[c] == 1 ? pad / 2 : 0);
        tbl_put(&x, ' ', C_NORM);
        for (k = 0; k < lp; ++k) tbl_put(&x, ' ', C_NORM);
        for (k = 0; k < shown; ++k) {
            if (cn > t_w[c] && k + 1 == shown) tbl_put(&x, '~', C_TBL);
            else tbl_put(&x, cch[k], cco[k]);
        }
        for (k = lp; k < pad; ++k) tbl_put(&x, ' ', C_NORM);
        tbl_put(&x, ' ', C_NORM);
        tbl_put(&x, G_V, C_TBL);
    }
    row_flush();
}

/* render the table starting at line l; returns first line after it */
static uint16_t render_table(uint16_t l)
{
    uint16_t t = l, r;
    const char *s;
    uint16_t n;
    uint8_t q, c, nc, tot, avail, widest;

    /* separator row: alignment */
    eff(l + 1, &s, &n, &q);
    nc = split_row(s, n);
    for (c = 0; c < nc; ++c) {
        uint16_t a = tc_s[c], b = tc_e[c];
        t_al[c] = 0;
        if (b > a && s[b - 1] == ':') t_al[c] = (s[a] == ':') ? 1 : 2;
    }
    eff(l, &s, &n, &q);
    t_nc = split_row(s, n);
    if (!t_nc) t_nc = 1;
    for (c = 0; c < t_nc; ++c) t_w[c] = 1;
    /* measure */
    for (r = l; r < nlines; ++r) {
        uint8_t nn;
        eff(r, &s, &n, &q);
        if (r != l && r != l + 1 && (blank_s(s, n) || !memchr(s, '|', n))) break;
        if (r == l + 1) continue;
        nn = split_row(s, n);
        for (c = 0; c < t_nc && c < nn; ++c) {
            cell_measure(s, c, r == l);
            if (cn > t_w[c]) t_w[c] = cn > 70 ? 70 : cn;
        }
    }
    t = r;
    tot = 1; for (c = 0; c < t_nc; ++c) tot += t_w[c] + 3;
    avail = pw - margin;
    while (tot > avail) {
        widest = 0;
        for (c = 1; c < t_nc; ++c) if (t_w[c] > t_w[widest]) widest = c;
        if (t_w[widest] <= 3) break;
        --t_w[widest]; --tot;
    }
    blank_row();
    tbl_border(G_TL, G_T, G_TR);
    eff(l, &s, &n, &q); tbl_row(s, n, 1);
    tbl_border(G_L, G_X, G_R);
    for (r = l + 2; r < t; ++r) { eff(r, &s, &n, &q); tbl_row(s, n, 0); }
    tbl_border(G_BL, G_B, G_BR);
    blank_row();
    return t;
}

static void render_toc(void)
{
    uint8_t i, minlv = 7, ind;
    const char *s;
    uint16_t n;
    if (!hn) return;
    for (i = 0; i < hn; ++i) if (hlv[i] < minlv) minlv = hlv[i];
    blank_row();
    begin_text(qd * 2, C_TOC, 1);
    inline_emit("Contents", 8);
    wflush();
    row_end();
    for (i = 0; i < hn; ++i) {
        ind = (hlv[i] - minlv) * 2;
        bul_pend = 1; bul_x = qd * 2 + ind; bul_len = 1; bul_buf[0] = G_BUL;
        begin_text(bul_x + 2, C_NORM, 0);
        heading_text(i, &s, &n);
        inline_emit(s, n);
        wflush();
        row_end();
    }
    blank_row();
}

static void pv_render(void)
{
    uint16_t l = 0;
    const char *s;
    uint16_t n, off;
    uint8_t k, q, lv, b;

    scan_headings();
    memset(hvis, 0xFF, sizeof hvis);
    pv_n = 0; pv_full = 0; lastblank = 1; hcur = 0;
    sink = 0; bul_pend = 0; qd = 0; margin = 0; wn = 0;
    while (l < nlines && !pv_full) {
        k = line_kind(l);
        eff(l, &s, &n, &q);
        qd = q;
        switch (k) {
        case K_BLANK:
            blank_row(); ++l;
            break;
        case K_FENCE:
            blank_row();
            margin = qd * 2;
            for (++l; l < nlines && !pv_full; ++l) {
                eff(l, &es, &en, &eq);
                if (fence_s(es, en)) { ++l; break; }
                qd = eq; margin = qd * 2;
                code_row();
            }
            blank_row();
            break;
        case K_ATX:
            atx_s(s, n, &lv, &off);
            s += off; n -= off;
            while (n && s[n - 1] == ' ') --n;
            while (n && s[n - 1] == '#') --n;
            while (n && s[n - 1] == ' ') --n;
            render_heading(lv, s, n);
            ++l;
            break;
        case K_SETEXT:
            lv = kind_lvl;
            while (n && *s == ' ') { ++s; --n; }
            while (n && s[n - 1] == ' ') --n;
            render_heading(lv, s, n);
            l += 2;
            break;
        case K_HR:
            blank_row();
            margin = qd * 2;
            rule_row(C_TBL);
            blank_row();
            ++l;
            break;
        case K_TOCM:
            render_toc(); ++l;
            break;
        case K_TABLE:
            margin = qd * 2;
            l = render_table(l);
            break;
        case K_LIST:
            list_s(s, n);
            b = L_ind > 12 ? 12 : (uint8_t)L_ind;
            bul_x = qd * 2 + b;
            if (L_ord) {
                bul_len = L_mlen > 8 ? 8 : (uint8_t)L_mlen;
                memcpy(bul_buf, s + L_mk, bul_len);
            } else { bul_len = 1; bul_buf[0] = G_BUL; }
            bul_pend = 1;
            begin_text(bul_x + bul_len + 1, C_NORM, 0);
            inline_emit(s + L_txt, n - L_txt);
            for (;;) {
                if (l + 1 >= nlines || line_kind(l + 1) != K_PARA) break;
                eff(l + 1, &es, &en, &eq);
                if (eq != q) break;
                inline_join();
                inline_emit(es, en);
                ++l;
            }
            wflush(); row_end();
            ++l;
            break;
        default:                        /* paragraph */
            begin_text(qd * 2, C_NORM, 0);
            inline_emit(s, n);
            for (;;) {
                if (l + 1 >= nlines || line_kind(l + 1) != K_PARA) break;
                eff(l + 1, &es, &en, &eq);
                if (eq != q) break;
                inline_join();
                inline_emit(es, en);
                ++l;
            }
            wflush(); row_end();
            ++l;
            break;
        }
    }
    qd = 0;
    if (pv_n == 0) { row_begin(); row_flush(); }
}

/* ------------------------------------------------------------------ */
/* text drawing helpers                                                */
/* ------------------------------------------------------------------ */
static void draw_text(uint8_t row, const char *s, uint8_t col)
{
    uint8_t x = 0;
    vera_at(0, row);
    while (x < scrw) {
        VERA.data0 = *s ? *s : ' ';
        VERA.data0 = col;
        if (*s) ++s;
        ++x;
    }
}

static char *scat(char *d, const char *src)
{
    while (*src) *d++ = *src++;
    return d;
}

static void pv_draw_row(uint8_t y, uint16_t n)
{
    uint8_t *p;
    uint8_t x;
    vera_at(0, y);
    if (n >= pv_n) {
        for (x = 0; x < scrw; ++x) { VERA.data0 = ' '; VERA.data0 = C_NORM; }
        return;
    }
    RAMBANK = 1 + n / PV_PER_BANK;
    p = (uint8_t *)(0xA000u + (uint16_t)(n % PV_PER_BANK) * 160u);
    for (x = 0; x < scrw; ++x) { VERA.data0 = p[x]; VERA.data0 = p[80 + x]; }
    RAMBANK = 0;
}

/* ------------------------------------------------------------------ */
/* dialogs: line prompt, help, TOC menu                                */
/* ------------------------------------------------------------------ */
static uint8_t read_line(const char *prompt, char *out, uint8_t max)
{
    uint8_t n = 0, k;
    char line[84];
    n = (uint8_t)strlen(out);
    for (;;) {
        char *d = scat(line, prompt);
        memcpy(d, out, n);
        d[n] = '_'; d[n + 1] = 0;
        draw_text(scrh - 1, line, (C_BG << 4) | C_BOLD);
        k = getkey();
        if (k == K_ESC) { out[0] = 0; return 0; }
        if (k == '\r' || k == '\n') { out[n] = 0; return 1; }
        if (k == K_BKSP || k == 0x08 || k == 0x7F) {
            if (n) --n;
            continue;
        }
        if (k >= 32 && k < 127 && n < max - 1) out[n++] = k;
    }
}

static void show_help(void)
{
    static const char *const help[] = {
        "MD - Markdown editor",
        "",
        "^W/F2 save   ^O/F3 open   ^X/F8 quit",
        "^P/F5 preview (toggle)    ^G/F4 contents",
        "^Z undo/redo  ^U kill line  ^F find",
        "F6/F7 page up/down",
        "^B bold  ^E italic  ^K code",
        "^A table  ^R [TOC] marker",
        "",
        "Preview: arrows, Space, b, n/p heading,",
        "  F4 contents, Esc or ^P back to editor",
        "",
        "Press any key",
        0
    };
    uint8_t r;
    clear_screen();
    for (r = 0; help[r]; ++r) draw_text(r + 1, help[r], r ? C_NORM : C_TOC);
    getkey();
    redraw_all = 1;
}

/* returns the chosen heading index, or -1 */
static int8_t toc_menu(void)
{
    uint8_t sel = 0, first = 0, vis, i, x, bw, bx, by, k, minlv = 7, ind, col, m;
    const char *s;
    uint16_t n, j;
    char line[SW + 1];

    scan_headings();
    if (!hn) { setmsg("No headings in this document"); return -1; }
    for (i = 0; i < hn; ++i) if (hlv[i] < minlv) minlv = hlv[i];
    bw = scrw > 66 ? 64 : scrw - 2;
    bx = (scrw - bw) / 2;
    vis = textrows - 4;
    if (vis > hn) vis = hn;
    by = 2;
    for (;;) {
        /* frame */
        memset(line, ' ', bw);
        for (x = 0; x < bw; ++x) put_cell(bx + x, by - 1, ' ', (1 << 4) | 0);
        {
            const char *t = " Table of Contents  (Enter=go  Esc=cancel) ";
            for (x = 0; t[x] && x < bw; ++x) put_cell(bx + x, by - 1, t[x], (1 << 4) | 0);
        }
        for (i = 0; i < vis; ++i) {
            m = first + i;
            memset(line, ' ', bw);
            ind = (hlv[m] - minlv) * 2;
            heading_text(m, &s, &n);
            for (x = 1 + ind, j = 0; j < n && x < bw - 1; ++j) {
                k = (uint8_t)s[j];
                if (k == '*' || k == '`') continue;
                if (k < 32 || k > 126) k = '?';
                line[x] = k;
                ++x;
            }
            col = (m == sel) ? ((1 << 4) | 0) : ((11 << 4) | hcol[hlv[m]]);
            for (x = 0; x < bw; ++x) put_cell(bx + x, by + i, line[x], col);
        }
        for (x = 0; x < bw; ++x) put_cell(bx + x, by + vis, ' ', (1 << 4) | 0);
        k = getkey();
        if (k == K_ESC || k == K_F4 || k == CTRL('G')) return -1;
        if (k == '\r' || k == '\n') return sel;
        if (k == K_DOWN && sel + 1 < hn) ++sel;
        else if (k == K_UP && sel) --sel;
        else if (k == K_F7 && sel + vis < hn) sel += vis;
        else if (k == K_F7) sel = hn - 1;
        else if (k == K_F6) sel = sel > vis ? sel - vis : 0;
        else if (k == K_HOME) sel = 0;
        else if (k == K_END) sel = hn - 1;
        if (sel < first) first = sel;
        if (sel >= first + vis) first = sel - vis + 1;
    }
}

/* ------------------------------------------------------------------ */
/* preview viewer                                                      */
/* ------------------------------------------------------------------ */
static void preview_mode(void)
{
    uint16_t pvtop = 0, maxtop;
    uint8_t i, k;
    int8_t t;
    char line[SW + 1], *d;

    draw_text(scrh - 1, "Rendering preview...", (C_BG << 4) | C_BOLD);
    pv_render();
    /* start at the heading nearest above the cursor */
    for (i = 0; i < hn; ++i) if (hl[i] <= cy) pvtop = hvis[i];
    for (;;) {
        maxtop = pv_n > textrows ? pv_n - textrows : 0;
        if (pvtop > maxtop) pvtop = maxtop;
        for (i = 0; i < textrows; ++i) pv_draw_row(i, pvtop + i);
        d = scat(line, " PREVIEW  ");
        d = scat(d, fname[0] ? fname : "[No Name]");
        d = scat(d, "   row ");
        utoa(pvtop + 1, d, 10); d += strlen(d);
        *d++ = '/';
        utoa(pv_n, d, 10); d += strlen(d);
        if (pv_full) d = scat(d, " (too long: end cut off)");
        *d = 0;
        draw_text(scrh - 2, line, (C_NORM << 4) | C_BG);
        draw_text(scrh - 1, "Up/Dn scroll  Space page  n/p heading  F4 contents  Ctrl-P or Esc = edit",
                  (C_BG << 4) | C_LAB);
        k = getkey();
        switch (k) {
        case K_DOWN: case 'j': if (pvtop < maxtop) ++pvtop; break;
        case K_UP: case 'k': if (pvtop) --pvtop; break;
        case ' ': case K_F7: case 'f':
            pvtop += textrows - 1; break;
        case 'b': case K_F6:
            pvtop = pvtop > textrows - 1 ? pvtop - (textrows - 1) : 0; break;
        case K_HOME: case 'g': pvtop = 0; break;
        case K_END: case 'G': pvtop = maxtop; break;
        case 'n':
            for (i = 0; i < hn; ++i) if (hvis[i] > pvtop && hvis[i] < pv_n) { pvtop = hvis[i]; break; }
            break;
        case 'p':
            for (i = hn; i-- > 0;) if (hvis[i] < pvtop) { pvtop = hvis[i]; break; }
            break;
        case K_F4: case 't': case CTRL('G'):
            t = toc_menu();
            if (t >= 0) pvtop = hvis[t];
            break;
        case K_F5: case CTRL('P'): case K_ESC: case 'e': case 'q':
            redraw_all = 1;
            return;
        }
    }
}

/* ------------------------------------------------------------------ */
/* editor: syntax colouring                                            */
/* ------------------------------------------------------------------ */
static void fillc(uint16_t from, uint16_t to, uint8_t col)
{
    if (to > CLSN) to = CLSN;
    if (from < to) memset(cls + from, col, to - from);
}

static void hl_md(const char *s, uint16_t n, uint8_t infence, uint8_t isfence)
{
    uint16_t m = n > CLSN ? CLSN : n, i = 0, j, a, b2;
    uint8_t c, bo = 0, it = 0, cd = 0, k, w;
    uint8_t lv;
    uint16_t off;

    fillc(0, m, C_NORM);
    if (isfence) { fillc(0, m, C_MARK); return; }
    if (infence) { fillc(0, m, C_LAB); return; }
    if (atx_s(s, n, &lv, &off)) { fillc(0, m, hcol[lv]); return; }
    if (toc_s(s, n)) { fillc(0, m, C_TOC); return; }
    if (hr_s(s, n) || sep_s(s, n)) { fillc(0, m, C_MARK); return; }
    while (i < m && s[i] == ' ') ++i;
    while (i < m && s[i] == '>') {
        cls[i++] = C_QBAR;
        if (i < m && s[i] == ' ') ++i;
    }
    if (list_s(s, n)) {
        fillc(L_mk, L_mk + L_mlen, C_BUL);
        i = L_txt;
    }
    for (j = i; j < m; ++j) {
        c = (uint8_t)s[j];
        if (c == '`') { cls[j] = C_MARK; cd = !cd; continue; }
        if (cd) { cls[j] = C_CODE & 15; continue; }
        if (c == '*' || c == '_') {
            w = (j + 1 < n && (uint8_t)s[j + 1] == c) ? 2 : 1;
            if (emph_ok(s, n, j, w, w == 2 ? bo : it)) {
                fillc(j, j + w, C_MARK);
                if (w == 2) bo = !bo; else it = !it;
                j += w - 1;
                continue;
            }
        } else if (c == '[' && link_at(s, n, j, &a, &b2)) {
            fillc(j, j + 1, C_MARK);
            fillc(j + 1, a, C_LINK);
            fillc(a, a + 2, C_MARK);
            fillc(a + 2, b2, C_URL);
            fillc(b2, b2 + 1, C_MARK);
            j = b2;
            continue;
        }
        k = bo ? C_BOLD : (it ? C_ITAL : C_NORM);
        cls[j] = k;
    }
    if (memchr(s, '|', m))
        for (j = 0; j < m; ++j) if (s[j] == '|') cls[j] = C_TBL;
}

static uint8_t fence_before(uint16_t l)
{
    uint16_t i;
    uint8_t f = 0;
    for (i = 0; i < l; ++i)
        if (fence_s(buf + lstart[i], linelen(i))) f = !f;
    return f;
}

static uint16_t rows_of(uint16_t l) { return linelen(l) / scrw + 1; }

/* draw logical line l with its first row at screen row `row`; returns rows used */
static uint8_t draw_logical(uint16_t l, uint8_t row, uint8_t f)
{
    const char *s = buf + lstart[l];
    uint16_t n = linelen(l), idx;
    uint8_t segs = (uint8_t)(n / scrw + 1), sg, x, ch, used = 0;
    uint8_t isf = fence_s(s, n);

    hl_md(s, n, f, isf);
    for (sg = 0; sg < segs && row + used < textrows; ++sg) {
        vera_at(0, row + used);
        idx = (uint16_t)sg * scrw;
        for (x = 0; x < scrw; ++x, ++idx) {
            if (idx < n) {
                ch = (uint8_t)s[idx];
                if (ch < 32 || ch > 126) ch = (ch == '\t') ? ' ' : '?';
                VERA.data0 = ch;
                VERA.data0 = idx < CLSN ? cls[idx] : C_NORM;
            } else {
                VERA.data0 = ' '; VERA.data0 = C_NORM;
            }
        }
        ++used;
    }
    return used;
}

static void draw_screen(void)
{
    uint16_t l = top;
    uint8_t row = 0, f = fence_before(top), x;
    while (row < textrows) {
        if (l >= nlines) {
            vera_at(0, row);
            VERA.data0 = '~'; VERA.data0 = C_LAB;
            for (x = 1; x < scrw; ++x) { VERA.data0 = ' '; VERA.data0 = C_NORM; }
            ++row;
            continue;
        }
        row += draw_logical(l, row, f);
        if (fence_s(buf + lstart[l], linelen(l))) f = !f;
        ++l;
    }
}

/* first screen row of logical line l (or 255 if off-screen) */
static uint8_t line_row(uint16_t l)
{
    uint16_t r = 0, i;
    if (l < top) return 255;
    for (i = top; i < l; ++i) { r += rows_of(i); if (r >= textrows) return 255; }
    return (uint8_t)r;
}

static void cursor_xy(uint8_t *x, uint8_t *y)
{
    uint16_t r = 0, i;
    for (i = top; i < cy; ++i) { r += rows_of(i); if (r > 200) break; }
    r += cx / scrw;
    *x = (uint8_t)(cx % scrw);
    *y = r > 250 ? 250 : (uint8_t)r;
}

static void draw_status(void)
{
    char line[84], r[32];
    char *d = line, *e;
    d = scat(d, " ");
    d = scat(d, fname[0] ? fname : "[No Name]");
    if (modified) d = scat(d, " [+]");
    while (d < line + scrw) *d++ = ' ';
    e = r;
    e = scat(e, "Ln ");
    utoa(cy + 1, e, 10); e += strlen(e);
    e = scat(e, " Col ");
    utoa(cx + 1, e, 10); e += strlen(e);
    e = scat(e, "  Free ");
    utoa(BUFSZ - len, e, 10); e += strlen(e);
    *e++ = ' ';
    memcpy(line + scrw - (e - r), r, e - r);
    line[scrw] = 0;
    draw_text(scrh - 2, line, (C_NORM << 4) | C_BG);
    if (msg[0]) draw_text(scrh - 1, msg, (C_BG << 4) | C_BOLD);
    else draw_text(scrh - 1,
        "^P preview  ^G contents  ^W save  ^O open  ^X quit  ^B bold ^E italic  F1 help",
        (C_BG << 4) | C_LAB);
}

static void scroll_to_cursor(void)
{
    uint8_t x, y;
    if (cy < top) { top = cy; redraw_all = 1; }
    for (;;) {
        cursor_xy(&x, &y);
        if (y < textrows || top >= cy) break;
        ++top; redraw_all = 1;
    }
}

static void refresh(void)
{
    uint8_t x, y, r, ch;
    scroll_to_cursor();
    if (redraw_all) {
        draw_screen();
        redraw_all = 0;
    } else {
        if (prev_cy != cy) {
            r = line_row(prev_cy);
            if (r != 255 && prev_cy < nlines) draw_logical(prev_cy, r, fence_before(prev_cy));
        }
        r = line_row(cy);
        if (r != 255) draw_logical(cy, r, fence_before(cy));
    }
    prev_cy = cy;
    draw_status();
    cursor_xy(&x, &y);
    if (y < textrows) {
        vera_at(x, y);
        ch = VERA.data0;
        put_cell(x, y, ch, (C_NORM << 4) | C_BG);
    }
}

/* ------------------------------------------------------------------ */
/* cursor movement                                                     */
/* ------------------------------------------------------------------ */
static void set_want(void) { want = cx % scrw; }

static void clamp_cx(void)
{
    uint16_t n = linelen(cy);
    if (cx > n) cx = n;
}

static void move_down(void)
{
    uint16_t n = linelen(cy), w = scrw;
    if (cx / w < n / w) {
        cx += w;
        if (cx > n) cx = n;
    } else if (cy + 1 < nlines) {
        ++cy;
        cx = want;
        clamp_cx();
    }
}

static void move_up(void)
{
    uint16_t w = scrw, n;
    if (cx >= w) cx -= w;
    else if (cy > 0) {
        --cy;
        n = linelen(cy);
        cx = (n / w) * w + want;
        if (cx > n) cx = n;
    }
}

/* ------------------------------------------------------------------ */
/* file i/o                                                            */
/* ------------------------------------------------------------------ */
static char *dosname(char *d, const char *src)
{
    char *o = d, c;
    for (; (c = *src) != 0; ++src, ++d) {
        if (c >= 'a' && c <= 'z') c -= 32;
        else if (c >= 'A' && c <= 'Z') c += 128;
        *d = c;
    }
    *d = 0;
    return o;
}

static void dos_status(char *out, uint8_t max)
{
    uint8_t n = 0;
    char c;
    out[0] = 0;
    if (cbm_open(15, DEVICE, 15, "") != 0) return;
    cbm_k_chkin(15);
    while (n + 1 < max) {
        c = cbm_k_basin();
        if (c == '\r' || c == '\n' || cbm_k_readst()) break;
        out[n++] = c;
    }
    out[n] = 0;
    for (c = 0; c < n; ++c)
        if (out[c] >= 0x41 && out[c] <= 0x5A) out[c] += 32;
    cbm_k_clrch();
    cbm_close(15);
}

static uint8_t load_file(const char *name)
{
    char *cname = (char *)iobuf2;
    uint8_t *chunk = iobuf;
    int n, i;
    uint16_t o = 0;
    char c;
    char st[40];

    strcpy(cname, name);
    strcat(cname, ",s,r");
    if (cbm_open(2, DEVICE, 2, dosname(cname, cname)) != 0) { cbm_close(2); setmsg("Cannot open file"); return 0; }
    truncated = 0;
    for (;;) {
        n = cbm_read(2, chunk, sizeof iobuf);
        if (n <= 0) break;
        for (i = 0; i < n; ++i) {
            c = chunk[i];
            if (c == '\r') {
                if (i + 1 < n && chunk[i + 1] == '\n') continue;
                c = '\n';
            }
            if (c == 0) continue;
            if (o >= BUFSZ - 2) { truncated = 1; break; }
            buf[o++] = c;
        }
        if (truncated) break;
    }
    cbm_close(2);
    dos_status(st, sizeof st);
    if (st[0] == '6' || st[0] == '7' || (st[0] == '5' && st[1] != '0')) {
        if (o == 0) { setmsg(st); return 0; }
    }
    if (o == 0 || buf[o - 1] != '\n') buf[o++] = '\n';
    len = o;
    rebuild_lines();
    return 1;
}

static uint8_t save_file(const char *name)
{
    char *cname = (char *)iobuf2;
    uint8_t *chunk = iobuf;
    uint16_t o = 0, n;
    char st[40];
    char lbl[60];

    strcpy(cname, "@:");
    strcat(cname, name);
    strcat(cname, ",s,w");
    if (cbm_open(2, DEVICE, 2, dosname(cname, cname)) != 0) { cbm_close(2); setmsg("Cannot open for write"); return 0; }
    while (o < len) {
        n = len - o; if (n > sizeof iobuf) n = sizeof iobuf;
        memcpy(chunk, buf + o, n);
        if (cbm_write(2, chunk, n) != n) break;
        o += n;
    }
    cbm_close(2);
    dos_status(st, sizeof st);
    if (st[0] != '0' || st[1] != '0') { setmsg(st); return 0; }
    modified = 0;
    strcpy(lbl, "\"");
    strcat(lbl, name);
    strcat(lbl, "\" written");
    setmsg(lbl);
    return 1;
}

static void open_file(const char *name)
{
    strncpy(fname, name, FNLEN); fname[FNLEN] = 0;
    if (!load_file(name)) {
        new_buffer();
    } else {
        cy = cx = want = top = 0;
        modified = 0; uvalid = 0;
        setmsg(truncated ? "File truncated (too big)!" : "File loaded");
    }
    redraw_all = 1;
}

static void do_save(void)
{
    char name[FNLEN + 1];
    if (!fname[0]) {
        name[0] = 0;
        if (!read_line("Save as: ", name, sizeof name)) { setmsg("Cancelled"); return; }
        if (!name[0]) return;
        strcpy(fname, name);
    }
    save_file(fname);
}

static uint8_t discard_ok(void)
{
    if (!modified || warned) { warned = 0; return 1; }
    warned = 1;
    setmsg("Unsaved changes! Press the key again to discard them");
    return 0;
}

/* ------------------------------------------------------------------ */
/* editing commands                                                    */
/* ------------------------------------------------------------------ */
static void begin_edit(void)
{
    if (!typing) { snap(); typing = 1; }
}

static void insert_char(char c)
{
    begin_edit();
    if (buf_insert(cur_pos(), &c, 1)) ++cx;
    set_want();
}

/* insert text at the cursor and leave the cursor after it */
static void insert_str(const char *t)
{
    uint16_t n = (uint16_t)strlen(t), i;
    if (!buf_insert(cur_pos(), t, n)) return;
    for (i = 0; i < n; ++i) {
        if (t[i] == '\n') { ++cy; cx = 0; } else ++cx;
    }
    set_want();
}

static void do_newline(void)
{
    char ins[12];
    uint8_t n = 1, i = 0;
    const char *sl = buf + lstart[cy];
    uint16_t ln = linelen(cy);
    begin_edit();
    ins[0] = '\n';
    while (i < ln && sl[i] == ' ' && i < 8) ins[n++] = sl[i++];
    if (i + 1 < ln && sl[i + 1] == ' ' && cx >= (uint16_t)i + 2 &&
        (sl[i] == '-' || sl[i] == '*' || sl[i] == '+' || sl[i] == '>')) {
        if (ln == (uint16_t)i + 2) {              /* empty item: end the list */
            buf_delete(lstart[cy], ln);
            cx = 0; set_want();
            return;
        }
        ins[n++] = sl[i]; ins[n++] = ' ';
    }
    if (buf_insert(cur_pos(), ins, n)) { ++cy; cx = n - 1; }
    set_want();
}

static void backspace(void)
{
    begin_edit();
    if (cx > 0) { --cx; buf_delete(cur_pos(), 1); }
    else if (cy > 0) {
        cx = linelen(cy - 1); --cy;
        buf_delete(cur_pos(), 1);
    }
    set_want();
}

static void kill_line(void)
{
    snap(); typing = 0;
    if (nlines == 1) {
        buf_delete(0, len - 1);
        cx = 0;
    } else if (cy + 1 < nlines) {
        buf_delete(lstart[cy], lstart[cy + 1] - lstart[cy]);
        cx = 0;
    } else {
        buf_delete(lstart[cy] - 1, len - lstart[cy]);
        --cy; cx = 0;
    }
    clamp_cx(); set_want();
}

static void pair_insert(const char *t, uint8_t back)
{
    snap(); typing = 0;
    insert_str(t);
    cx -= back;
    set_want();
}

static void insert_table(void)
{
    snap(); typing = 0;
    if (linelen(cy) > 0) { cx = linelen(cy); insert_str("\n\n"); }
    else cx = 0;
    insert_str("| Column A | Column B | Column C |\n"
               "|:---------|:--------:|---------:|\n"
               "| one      | two      | three    |\n");
    cy -= 3; cx = 2;
    set_want();
    setmsg("Table inserted - edit the cells, Ctrl-P to preview");
}

static void insert_toc_marker(void)
{
    snap(); typing = 0;
    if (linelen(cy) > 0) { cx = linelen(cy); insert_str("\n\n"); }
    else cx = 0;
    insert_str("[TOC]\n\n");
    set_want();
    setmsg("[TOC] marker inserted - shown as contents in the preview");
}

static void do_find(void)
{
    char pat[32];
    uint16_t pos, i, pl, start;
    strcpy(pat, lastsearch);
    if (!read_line("Find: ", pat, sizeof pat)) { msg[0] = 0; return; }
    if (pat[0]) strcpy(lastsearch, pat);
    pl = (uint16_t)strlen(lastsearch);
    if (!pl) return;
    start = cur_pos() + 1;
    for (i = 0; i < len; ++i) {
        pos = start + i;
        if (pos >= len) pos -= len;
        if (pos + pl <= len && memcmp(buf + pos, lastsearch, pl) == 0) {
            cy = find_line(pos);
            cx = pos - lstart[cy];
            set_want();
            setmsg("Found");
            return;
        }
    }
    setmsg("Not found");
}

static void goto_heading(uint8_t i)
{
    cy = hl[i]; cx = 0; top = cy;
    set_want();
    redraw_all = 1;
}

static void edit_key(uint8_t k)
{
    char name[FNLEN + 1];
    uint8_t i;

    if (!(k == CTRL('X') || k == K_F8 || k == CTRL('O') || k == K_F3)) warned = 0;
    if (k >= 32 && k < 127) { insert_char(k); return; }
    switch (k) {
    case '\r': case '\n': do_newline(); return;
    case K_BKSP: case 0x08: case 0x7F: backspace(); return;
    case K_DEL:
        begin_edit();
        if (cx < linelen(cy) || cy + 1 < nlines) buf_delete(cur_pos(), 1);
        return;
    case '\t': begin_edit(); insert_char(' '); insert_char(' '); return;
    }
    typing = 0;
    switch (k) {
    case K_LEFT:
        if (cx) --cx; else if (cy) { --cy; cx = linelen(cy); }
        set_want(); break;
    case K_RIGHT:
        if (cx < linelen(cy)) ++cx; else if (cy + 1 < nlines) { ++cy; cx = 0; }
        set_want(); break;
    case K_UP: move_up(); break;
    case K_DOWN: move_down(); break;
    case K_HOME: cx = 0; set_want(); break;
    case K_END: cx = linelen(cy); set_want(); break;
    case K_F6:
        for (i = 0; i < textrows - 1; ++i) move_up();
        break;
    case K_F7:
        for (i = 0; i < textrows - 1; ++i) move_down();
        break;
    case CTRL('P'): case K_F5:
        preview_mode();
        break;
    case CTRL('G'): case K_F4: {
        int8_t t = toc_menu();
        redraw_all = 1;
        if (t >= 0) goto_heading((uint8_t)t);
        break;
    }
    case CTRL('W'): case K_F2: do_save(); break;
    case CTRL('O'): case K_F3:
        if (!discard_ok()) break;
        name[0] = 0;
        if (read_line("Open file: ", name, sizeof name) && name[0]) open_file(name);
        break;
    case CTRL('X'): case K_F8:
        if (discard_ok()) quit = 1;
        break;
    case CTRL('Z'): do_undo(); break;
    case CTRL('U'): kill_line(); break;
    case CTRL('F'): do_find(); break;
    case CTRL('B'): pair_insert("****", 2); break;
    case CTRL('E'): pair_insert("**", 1); break;
    case CTRL('K'): pair_insert("``", 1); break;
    case CTRL('A'): insert_table(); break;
    case CTRL('R'): insert_toc_marker(); break;
    case K_F1: show_help(); break;
    }
}

static void editor(void)
{
    uint8_t k;
    redraw_all = 1;
    while (!quit) {
        refresh();
        k = getkey();
        msg[0] = 0;
        edit_key(k);
    }
}

#ifdef SELFTEST
extern const char *selftest_keys;
extern const char *selftest_file;
#endif

int main(void)
{
    init_screen();
    iso_mode();
    build_fonts();
    clear_screen();
    VERA.display.border = 0;
    new_buffer();
    fname[0] = 0;
    msg[0] = 0;
#ifdef SELFTEST
    open_file(selftest_file);
    selfkeys = selftest_keys;
#endif
    setmsg("MD for X16 - F1 help, Ctrl-O open, Ctrl-P preview");
    editor();
    asm("lda #$8f");     /* ISO mode off */
    asm("jsr $ffd2");
    asm("lda #$03");     /* restore the standard PETSCII charset (we edited glyphs) */
    asm("ldx #$00");
    asm("ldy #$00");
    asm("jsr $ff62");
    asm("lda #$93");     /* clear screen */
    asm("jsr $ffd2");
    return 0;
}
