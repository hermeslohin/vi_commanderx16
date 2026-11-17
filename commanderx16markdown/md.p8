; MD - a Markdown editor for the Commander X16  (Prog8, target cx16)
;
;  - modeless editor with Markdown syntax colouring and soft line wrap
;  - Ctrl-P / F5 toggles a rendered preview: headings, bold, italic, code,
;    links, lists, block quotes, rules, fenced code and boxed tables
;  - Ctrl-G / F4 opens a table-of-contents jump menu; a line containing
;    [TOC] expands to a contents list in the preview
;  - bold / italic faces are synthesised from the ISO charset at start-up
;    and stored in the unused upper half of VERA's character set
;
; Draws straight into VERA text memory (ISO mode, so files are plain ASCII).
; This is a port of md.c (cc65).

%import syslib
%zeropage basicsafe

main {
    ; ---------------------------------------------------------------
    ; configuration
    ; ---------------------------------------------------------------
    const uword BUFSZ = 8000
    const uword MAXL  = 500
    const ubyte FNLEN = 40
    const ubyte DEVICE = 8
    const ubyte SW    = 80            ; widest text screen
    const ubyte MAXH  = 100           ; headings tracked for the TOC
    const ubyte MAXC  = 8             ; table columns
    const uword CLSN  = 240           ; chars coloured per editor line
    const ubyte PV_PER_BANK = 51      ; preview rows (2*80 bytes) per 8K bank
    const ubyte PV_BANKS = 10
    const uword PVMAXL = 510          ; PV_PER_BANK * PV_BANKS
    const ubyte UNDO_BANK = 20

    const ubyte NL  = 10
    const ubyte TAB = 9
    const ubyte SP  = 32

    ; keys (ISO mode)
    const ubyte K_DOWN  = $11
    const ubyte K_UP    = $91
    const ubyte K_LEFT  = $9d
    const ubyte K_RIGHT = $1d
    const ubyte K_HOME  = $13
    const ubyte K_END   = $04
    const ubyte K_BKSP  = $14
    const ubyte K_DEL   = $19
    const ubyte K_ESC   = $1b
    const ubyte K_F1 = $85
    const ubyte K_F2 = $89
    const ubyte K_F3 = $86
    const ubyte K_F4 = $8a
    const ubyte K_F5 = $87
    const ubyte K_F6 = $8b
    const ubyte K_F7 = $88
    const ubyte K_F8 = $8c
    const ubyte CTRL_A = 1
    const ubyte CTRL_B = 2
    const ubyte CTRL_E = 5
    const ubyte CTRL_F = 6
    const ubyte CTRL_G = 7
    const ubyte CTRL_K = 11
    const ubyte CTRL_O = 15
    const ubyte CTRL_P = 16
    const ubyte CTRL_R = 18
    const ubyte CTRL_U = 21
    const ubyte CTRL_W = 23
    const ubyte CTRL_X = 24
    const ubyte CTRL_Z = 26

    ; colours (VERA palette indexes)
    const ubyte C_BG   = 0
    const ubyte C_NORM = 15
    const ubyte C_BOLD = 1
    const ubyte C_ITAL = 14
    const ubyte C_CODE = (11 << 4) | 13         ; inline code
    const ubyte C_CODEBLK = (11 << 4) | 1       ; fenced code
    const ubyte C_LINK = 3
    const ubyte C_IMG  = 10
    const ubyte C_STRIKE = 12
    const ubyte C_MARK = 12                     ; markdown punctuation in editor
    const ubyte C_BUL  = 8
    const ubyte C_QBAR = 5
    const ubyte C_TBL  = 12
    const ubyte C_URL  = 11
    const ubyte C_TOC  = 7
    const ubyte C_LAB  = 13

    ; special glyphs living in otherwise unused charset slots
    const ubyte G_H  = 27
    const ubyte G_V  = 28
    const ubyte G_TL = 29
    const ubyte G_TR = 30
    const ubyte G_BL = 31
    const ubyte G_BR = 127
    const ubyte G_T  = 154
    const ubyte G_B  = 155
    const ubyte G_L  = 156
    const ubyte G_R  = 157
    const ubyte G_X  = 158
    const ubyte G_BUL = 159

    ubyte[7] hcol = [C_NORM, 7, 3, 13, 14, 10, 12]

    ; line kinds
    const ubyte LK_BLANK  = 0
    const ubyte LK_FENCE  = 1
    const ubyte LK_ATX    = 2
    const ubyte LK_SETEXT = 3
    const ubyte LK_HR     = 4
    const ubyte LK_LIST   = 5
    const ubyte LK_TABLE  = 6
    const ubyte LK_TOCM   = 7
    const ubyte LK_PARA   = 8

    ; ---------------------------------------------------------------
    ; state
    ; ---------------------------------------------------------------
    uword buf    = memory("buf", 8002, 0)
    uword lstart = memory("lstart", 1004, 0)

    uword blen
    uword nlines
    uword cy
    uword cx
    uword want
    uword top

    ubyte scrw
    ubyte scrh
    ubyte textrows
    ubyte pw
    uword vbase
    uword vstride

    bool modified
    bool truncated
    bool quit
    bool warned
    bool typing
    bool redraw_all
    uword prev_cy
    ubyte[41] fname
    ubyte[80] msg
    ubyte[32] lastsearch

    uword[2] smeta_len
    uword[2] smeta_cx
    uword[2] smeta_cy
    ubyte usel
    bool uvalid

    ubyte[240] cls
    ubyte[52] iobuf2
    ubyte[40] dstat

    ; headings
    uword[100] hl            ; source line
    ubyte[100] hlv           ; level 1..6
    uword[100] hvis          ; preview row
    ubyte hn
    ubyte kind_lvl           ; set by line_kind(): heading level

    ; "effective line": a source line with block-quote markers removed
    uword es
    uword en
    ubyte eq

    ; list parse results
    uword L_ind
    uword L_mk
    uword L_mlen
    uword L_txt
    bool L_ord

    ; atx / link results
    ubyte atx_lvl
    uword atx_off
    uword lk_rb
    uword lk_rp

    ubyte[84] sline
    ubyte[34] rbuf
    ubyte[84] rline
    ubyte[1] chbuf

    ; ---------------------------------------------------------------
    ; small helpers
    ; ---------------------------------------------------------------
    sub slen(uword s) -> ubyte {
        ubyte n = 0
        while @(s + n) != 0
            n++
        return n
    }

    sub copystr(uword dst, uword src, ubyte maxn) {
        ubyte n = 0
        while @(src + n) != 0 and n < maxn {
            @(dst + n) = @(src + n)
            n++
        }
        @(dst + n) = 0
    }

    sub appendstr(uword dst, uword src) {
        ubyte n = slen(dst)
        ubyte i = 0
        while @(src + i) != 0 {
            @(dst + n) = @(src + i)
            n++
            i++
        }
        @(dst + n) = 0
    }

    ; append string src to dst at offset d, return new offset
    sub bcat(uword dst, ubyte d, uword src) -> ubyte {
        while @(src) != 0 {
            @(dst + d) = @(src)
            d++
            src++
        }
        return d
    }

    ; append decimal number
    sub bnum(uword dst, ubyte d, uword v) -> ubyte {
        ubyte[6] tmp
        ubyte t = 0
        repeat {
            tmp[t] = lsb(v % 10) + '0'
            t++
            v /= 10
            if v == 0
                break
        }
        while t != 0 {
            t--
            @(dst + d) = tmp[t]
            d++
        }
        return d
    }

    sub memeq(uword a, uword b, uword n) -> bool {
        uword i = 0
        while i < n {
            if @(a + i) != @(b + i)
                return false
            i++
        }
        return true
    }

    sub has_char(uword s, uword n, ubyte c) -> bool {
        uword i = 0
        while i < n {
            if @(s + i) == c
                return true
            i++
        }
        return false
    }

    sub setmsg(uword s) {
        copystr(&msg, s, 79)
    }

    sub ls(uword i) -> uword {
        return peekw(lstart + (i << 1))
    }

    sub setls(uword i, uword v) {
        pokew(lstart + (i << 1), v)
    }

    ; ---------------------------------------------------------------
    ; keyboard / VERA
    ; ---------------------------------------------------------------
    sub getkey() -> ubyte {
        ubyte k
        ;@SELFTEST-HOOK
        repeat {
            k = cbm.GETIN2()
            if k != 0
                break
        }
        return k
    }

    sub vera_at(ubyte x, ubyte y) {
        cx16.VERA_CTRL &= $fe
        cx16.VERA_ADDR = vbase + (y as uword) * vstride + (x as uword) * 2
        cx16.VERA_ADDR_H = $11
    }

    sub put_cell(ubyte x, ubyte y, ubyte ch, ubyte col) {
        vera_at(x, y)
        cx16.VERA_DATA0 = ch
        cx16.VERA_DATA0 = col
    }

    sub init_screen() {
        ubyte m
        scrw, scrh = cbm.SCREEN()
        textrows = scrh - 2
        if scrw > SW
            pw = SW
        else
            pw = scrw
        cx16.VERA_CTRL &= $fe
        m = cx16.VERA_L1_CONFIG
        when (m >> 4) & 3 {
            0 -> vstride = 64
            1 -> vstride = 128
            2 -> vstride = 256
            else -> vstride = 512
        }
        vbase = ((cx16.VERA_L1_MAPBASE & $7f) as uword) << 9
    }

    sub clear_screen() {
        ubyte y = 0
        ubyte x
        while y < scrh {
            vera_at(0, y)
            x = 0
            while x < scrw {
                cx16.VERA_DATA0 = SP
                cx16.VERA_DATA0 = (C_BG << 4) | C_NORM
                x++
            }
            y++
        }
    }

    ; ---------------------------------------------------------------
    ; fonts: bold, italic and box-drawing glyphs built from the ISO set
    ; ---------------------------------------------------------------
    uword tilebase
    ubyte[8] gg
    ubyte[8] hh

    sub gl_addr(ubyte c) {
        cx16.VERA_CTRL &= $fe
        cx16.VERA_ADDR = tilebase + (c as uword) * 8
        cx16.VERA_ADDR_H = $11
    }

    sub gl_read(ubyte c) {
        ubyte i
        gl_addr(c)
        for i in 0 to 7
            gg[i] = cx16.VERA_DATA0
    }

    sub gl_write(ubyte c) {
        ubyte i
        gl_addr(c)
        for i in 0 to 7
            cx16.VERA_DATA0 = hh[i]
    }

    sub box_glyph(ubyte idx, ubyte u, ubyte d, ubyte l, ubyte r) {
        ubyte i
        for i in 0 to 7
            hh[i] = 0
        if u != 0 {
            for i in 0 to 3
                hh[i] |= $10
        }
        if d != 0 {
            for i in 3 to 7
                hh[i] |= $10
        }
        if l != 0
            hh[3] |= $f0
        if r != 0
            hh[3] |= $1f
        gl_write(idx)
    }

    sub bold_glyph(ubyte c) -> ubyte {
        if c > 32 and c < 127
            return c + 128
        return c
    }

    sub ital_glyph(ubyte c) -> ubyte {
        if c >= iso:'A' and c <= iso:'Z'
            return c - iso:'A' + 1
        if c >= iso:'a' and c <= iso:'z'
            return c - iso:'a' + 128
        return c
    }

    sub build_fonts() {
        ubyte c
        ubyte i
        tilebase = ((cx16.VERA_L1_TILEBASE & $fc) as uword) << 9
        for c in 33 to 126 {
            gl_read(c)
            for i in 0 to 7
                hh[i] = gg[i] | (gg[i] >> 1)
            gl_write(bold_glyph(c))
            if (c >= iso:'A' and c <= iso:'Z') or (c >= iso:'a' and c <= iso:'z') {
                for i in 0 to 7 {
                    if i < 4
                        hh[i] = gg[i] >> 1
                    else
                        hh[i] = gg[i]
                }
                gl_write(ital_glyph(c))
            }
        }
        box_glyph(G_H, 0, 0, 1, 1)
        box_glyph(G_V, 1, 1, 0, 0)
        box_glyph(G_TL, 0, 1, 0, 1)
        box_glyph(G_TR, 0, 1, 1, 0)
        box_glyph(G_BL, 1, 0, 0, 1)
        box_glyph(G_BR, 1, 0, 1, 0)
        box_glyph(G_T, 0, 1, 1, 1)
        box_glyph(G_B, 1, 0, 1, 1)
        box_glyph(G_L, 1, 1, 0, 1)
        box_glyph(G_R, 1, 1, 1, 0)
        box_glyph(G_X, 1, 1, 1, 1)
        hh[0] = 0
        hh[1] = 0
        hh[2] = $18
        hh[3] = $3c
        hh[4] = $3c
        hh[5] = $18
        hh[6] = 0
        hh[7] = 0
        gl_write(G_BUL)
    }

    ; ---------------------------------------------------------------
    ; buffer / lines
    ; ---------------------------------------------------------------
    sub linelen(uword l) -> uword {
        return ls(l + 1) - ls(l) - 1
    }

    sub find_line(uword pos) -> uword {
        uword lo = 0
        uword hi = nlines
        uword mid
        while hi - lo > 1 {
            mid = (lo + hi) >> 1
            if ls(mid) <= pos
                lo = mid
            else
                hi = mid
        }
        return lo
    }

    sub rebuild_lines() {
        uword i = 0
        nlines = 0
        setls(0, 0)
        while i < blen {
            if @(buf + i) == NL {
                if nlines >= MAXL
                    break
                nlines++
                setls(nlines, i + 1)
            }
            i++
        }
    }

    sub new_buffer() {
        @(buf) = NL
        blen = 1
        rebuild_lines()
        cy = 0
        cx = 0
        want = 0
        top = 0
        modified = false
        uvalid = false
    }

    sub buf_insert(uword pos, uword src, uword n) -> bool {
        uword L
        uword k = 0
        uword i
        uword j
        if blen + n > BUFSZ {
            setmsg(iso:"Buffer full!")
            return false
        }
        i = 0
        while i < n {
            if @(src + i) == NL
                k++
            i++
        }
        if nlines + k > MAXL {
            setmsg(iso:"Too many lines!")
            return false
        }
        L = find_line(pos)
        cx16.memory_copy(buf + pos, buf + pos + n, blen - pos)
        sys.memcopy(src, buf + pos, n)
        blen += n
        if k != 0 {
            cx16.memory_copy(lstart + ((L + 1) << 1), lstart + ((L + 1 + k) << 1), (nlines - L) << 1)
            j = L + 1
            i = 0
            while i < n {
                if @(src + i) == NL {
                    setls(j, pos + i + 1)
                    j++
                }
                i++
            }
            i = L + 1 + k
            while i <= nlines + k {
                setls(i, ls(i) + n)
                i++
            }
            nlines += k
        } else {
            i = L + 1
            while i <= nlines {
                setls(i, ls(i) + n)
                i++
            }
        }
        modified = true
        redraw_all = true
        return true
    }

    sub buf_delete(uword pos, uword n) {
        uword L
        uword k = 0
        uword i
        if pos + n >= blen {                  ; never remove the final newline
            if pos >= blen - 1
                return
            n = blen - 1 - pos
        }
        if n == 0
            return
        L = find_line(pos)
        i = pos
        while i < pos + n {
            if @(buf + i) == NL
                k++
            i++
        }
        cx16.memory_copy(buf + pos + n, buf + pos, blen - pos - n)
        blen -= n
        if k != 0 {
            cx16.memory_copy(lstart + ((L + 1 + k) << 1), lstart + ((L + 1) << 1), (nlines - L - k + 1) << 1)
            nlines -= k
        }
        i = L + 1
        while i <= nlines {
            setls(i, ls(i) - n)
            i++
        }
        modified = true
        redraw_all = true
    }

    sub cur_pos() -> uword {
        return ls(cy) + cx
    }

    ; ---------------------------------------------------------------
    ; undo: one level, kept in banked RAM (swap style)
    ; ---------------------------------------------------------------
    sub bank_save(ubyte set) {
        uword off = 0
        uword n
        ubyte b = UNDO_BANK + set * 2
        while off < blen {
            n = blen - off
            if n > $2000
                n = $2000
            cx16.rambank(b)
            b++
            sys.memcopy(buf + off, $a000, n)
            off += n
        }
        cx16.rambank(0)
    }

    sub bank_load(ubyte set, uword total) {
        uword off = 0
        uword n
        ubyte b = UNDO_BANK + set * 2
        while off < total {
            n = total - off
            if n > $2000
                n = $2000
            cx16.rambank(b)
            b++
            sys.memcopy($a000, buf + off, n)
            off += n
        }
        cx16.rambank(0)
    }

    sub snap() {
        bank_save(usel)
        smeta_len[usel] = blen
        smeta_cx[usel] = cx
        smeta_cy[usel] = cy
        uvalid = true
    }

    sub do_undo() {
        ubyte other = usel ^ 1
        if not uvalid {
            setmsg(iso:"Nothing to undo")
            return
        }
        bank_save(other)
        smeta_len[other] = blen
        smeta_cx[other] = cx
        smeta_cy[other] = cy
        bank_load(usel, smeta_len[usel])
        blen = smeta_len[usel]
        rebuild_lines()
        cy = smeta_cy[usel]
        cx = smeta_cx[usel]
        if cy >= nlines
            cy = nlines - 1
        if cx > linelen(cy)
            cx = linelen(cy)
        usel = other
        modified = true
        redraw_all = true
        setmsg(iso:"Undo (Ctrl-Z again = redo)")
    }

    ; ---------------------------------------------------------------
    ; character helpers
    ; ---------------------------------------------------------------
    sub is_digit(ubyte c) -> bool {
        return c >= '0' and c <= '9'
    }

    sub is_alnum(ubyte c) -> bool {
        return is_digit(c) or (c >= iso:'A' and c <= iso:'Z') or (c >= iso:'a' and c <= iso:'z')
    }

    sub is_punct(ubyte c) -> bool {
        return c > 32 and c < 127 and not is_alnum(c)
    }

    sub is_sp(ubyte c) -> bool {
        return c == SP or c == TAB
    }

    ; ---------------------------------------------------------------
    ; markdown line classification
    ; ---------------------------------------------------------------
    sub blank_s(uword s, uword n) -> bool {
        while n != 0 {
            if not is_sp(@(s))
                return false
            s++
            n--
        }
        return true
    }

    ; strip leading '>' block-quote markers of line l  -> es, en, eq
    sub eff(uword l) {
        uword s = buf + ls(l)
        uword n = linelen(l)
        ubyte q = 0
        ubyte sp
        repeat {
            sp = 0
            while n != 0 and @(s) == SP and sp < 3 {
                s++
                n--
                sp++
            }
            if n != 0 and @(s) == iso:'>' and q < 4 {
                q++
                s++
                n--
                if n != 0 and @(s) == SP {
                    s++
                    n--
                }
            } else {
                s -= sp
                n += sp
                break
            }
        }
        es = s
        en = n
        eq = q
    }

    sub fence_s(uword s, uword n) -> bool {
        ubyte sp = 0
        ubyte c
        while n != 0 and @(s) == SP and sp < 3 {
            s++
            n--
            sp++
        }
        if n < 3
            return false
        c = @(s)
        return (c == iso:'`' or c == iso:'~') and @(s + 1) == c and @(s + 2) == c
    }

    ; sets atx_lvl, atx_off
    sub atx_s(uword s, uword n) -> bool {
        uword i = 0
        ubyte k = 0
        while i < n and @(s + i) == SP and i < 3
            i++
        while i < n and @(s + i) == iso:'#' and k < 7 {
            i++
            k++
        }
        if k < 1 or k > 6
            return false
        if i < n and @(s + i) != SP
            return false
        while i < n and @(s + i) == SP
            i++
        atx_lvl = k
        atx_off = i
        return true
    }

    sub hr_s(uword s, uword n) -> bool {
        uword i = 0
        uword cnt = 0
        ubyte c
        while i < n and @(s + i) == SP and i < 3
            i++
        if i >= n
            return false
        c = @(s + i)
        if c != iso:'-' and c != iso:'*' and c != iso:'_'
            return false
        while i < n {
            if @(s + i) == c
                cnt++
            else if @(s + i) != SP
                return false
            i++
        }
        return cnt >= 3
    }

    sub list_s(uword s, uword n) -> bool {
        uword i = 0
        uword ind = 0
        uword st
        ubyte c
        while i < n and is_sp(@(s + i)) {
            if @(s + i) == TAB
                ind += 4
            else
                ind++
            i++
        }
        if i >= n
            return false
        L_ind = ind
        L_mk = i
        c = @(s + i)
        if (c == iso:'-' or c == iso:'*' or c == iso:'+') and (i + 1 >= n or @(s + i + 1) == SP) {
            L_ord = false
            L_mlen = 1
            i++
        } else if is_digit(c) {
            st = i
            while i < n and is_digit(@(s + i)) and i - st < 9
                i++
            if i >= n or (@(s + i) != iso:'.' and @(s + i) != iso:')') or (i + 1 < n and @(s + i + 1) != SP)
                return false
            i++
            L_ord = true
            L_mlen = i - st
        } else
            return false
        while i < n and @(s + i) == SP
            i++
        L_txt = i
        return true
    }

    sub sep_s(uword s, uword n) -> bool {
        uword i = 0
        bool dash = false
        bool pipe = false
        ubyte c
        while i < n {
            c = @(s + i)
            if c == iso:'-'
                dash = true
            else if c == iso:'|'
                pipe = true
            else if c != iso:':' and c != SP and c != TAB
                return false
            i++
        }
        return dash and pipe
    }

    ; sets kind_lvl
    sub setext_s(uword s, uword n) -> bool {
        uword i = 0
        uword cnt = 0
        ubyte c
        while i < n and @(s + i) == SP and i < 3
            i++
        if i >= n
            return false
        c = @(s + i)
        if c != iso:'=' and c != iso:'-'
            return false
        while i < n {
            if @(s + i) == c
                cnt++
            else if @(s + i) != SP
                return false
            i++
        }
        if c == iso:'-' and cnt < 2
            return false
        if c == iso:'='
            kind_lvl = 1
        else
            kind_lvl = 2
        return true
    }

    sub toc_s(uword s, uword n) -> bool {
        while n != 0 and is_sp(@(s + n - 1))
            n--
        while n != 0 and @(s) == SP {
            s++
            n--
        }
        return n == 5 and @(s) == iso:'[' and @(s + 4) == iso:']' and (@(s + 1) | 32) == iso:'t' and
               (@(s + 2) | 32) == iso:'o' and (@(s + 3) | 32) == iso:'c'
    }

    sub line_kind(uword l) -> ubyte {
        uword s
        uword n
        uword s2
        uword n2
        ubyte q
        ubyte q2
        ubyte lv

        eff(l)
        s = es
        n = en
        q = eq
        if blank_s(s, n)
            return LK_BLANK
        if fence_s(s, n)
            return LK_FENCE
        if atx_s(s, n) {
            kind_lvl = atx_lvl
            return LK_ATX
        }
        if toc_s(s, n)
            return LK_TOCM
        if hr_s(s, n)
            return LK_HR
        if list_s(s, n)
            return LK_LIST
        if l + 1 < nlines {
            eff(l + 1)
            s2 = es
            n2 = en
            q2 = eq
            if q2 == q {
                if has_char(s, n, iso:'|') and sep_s(s2, n2)
                    return LK_TABLE
                if setext_s(s2, n2)
                    return LK_SETEXT
            }
        }
        return LK_PARA
    }

    uword ht_s
    uword ht_n

    ; heading text of heading i (without #'s) -> ht_s, ht_n
    sub heading_text(ubyte i) {
        uword s
        uword n
        uword off = 0
        eff(hl[i])
        s = es
        n = en
        if atx_s(s, n) {
            s += atx_off
            n -= atx_off
            while n != 0 and @(s + n - 1) == SP
                n--
            while n != 0 and @(s + n - 1) == iso:'#'
                n--
            while n != 0 and @(s + n - 1) == SP
                n--
        } else {
            while off < n and @(s + off) == SP
                off++
            s += off
            n -= off
            while n != 0 and @(s + n - 1) == SP
                n--
        }
        ht_s = s
        ht_n = n
    }

    sub scan_headings() {
        uword l = 0
        bool infence = false
        ubyte k
        hn = 0
        while l < nlines and hn < MAXH {
            k = line_kind(l)
            if infence {
                if k == LK_FENCE
                    infence = false
            } else if k == LK_FENCE {
                infence = true
            } else if k == LK_ATX {
                hl[hn] = l
                hlv[hn] = kind_lvl
                hn++
            } else if k == LK_SETEXT {
                hl[hn] = l
                hlv[hn] = kind_lvl
                hn++
                l++
            }
            l++
        }
    }

    ; ---------------------------------------------------------------
    ; inline markup helpers shared by editor colouring and preview
    ; ---------------------------------------------------------------
    ; may the emphasis marker run at s[i] (width w) open/close?
    sub emph_ok(uword s, uword n, uword i, ubyte w, bool on) -> bool {
        ubyte c = @(s + i)
        ubyte prev = SP
        ubyte next = SP
        if i != 0
            prev = @(s + i - 1)
        if i + w < n
            next = @(s + i + w)
        if not on
            return next != SP and not (c == iso:'_' and is_alnum(prev))
        return prev != SP and not (c == iso:'_' and is_alnum(next))
    }

    ; is there a complete [text](url) starting at s[i]=='['?  sets lk_rb (']') and lk_rp (')')
    sub link_at(uword s, uword n, uword i) -> bool {
        uword j = i + 1
        uword k
        while j < n and @(s + j) != iso:']'
            j++
        if j + 1 >= n or @(s + j + 1) != iso:'('
            return false
        k = j + 2
        while k < n and @(s + k) != iso:')'
            k++
        if k >= n
            return false
        lk_rb = j
        lk_rp = k
        return true
    }

    ; ---------------------------------------------------------------
    ; preview renderer -> banked RAM
    ; ---------------------------------------------------------------
    const ubyte ST_B = 1
    ubyte[80] prch
    ubyte[80] prco           ; row under construction
    ubyte[80] wch
    ubyte[80] wco            ; pending word
    ubyte[80] cch
    ubyte[80] cco            ; table cell sink
    ubyte px
    ubyte wn
    ubyte cn
    bool sink
    bool rowdirty
    bool lastblank
    bool pv_full
    ubyte margin
    ubyte qd
    bool bul_pend
    ubyte bul_x
    ubyte bul_len
    ubyte[12] bul_buf
    uword pv_n
    ubyte hcur

    bool st_b
    bool st_i
    bool st_c
    bool st_s
    bool st_link
    bool st_img
    bool hmode
    ubyte base_col
    bool prev_sp
    uword lk_end
    uword lk_close

    sub pv_addr(uword n) -> uword {
        ; selects the bank holding preview row n, returns its address in $A000
        cx16.rambank(1 + lsb(n / PV_PER_BANK))
        return $a000 + (n % PV_PER_BANK) * 160
    }

    sub row_flush() {
        uword p
        lastblank = false
        if pv_n >= PVMAXL {
            pv_full = true
            return
        }
        p = pv_addr(pv_n)
        sys.memcopy(&prch, p, SW)
        sys.memcopy(&prco, p + 80, SW)
        cx16.rambank(0)
        pv_n++
    }

    sub row_begin() {
        ubyte i
        sys.memset(&prch, SW, SP)
        sys.memset(&prco, SW, C_NORM)
        i = 0
        while i < qd {
            prch[i * 2] = G_V
            prco[i * 2] = C_QBAR
            i++
        }
        px = margin
        rowdirty = false
        if bul_pend {
            i = 0
            while i < bul_len and bul_x + i < pw {
                prch[bul_x + i] = bul_buf[i]
                prco[bul_x + i] = C_BUL
                i++
            }
            bul_pend = false
            rowdirty = true
        }
    }

    sub row_end() {
        if rowdirty
            row_flush()
        rowdirty = false
    }

    sub blank_row() {
        if lastblank
            return
        row_begin()
        row_flush()
        lastblank = true
    }

    sub wflush() {
        ubyte i
        if wn == 0
            return
        if px + wn > pw and px > margin {
            row_flush()
            row_begin()
        }
        i = 0
        while i < wn {
            if px >= pw {
                row_flush()
                row_begin()
            }
            prch[px] = wch[i]
            prco[px] = wco[i]
            px++
            i++
        }
        wn = 0
        rowdirty = true
    }

    sub out_glyph(ubyte g, ubyte col, bool sp) {
        if sink {
            if cn < SW {
                cch[cn] = g
                cco[cn] = col
                cn++
            }
            return
        }
        if sp {
            wflush()
            if px > margin and px < pw {
                prch[px] = SP
                prco[px] = col
                px++
            }
        } else {
            if wn >= SW
                wflush()
            wch[wn] = g
            wco[wn] = col
            wn++
        }
    }

    sub inl_reset() {
        st_b = false
        st_i = false
        st_c = false
        st_s = false
        st_link = false
        st_img = false
        prev_sp = true
    }

    sub put_styled(ubyte c) {
        ubyte g = c
        ubyte col = base_col
        if st_c {
            col = C_CODE
        } else {
            if st_link
                col = C_LINK
            else if st_img
                col = C_IMG
            else if st_s
                col = C_STRIKE
            else if not hmode {
                if st_b
                    col = C_BOLD
                else if st_i
                    col = C_ITAL
            }
            if st_b or hmode
                g = bold_glyph(c)
            else if st_i
                g = ital_glyph(c)
        }
        out_glyph(g, col, c == SP)
    }

    sub inline_emit(uword s, uword n) {
        uword i = 0
        ubyte c
        ubyte w
        bool on
        while i < n {
            if (st_link or st_img) and i == lk_end {
                if st_img
                    put_styled(iso:']')
                st_link = false
                st_img = false
                i = lk_close + 1
                continue
            }
            c = @(s + i)
            if c == TAB
                c = SP
            if c == SP {
                if not prev_sp
                    put_styled(SP)
                prev_sp = true
                i++
                continue
            }
            prev_sp = false
            if c == iso:'\\' and i + 1 < n and is_punct(@(s + i + 1)) {
                put_styled(@(s + i + 1))
                i += 2
                continue
            }
            if c == iso:'`' {
                st_c = not st_c
                i++
                continue
            }
            if st_c {
                if c < 32 or c > 126
                    c = iso:'?'
                put_styled(c)
                i++
                continue
            }
            if c == iso:'*' or c == iso:'_' {
                w = 1
                if i + 1 < n and @(s + i + 1) == c
                    w = 2
                if w == 2
                    on = st_b
                else
                    on = st_i
                if emph_ok(s, n, i, w, on) {
                    if w == 2
                        st_b = not st_b
                    else
                        st_i = not st_i
                    i += w
                    continue
                }
            } else if c == iso:'~' and i + 1 < n and @(s + i + 1) == iso:'~' {
                st_s = not st_s
                i += 2
                continue
            } else if c == iso:'[' and not st_link and not st_img and link_at(s, n, i) {
                st_link = true
                lk_end = lk_rb
                lk_close = lk_rp
                i++
                continue
            } else if c == iso:'!' and i + 1 < n and @(s + i + 1) == iso:'[' and not st_link and not st_img and link_at(s, n, i + 1) {
                st_img = true
                lk_end = lk_rb
                lk_close = lk_rp
                put_styled(iso:'[')
                i += 2
                continue
            }
            if c < 32 or c > 126
                c = iso:'?'
            put_styled(c)
            i++
        }
    }

    ; paragraph helper: separate consecutive source lines with a space
    sub inline_join() {
        if not prev_sp {
            put_styled(SP)
            prev_sp = true
        }
    }

    sub begin_text(ubyte m, ubyte col, bool h) {
        margin = m
        base_col = col
        hmode = h
        inl_reset()
        wn = 0
        row_begin()
    }

    sub rule_row(ubyte col) {
        ubyte x
        row_begin()
        x = margin
        while x < pw {
            prch[x] = G_H
            prco[x] = col
            x++
        }
        row_flush()
    }

    sub code_row() {
        uword i = 0
        ubyte x = margin + 1
        ubyte c
        row_begin()
        c = margin
        while c < pw {
            prco[c] = C_CODEBLK
            c++
        }
        while i < en and x < pw {
            c = @(es + i)
            i++
            if c == TAB {
                x += 4
                continue
            }
            if c < 32 or c > 126
                c = iso:'?'
            prch[x] = c
            x++
        }
        row_flush()
    }

    sub render_heading(ubyte lvl, uword s, uword n) {
        blank_row()
        if hcur < hn
            hvis[hcur] = pv_n
        hcur++
        begin_text(qd * 2, hcol[lvl], true)
        inline_emit(s, n)
        wflush()
        row_end()
        if lvl == 1
            rule_row(hcol[1])
        else if lvl == 2
            rule_row(C_TBL)
        blank_row()
    }

    ; --- tables ---
    uword[8] tc_s
    uword[8] tc_e
    ubyte[8] t_w
    ubyte[8] t_al
    ubyte t_nc
    ubyte tx

    sub split_row(uword s, uword n) -> ubyte {
        uword i = 0
        uword st
        uword e
        ubyte c = 0
        while i < n and is_sp(@(s + i))
            i++
        if i < n and @(s + i) == iso:'|'
            i++
        while i < n and c < MAXC {
            st = i
            while i < n and @(s + i) != iso:'|' {
                if @(s + i) == iso:'\\' and i + 1 < n
                    i++
                i++
            }
            e = i
            while st < e and is_sp(@(s + st))
                st++
            while e > st and is_sp(@(s + e - 1))
                e--
            tc_s[c] = st
            tc_e[c] = e
            c++
            if i < n
                i++
        }
        return c
    }

    sub cell_measure(uword s, ubyte c, bool header) {
        sink = true
        cn = 0
        if header
            base_col = 7
        else
            base_col = C_NORM
        hmode = header
        inl_reset()
        inline_emit(s + tc_s[c], tc_e[c] - tc_s[c])
        sink = false
    }

    sub tbl_put(ubyte g, ubyte col) {
        if tx < pw {
            prch[tx] = g
            prco[tx] = col
            tx++
        }
    }

    sub tbl_border(ubyte gl, ubyte gm, ubyte gr) {
        ubyte c
        ubyte k
        row_begin()
        tx = margin
        tbl_put(gl, C_TBL)
        c = 0
        while c < t_nc {
            k = 0
            while k < t_w[c] + 2 {
                tbl_put(G_H, C_TBL)
                k++
            }
            if c + 1 < t_nc
                tbl_put(gm, C_TBL)
            else
                tbl_put(gr, C_TBL)
            c++
        }
        row_flush()
    }

    sub tbl_row(uword s, uword n, bool header) {
        ubyte c
        ubyte shown
        ubyte pad
        ubyte lp
        ubyte k
        ubyte ncell
        ncell = split_row(s, n)
        row_begin()
        tx = margin
        tbl_put(G_V, C_TBL)
        c = 0
        while c < t_nc {
            if c < ncell
                cell_measure(s, c, header)
            else
                cn = 0
            if cn > t_w[c]
                shown = t_w[c]
            else
                shown = cn
            pad = t_w[c] - shown
            if t_al[c] == 2
                lp = pad
            else if t_al[c] == 1
                lp = pad / 2
            else
                lp = 0
            tbl_put(SP, C_NORM)
            k = 0
            while k < lp {
                tbl_put(SP, C_NORM)
                k++
            }
            k = 0
            while k < shown {
                if cn > t_w[c] and k + 1 == shown
                    tbl_put(iso:'~', C_TBL)
                else
                    tbl_put(cch[k], cco[k])
                k++
            }
            k = lp
            while k < pad {
                tbl_put(SP, C_NORM)
                k++
            }
            tbl_put(SP, C_NORM)
            tbl_put(G_V, C_TBL)
            c++
        }
        row_flush()
    }

    ; render the table starting at line l; returns first line after it
    sub render_table(uword l) -> uword {
        uword t
        uword r
        uword s
        uword n
        uword tot
        uword a
        uword b
        ubyte c
        ubyte nc
        ubyte nn
        ubyte avail
        ubyte widest

        ; separator row: alignment
        eff(l + 1)
        s = es
        n = en
        nc = split_row(s, n)
        c = 0
        while c < nc {
            a = tc_s[c]
            b = tc_e[c]
            t_al[c] = 0
            if b > a and @(s + b - 1) == iso:':' {
                if @(s + a) == iso:':'
                    t_al[c] = 1
                else
                    t_al[c] = 2
            }
            c++
        }
        eff(l)
        t_nc = split_row(es, en)
        if t_nc == 0
            t_nc = 1
        c = 0
        while c < t_nc {
            t_w[c] = 1
            c++
        }
        ; measure
        r = l
        while r < nlines {
            eff(r)
            s = es
            n = en
            if r != l and r != l + 1 and (blank_s(s, n) or not has_char(s, n, iso:'|'))
                break
            if r != l + 1 {
                nn = split_row(s, n)
                c = 0
                while c < t_nc and c < nn {
                    cell_measure(s, c, r == l)
                    if cn > t_w[c] {
                        if cn > 70
                            t_w[c] = 70
                        else
                            t_w[c] = cn
                    }
                    c++
                }
            }
            r++
        }
        t = r
        tot = 1
        c = 0
        while c < t_nc {
            tot += t_w[c] + 3
            c++
        }
        avail = pw - margin
        while tot > avail {
            widest = 0
            c = 1
            while c < t_nc {
                if t_w[c] > t_w[widest]
                    widest = c
                c++
            }
            if t_w[widest] <= 3
                break
            t_w[widest]--
            tot--
        }
        blank_row()
        tbl_border(G_TL, G_T, G_TR)
        eff(l)
        tbl_row(es, en, true)
        tbl_border(G_L, G_X, G_R)
        r = l + 2
        while r < t {
            eff(r)
            tbl_row(es, en, false)
            r++
        }
        tbl_border(G_BL, G_B, G_BR)
        blank_row()
        return t
    }

    sub emit_str(uword s) {
        inline_emit(s, slen(s))
    }

    sub render_toc() {
        ubyte i
        ubyte minlv = 7
        ubyte ind
        if hn == 0
            return
        i = 0
        while i < hn {
            if hlv[i] < minlv
                minlv = hlv[i]
            i++
        }
        blank_row()
        begin_text(qd * 2, C_TOC, true)
        emit_str(iso:"Contents")
        wflush()
        row_end()
        i = 0
        while i < hn {
            ind = (hlv[i] - minlv) * 2
            bul_pend = true
            bul_x = qd * 2 + ind
            bul_len = 1
            bul_buf[0] = G_BUL
            begin_text(bul_x + 2, C_NORM, false)
            heading_text(i)
            inline_emit(ht_s, ht_n)
            wflush()
            row_end()
            i++
        }
        blank_row()
    }

    sub pv_render() {
        uword l = 0
        uword s
        uword n
        ubyte k
        ubyte q
        ubyte lv
        ubyte b
        ubyte j

        scan_headings()
        j = 0
        while j < MAXH {
            hvis[j] = $ffff
            j++
        }
        pv_n = 0
        pv_full = false
        lastblank = true
        hcur = 0
        sink = false
        bul_pend = false
        qd = 0
        margin = 0
        wn = 0
        while l < nlines and not pv_full {
            k = line_kind(l)
            eff(l)
            s = es
            n = en
            q = eq
            qd = q
            when k {
                LK_BLANK -> {
                    blank_row()
                    l++
                }
                LK_FENCE -> {
                    blank_row()
                    margin = qd * 2
                    l++
                    while l < nlines and not pv_full {
                        eff(l)
                        if fence_s(es, en) {
                            l++
                            break
                        }
                        qd = eq
                        margin = qd * 2
                        code_row()
                        l++
                    }
                    blank_row()
                }
                LK_ATX -> {
                    void atx_s(s, n)
                    lv = atx_lvl
                    s += atx_off
                    n -= atx_off
                    while n != 0 and @(s + n - 1) == SP
                        n--
                    while n != 0 and @(s + n - 1) == iso:'#'
                        n--
                    while n != 0 and @(s + n - 1) == SP
                        n--
                    render_heading(lv, s, n)
                    l++
                }
                LK_SETEXT -> {
                    lv = kind_lvl
                    while n != 0 and @(s) == SP {
                        s++
                        n--
                    }
                    while n != 0 and @(s + n - 1) == SP
                        n--
                    render_heading(lv, s, n)
                    l += 2
                }
                LK_HR -> {
                    blank_row()
                    margin = qd * 2
                    rule_row(C_TBL)
                    blank_row()
                    l++
                }
                LK_TOCM -> {
                    render_toc()
                    l++
                }
                LK_TABLE -> {
                    margin = qd * 2
                    l = render_table(l)
                }
                LK_LIST -> {
                    void list_s(s, n)
                    if L_ind > 12
                        b = 12
                    else
                        b = lsb(L_ind)
                    bul_x = qd * 2 + b
                    if L_ord {
                        if L_mlen > 8
                            bul_len = 8
                        else
                            bul_len = lsb(L_mlen)
                        sys.memcopy(s + L_mk, &bul_buf, bul_len)
                    } else {
                        bul_len = 1
                        bul_buf[0] = G_BUL
                    }
                    bul_pend = true
                    begin_text(bul_x + bul_len + 1, C_NORM, false)
                    inline_emit(s + L_txt, n - L_txt)
                    repeat {
                        if l + 1 >= nlines
                            break
                        if line_kind(l + 1) != LK_PARA
                            break
                        eff(l + 1)
                        if eq != q
                            break
                        inline_join()
                        inline_emit(es, en)
                        l++
                    }
                    wflush()
                    row_end()
                    l++
                }
                else -> {                        ; paragraph
                    begin_text(qd * 2, C_NORM, false)
                    inline_emit(s, n)
                    repeat {
                        if l + 1 >= nlines
                            break
                        if line_kind(l + 1) != LK_PARA
                            break
                        eff(l + 1)
                        if eq != q
                            break
                        inline_join()
                        inline_emit(es, en)
                        l++
                    }
                    wflush()
                    row_end()
                    l++
                }
            }
        }
        qd = 0
        if pv_n == 0 {
            row_begin()
            row_flush()
        }
    }

    ; ---------------------------------------------------------------
    ; text drawing helpers
    ; ---------------------------------------------------------------
    sub draw_text(ubyte row, uword s, ubyte col) {
        ubyte x = 0
        vera_at(0, row)
        while x < scrw {
            if @(s) != 0 {
                cx16.VERA_DATA0 = @(s)
                s++
            } else
                cx16.VERA_DATA0 = SP
            cx16.VERA_DATA0 = col
            x++
        }
    }

    sub pv_draw_row(ubyte y, uword n) {
        uword p
        ubyte x
        vera_at(0, y)
        if n >= pv_n {
            x = 0
            while x < scrw {
                cx16.VERA_DATA0 = SP
                cx16.VERA_DATA0 = C_NORM
                x++
            }
            return
        }
        p = pv_addr(n)
        x = 0
        while x < scrw {
            cx16.VERA_DATA0 = @(p + x)
            cx16.VERA_DATA0 = @(p + 80 + x)
            x++
        }
        cx16.rambank(0)
    }

    ; ---------------------------------------------------------------
    ; dialogs: line prompt, help, TOC menu
    ; ---------------------------------------------------------------
    sub read_line(uword prompt, uword out, ubyte maxn) -> bool {
        ubyte n = slen(out)
        ubyte k
        ubyte d
        repeat {
            d = bcat(&rline, 0, prompt)
            k = 0
            while k < n {
                rline[d] = @(out + k)
                d++
                k++
            }
            rline[d] = iso:'_'
            rline[d + 1] = 0
            draw_text(scrh - 1, &rline, (C_BG << 4) | C_BOLD)
            k = getkey()
            if k == K_ESC {
                @(out) = 0
                return false
            }
            if k == 13 or k == 10 {
                @(out + n) = 0
                return true
            }
            if k == K_BKSP or k == $08 or k == $7f {
                if n != 0
                    n--
                @(out + n) = 0
                continue
            }
            if k >= 32 and k < 127 and n < maxn - 1 {
                @(out + n) = k
                n++
                @(out + n) = 0
            }
        }
    }

    sub show_help() {
        clear_screen()
        draw_text(1, iso:"MD - Markdown editor", C_TOC)
        draw_text(3, iso:"^W/F2 save   ^O/F3 open   ^X/F8 quit", C_NORM)
        draw_text(4, iso:"^P/F5 preview (toggle)    ^G/F4 contents", C_NORM)
        draw_text(5, iso:"^Z undo/redo  ^U kill line  ^F find", C_NORM)
        draw_text(6, iso:"F6/F7 page up/down", C_NORM)
        draw_text(7, iso:"^B bold  ^E italic  ^K code", C_NORM)
        draw_text(8, iso:"^A table  ^R [TOC] marker", C_NORM)
        draw_text(10, iso:"Preview: arrows, Space, b, n/p heading,", C_NORM)
        draw_text(11, iso:"  F4 contents, Esc or ^P back to editor", C_NORM)
        draw_text(13, iso:"Press any key", C_NORM)
        void getkey()
        redraw_all = true
    }

    ; returns the chosen heading index, or 255
    sub toc_menu() -> ubyte {
        ubyte sel = 0
        ubyte first = 0
        ubyte vis
        ubyte i
        ubyte x
        ubyte bw
        ubyte bx
        ubyte by
        ubyte k
        ubyte minlv = 7
        ubyte ind
        ubyte col
        ubyte m
        uword j
        ubyte[81] line
        str title = iso:" Table of Contents  (Enter=go  Esc=cancel) "

        scan_headings()
        if hn == 0 {
            setmsg(iso:"No headings in this document")
            return 255
        }
        i = 0
        while i < hn {
            if hlv[i] < minlv
                minlv = hlv[i]
            i++
        }
        if scrw > 66
            bw = 64
        else
            bw = scrw - 2
        bx = (scrw - bw) / 2
        vis = textrows - 4
        if vis > hn
            vis = hn
        by = 2
        repeat {
            ; frame
            x = 0
            while x < bw {
                put_cell(bx + x, by - 1, SP, (1 << 4) | 0)
                x++
            }
            x = 0
            while title[x] != 0 and x < bw {
                put_cell(bx + x, by - 1, title[x], (1 << 4) | 0)
                x++
            }
            i = 0
            while i < vis {
                m = first + i
                sys.memset(&line, bw, SP)
                ind = (hlv[m] - minlv) * 2
                heading_text(m)
                x = 1 + ind
                j = 0
                while j < ht_n and x < bw - 1 {
                    k = @(ht_s + j)
                    j++
                    if k == iso:'*' or k == iso:'`'
                        continue
                    if k < 32 or k > 126
                        k = iso:'?'
                    line[x] = k
                    x++
                }
                if m == sel
                    col = (1 << 4) | 0
                else
                    col = (11 << 4) | hcol[hlv[m]]
                x = 0
                while x < bw {
                    put_cell(bx + x, by + i, line[x], col)
                    x++
                }
                i++
            }
            x = 0
            while x < bw {
                put_cell(bx + x, by + vis, SP, (1 << 4) | 0)
                x++
            }
            k = getkey()
            if k == K_ESC or k == K_F4 or k == CTRL_G
                return 255
            if k == 13 or k == 10
                return sel
            if k == K_DOWN and sel + 1 < hn
                sel++
            else if k == K_UP and sel != 0
                sel--
            else if k == K_F7 and sel + vis < hn
                sel += vis
            else if k == K_F7
                sel = hn - 1
            else if k == K_F6 {
                if sel > vis
                    sel -= vis
                else
                    sel = 0
            } else if k == K_HOME
                sel = 0
            else if k == K_END
                sel = hn - 1
            if sel < first
                first = sel
            if sel >= first + vis
                first = sel - vis + 1
        }
    }

    ; ---------------------------------------------------------------
    ; preview viewer
    ; ---------------------------------------------------------------
    sub preview_mode() {
        uword pvtop = 0
        uword maxtop
        ubyte i
        ubyte k
        ubyte t
        ubyte d

        draw_text(scrh - 1, iso:"Rendering preview...", (C_BG << 4) | C_BOLD)
        pv_render()
        ; start at the heading nearest above the cursor
        i = 0
        while i < hn {
            if hl[i] <= cy
                pvtop = hvis[i]
            i++
        }
        repeat {
            if pv_n > textrows
                maxtop = pv_n - textrows
            else
                maxtop = 0
            if pvtop > maxtop
                pvtop = maxtop
            i = 0
            while i < textrows {
                pv_draw_row(i, pvtop + i)
                i++
            }
            d = bcat(&sline, 0, iso:" PREVIEW  ")
            if fname[0] != 0
                d = bcat(&sline, d, &fname)
            else
                d = bcat(&sline, d, iso:"[No Name]")
            d = bcat(&sline, d, iso:"   row ")
            d = bnum(&sline, d, pvtop + 1)
            sline[d] = iso:'/'
            d++
            d = bnum(&sline, d, pv_n)
            if pv_full
                d = bcat(&sline, d, iso:" (too long: end cut off)")
            sline[d] = 0
            draw_text(scrh - 2, &sline, (C_NORM << 4) | C_BG)
            draw_text(scrh - 1, iso:"Up/Dn scroll  Space page  n/p heading  F4 contents  Ctrl-P or Esc = edit",
                      (C_BG << 4) | C_LAB)
            k = getkey()
            when k {
                K_DOWN, iso:'j' -> {
                    if pvtop < maxtop
                        pvtop++
                }
                K_UP, iso:'k' -> {
                    if pvtop != 0
                        pvtop--
                }
                SP, K_F7, iso:'f' -> pvtop += textrows - 1
                iso:'b', K_F6 -> {
                    if pvtop > textrows - 1
                        pvtop -= textrows - 1
                    else
                        pvtop = 0
                }
                K_HOME, iso:'g' -> pvtop = 0
                K_END, iso:'G' -> pvtop = maxtop
                iso:'n' -> {
                    i = 0
                    while i < hn {
                        if hvis[i] > pvtop and hvis[i] < pv_n {
                            pvtop = hvis[i]
                            break
                        }
                        i++
                    }
                }
                iso:'p' -> {
                    i = hn
                    while i != 0 {
                        i--
                        if hvis[i] < pvtop {
                            pvtop = hvis[i]
                            break
                        }
                    }
                }
                K_F4, iso:'t', CTRL_G -> {
                    t = toc_menu()
                    if t != 255
                        pvtop = hvis[t]
                }
                K_F5, CTRL_P, K_ESC, iso:'e', iso:'q' -> {
                    redraw_all = true
                    return
                }
            }
        }
    }

    ; ---------------------------------------------------------------
    ; editor: syntax colouring
    ; ---------------------------------------------------------------
    sub fillc(uword fstart, uword fend, ubyte col) {
        if fend > CLSN
            fend = CLSN
        while fstart < fend {
            cls[lsb(fstart)] = col
            fstart++
        }
    }

    sub hl_md(uword s, uword n, bool infence, bool isfence) {
        uword m
        uword i = 0
        uword j
        uword a
        uword b2
        ubyte c
        bool bo = false
        bool it = false
        bool cd = false
        ubyte k
        ubyte w
        bool on

        if n > CLSN
            m = CLSN
        else
            m = n
        fillc(0, m, C_NORM)
        if isfence {
            fillc(0, m, C_MARK)
            return
        }
        if infence {
            fillc(0, m, C_LAB)
            return
        }
        if atx_s(s, n) {
            fillc(0, m, hcol[atx_lvl])
            return
        }
        if toc_s(s, n) {
            fillc(0, m, C_TOC)
            return
        }
        if hr_s(s, n) or sep_s(s, n) {
            fillc(0, m, C_MARK)
            return
        }
        while i < m and @(s + i) == SP
            i++
        while i < m and @(s + i) == iso:'>' {
            cls[lsb(i)] = C_QBAR
            i++
            if i < m and @(s + i) == SP
                i++
        }
        if list_s(s, n) {
            fillc(L_mk, L_mk + L_mlen, C_BUL)
            i = L_txt
        }
        j = i
        while j < m {
            c = @(s + j)
            if c == iso:'`' {
                cls[lsb(j)] = C_MARK
                cd = not cd
                j++
                continue
            }
            if cd {
                cls[lsb(j)] = C_CODE & 15
                j++
                continue
            }
            if c == iso:'*' or c == iso:'_' {
                w = 1
                if j + 1 < n and @(s + j + 1) == c
                    w = 2
                if w == 2
                    on = bo
                else
                    on = it
                if emph_ok(s, n, j, w, on) {
                    fillc(j, j + w, C_MARK)
                    if w == 2
                        bo = not bo
                    else
                        it = not it
                    j += w
                    continue
                }
            } else if c == iso:'[' and link_at(s, n, j) {
                a = lk_rb
                b2 = lk_rp
                fillc(j, j + 1, C_MARK)
                fillc(j + 1, a, C_LINK)
                fillc(a, a + 2, C_MARK)
                fillc(a + 2, b2, C_URL)
                fillc(b2, b2 + 1, C_MARK)
                j = b2 + 1
                continue
            }
            if bo
                k = C_BOLD
            else if it
                k = C_ITAL
            else
                k = C_NORM
            cls[lsb(j)] = k
            j++
        }
        if has_char(s, m, iso:'|') {
            j = 0
            while j < m {
                if @(s + j) == iso:'|'
                    cls[lsb(j)] = C_TBL
                j++
            }
        }
    }

    sub fence_before(uword l) -> bool {
        uword i = 0
        bool f = false
        while i < l {
            if fence_s(buf + ls(i), linelen(i))
                f = not f
            i++
        }
        return f
    }

    sub rows_of(uword l) -> uword {
        return linelen(l) / scrw + 1
    }

    ; draw logical line l with its first row at screen row `row`; returns rows used
    sub draw_logical(uword l, ubyte row, bool f) -> ubyte {
        uword s = buf + ls(l)
        uword n = linelen(l)
        uword idx
        ubyte segs = lsb(n / scrw + 1)
        ubyte sg = 0
        ubyte x
        ubyte ch
        ubyte used = 0
        bool isf = fence_s(s, n)

        hl_md(s, n, f, isf)
        while sg < segs and row + used < textrows {
            vera_at(0, row + used)
            idx = (sg as uword) * scrw
            x = 0
            while x < scrw {
                if idx < n {
                    ch = @(s + idx)
                    if ch < 32 or ch > 126 {
                        if ch == TAB
                            ch = SP
                        else
                            ch = iso:'?'
                    }
                    cx16.VERA_DATA0 = ch
                    if idx < CLSN
                        cx16.VERA_DATA0 = cls[lsb(idx)]
                    else
                        cx16.VERA_DATA0 = C_NORM
                } else {
                    cx16.VERA_DATA0 = SP
                    cx16.VERA_DATA0 = C_NORM
                }
                x++
                idx++
            }
            used++
            sg++
        }
        return used
    }

    sub draw_screen() {
        uword l = top
        ubyte row = 0
        bool f = fence_before(top)
        ubyte x
        while row < textrows {
            if l >= nlines {
                vera_at(0, row)
                cx16.VERA_DATA0 = iso:'~'
                cx16.VERA_DATA0 = C_LAB
                x = 1
                while x < scrw {
                    cx16.VERA_DATA0 = SP
                    cx16.VERA_DATA0 = C_NORM
                    x++
                }
                row++
                continue
            }
            row += draw_logical(l, row, f)
            if fence_s(buf + ls(l), linelen(l))
                f = not f
            l++
        }
    }

    ; first screen row of logical line l (or 255 if off-screen)
    sub line_row(uword l) -> ubyte {
        uword r = 0
        uword i
        if l < top
            return 255
        i = top
        while i < l {
            r += rows_of(i)
            if r >= textrows
                return 255
            i++
        }
        return lsb(r)
    }

    ubyte cur_x
    ubyte cur_y

    sub cursor_xy() {
        uword r = 0
        uword i = top
        while i < cy {
            r += rows_of(i)
            if r > 200
                break
            i++
        }
        r += cx / scrw
        cur_x = lsb(cx % scrw)
        if r > 250
            cur_y = 250
        else
            cur_y = lsb(r)
    }

    sub draw_status() {
        ubyte d = 0
        ubyte e
        ubyte i
        d = bcat(&sline, d, iso:" ")
        if fname[0] != 0
            d = bcat(&sline, d, &fname)
        else
            d = bcat(&sline, d, iso:"[No Name]")
        if modified
            d = bcat(&sline, d, iso:" [+]")
        while d < scrw {
            sline[d] = SP
            d++
        }
        e = bcat(&rbuf, 0, iso:"Ln ")
        e = bnum(&rbuf, e, cy + 1)
        e = bcat(&rbuf, e, iso:" Col ")
        e = bnum(&rbuf, e, cx + 1)
        e = bcat(&rbuf, e, iso:"  Free ")
        e = bnum(&rbuf, e, BUFSZ - blen)
        rbuf[e] = SP
        e++
        i = 0
        while i < e {
            sline[scrw - e + i] = rbuf[i]
            i++
        }
        sline[scrw] = 0
        draw_text(scrh - 2, &sline, (C_NORM << 4) | C_BG)
        if msg[0] != 0
            draw_text(scrh - 1, &msg, (C_BG << 4) | C_BOLD)
        else
            draw_text(scrh - 1, iso:"^P preview  ^G contents  ^W save  ^O open  ^X quit  ^B bold ^E italic  F1 help",
                      (C_BG << 4) | C_LAB)
    }

    sub scroll_to_cursor() {
        if cy < top {
            top = cy
            redraw_all = true
        }
        repeat {
            cursor_xy()
            if cur_y < textrows or top >= cy
                break
            top++
            redraw_all = true
        }
    }

    sub refresh() {
        ubyte r
        ubyte ch
        scroll_to_cursor()
        if redraw_all {
            draw_screen()
            redraw_all = false
        } else {
            if prev_cy != cy {
                r = line_row(prev_cy)
                if r != 255 and prev_cy < nlines
                    void draw_logical(prev_cy, r, fence_before(prev_cy))
            }
            r = line_row(cy)
            if r != 255
                void draw_logical(cy, r, fence_before(cy))
        }
        prev_cy = cy
        draw_status()
        cursor_xy()
        if cur_y < textrows {
            vera_at(cur_x, cur_y)
            ch = cx16.VERA_DATA0
            put_cell(cur_x, cur_y, ch, (C_NORM << 4) | C_BG)
        }
    }

    ; ---------------------------------------------------------------
    ; cursor movement
    ; ---------------------------------------------------------------
    sub set_want() {
        want = cx % scrw
    }

    sub clamp_cx() {
        uword n = linelen(cy)
        if cx > n
            cx = n
    }

    sub move_down() {
        uword n = linelen(cy)
        uword w = scrw
        if cx / w < n / w {
            cx += w
            if cx > n
                cx = n
        } else if cy + 1 < nlines {
            cy++
            cx = want
            clamp_cx()
        }
    }

    sub move_up() {
        uword w = scrw
        uword n
        if cx >= w
            cx -= w
        else if cy > 0 {
            cy--
            n = linelen(cy)
            cx = (n / w) * w + want
            if cx > n
                cx = n
        }
    }

    ; ---------------------------------------------------------------
    ; file i/o
    ; ---------------------------------------------------------------
    ; CMDR-DOS wants PETSCII style names: a-z -> $41-$5A, A-Z -> $C1-$DA
    sub dosname(uword d) {
        ubyte c
        while @(d) != 0 {
            c = @(d)
            if c >= iso:'a' and c <= iso:'z'
                c -= 32
            else if c >= iso:'A' and c <= iso:'Z'
                c += 128
            @(d) = c
            d++
        }
    }

    sub dos_status(uword out, ubyte maxn) {
        ubyte n = 0
        ubyte c
        ubyte i
        @(out) = 0
        cbm.SETNAM(0, 0)
        cbm.SETLFS(15, DEVICE, 15)
        void cbm.OPEN()
        void cbm.CHKIN(15)
        while n + 1 < maxn {
            c = cbm.CHRIN()
            if c == 13 or c == 10 or cbm.READST() != 0
                break
            @(out + n) = c
            n++
        }
        @(out + n) = 0
        i = 0
        while i < n {
            c = @(out + i)
            if c >= $41 and c <= $5a
                @(out + i) = c + 32
            i++
        }
        cbm.CLRCHN()
        cbm.CLOSE(15)
    }

    sub load_file(uword name) -> bool {
        uword o = 0
        ubyte c
        ubyte prev = 0
        ubyte stt

        copystr(&iobuf2, name, 44)
        appendstr(&iobuf2, iso:",s,r")
        dosname(&iobuf2)
        cbm.SETNAM(slen(&iobuf2), &iobuf2)
        cbm.SETLFS(2, DEVICE, 2)
        void cbm.OPEN()
        truncated = false
        void cbm.CHKIN(2)
        repeat {
            c = cbm.CHRIN()
            stt = cbm.READST()
            if stt & $bf != 0
                break
            if c == 13 {
                c = NL
            } else if c == NL and prev == 13 {
                prev = c
                if stt & $40 != 0
                    break
                continue
            }
            prev = c
            if c != 0 {
                if o >= BUFSZ - 2 {
                    truncated = true
                    break
                }
                @(buf + o) = c
                o++
            }
            if stt & $40 != 0
                break
        }
        cbm.CLRCHN()
        cbm.CLOSE(2)
        dos_status(&dstat, 40)
        if dstat[0] == iso:'6' or dstat[0] == iso:'7' or (dstat[0] == iso:'5' and dstat[1] != iso:'0') {
            if o == 0 {
                setmsg(&dstat)
                return false
            }
        }
        if o == 0 or @(buf + o - 1) != NL {
            @(buf + o) = NL
            o++
        }
        blen = o
        rebuild_lines()
        return true
    }

    sub save_file(uword name) -> bool {
        uword o = 0

        copystr(&iobuf2, iso:"@:", 4)
        appendstr(&iobuf2, name)
        appendstr(&iobuf2, iso:",s,w")
        dosname(&iobuf2)
        cbm.SETNAM(slen(&iobuf2), &iobuf2)
        cbm.SETLFS(2, DEVICE, 2)
        void cbm.OPEN()
        cbm.CHKOUT(2)
        while o < blen {
            cbm.CHROUT(@(buf + o))
            o++
        }
        cbm.CLRCHN()
        cbm.CLOSE(2)
        dos_status(&dstat, 40)
        if dstat[0] != iso:'0' or dstat[1] != iso:'0' {
            setmsg(&dstat)
            return false
        }
        modified = false
        copystr(&sline, iso:"\"", 1)
        appendstr(&sline, name)
        appendstr(&sline, iso:"\" written")
        setmsg(&sline)
        return true
    }

    sub open_file(uword name) {
        copystr(&fname, name, FNLEN)
        if not load_file(name) {
            new_buffer()
        } else {
            cy = 0
            cx = 0
            want = 0
            top = 0
            modified = false
            uvalid = false
            if truncated
                setmsg(iso:"File truncated (too big)!")
            else
                setmsg(iso:"File loaded")
        }
        redraw_all = true
    }

    ubyte[41] sname

    sub do_save() {
        if fname[0] == 0 {
            sname[0] = 0
            if not read_line(iso:"Save as: ", &sname, 41) {
                setmsg(iso:"Cancelled")
                return
            }
            if sname[0] == 0
                return
            copystr(&fname, &sname, FNLEN)
        }
        void save_file(&fname)
    }

    sub discard_ok() -> bool {
        if not modified or warned {
            warned = false
            return true
        }
        warned = true
        setmsg(iso:"Unsaved changes! Press the key again to discard them")
        return false
    }

    ; ---------------------------------------------------------------
    ; editing commands
    ; ---------------------------------------------------------------
    sub begin_edit() {
        if not typing {
            snap()
            typing = true
        }
    }

    sub insert_char(ubyte c) {
        begin_edit()
        chbuf[0] = c
        if buf_insert(cur_pos(), &chbuf, 1)
            cx++
        set_want()
    }

    ubyte[128] tbuf

    ; insert constant text at the cursor and leave the cursor after it.
    ; (a "\n" in a Prog8 string is CR, so CR is converted to a newline here)
    sub insert_str(uword t) {
        ubyte n = 0
        ubyte i
        ubyte c
        while @(t + n) != 0 and n < 127 {
            c = @(t + n)
            if c == 13
                c = NL
            tbuf[n] = c
            n++
        }
        if not buf_insert(cur_pos(), &tbuf, n)
            return
        i = 0
        while i < n {
            if tbuf[i] == NL {
                cy++
                cx = 0
            } else
                cx++
            i++
        }
        set_want()
    }

    ubyte[12] ins

    sub do_newline() {
        ubyte n = 1
        ubyte i = 0
        uword sl = buf + ls(cy)
        uword ln = linelen(cy)
        begin_edit()
        ins[0] = NL
        while i < ln and @(sl + i) == SP and i < 8 {
            ins[n] = @(sl + i)
            n++
            i++
        }
        if i + 1 < ln and @(sl + i + 1) == SP and cx >= (i as uword) + 2 and
           (@(sl + i) == iso:'-' or @(sl + i) == iso:'*' or @(sl + i) == iso:'+' or @(sl + i) == iso:'>') {
            if ln == (i as uword) + 2 {               ; empty item: end the list
                buf_delete(ls(cy), ln)
                cx = 0
                set_want()
                return
            }
            ins[n] = @(sl + i)
            n++
            ins[n] = SP
            n++
        }
        if buf_insert(cur_pos(), &ins, n) {
            cy++
            cx = n - 1
        }
        set_want()
    }

    sub backspace() {
        begin_edit()
        if cx > 0 {
            cx--
            buf_delete(cur_pos(), 1)
        } else if cy > 0 {
            cx = linelen(cy - 1)
            cy--
            buf_delete(cur_pos(), 1)
        }
        set_want()
    }

    sub kill_line() {
        snap()
        typing = false
        if nlines == 1 {
            buf_delete(0, blen - 1)
            cx = 0
        } else if cy + 1 < nlines {
            buf_delete(ls(cy), ls(cy + 1) - ls(cy))
            cx = 0
        } else {
            buf_delete(ls(cy) - 1, blen - ls(cy))
            cy--
            cx = 0
        }
        clamp_cx()
        set_want()
    }

    sub pair_insert(uword t, ubyte back) {
        snap()
        typing = false
        insert_str(t)
        cx -= back
        set_want()
    }

    sub insert_table() {
        snap()
        typing = false
        if linelen(cy) > 0 {
            cx = linelen(cy)
            insert_str(iso:"\n\n")
        } else
            cx = 0
        insert_str(iso:"| Column A | Column B | Column C |\n")
        insert_str(iso:"|:---------|:--------:|---------:|\n")
        insert_str(iso:"| one      | two      | three    |\n")
        cy -= 3
        cx = 2
        set_want()
        setmsg(iso:"Table inserted - edit the cells, Ctrl-P to preview")
    }

    sub insert_toc_marker() {
        snap()
        typing = false
        if linelen(cy) > 0 {
            cx = linelen(cy)
            insert_str(iso:"\n\n")
        } else
            cx = 0
        insert_str(iso:"[TOC]\n\n")
        set_want()
        setmsg(iso:"[TOC] marker inserted - shown as contents in the preview")
    }

    ubyte[32] pat

    sub do_find() {
        uword pos
        uword i
        uword pl
        uword start
        copystr(&pat, &lastsearch, 31)
        if not read_line(iso:"Find: ", &pat, 32) {
            msg[0] = 0
            return
        }
        if pat[0] != 0
            copystr(&lastsearch, &pat, 31)
        pl = slen(&lastsearch)
        if pl == 0
            return
        start = cur_pos() + 1
        i = 0
        while i < blen {
            pos = start + i
            if pos >= blen
                pos -= blen
            if pos + pl <= blen and memeq(buf + pos, &lastsearch, pl) {
                cy = find_line(pos)
                cx = pos - ls(cy)
                set_want()
                setmsg(iso:"Found")
                return
            }
            i++
        }
        setmsg(iso:"Not found")
    }

    sub goto_heading(ubyte i) {
        cy = hl[i]
        cx = 0
        top = cy
        set_want()
        redraw_all = true
    }

    ubyte[41] oname

    sub edit_key(ubyte k) {
        ubyte i
        ubyte t

        if not (k == CTRL_X or k == K_F8 or k == CTRL_O or k == K_F3)
            warned = false
        if k >= 32 and k < 127 {
            insert_char(k)
            return
        }
        when k {
            13, 10 -> {
                do_newline()
                return
            }
            K_BKSP, $08, $7f -> {
                backspace()
                return
            }
            K_DEL -> {
                begin_edit()
                if cx < linelen(cy) or cy + 1 < nlines
                    buf_delete(cur_pos(), 1)
                return
            }
            TAB -> {
                begin_edit()
                insert_char(SP)
                insert_char(SP)
                return
            }
        }
        typing = false
        when k {
            K_LEFT -> {
                if cx != 0
                    cx--
                else if cy != 0 {
                    cy--
                    cx = linelen(cy)
                }
                set_want()
            }
            K_RIGHT -> {
                if cx < linelen(cy)
                    cx++
                else if cy + 1 < nlines {
                    cy++
                    cx = 0
                }
                set_want()
            }
            K_UP -> move_up()
            K_DOWN -> move_down()
            K_HOME -> {
                cx = 0
                set_want()
            }
            K_END -> {
                cx = linelen(cy)
                set_want()
            }
            K_F6 -> {
                i = 0
                while i < textrows - 1 {
                    move_up()
                    i++
                }
            }
            K_F7 -> {
                i = 0
                while i < textrows - 1 {
                    move_down()
                    i++
                }
            }
            CTRL_P, K_F5 -> preview_mode()
            CTRL_G, K_F4 -> {
                t = toc_menu()
                redraw_all = true
                if t != 255
                    goto_heading(t)
            }
            CTRL_W, K_F2 -> do_save()
            CTRL_O, K_F3 -> {
                if discard_ok() {
                    oname[0] = 0
                    if read_line(iso:"Open file: ", &oname, 41) and oname[0] != 0
                        open_file(&oname)
                }
            }
            CTRL_X, K_F8 -> {
                if discard_ok()
                    quit = true
            }
            CTRL_Z -> do_undo()
            CTRL_U -> kill_line()
            CTRL_F -> do_find()
            CTRL_B -> pair_insert(iso:"****", 2)
            CTRL_E -> pair_insert(iso:"**", 1)
            CTRL_K -> pair_insert(iso:"``", 1)
            CTRL_A -> insert_table()
            CTRL_R -> insert_toc_marker()
            K_F1 -> show_help()
        }
    }

    sub editor() {
        ubyte k
        redraw_all = true
        while not quit {
            refresh()
            k = getkey()
            msg[0] = 0
            edit_key(k)
        }
    }

    ;@SELFTEST-SUBS

    sub start() {
        init_screen()
        cbm.CHROUT($0f)              ; ISO mode
        build_fonts()
        clear_screen()
        cx16.VERA_CTRL &= $fe
        cx16.VERA_DC_BORDER = 0
        new_buffer()
        fname[0] = 0
        msg[0] = 0
        ;@SELFTEST-INIT
        setmsg(iso:"MD for X16 - F1 help, Ctrl-O open, Ctrl-P preview")
        editor()
        cbm.CHROUT($8f)              ; ISO mode off
        cx16.screen_set_charset(3, 0)    ; restore the standard PETSCII charset (we edited glyphs)
        cbm.CHROUT($93)              ; clear screen
    }
}
