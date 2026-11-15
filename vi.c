/*
 * VI for the Commander X16  (cc65, target cx16)
 *
 * A small vi clone with syntax highlighting for C, BASIC and 6502 assembly.
 * Draws straight into VERA text memory in ISO mode (screen code == ASCII).
 *
 * Build:  make        Run:  make run   (x16emu)   Usage:  vi.prg, then :e file
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
#define BUFSZ    9000u
#endif
#define MAXL     500u
#define REGSZ    512u
#define FNLEN    40
#define CMDLEN   70
#define DEVICE   8

#define RAMBANK  (*(volatile uint8_t *)0x0000)
#define KERNAL_GETIN 0xFFE4

/* languages */
#define L_NONE  0
#define L_C     1
#define L_BAS   2
#define L_ASM   3

/* colour classes (VERA palette indexes) */
#define C_BG     0
#define C_NORM   1
#define C_KEY    7   /* keywords / mnemonics  yellow */
#define C_TYPE   5   /* types / functions     green  */
#define C_STR    8   /* strings               orange */
#define C_NUM    3   /* numbers               cyan   */
#define C_COM    12  /* comments              grey   */
#define C_PRE    4   /* preprocessor / dirs   purple */
#define C_LAB    13  /* labels                lt grn */
#define C_REG    14  /* registers             lt blu */
#define C_LNO    11  /* line numbers          dk gry */

/* ------------------------------------------------------------------ */
/* state                                                               */
/* ------------------------------------------------------------------ */
static char     buf[BUFSZ + 2];
static uint16_t lstart[MAXL + 2];

#pragma bss-name (push, "ZEROPAGE")
static uint16_t len;
static uint16_t nlines;
static uint16_t cy;          /* cursor line */
static uint16_t cx;          /* cursor column (char index in line) */
static uint16_t want;        /* desired visual column for j/k */
static uint16_t top;         /* first visible line */
static uint16_t leftcol;     /* horizontal scroll */
static uint8_t  mode;        /* 0 normal 1 insert 2 replace */
static uint8_t  lang;
#pragma bss-name (pop)

static uint8_t  scrw, scrh;  /* screen size in chars */
static uint8_t  textrows;
static uint16_t vbase;       /* VERA address of map */
static uint16_t vstride;     /* bytes per map row */

static uint8_t  tabw = 8;
static uint8_t  shownum = 0;
static uint8_t  autoind = 1;
static uint8_t  modified;
static uint8_t  truncated;
static char     fname[FNLEN + 1];
static char     msg[80];
static uint8_t  quit;

static char     reg[REGSZ];
static uint16_t reglen;
static uint8_t  reglines;

static char     lastsearch[32];
static int8_t   searchdir = 1;

/* undo (single level, swap style) held in banked RAM */
typedef struct { uint16_t len, cx, cy; } snapmeta;
static snapmeta smeta[2];
static uint8_t  usel;
static uint8_t  uvalid;

/* syntax state per line: bit 0 = line begins inside /* comment */
static uint8_t  cstate[(MAXL + 8) / 8 + 1];
static uint16_t cstate_valid;    /* states known for lines <= this index */

static uint8_t  cls[260];
static uint8_t  iobuf[168];
static char     iobuf2[FNLEN + 12];

static uint8_t  redraw_all;
static uint16_t prev_cy;

/* ------------------------------------------------------------------ */
/* low level: keyboard, VERA                                           */
/* ------------------------------------------------------------------ */
#ifdef SELFTEST
static const char *selfkeys;
static void selftest_dump(void);
static char *dosname(char *d, const char *src);
#endif

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
    VERA.address_hi = 0x10 | 1;   /* increment 1, bank 1 ($1xxxx) */
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
    textrows = scrh - 1;
    VERA.control &= 0xFE;
    m = VERA.layer1.config;
    switch ((m >> 4) & 3) {
        case 0: vstride = 64;  break;
        case 1: vstride = 128; break;
        case 2: vstride = 256; break;
        default: vstride = 512; break;
    }
    /* mapbase register holds address bits 16:9 */
    vbase = ((uint16_t)(VERA.layer1.mapbase & 0x7F)) << 9;
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
    cstate_valid = 0;
}

static void new_buffer(void)
{
    buf[0] = '\n';
    len = 1;
    rebuild_lines();
    cy = cx = want = top = leftcol = 0;
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
    if (L < cstate_valid) cstate_valid = L;
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
    if (L < cstate_valid) cstate_valid = L;
    modified = 1;
    redraw_all = 1;
}

/* ------------------------------------------------------------------ */
/* undo snapshots in banked RAM (banks 1-4 and 5-8)                    */
/* ------------------------------------------------------------------ */
static void bank_save(uint8_t set)
{
    uint16_t off = 0, n;
    uint8_t b = 1 + set * 4;
    while (off < len) {
        n = len - off; if (n > 0x2000) n = 0x2000;
        RAMBANK = b++;
        memcpy((void *)0xA000, buf + off, n);
        off += n;
    }
    RAMBANK = 0;
}

static void bank_load(uint8_t set, uint16_t n_total)
{
    uint16_t off = 0, n;
    uint8_t b = 1 + set * 4;
    while (off < n_total) {
        n = n_total - off; if (n > 0x2000) n = 0x2000;
        RAMBANK = b++;
        memcpy(buf + off, (void *)0xA000, n);
        off += n;
    }
    RAMBANK = 0;
}

static void snap(void)
{
    bank_save(usel);
    smeta[usel].len = len;
    smeta[usel].cx = cx;
    smeta[usel].cy = cy;
    uvalid = 1;
}

static void do_undo(void)
{
    uint8_t other = 1 - usel;
    if (!uvalid) { setmsg("Nothing to undo"); return; }
    bank_save(other);
    smeta[other].len = len; smeta[other].cx = cx; smeta[other].cy = cy;
    len = smeta[usel].len;
    bank_load(usel, len);
    cx = smeta[usel].cx; cy = smeta[usel].cy;
    usel = other;
    rebuild_lines();
    if (cy >= nlines) cy = nlines - 1;
    modified = 1;
    redraw_all = 1;
}

/* ------------------------------------------------------------------ */
/* syntax highlighting                                                 */
/* ------------------------------------------------------------------ */
static const char *const kw_c[] = {
    "asm","auto","break","case","const","continue","default","do","else",
    "enum","extern","for","goto","if","register","return","sizeof","static",
    "struct","switch","typedef","union","volatile","while",0 };
static const char *const ty_c[] = {
    "char","double","float","int","long","short","signed","unsigned","void",
    "int8_t","int16_t","int32_t","uint8_t","uint16_t","uint32_t","size_t",
    "bool","FILE","NULL","true","false","BYTE","WORD",0 };

static const char *const kw_bas[] = {
    "end","for","next","data","input","dim","read","let","goto","run","if",
    "restore","gosub","return","rem","stop","on","wait","load","save","verify",
    "def","poke","print","cont","list","clr","cmd","sys","open","close","get",
    "new","tab","to","fn","spc","then","not","step","and","or","go","else",
    "vpoke","bank","screen","color","cls","locate","mouse","pset","line",
    "frame","rect","char","mon","reset","bload","bvload","bvrify","bverify",
    "ovload","dos","old","geos","vload","sleep","monitor","bin$","hex$",0 };
static const char *const fn_bas[] = {
    "sgn","int","abs","usr","fre","pos","sqr","rnd","log","exp","cos","sin",
    "tan","atn","peek","len","str$","val","asc","chr$","left$","right$","mid$",
    "vpeek","joy","rpt$","pointer","time","ti","ti$","st","rdtim","timer", 0 };

static const char *const op_asm[] = {
    "adc","and","asl","bbr0","bbr1","bbr2","bbr3","bbr4","bbr5","bbr6","bbr7",
    "bbs0","bbs1","bbs2","bbs3","bbs4","bbs5","bbs6","bbs7","bcc","bcs","beq",
    "bit","bmi","bne","bpl","bra","brk","bvc","bvs","clc","cld","cli","clv",
    "cmp","cpx","cpy","dec","dex","dey","eor","inc","inx","iny","jmp","jsr",
    "lda","ldx","ldy","lsr","nop","ora","pha","php","phx","phy","pla","plp",
    "plx","ply","rmb0","rmb1","rmb2","rmb3","rmb4","rmb5","rmb6","rmb7","rol",
    "ror","rti","rts","sbc","sec","sed","sei","smb0","smb1","smb2","smb3",
    "smb4","smb5","smb6","smb7","sta","stp","stx","sty","stz","tax","tay",
    "trb","tsb","tsx","txa","txs","tya","wai","asr","ina","dea", 0 };

#define ST_BLOCK 1

static uint8_t is_idstart(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}
static uint8_t is_digit(char c) { return c >= '0' && c <= '9'; }
static uint8_t is_hex(char c)
{
    return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
static uint8_t is_idchar(char c) { return is_idstart(c) || is_digit(c); }

/* copy word, lower-cased, into w (max 15 chars) */
static void getword(const char *s, uint8_t n, uint8_t i, uint8_t extra, char *w)
{
    uint8_t k = 0;
    while (i < n && (is_idchar(s[i]) || (extra && (s[i] == '$' || s[i] == '%')))) {
        if (k < 14) {
            char c = s[i];
            if (c >= 'A' && c <= 'Z') c += 32;
            w[k++] = c;
        }
        ++i;
    }
    w[k] = 0;
}

static uint8_t in_list(const char *const *tab, const char *w)
{
    for (; *tab; ++tab)
        if ((*tab)[0] == w[0] && !strcmp(*tab, w)) return 1;
    return 0;
}

static void fillc(uint8_t from, uint8_t to, uint8_t col)
{
    while (from < to) cls[from++] = col;
}

static uint8_t hl_c(const char *s, uint8_t n, uint8_t st)
{
    uint8_t i = 0, j, c;
    char w[16];
    uint8_t first = 1;

    while (i < n) {
        c = s[i];
        if (st & ST_BLOCK) {
            j = i;
            while (j < n && !(s[j] == '*' && j + 1 < n && s[j + 1] == '/')) ++j;
            if (j < n) { j += 2; st &= ~ST_BLOCK; }
            fillc(i, j, C_COM);
            i = j;
            continue;
        }
        if (c == ' ' || c == '\t') { cls[i++] = C_NORM; continue; }
        if (c == '/' && i + 1 < n && s[i + 1] == '/') {
            fillc(i, n, C_COM); return st;
        }
        if (c == '/' && i + 1 < n && s[i + 1] == '*') {
            st |= ST_BLOCK; cls[i] = cls[i + 1] = C_COM; i += 2; continue;
        }
        if (c == '#' && first) {
            j = i;
            while (j < n && s[j] != ' ' && s[j] != '\t' && s[j] != '<' && s[j] != '"') ++j;
            fillc(i, j, C_PRE);
            i = j;
            first = 0;
            continue;
        }
        first = 0;
        if (c == '"' || c == '\'') {
            j = i + 1;
            while (j < n && s[j] != c) { if (s[j] == '\\') ++j; ++j; }
            if (j < n) ++j;
            if (j > n) j = n;
            fillc(i, j, C_STR);
            i = j; continue;
        }
        if (c == '<' && i > 0 && cls[i - 1] == C_NORM) { /* maybe <stdio.h> after #include */
            uint8_t p = 0;
            while (p < i && (s[p] == ' ' || s[p] == '\t')) ++p;
            if (s[p] == '#') {
                j = i;
                while (j < n && s[j] != '>') ++j;
                if (j < n) ++j;
                fillc(i, j, C_STR); i = j; continue;
            }
        }
        if (is_digit(c)) {
            j = i + 1;
            while (j < n && (is_idchar(s[j]) || s[j] == '.')) ++j;
            fillc(i, j, C_NUM); i = j; continue;
        }
        if (is_idstart(c)) {
            j = i;
            while (j < n && is_idchar(s[j])) ++j;
            getword(s, n, i, 0, w);
            /* keywords are case sensitive in C, getword lowercases:
               compare against original only if it was already lower/same */
            {
                uint8_t k, same = 1;
                for (k = 0; k < j - i && k < 14; ++k) if (s[i + k] != w[k]) { same = 0; break; }
                if (same && in_list(kw_c, w)) fillc(i, j, C_KEY);
                else if (in_list(ty_c, w)) fillc(i, j, C_TYPE);
                else if (!same) {
                    /* case-sensitive types like FILE, NULL */
                    char u[16]; uint8_t m = j - i; if (m > 14) m = 14;
                    memcpy(u, s + i, m); u[m] = 0;
                    if (in_list(ty_c, u)) fillc(i, j, C_TYPE); else fillc(i, j, C_NORM);
                } else fillc(i, j, C_NORM);
            }
            i = j; continue;
        }
        cls[i++] = C_NORM;
    }
    return st;
}

static uint8_t hl_bas(const char *s, uint8_t n, uint8_t st)
{
    uint8_t i = 0, j, c;
    char w[16];

    /* leading line number */
    while (i < n && (s[i] == ' ')) cls[i++] = C_NORM;
    j = i;
    while (j < n && is_digit(s[j])) ++j;
    fillc(i, j, C_LNO);
    i = j;
    while (i < n) {
        c = s[i];
        if (c == '"') {
            j = i + 1;
            while (j < n && s[j] != '"') ++j;
            if (j < n) ++j;
            fillc(i, j, C_STR); i = j; continue;
        }
        if (is_digit(c) || (c == '.' && i + 1 < n && is_digit(s[i + 1])) ||
            (c == '$' && i + 1 < n && is_hex(s[i + 1]))) {
            j = i + 1;
            if (c == '$') { while (j < n && is_hex(s[j])) ++j; }
            else while (j < n && (is_digit(s[j]) || s[j] == '.')) ++j;
            fillc(i, j, C_NUM); i = j; continue;
        }
        if (is_idstart(c)) {
            j = i;
            while (j < n && (is_idchar(s[j]) || s[j] == '$' || s[j] == '%')) ++j;
            getword(s, n, i, 1, w);
            if (!strcmp(w, "rem")) { fillc(i, n, C_COM); return st; }
            if (in_list(kw_bas, w)) fillc(i, j, C_KEY);
            else if (in_list(fn_bas, w)) fillc(i, j, C_TYPE);
            else fillc(i, j, C_NORM);
            i = j; continue;
        }
        cls[i++] = C_NORM;
    }
    return st;
}

static uint8_t hl_asm(const char *s, uint8_t n, uint8_t st)
{
    uint8_t i = 0, j, c, opdone = 0;
    char w[16];

    if (n && s[0] != ' ' && s[0] != '\t' && s[0] != ';' && s[0] != '.' &&
        s[0] != '!' && s[0] != '*' && s[0] != '#') {
        /* label at column 0 */
        j = 0;
        while (j < n && s[j] != ' ' && s[j] != '\t' && s[j] != ':' && s[j] != ';' && s[j] != '=') ++j;
        if (j < n && s[j] == ':') ++j;
        fillc(0, j, C_LAB);
        i = j;
    }
    while (i < n) {
        c = s[i];
        if (c == ' ' || c == '\t') { cls[i++] = C_NORM; continue; }
        if (c == ';') { fillc(i, n, C_COM); return st; }
        if (c == '"' || c == '\'') {
            j = i + 1;
            while (j < n && s[j] != c) { if (s[j] == '\\') ++j; ++j; }
            if (j < n) ++j;
            if (j > n) j = n;
            fillc(i, j, C_STR); i = j; opdone = 1; continue;
        }
        if (c == '$' || c == '%' ) {
            j = i + 1;
            while (j < n && is_hex(s[j])) ++j;
            if (j > i + 1) { fillc(i, j, C_NUM); i = j; opdone = 1; continue; }
            cls[i++] = C_NORM; continue;
        }
        if (is_digit(c)) {
            j = i + 1;
            while (j < n && is_idchar(s[j])) ++j;
            fillc(i, j, C_NUM); i = j; opdone = 1; continue;
        }
        if ((c == '.' || c == '!') && !opdone && i + 1 < n && is_idstart(s[i + 1])) {
            j = i + 1;
            while (j < n && is_idchar(s[j])) ++j;
            fillc(i, j, C_PRE); i = j; opdone = 1; continue;
        }
        if (is_idstart(c) || c == '@') {
            j = i + 1;
            while (j < n && (is_idchar(s[j]) || s[j] == '.')) ++j;
            getword(s, n, i + (c == '@'), 0, w);
            if (!opdone && c != '@') {
                opdone = 1;
                if (in_list(op_asm, w)) { fillc(i, j, C_KEY); i = j; continue; }
            }
            opdone = 1;
            if (j - i == 1 && (w[0] == 'a' || w[0] == 'x' || w[0] == 'y') && i > 0)
                fillc(i, j, C_REG);
            else
                fillc(i, j, C_NORM);
            i = j; continue;
        }
        cls[i++] = C_NORM;
    }
    return st;
}

static uint8_t highlight(const char *s, uint16_t n16, uint8_t st)
{
    uint8_t n = n16 > 255 ? 255 : (uint8_t)n16;
    memset(cls, C_NORM, n + 1);
    switch (lang) {
        case L_C:   return hl_c(s, n, st);
        case L_BAS: return hl_bas(s, n, st);
        case L_ASM: return hl_asm(s, n, st);
    }
    return st;
}

/* line begin state (only C needs it) */
static uint8_t line_state(uint16_t l)
{
    uint8_t st;
    if (lang != L_C) return 0;
    while (cstate_valid < l) {
        st = (cstate[cstate_valid >> 3] >> (cstate_valid & 7)) & 1;
        st = highlight(buf + lstart[cstate_valid], linelen(cstate_valid), st);
        ++cstate_valid;
        if (st & ST_BLOCK) cstate[cstate_valid >> 3] |= 1 << (cstate_valid & 7);
        else cstate[cstate_valid >> 3] &= ~(1 << (cstate_valid & 7));
    }
    if (l == 0) return 0;
    return (cstate[l >> 3] >> (l & 7)) & 1;
}

static void detect_lang(const char *name)
{
    /* table: name, NUL, language byte ... */
    static const char ext[] =
        "c\0\1h\0\1bas\0\2bi\0\2asm\0\3s\0\3inc\0\3a65\0\3a\0\3";
    const char *e = strrchr(name, '.');
    const char *t = ext;
    char lc[6];
    uint8_t n = 0;
    if (!e) return;
    for (++e; *e && n < 5; ++e) lc[n++] = (*e >= 'A' && *e <= 'Z') ? *e + 32 : *e;
    lc[n] = 0;
    cstate_valid = 0;
    while (*t) {
        n = strlen(t);
        if (!strcmp(lc, t)) { lang = t[n + 1]; return; }
        t += n + 2;
    }
}

/* ------------------------------------------------------------------ */
/* drawing                                                             */
/* ------------------------------------------------------------------ */
static uint16_t visual_col(uint16_t l, uint16_t upto)
{
    const char *s = buf + lstart[l];
    uint16_t i, v = 0;
    for (i = 0; i < upto; ++i)
        v += (s[i] == '\t') ? tabw - (v % tabw) : 1;
    return v;
}

static uint8_t gutter(void) { return shownum ? 5 : 0; }

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

static void draw_row(uint8_t row)
{
    uint16_t l = top + row;
    uint8_t g = gutter();
    uint8_t x = 0;
    uint16_t vcol = 0, n, i;
    const char *s;
    uint8_t st, ch, col;
    uint8_t width = scrw;

    vera_at(0, row);
    if (l >= nlines) {
        if (g) { /* nothing */ }
        VERA.data0 = '~'; VERA.data0 = C_LAB;
        for (x = 1; x < width; ++x) { VERA.data0 = ' '; VERA.data0 = C_NORM; }
        return;
    }
    s = buf + lstart[l];
    n = linelen(l);
    st = line_state(l);
    highlight(s, n, st);
    x = 0;
    if (g) {
        char nb[6];
        uint16_t v = l + 1; uint8_t p = 3;
        memset(nb, ' ', 5); nb[5] = 0;
        do { nb[p--] = '0' + v % 10; v /= 10; } while (v && p < 4);
        for (; x < 4; ++x) { VERA.data0 = nb[x]; VERA.data0 = C_LNO; }
        VERA.data0 = ' '; VERA.data0 = C_NORM; ++x;
    }
    for (i = 0; i < n && x < width; ++i) {
        ch = s[i];
        col = (i < 255) ? cls[i] : C_NORM;
        if (ch == '\t') {
            uint16_t w = tabw - (vcol % tabw);
            while (w--) {
                if (vcol >= leftcol && x < width) { VERA.data0 = ' '; VERA.data0 = col; ++x; }
                ++vcol;
            }
        } else {
            if (ch < 32) ch = '?';
            if (vcol >= leftcol) { VERA.data0 = ch; VERA.data0 = col; ++x; }
            ++vcol;
        }
    }
    for (; x < width; ++x) { VERA.data0 = ' '; VERA.data0 = C_NORM; }
}

static uint8_t cursor_scrx(void)
{
    return (uint8_t)(visual_col(cy, cx) - leftcol + gutter());
}

static char *scat(char *d, const char *src)
{
    while (*src) *d++ = *src++;
    return d;
}

static void draw_status(const char *cmdline)
{
    static const char *const lname[] = { "text", "C", "BASIC", "asm" };
    char line[84];
    char *d = line;

    if (cmdline) {
        draw_text(scrh - 1, cmdline, (C_BG << 4) | C_NORM);
        return;
    }
    if (mode == 1) d = scat(d, "-- INSERT --");
    else if (mode == 2) d = scat(d, "-- REPLACE --");
    else {
        d = scat(d, fname[0] ? fname : "[No Name]");
        if (modified) d = scat(d, " [+]");
    }
    *d++ = ' ';
    d = scat(d, msg);
    while (d < line + scrw) *d++ = ' ';
    /* right side, built backwards from a scratch string */
    {
        char r[24], *e = r;
        e = scat(e, lname[lang]);
        *e++ = ' ';
        utoa(cy + 1, e, 10); e += strlen(e);
        *e++ = ',';
        utoa(cx + 1, e, 10); e += strlen(e);
        *e = 0;
        memcpy(line + scrw - (e - r), r, e - r);
    }
    line[scrw] = 0;
    draw_text(scrh - 1, line, (C_NORM << 4) | C_BG);
}

static void place_cursor(void)
{
    uint8_t x = cursor_scrx();
    uint8_t y = (uint8_t)(cy - top);
    uint8_t col;
    uint8_t ch;
    vera_at(x, y);
    ch = VERA.data0;
    col = (mode == 0) ? ((C_NORM << 4) | C_BG) : ((C_LAB << 4) | C_BG);
    put_cell(x, y, ch, col);
}

static void scroll_to_cursor(uint8_t center)
{
    uint16_t vc = visual_col(cy, cx);
    uint8_t g = gutter();
    uint8_t w = scrw - g;
    if (cy < top) { top = center ? (cy > textrows / 2 ? cy - textrows / 2 : 0) : cy; redraw_all = 1; }
    else if (cy >= top + textrows) {
        top = center ? cy - textrows / 2 : cy - textrows + 1; redraw_all = 1;
    }
    if (vc < leftcol) { leftcol = vc; redraw_all = 1; }
    else if (vc >= leftcol + w) { leftcol = vc - w + 1; redraw_all = 1; }
}

static void refresh(uint8_t center)
{
    uint8_t r;
    scroll_to_cursor(center);
    if (redraw_all) {
        for (r = 0; r < textrows; ++r) draw_row(r);
        redraw_all = 0;
    } else {
        if (prev_cy >= top && prev_cy < top + textrows && prev_cy != cy)
            draw_row((uint8_t)(prev_cy - top));
        draw_row((uint8_t)(cy - top));
    }
    prev_cy = cy;
    draw_status(0);
    place_cursor();
}

/* ------------------------------------------------------------------ */
/* cursor helpers                                                      */
/* ------------------------------------------------------------------ */
static void clamp_cx(void)
{
    uint16_t n = linelen(cy);
    uint16_t maxx = (mode == 0 && n) ? n - 1 : n;
    if (cx > maxx) cx = maxx;
}

static void set_want(void) { want = visual_col(cy, cx); }

static void apply_want(void)
{
    uint16_t n = linelen(cy), i, v = 0;
    const char *s = buf + lstart[cy];
    for (i = 0; i < n; ++i) {
        uint16_t w = (s[i] == '\t') ? tabw - (v % tabw) : 1;
        if (v + w > want) break;
        v += w;
    }
    cx = i;
    clamp_cx();
}

static void goto_line(uint16_t l)
{
    if (l >= nlines) l = nlines - 1;
    cy = l;
    cx = 0;
    {
        const char *s = buf + lstart[cy];
        uint16_t n = linelen(cy);
        while (cx < n && (s[cx] == ' ' || s[cx] == '\t')) ++cx;
        clamp_cx();
    }
    set_want();
}

static void move_down(uint16_t n)
{
    if (cy + n >= nlines) cy = nlines - 1; else cy += n;
    apply_want();
}
static void move_up(uint16_t n)
{
    cy = (n > cy) ? 0 : cy - n;
    apply_want();
}

static uint8_t is_word(char c) { return is_idchar(c); }

static uint16_t cur_pos(void) { return lstart[cy] + cx; }

static void set_pos(uint16_t pos)
{
    cy = find_line(pos);
    cx = pos - lstart[cy];
    clamp_cx();
    set_want();
}

static uint16_t word_fwd(uint16_t p)
{
    if (p >= len - 1) return len - 1;
    if (is_word(buf[p])) while (p < len - 1 && is_word(buf[p])) ++p;
    else if (buf[p] != ' ' && buf[p] != '\t' && buf[p] != '\n') {
        while (p < len - 1 && !is_word(buf[p]) && buf[p] != ' ' &&
               buf[p] != '\t' && buf[p] != '\n') ++p;
    }
    while (p < len - 1 && (buf[p] == ' ' || buf[p] == '\t' ||
           (buf[p] == '\n' && p + 1 < len && buf[p - 1] != '\n' ? 0 : 0))) ++p;
    if (p < len - 1 && buf[p] == '\n') { ++p; /* move onto next line start */
        while (p < len - 1 && (buf[p] == ' ' || buf[p] == '\t')) ++p; }
    return p;
}

static uint16_t word_back(uint16_t p)
{
    if (p == 0) return 0;
    --p;
    while (p > 0 && (buf[p] == ' ' || buf[p] == '\t' || buf[p] == '\n')) --p;
    if (is_word(buf[p])) while (p > 0 && is_word(buf[p - 1])) --p;
    else while (p > 0 && !is_word(buf[p - 1]) && buf[p - 1] != ' ' &&
                buf[p - 1] != '\t' && buf[p - 1] != '\n') --p;
    return p;
}

/* ------------------------------------------------------------------ */
/* register (yank) handling                                            */
/* ------------------------------------------------------------------ */
static void yank_range(uint16_t a, uint16_t b, uint8_t linewise)
{
    uint16_t n = b - a;
    if (n > REGSZ) { n = REGSZ; setmsg("Yank truncated"); }
    memcpy(reg, buf + a, n);
    reglen = n;
    reglines = linewise;
}

static void delete_range(uint16_t a, uint16_t b, uint8_t linewise)
{
    yank_range(a, b, linewise);
    buf_delete(a, b - a);
}

static void line_range(uint16_t l, uint16_t cnt, uint16_t *a, uint16_t *b)
{
    uint16_t last = l + cnt;
    if (last > nlines) last = nlines;
    *a = lstart[l];
    *b = lstart[last];
}

/* ------------------------------------------------------------------ */
/* search                                                              */
/* ------------------------------------------------------------------ */
static uint8_t do_search(int8_t dir, uint8_t from_next)
{
    uint16_t plen = strlen(lastsearch), p, start;
    uint16_t i;
    if (!plen) { setmsg("No previous search"); return 0; }
    start = cur_pos();
    if (dir > 0) {
        p = start + (from_next ? 1 : 0);
        for (i = 0; i < len; ++i, ++p) {
            if (p >= len) p -= len;
            if (p + plen <= len && buf[p] == lastsearch[0] &&
                !memcmp(buf + p, lastsearch, plen)) { set_pos(p); return 1; }
        }
    } else {
        p = start;
        for (i = 0; i < len; ++i) {
            p = p ? p - 1 : len - 1;
            if (p + plen <= len && buf[p] == lastsearch[0] &&
                !memcmp(buf + p, lastsearch, plen)) { set_pos(p); return 1; }
        }
    }
    setmsg("Pattern not found");
    return 0;
}

static void match_bracket(void)
{
    uint16_t p = cur_pos(), q;
    char c = buf[p], t;
    int8_t d;
    uint16_t depth = 0;
    switch (c) {
        case '(': t = ')'; d = 1; break;
        case '[': t = ']'; d = 1; break;
        case '{': t = '}'; d = 1; break;
        case ')': t = '('; d = -1; break;
        case ']': t = '['; d = -1; break;
        case '}': t = '{'; d = -1; break;
        default: return;
    }
    q = p;
    for (;;) {
        if (d > 0) { if (++q >= len) return; }
        else { if (q == 0) return; --q; }
        if (buf[q] == c) ++depth;
        else if (buf[q] == t) {
            if (!depth) { set_pos(q); return; }
            --depth;
        }
    }
}

/* ------------------------------------------------------------------ */
/* file I/O                                                            */
/* ------------------------------------------------------------------ */
/* CMDR-DOS wants PETSCII style names: a-z -> $41-$5A, A-Z -> $C1-$DA */
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
        /* 62 = file not found, etc */
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
    uint8_t ok;
    strncpy(fname, name, FNLEN); fname[FNLEN] = 0;
    lang = L_NONE;
    ok = load_file(name);
    if (!ok) {
        new_buffer();
    } else {
        cy = cx = want = top = leftcol = 0;
        modified = 0; uvalid = 0;
        setmsg(truncated ? "File truncated (too big)!" : "File loaded");
    }
    detect_lang(name);
    redraw_all = 1;
}

/* ------------------------------------------------------------------ */
/* line reading for ':' and '/' prompts                                */
/* ------------------------------------------------------------------ */
static uint8_t read_line(char prompt, char *out, uint8_t max)
{
    uint8_t n = 0, k;
    char line[84];
    for (;;) {
        line[0] = prompt;
        memcpy(line + 1, out, n);
        line[n + 1] = '_';
        line[n + 2] = 0;
        draw_status(line);
        k = getkey();
        if (k == 0x1B) { out[0] = 0; return 0; }
        if (k == '\r' || k == '\n') { out[n] = 0; return 1; }
        if (k == 0x14 || k == 0x08 || k == 0x7F) {
            if (!n) { out[0] = 0; return 0; }
            --n; continue;
        }
        if (k >= 32 && k < 127 && n < max - 1) out[n++] = k;
    }
}

/* ------------------------------------------------------------------ */
/* :commands                                                           */
/* ------------------------------------------------------------------ */
static uint16_t parse_num(const char **p)
{
    uint16_t v = 0;
    while (is_digit(**p)) { v = v * 10 + (**p - '0'); ++(*p); }
    return v;
}

static void exec_cmd(char *cmd)
{
    const char *p = cmd;
    uint16_t l1 = 0, l2 = 0;
    uint8_t haverange = 0, bang = 0;
    char word[12];
    uint8_t w = 0;

    while (*p == ' ') ++p;
    if (*p == '%') { l1 = 0; l2 = nlines - 1; haverange = 1; ++p; }
    else if (is_digit(*p) || *p == '$' || *p == '.') {
        if (*p == '$') { l1 = nlines - 1; ++p; }
        else if (*p == '.') { l1 = cy; ++p; }
        else { l1 = parse_num(&p); if (l1) --l1; }
        l2 = l1; haverange = 1;
        if (*p == ',') {
            ++p;
            if (*p == '$') { l2 = nlines - 1; ++p; }
            else if (*p == '.') { l2 = cy; ++p; }
            else { l2 = parse_num(&p); if (l2) --l2; }
        }
    }
    while (*p == ' ') ++p;
    if (!*p) {
        if (haverange) { goto_line(l2); }
        return;
    }
    while (is_idstart(*p) && w < 10) word[w++] = *p++;
    word[w] = 0;
    if (*p == '!') { bang = 1; ++p; }
    while (*p == ' ') ++p;

    if (!strcmp(word, "w") || !strcmp(word, "write")) {
        if (*p) { strncpy(fname, p, FNLEN); detect_lang(fname); }
        if (!fname[0]) { setmsg("No file name"); return; }
        if (truncated && !bang) { setmsg("File was truncated; use :w! to force"); return; }
        save_file(fname);
        redraw_all = 1;
    } else if (!strcmp(word, "q") || !strcmp(word, "quit")) {
        if (modified && !bang) setmsg("No write since last change (add ! to override)");
        else quit = 1;
    } else if (!strcmp(word, "wq") || !strcmp(word, "x") || !strcmp(word, "exit")) {
        if (*p) strncpy(fname, p, FNLEN);
        if (!fname[0]) { setmsg("No file name"); return; }
        if (save_file(fname)) quit = 1;
    } else if (!strcmp(word, "e") || !strcmp(word, "edit")) {
        if (modified && !bang) { setmsg("No write since last change (add ! to override)"); return; }
        if (*p) open_file(p);
        else if (fname[0]) open_file(fname);
        else setmsg("No file name");
    } else if (!strcmp(word, "set") || !strcmp(word, "se")) {
        if (!strncmp(p, "syntax=", 7) || !strncmp(p, "syn=", 4) || !strncmp(p, "ft=", 3)) {
            const char *v = strchr(p, '=') + 1;
            if (!strcmp(v, "c")) lang = L_C;
            else if (!strcmp(v, "basic") || !strcmp(v, "bas")) lang = L_BAS;
            else if (!strcmp(v, "asm") || !strcmp(v, "s")) lang = L_ASM;
            else lang = L_NONE;
            cstate_valid = 0; redraw_all = 1;
        } else if (!strncmp(p, "ts=", 3)) {
            const char *v = p + 3; uint16_t t = parse_num(&v);
            if (t >= 1 && t <= 16) { tabw = t; redraw_all = 1; }
        } else if (!strcmp(p, "nu") || !strcmp(p, "number")) { shownum = 1; redraw_all = 1; }
        else if (!strcmp(p, "nonu") || !strcmp(p, "nonumber")) { shownum = 0; redraw_all = 1; }
        else if (!strcmp(p, "ai") || !strcmp(p, "autoindent")) autoind = 1;
        else if (!strcmp(p, "noai") || !strcmp(p, "noautoindent")) autoind = 0;
        else setmsg("Unknown option");
    } else if (!strcmp(word, "syntax") || !strcmp(word, "syn")) {
        if (!strcmp(p, "c")) lang = L_C;
        else if (!strcmp(p, "basic") || !strcmp(p, "bas")) lang = L_BAS;
        else if (!strcmp(p, "asm")) lang = L_ASM;
        else lang = L_NONE;
        cstate_valid = 0; redraw_all = 1;
    } else if (!strcmp(word, "help") || !strcmp(word, "h")) {
        setmsg(":w :q :wq :e f :set syntax=c|basic|asm|none ts=N nu :%s/a/b/g");
    } else {
        setmsg("Not an editor command");
    }
}

/* ------------------------------------------------------------------ */
/* insert mode                                                         */
/* ------------------------------------------------------------------ */
static void insert_char(char c)
{
    if (buf_insert(cur_pos(), &c, 1)) ++cx;
}

static void do_newline(void)
{
    char ins[40];
    uint8_t n = 1;
    ins[0] = '\n';
    if (autoind) {
        const char *s = buf + lstart[cy];
        uint16_t i = 0;
        while (i < cx && i < 36 && (s[i] == ' ' || s[i] == '\t')) ins[n++] = s[i++];
    }
    if (buf_insert(cur_pos(), ins, n)) {
        ++cy; cx = n - 1;
    }
}

static void insert_loop(void)
{
    uint8_t k;
    for (;;) {
        refresh(0);
        k = getkey();
        if (k == 0x1B) break;
        msg[0] = 0;
        switch (k) {
            case '\r': case '\n': do_newline(); break;
            case 0x14: case 0x08: case 0x7F:        /* backspace */
                if (cx > 0) { --cx; buf_delete(cur_pos(), 1); }
                else if (cy > 0) {
                    cx = linelen(cy - 1); --cy;
                    buf_delete(cur_pos(), 1);
                }
                break;
            case 0x19: /* delete */
                if (cx < linelen(cy) || cy + 1 < nlines) buf_delete(cur_pos(), 1);
                break;
            case 0x9D: if (cx) --cx; break;
            case 0x1D: if (cx < linelen(cy)) ++cx; break;
            case 0x91: if (cy) { --cy; if (cx > linelen(cy)) cx = linelen(cy); } break;
            case 0x11: if (cy + 1 < nlines) { ++cy; if (cx > linelen(cy)) cx = linelen(cy); } break;
            case '\t': insert_char('\t'); break;
            default:
                if (k >= 32 && k != 127) insert_char(k);
        }
    }
    mode = 0;
    if (cx) --cx;
    clamp_cx();
    set_want();
}

static void replace_loop(void)
{
    uint8_t k;
    for (;;) {
        refresh(0);
        k = getkey();
        if (k == 0x1B) break;
        if (k == '\r') { do_newline(); continue; }
        if (k == 0x14 || k == 0x08) { if (cx) --cx; continue; }
        if (k < 32) continue;
        if (cx < linelen(cy)) buf_delete(cur_pos(), 1);
        insert_char(k);
    }
    mode = 0;
    if (cx) --cx;
    clamp_cx();
    set_want();
}

static void start_insert(void)
{
    mode = 1;
    msg[0] = 0;
    insert_loop();
}

/* ------------------------------------------------------------------ */
/* normal mode                                                         */
/* ------------------------------------------------------------------ */
static void open_line(uint8_t below)
{
    uint16_t pos;
    char ins[40];
    uint8_t n = 0;
    const char *s = buf + lstart[cy];
    uint16_t i = 0, ll = linelen(cy);
    if (autoind)
        while (i < ll && n < 36 && (s[i] == ' ' || s[i] == '\t')) ins[n++] = s[i++];
    if (below) {                      /* "\n" + indent, before this line's newline */
        memmove(ins + 1, ins, n);
        ins[0] = '\n';
        ++n;
        pos = lstart[cy + 1] - 1;
    } else {
        ins[n++] = '\n';
        pos = lstart[cy];
    }
    snap();
    if (buf_insert(pos, ins, n)) {
        if (below) ++cy;
        cx = n - 1;
        mode = 1;
        insert_loop();
    }
}

static void paste(uint8_t after, uint16_t count)
{
    uint16_t pos, c;
    if (!reglen) { setmsg("Nothing in register"); return; }
    snap();
    if (reglines) {
        if (after) {
            pos = lstart[cy + 1] - 1;
            for (c = 0; c < count; ++c)
                if (!buf_insert(pos, "\n", 1) || !buf_insert(pos + 1, reg, reglen - 1)) break;
            cy = find_line(pos + 1);
        } else {
            pos = lstart[cy];
            for (c = 0; c < count; ++c) if (!buf_insert(pos, reg, reglen)) break;
            cy = find_line(pos);
        }
        goto_line(cy);
    } else {
        pos = cur_pos();
        if (after && linelen(cy)) ++pos;
        for (c = 0; c < count; ++c)
            if (!buf_insert(pos, reg, reglen)) break;
        set_pos(pos + reglen * count - 1);
    }
}

static void join_lines(uint16_t count)
{
    uint16_t c, pos, n;
    snap();
    if (count < 2) count = 2;
    for (c = 1; c < count; ++c) {
        if (cy + 1 >= nlines) break;
        pos = lstart[cy + 1] - 1;           /* the newline */
        n = 1;
        while (pos + n < len - 1 && (buf[pos + n] == ' ' || buf[pos + n] == '\t')) ++n;
        buf_delete(pos, n);
        if (linelen(cy) && pos > lstart[cy] && buf[pos - 1] != ' ' &&
            buf[pos] != '\n' ) {
            buf_insert(pos, " ", 1);
        }
        cx = pos - lstart[cy];
    }
    clamp_cx(); set_want();
}

/* run an operator (d/c/y) over a motion; returns 1 if consumed */
static void operator_cmd(uint8_t op, uint16_t count)
{
    uint8_t k, mcount_set = 0;
    uint16_t mcount = 0, a, b, p0 = cur_pos(), p1;

    for (;;) {
        k = getkey();
        if (k >= '1' && k <= '9' || (mcount_set && k == '0')) {
            mcount = mcount * 10 + (k - '0'); mcount_set = 1; continue;
        }
        break;
    }
    if (mcount_set) count *= mcount;
    if (!count) count = 1;

    if (k == 0x1B) return;
    if (k == op) {                            /* dd, yy, cc */
        line_range(cy, count, &a, &b);
        if (op == 'y') { yank_range(a, b, 1); setmsg("yanked"); return; }
        snap();
        if (op == 'c') {
            /* keep indentation-less empty line */
            yank_range(a, b, 1);
            buf_delete(a, b - a - 1);
            cx = 0;
            start_insert();
            return;
        }
        delete_range(a, b, 1);
        if (cy >= nlines) cy = nlines - 1;
        goto_line(cy);
        return;
    }
    switch (k) {
        case 'w': {
            uint16_t q = p0, c;
            uint16_t eol = lstart[cy + 1] - 1;
            for (c = 0; c < count; ++c) q = word_fwd(q);
            if (op == 'c') {              /* cw acts like ce */
                q = p0;
                for (c = 0; c < count; ++c) {
                    if (q < len - 1 && buf[q] != ' ' && buf[q] != '\t') {
                        if (is_word(buf[q])) while (q < len - 1 && is_word(buf[q])) ++q;
                        else ++q;
                    }
                    if (c + 1 < count) while (q < len - 1 && (buf[q] == ' ' || buf[q] == '\t')) ++q;
                }
            }
            if (q > eol && count == 1) q = eol;
            a = p0; b = q; break;
        }
        case '$':
            a = p0; b = lstart[cy + count] - 1;
            if (cy + count > nlines) b = lstart[nlines] - 1;
            break;
        case '0': a = lstart[cy]; b = p0; break;
        case '^': {
            uint16_t q = lstart[cy];
            while (buf[q] == ' ' || buf[q] == '\t') ++q;
            if (q < p0) { a = q; b = p0; } else { a = p0; b = q; }
            break;
        }
        case 'b': {
            uint16_t q = p0, c;
            for (c = 0; c < count; ++c) q = word_back(q);
            a = q; b = p0; break;
        }
        case 'l': a = p0; b = p0 + count; if (b > lstart[cy + 1] - 1) b = lstart[cy + 1] - 1; break;
        case 'h': a = (p0 > lstart[cy] + count) ? p0 - count : lstart[cy]; b = p0; break;
        default: return;
    }
    if (a >= b) { if (op == 'c') start_insert(); return; }
    snap();
    if (op == 'y') { yank_range(a, b, k == 'L'); set_pos(a); return; }
    delete_range(a, b, k == 'L');
    if (k == 'L') {
        if (cy >= nlines) cy = nlines - 1;
        goto_line(cy);
        return;
    }
    p1 = a;
    set_pos(p1);
    if (op == 'c') { cx = p1 - lstart[cy]; start_insert(); }
}

static void normal_key(uint8_t k, uint16_t count)
{
    uint16_t c, n, p;
    uint8_t k2;

    msg[0] = (k == ':' || k == '/' || k == '?') ? msg[0] : 0;
    switch (k) {
    /* movement */
    case 'h': case 0x9D: case 0x08:
        cx = (cx > count) ? cx - count : 0; set_want(); break;
    case 'l': case 0x1D: case ' ':
        cx += count; clamp_cx(); set_want(); break;
    case 'j': case 0x11: case '\n':
        move_down(count); break;
    case 'k': case 0x91:
        move_up(count); break;
    case '0': cx = 0; set_want(); break;
    case '^': goto_line(cy); break;
    case '$': cx = linelen(cy); clamp_cx(); want = 0xFFF; break;
    case 'w': p = cur_pos(); for (c = 0; c < count; ++c) p = word_fwd(p); set_pos(p); break;
    case 'b': p = cur_pos(); for (c = 0; c < count; ++c) p = word_back(p); set_pos(p); break;
    case 'G':
        goto_line(count ? count - 1 : nlines - 1); refresh(1); break;
    case 'g':
        k2 = getkey();
        if (k2 == 'g') goto_line(count ? count - 1 : 0);
        break;
    case 0x06: /* ^F */ move_down(textrows - 2); top = cy; break;
    case 0x02: /* ^B */ move_up(textrows - 2); break;
    case '%': match_bracket(); break;

    /* search */
    case '/': case '?': {
        char t[32];
        t[0] = 0;
        if (read_line(k, t, sizeof t) && t[0]) strcpy(lastsearch, t);
        searchdir = (k == '/') ? 1 : -1;
        if (do_search(searchdir, 1)) refresh(1);
        break;
    }
    case 'n': for (c = 0; c < count; ++c) do_search(searchdir, 1); break;
    case 'N': for (c = 0; c < count; ++c) do_search(-searchdir, 1); break;

    /* entering insert */
    case 'i': snap(); start_insert(); break;
    case 'a': snap(); if (linelen(cy)) ++cx; start_insert(); break;
    case 'I': snap(); goto_line(cy); cx = 0;
        { const char *s = buf + lstart[cy]; while (cx < linelen(cy) && (s[cx]==' '||s[cx]=='\t')) ++cx; }
        start_insert(); break;
    case 'A': snap(); cx = linelen(cy); start_insert(); break;
    case 'o': open_line(1); break;
    case 'O': open_line(0); break;
    case 'R': snap(); mode = 2; replace_loop(); break;

    /* editing */
    case 'x': case 0x19:
        n = linelen(cy) - cx;
        if (!n) break;
        if (n > count) n = count;
        snap();
        delete_range(cur_pos(), cur_pos() + n, 0);
        clamp_cx(); set_want(); break;
    case 'X':
        n = cx > count ? count : cx;
        if (!n) break;
        snap();
        delete_range(cur_pos() - n, cur_pos(), 0);
        cx -= n; set_want(); break;
    case 'D': case 'C':
        snap();
        p = lstart[cy + 1] - 1;
        if (p > cur_pos()) delete_range(cur_pos(), p, 0);
        if (k == 'C') { cx = linelen(cy); start_insert(); }
        else { clamp_cx(); set_want(); }
        break;
    case 's':
        snap();
        n = linelen(cy) - cx; if (n > count) n = count;
        if (n) delete_range(cur_pos(), cur_pos() + n, 0);
        start_insert(); break;
    case 'r':
        k2 = getkey();
        if (k2 >= 32 && k2 != 127 && cx + count <= linelen(cy)) {
            snap();
            for (c = 0; c < count; ++c) { buf_delete(cur_pos(), 1); buf_insert(cur_pos(), (char *)&k2, 1); ++cx; }
            --cx; set_want();
        }
        break;
    case 'J': join_lines(count); break;
    case 'd': case 'c': case 'y': operator_cmd(k, count ? count : 1); break;
    case 'Y': {
        uint16_t a, b; line_range(cy, count ? count : 1, &a, &b); yank_range(a, b, 1); break; }
    case 'p': paste(1, count ? count : 1); break;
    case 'P': paste(0, count ? count : 1); break;
    case 'u': do_undo(); clamp_cx(); set_want(); break;
    case 'Z':
        k2 = getkey();
        if (k2 == 'Z') { if (!fname[0] || save_file(fname)) quit = 1; }
        else if (k2 == 'Q') quit = 1;
        break;
    case ':': {
        char t[CMDLEN];
        t[0] = 0;
        if (read_line(':', t, sizeof t) && t[0]) { msg[0] = 0; exec_cmd(t); }
        break;
    }
    }
}

/* ------------------------------------------------------------------ */
static void editor(void)
{
    uint8_t k;
    uint16_t count;
    uint8_t center;

    redraw_all = 1;
    while (!quit) {
        center = 0;
        refresh(center);
        k = getkey();
        count = 0;
        if (k >= '1' && k <= '9') {
            count = k - '0';
            for (;;) {
                k = getkey();
                if (is_digit(k)) count = count * 10 + (k - '0');
                else break;
            }
        }
        if (k == 0x1B) { count = 0; msg[0] = 0; continue; }
        if (!count && (k == 'x' || k == 'X' || k == 'p' || k == 'P' || k == 'J' ||
                       k == 'h' || k == 'l' || k == 'j' || k == 'k' || k == 'w' ||
                       k == 'b' || k == 'r' || k == 's' ||
                       k == 0x9D || k == 0x1D || k == 0x11 || k == 0x91 || k == ' ' ||
                       k == 'n' || k == 'N' || k == 'd' || k == 'c' || k == 'y'))
            count = 1;
        if (k == 'G' || k == 'g') center = 1;
        normal_key(k, count);
        if (center) refresh(1);
    }
}

#ifdef SELFTEST
extern const char *selftest_keys;
#endif

int main(void)
{
    init_screen();
    iso_mode();
    {   /* clear screen to black and hide the kernal cursor */
        uint8_t y, x;
        for (y = 0; y < scrh; ++y) {
            vera_at(0, y);
            for (x = 0; x < scrw; ++x) { VERA.data0 = ' '; VERA.data0 = (C_BG << 4) | C_NORM; }
        }
    }
    VERA.display.border = 0;
    new_buffer();
    fname[0] = 0;
    msg[0] = 0;
#ifdef SELFTEST
    open_file("test.c");
    selfkeys = selftest_keys;
#endif
    setmsg("vi for X16 - :e <file>  :help");
    editor();
    asm("lda #$8f");     /* ISO mode off (back to PETSCII) */
    asm("jsr $ffd2");
    asm("lda #$93");     /* clear screen */
    asm("jsr $ffd2");
    return 0;
}
