; VI for the Commander X16  (Prog8, target cx16)
;
; A small vi clone with syntax highlighting for C, BASIC, 6502 assembly and Prog8.
; (It started life as a C / cc65 program; Prog8 gives smaller, faster code.)
;
; HOW IT WORKS
;   * The whole file lives in one flat byte buffer `buf` (lines end in $0A, ASCII).
;     `lstart` is a table with the offset where each line begins, plus one extra
;     entry for 'end of last line', so line l is buf[lstart[l] .. lstart[l+1]-2].
;     Every insert/delete shifts the tail of the buffer and patches `lstart`.
;   * The screen is drawn by writing character/colour pairs straight into VERA's
;     text map. The X16 is put in ISO mode ($0F), so a screen code is plain ASCII.
;   * Syntax colouring is done per line when it is drawn: highlight() fills the
;     `cls` array with one colour per character. C and Prog8 need one bit of state
;     carried from line to line (inside a /* */ comment or an %asm block); those
;     bits are cached in `cstate` and recomputed lazily (see line_state()).
;   * Undo keeps ONE snapshot of the whole buffer in banked RAM (banks 1-8) and
;     swaps with it, so pressing `u` again redoes.
;   * Input is a blocking getkey(); the editor is a set of nested loops
;     (editor -> normal_key -> insert_loop/operator_cmd ...) rather than a state machine.
;
; CODE MAP (top to bottom)
;   configuration & state  ->  small helpers  ->  keyboard & VERA  ->  buffer & lines
;   ->  undo  ->  syntax highlighting  ->  drawing  ->  cursor & motion helpers
;   ->  yank / search / bracket match  ->  file I/O  ->  ':' commands  ->  insert mode
;   ->  normal mode  ->  editor loop and start()
;
; NOTES FOR READERS NEW TO PROG8
;   * `iso:"text"` / `iso:'c'` are ASCII literals; plain "text" would be PETSCII.
;   * `@(addr)` reads or writes one byte of memory; `peekw/pokew` do 16-bit words.
;   * `memory(name,size,align)` reserves an uninitialised RAM slab (arrays are limited
;     to 256 elements, so big buffers are done this way).
;   * Sub-routine variables are static (no recursion), so nothing here is recursive.
;
; Build:  make         Run:  make run     (x16emu)      Usage: run it, then :e file

%import syslib
%zeropage basicsafe

main {
    ; ---------------------------------------------------------------
    ; configuration
    ; ---------------------------------------------------------------
    const uword BUFSZ  = 7500
    const uword MAXL   = 500
    const uword REGSZ  = 512
    const ubyte FNLEN  = 40
    const ubyte CMDLEN = 70
    const ubyte DEVICE = 8

    const ubyte NL  = 10
    const ubyte TAB = 9
    const ubyte SP  = 32
    const ubyte ESC = 27

    ; languages
    const ubyte L_NONE = 0
    const ubyte L_C    = 1
    const ubyte L_BAS  = 2
    const ubyte L_ASM  = 3
    const ubyte L_P8   = 4

    ; colour classes (VERA palette indexes)
    const ubyte C_BG   = 0
    const ubyte C_NORM = 1
    const ubyte C_KEY  = 7     ; keywords / mnemonics  yellow
    const ubyte C_TYPE = 5     ; types / functions     green
    const ubyte C_STR  = 8     ; strings               orange
    const ubyte C_NUM  = 3     ; numbers               cyan
    const ubyte C_COM  = 12    ; comments              grey
    const ubyte C_PRE  = 4     ; preprocessor / dirs   purple
    const ubyte C_LAB  = 13    ; labels                lt grn
    const ubyte C_REG  = 14    ; registers             lt blu
    const ubyte C_LNO  = 11    ; line numbers          dk gry

    const ubyte ST_BLOCK = 1

    ; ---------------------------------------------------------------
    ; state
    ; ---------------------------------------------------------------
    ; Text buffer and tables live in raw RAM slabs (see header). Sizes are BUFSZ+2 so a
    ; trailing newline always fits; the line table holds MAXL+2 16-bit offsets.
    uword buf    = memory("buf", 7502, 0)
    uword lstart = memory("lstart", 1004, 0)     ; uword per line start
    uword cstate = memory("cstate", 70, 0)       ; 1 bit per line: starts inside /* */

    uword blen           ; number of bytes of text in buf
    uword nlines
    uword cy             ; cursor line
    uword cx             ; cursor column (char index in line)
    uword want           ; desired visual column for j/k
    uword top            ; first visible line
    uword leftcol        ; horizontal scroll
    ubyte mode           ; 0 normal 1 insert 2 replace
    ubyte lang

    ubyte scrw
    ubyte scrh
    ubyte textrows
    uword vbase
    uword vstride

    ubyte tabw = 8
    bool shownum = false
    bool autoind = true
    bool modified
    bool truncated
    bool quit
    ubyte[41] fname
    ubyte[80] msg

    uword reg = memory("reg", 512, 0)
    uword reglen
    bool reglines

    ubyte[32] lastsearch
    byte searchdir = 1

    ; undo (single level, swap style) held in banked RAM
    uword[2] smeta_len
    uword[2] smeta_cx
    uword[2] smeta_cy
    ubyte usel
    bool uvalid

    uword cstate_valid

    ubyte[256] cls
    ubyte[16] wbuf
    ubyte[16] wbuf2
    ubyte[52] iobuf2
    ubyte[1] chbuf
    ubyte[1] nlbuf = [10]

    bool redraw_all
    uword prev_cy

    ; ---------------------------------------------------------------
    ; small helpers (string / memory)
    ; ---------------------------------------------------------------
    ; Length of a NUL-terminated string (max 255).
    sub slen(uword s) -> ubyte {
        ubyte n = 0
        while @(s + n) != 0
            n++
        return n
    }

    ; Copy a NUL-terminated string, at most maxn characters, always NUL-terminating dst.
    sub copystr(uword dst, uword src, ubyte maxn) {
        ubyte n = 0
        while @(src + n) != 0 and n < maxn {
            @(dst + n) = @(src + n)
            n++
        }
        @(dst + n) = 0
    }

    ; Append src to the end of the NUL-terminated string dst.
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

    ; True if the two NUL-terminated strings are identical.
    sub streq(uword a, uword b) -> bool {
        ubyte i = 0
        while @(a + i) == @(b + i) {
            if @(a + i) == 0
                return true
            i++
        }
        return false
    }

    ; True if the first n characters of a and b are identical.
    sub strneq(uword a, uword b, ubyte n) -> bool {
        ubyte i = 0
        while i < n {
            if @(a + i) != @(b + i)
                return false
            i++
        }
        return true
    }

    ; True if n bytes at a and b are identical.
    sub memeq(uword a, uword b, uword n) -> bool {
        uword i = 0
        while i < n {
            if @(a + i) != @(b + i)
                return false
            i++
        }
        return true
    }

    ; Set the message shown on the status line (truncated to 79 characters).
    sub setmsg(uword s) {
        copystr(&msg, s, 79)
    }

    ; Line-start table accessors: ls(i) is the buffer offset where line i begins.
    sub ls(uword i) -> uword {
        return peekw(lstart + (i << 1))
    }

    ; Store a line-start offset (the table is 16-bit values kept in a raw RAM slab).
    sub setls(uword i, uword v) {
        pokew(lstart + (i << 1), v)
    }

    ; Character class helpers used by the tokenisers and the editor.
    sub is_digit(ubyte c) -> bool {
        return c >= '0' and c <= '9'
    }

    sub is_idstart(ubyte c) -> bool {
        return (c >= iso:'a' and c <= iso:'z') or (c >= iso:'A' and c <= iso:'Z') or c == iso:'_'
    }

    sub is_hex(ubyte c) -> bool {
        return is_digit(c) or (c >= iso:'a' and c <= iso:'f') or (c >= iso:'A' and c <= iso:'F')
    }

    sub is_idchar(ubyte c) -> bool {
        return is_idstart(c) or is_digit(c)
    }

    ; ---------------------------------------------------------------
    ; low level: keyboard, VERA
    ; ---------------------------------------------------------------
    ; Wait for a key and return it (ISO/ASCII, cursor keys are the usual PETSCII codes).
    ; The line below marked SELFTEST-HOOK (a comment) is swapped in by runtest.sh to feed scripted keys.
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

    ; Point VERA data port 0 at the text-map cell (x,y) with auto-increment 1,
    ; so successive writes fill: char, colour, char, colour ... across the row.
    sub vera_at(ubyte x, ubyte y) {
        cx16.VERA_CTRL &= $fe
        cx16.VERA_ADDR = vbase + (y as uword) * vstride + (x as uword) * 2
        cx16.VERA_ADDR_H = $11          ; increment 1, bank 1 ($1xxxx)
    }

    ; Write one character + colour attribute at (x,y). Colour byte = background<<4 | foreground.
    sub put_cell(ubyte x, ubyte y, ubyte ch, ubyte col) {
        vera_at(x, y)
        cx16.VERA_DATA0 = ch
        cx16.VERA_DATA0 = col
    }

    ; Switch the X16 console to ISO mode so screen codes equal ASCII.
    sub iso_mode() {
        cbm.CHROUT($0f)
    }

    ; Read the screen size from the KERNAL and work out where VERA keeps the text map
    ; (layer 1): map width in bytes per row (vstride) and the map's base address (vbase).
    sub init_screen() {
        ubyte m
        scrw, scrh = cbm.SCREEN()
        textrows = scrh - 1
        cx16.VERA_CTRL &= $fe
        m = cx16.VERA_L1_CONFIG
        when (m >> 4) & 3 {
            0 -> vstride = 64
            1 -> vstride = 128
            2 -> vstride = 256
            else -> vstride = 512
        }
        ; mapbase register holds address bits 16:9
        vbase = ((cx16.VERA_L1_MAPBASE & $7f) as uword) << 9
    }

    ; ---------------------------------------------------------------
    ; buffer / lines
    ; ---------------------------------------------------------------
    ; Number of characters in line l (not counting its newline).
    sub linelen(uword l) -> uword {
        return ls(l + 1) - ls(l) - 1
    }

    ; Binary search: which line contains buffer offset pos?
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

    ; Rescan the whole buffer and rebuild the line-start table (after load / undo).
    ; Stops at MAXL lines. Also invalidates the cached comment state.
    sub rebuild_lines() {
        uword i
        nlines = 0
        setls(0, 0)
        i = 0
        while i < blen {
            if @(buf + i) == NL {
                if nlines >= MAXL
                    break
                nlines++
                setls(nlines, i + 1)
            }
            i++
        }
        cstate_valid = 0
    }

    ; Reset to an empty document (a single newline) and home the cursor.
    sub new_buffer() {
        @(buf) = NL
        blen = 1
        rebuild_lines()
        cy = 0
        cx = 0
        want = 0
        top = 0
        leftcol = 0
        modified = false
        uvalid = false
    }

    ; Insert n bytes from src at buffer offset pos. Shifts the tail up, patches the
    ; line-start table (adding entries for any newlines inserted) and returns false
    ; (with a message) if the buffer or the line table would overflow.
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
        if L < cstate_valid
            cstate_valid = L
        modified = true
        redraw_all = true
        return true
    }

    ; Delete n bytes at pos. The buffer's final newline is never removed. Shifts the
    ; tail down and patches the line-start table.
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
        if L < cstate_valid
            cstate_valid = L
        modified = true
        redraw_all = true
    }

    ; ---------------------------------------------------------------
    ; undo snapshots in banked RAM (banks 1-4 and 5-8)
    ; ---------------------------------------------------------------
    ; Undo storage. A snapshot is the raw buffer copied into banked RAM at $A000,
    ; 8 KB per bank: snapshot set 0 uses banks 1-4, set 1 uses banks 5-8.
    ; bank_save copies the current buffer into set `set`.
    sub bank_save(ubyte set) {
        uword off = 0
        uword n
        ubyte b = 1 + set * 4
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

    ; Copy a saved snapshot (n_total bytes) from banked RAM back into the buffer.
    sub bank_load(ubyte set, uword n_total) {
        uword off = 0
        uword n
        ubyte b = 1 + set * 4
        while off < n_total {
            n = n_total - off
            if n > $2000
                n = $2000
            cx16.rambank(b)
            b++
            sys.memcopy($a000, buf + off, n)
            off += n
        }
        cx16.rambank(0)
    }

    ; Take an undo snapshot of the current state; call this BEFORE every change.
    sub snap() {
        bank_save(usel)
        smeta_len[usel] = blen
        smeta_cx[usel] = cx
        smeta_cy[usel] = cy
        uvalid = true
    }

    ; `u`: swap the current buffer with the saved snapshot. Because the current state is
    ; saved into the other slot first, pressing `u` twice returns to where you were (redo).
    sub do_undo() {
        ubyte other = 1 - usel
        if not uvalid {
            setmsg(iso:"Nothing to undo")
            return
        }
        bank_save(other)
        smeta_len[other] = blen
        smeta_cx[other] = cx
        smeta_cy[other] = cy
        blen = smeta_len[usel]
        bank_load(usel, blen)
        cx = smeta_cx[usel]
        cy = smeta_cy[usel]
        usel = other
        rebuild_lines()
        if cy >= nlines
            cy = nlines - 1
        modified = true
        redraw_all = true
    }

    ; ---------------------------------------------------------------
    ; syntax highlighting
    ; ---------------------------------------------------------------
    ; Keyword tables for the highlighters. Each string is a list of space-separated
    ; words with a trailing space (Prog8 strings are limited to 255 characters, so the
    ; longer lists are split across several strings). All matching is done lower-case.
    str kw_c = iso:"asm auto break case const continue default do else enum extern for goto if register return sizeof static struct switch typedef union volatile while "
    str ty_c = iso:"char double float int long short signed unsigned void int8_t int16_t int32_t uint8_t uint16_t uint32_t size_t bool FILE NULL true false BYTE WORD "

    str kw_bas1 = iso:"end for next data input dim read let goto run if restore gosub return rem stop on wait load save verify def poke print cont list clr cmd sys open close get new tab to fn spc then not step and or go else "
    str kw_bas2 = iso:"vpoke bank screen color cls locate mouse pset line frame rect char mon reset bload bvload bvrify bverify ovload dos old geos vload sleep monitor bin$ hex$ "
    str fn_bas = iso:"sgn int abs usr fre pos sqr rnd log exp cos sin tan atn peek len str$ val asc chr$ left$ right$ mid$ vpeek joy rpt$ pointer time ti ti$ st rdtim timer "

    str op_asm1 = iso:"adc and asl bbr0 bbr1 bbr2 bbr3 bbr4 bbr5 bbr6 bbr7 bbs0 bbs1 bbs2 bbs3 bbs4 bbs5 bbs6 bbs7 bcc bcs beq bit bmi bne bpl bra brk bvc bvs clc cld cli clv cmp cpx cpy dec dex dey eor "
    str op_asm2 = iso:"inc inx iny jmp jsr lda ldx ldy lsr nop ora pha php phx phy pla plp plx ply rmb0 rmb1 rmb2 rmb3 rmb4 rmb5 rmb6 rmb7 rol ror rti rts sbc sec sed sei smb0 smb1 smb2 smb3 smb4 smb5 "
    str op_asm3 = iso:"smb6 smb7 sta stp stx sty stz tax tay trb tsb tsx txa txs tya wai asr ina dea "

    str kw_p8 = iso:"sub asmsub extsub romsub inline private if else when for in to downto step while until do repeat break continue return goto not and or xor const void as on call clobbers true false struct enum "
    str kw_p82 = iso:"if_cs if_cc if_eq if_z if_ne if_nz if_pl if_pos if_mi if_neg if_vs if_vc "
    str ty_p81 = iso:"ubyte byte uword word long float str bool peek poke peekw pokew peekf pokef memory len lsb msb abs sqrt sgn min max sort reverse any all sizeof "
    str ty_p82 = iso:"rol ror rol2 ror2 swap push pop pushw popw cmp divmod mkword setlsb setmsb callfar callfar2 rsave rrestore clamp lsl lsr sin cos tan atn ln log2 floor ceil round rnd rndw rndf "

    ; Is the NUL-terminated word w one of the words in `list`?
    ; Lists are strings of space-separated words with a trailing space, e.g. "if else ".
    sub in_list(uword list, uword w) -> bool {
        uword p = list
        ubyte i
        while @(p) != 0 {
            i = 0
            while @(w + i) != 0 and @(p + i) == @(w + i)
                i++
            if @(w + i) == 0 and @(p + i) == SP
                return true
            while @(p) != 0 and @(p) != SP
                p++
            if @(p) == SP
                p++
        }
        return false
    }

    ; Copy the identifier starting at s[i] into wbuf, lower-cased (max 14 chars).
    ; With extra=true, BASIC's $ and % type suffixes count as part of the word.
    sub getword(uword s, ubyte n, ubyte i, bool extra) {
        ubyte k = 0
        ubyte c
        while i < n and (is_idchar(@(s + i)) or (extra and (@(s + i) == iso:'$' or @(s + i) == iso:'%'))) {
            if k < 14 {
                c = @(s + i)
                if c >= iso:'A' and c <= iso:'Z'
                    c += 32
                wbuf[k] = c
                k++
            }
            i++
        }
        wbuf[k] = 0
    }

    ; Give characters fstart..fend-1 of the current line the colour class `col`.
    sub fillc(ubyte fstart, ubyte fend, ubyte col) {
        while fstart < fend {
            cls[fstart] = col
            fstart++
        }
    }

    ; Colour one line of C. s = line text, n = length, st = state at the start of the line
    ; (bit 0 set = we are inside a /* */ comment). Returns the state at the end of the line.
    ; Handles // and /* */ comments, strings and chars, #preprocessor lines, <header.h>,
    ; numbers, keywords and types. Colours go into the `cls` array.
    sub hl_c(uword s, ubyte n, ubyte st) -> ubyte {
        ubyte i = 0
        ubyte j
        ubyte c
        ubyte p
        ubyte k
        ubyte m
        bool same
        bool first = true

        while i < n {
            c = @(s + i)
            if st & ST_BLOCK != 0 {
                j = i
                while j < n and not (@(s + j) == iso:'*' and j + 1 < n and @(s + j + 1) == iso:'/')
                    j++
                if j < n {
                    j += 2
                    st &= $fe
                }
                fillc(i, j, C_COM)
                i = j
                continue
            }
            if c == SP or c == TAB {
                cls[i] = C_NORM
                i++
                continue
            }
            if c == iso:'/' and i + 1 < n and @(s + i + 1) == iso:'/' {
                fillc(i, n, C_COM)
                return st
            }
            if c == iso:'/' and i + 1 < n and @(s + i + 1) == iso:'*' {
                st |= ST_BLOCK
                cls[i] = C_COM
                cls[i + 1] = C_COM
                i += 2
                continue
            }
            if c == iso:'#' and first {
                j = i
                while j < n and @(s + j) != SP and @(s + j) != TAB and @(s + j) != iso:'<' and @(s + j) != iso:'"'
                    j++
                fillc(i, j, C_PRE)
                i = j
                first = false
                continue
            }
            first = false
            if c == iso:'"' or c == iso:'\'' {
                j = i + 1
                while j < n and @(s + j) != c {
                    if @(s + j) == iso:'\\'
                        j++
                    j++
                }
                if j < n
                    j++
                if j > n
                    j = n
                fillc(i, j, C_STR)
                i = j
                continue
            }
            if c == iso:'<' and i > 0 and cls[i - 1] == C_NORM {    ; maybe <stdio.h> after #include
                p = 0
                while p < i and (@(s + p) == SP or @(s + p) == TAB)
                    p++
                if @(s + p) == iso:'#' {
                    j = i
                    while j < n and @(s + j) != iso:'>'
                        j++
                    if j < n
                        j++
                    fillc(i, j, C_STR)
                    i = j
                    continue
                }
            }
            if is_digit(c) {
                j = i + 1
                while j < n and (is_idchar(@(s + j)) or @(s + j) == iso:'.')
                    j++
                fillc(i, j, C_NUM)
                i = j
                continue
            }
            if is_idstart(c) {
                j = i
                while j < n and is_idchar(@(s + j))
                    j++
                getword(s, n, i, false)
                ; keywords are case sensitive in C, getword lowercases:
                ; compare against original only if it was already lower/same
                same = true
                k = 0
                while k < j - i and k < 14 {
                    if @(s + i + k) != wbuf[k] {
                        same = false
                        break
                    }
                    k++
                }
                if same and in_list(kw_c, &wbuf)
                    fillc(i, j, C_KEY)
                else if in_list(ty_c, &wbuf)
                    fillc(i, j, C_TYPE)
                else if not same {
                    ; case-sensitive types like FILE, NULL
                    m = j - i
                    if m > 14
                        m = 14
                    k = 0
                    while k < m {
                        wbuf2[k] = @(s + i + k)
                        k++
                    }
                    wbuf2[m] = 0
                    if in_list(ty_c, &wbuf2)
                        fillc(i, j, C_TYPE)
                    else
                        fillc(i, j, C_NORM)
                } else
                    fillc(i, j, C_NORM)
                i = j
                continue
            }
            cls[i] = C_NORM
            i++
        }
        return st
    }

    ; Colour one line of Commander X16 BASIC: leading line number, strings, numbers
    ; ($hex too), keywords, functions, and REM comments. BASIC has no multi-line state.
    sub hl_bas(uword s, ubyte n, ubyte st) -> ubyte {
        ubyte i = 0
        ubyte j
        ubyte c

        ; leading line number
        while i < n and @(s + i) == SP {
            cls[i] = C_NORM
            i++
        }
        j = i
        while j < n and is_digit(@(s + j))
            j++
        fillc(i, j, C_LNO)
        i = j
        while i < n {
            c = @(s + i)
            if c == iso:'"' {
                j = i + 1
                while j < n and @(s + j) != iso:'"'
                    j++
                if j < n
                    j++
                fillc(i, j, C_STR)
                i = j
                continue
            }
            if is_digit(c) or (c == iso:'.' and i + 1 < n and is_digit(@(s + i + 1))) or
               (c == iso:'$' and i + 1 < n and is_hex(@(s + i + 1))) {
                j = i + 1
                if c == iso:'$' {
                    while j < n and is_hex(@(s + j))
                        j++
                } else {
                    while j < n and (is_digit(@(s + j)) or @(s + j) == iso:'.')
                        j++
                }
                fillc(i, j, C_NUM)
                i = j
                continue
            }
            if is_idstart(c) {
                j = i
                while j < n and (is_idchar(@(s + j)) or @(s + j) == iso:'$' or @(s + j) == iso:'%')
                    j++
                getword(s, n, i, true)
                if streq(&wbuf, iso:"rem") {
                    fillc(i, n, C_COM)
                    return st
                }
                if in_list(kw_bas1, &wbuf) or in_list(kw_bas2, &wbuf)
                    fillc(i, j, C_KEY)
                else if in_list(fn_bas, &wbuf)
                    fillc(i, j, C_TYPE)
                else
                    fillc(i, j, C_NORM)
                i = j
                continue
            }
            cls[i] = C_NORM
            i++
        }
        return st
    }

    ; Colour one line of 65C02 assembly: a label at column 0, `;` comments, strings,
    ; $hex/%bin/decimal numbers, .directives, mnemonics (first word after the label),
    ; and the A/X/Y registers used as operands.
    sub hl_asm(uword s, ubyte n, ubyte st) -> ubyte {
        ubyte i = 0
        ubyte j
        ubyte c
        bool opdone = false

        if n != 0 and @(s) != SP and @(s) != TAB and @(s) != iso:';' and @(s) != iso:'.' and
           @(s) != iso:'!' and @(s) != iso:'*' and @(s) != iso:'#' {
            ; label at column 0
            j = 0
            while j < n and @(s + j) != SP and @(s + j) != TAB and @(s + j) != iso:':' and @(s + j) != iso:';' and @(s + j) != iso:'='
                j++
            if j < n and @(s + j) == iso:':'
                j++
            fillc(0, j, C_LAB)
            i = j
        }
        while i < n {
            c = @(s + i)
            if c == SP or c == TAB {
                cls[i] = C_NORM
                i++
                continue
            }
            if c == iso:';' {
                fillc(i, n, C_COM)
                return st
            }
            if c == iso:'"' or c == iso:'\'' {
                j = i + 1
                while j < n and @(s + j) != c {
                    if @(s + j) == iso:'\\'
                        j++
                    j++
                }
                if j < n
                    j++
                if j > n
                    j = n
                fillc(i, j, C_STR)
                i = j
                opdone = true
                continue
            }
            if c == iso:'$' or c == iso:'%' {
                j = i + 1
                while j < n and is_hex(@(s + j))
                    j++
                if j > i + 1 {
                    fillc(i, j, C_NUM)
                    i = j
                    opdone = true
                    continue
                }
                cls[i] = C_NORM
                i++
                continue
            }
            if is_digit(c) {
                j = i + 1
                while j < n and is_idchar(@(s + j))
                    j++
                fillc(i, j, C_NUM)
                i = j
                opdone = true
                continue
            }
            if (c == iso:'.' or c == iso:'!') and not opdone and i + 1 < n and is_idstart(@(s + i + 1)) {
                j = i + 1
                while j < n and is_idchar(@(s + j))
                    j++
                fillc(i, j, C_PRE)
                i = j
                opdone = true
                continue
            }
            if is_idstart(c) or c == iso:'@' {
                j = i + 1
                while j < n and (is_idchar(@(s + j)) or @(s + j) == iso:'.')
                    j++
                if c == iso:'@'
                    getword(s, n, i + 1, false)
                else
                    getword(s, n, i, false)
                if not opdone and c != iso:'@' {
                    opdone = true
                    if in_list(op_asm1, &wbuf) or in_list(op_asm2, &wbuf) or in_list(op_asm3, &wbuf) {
                        fillc(i, j, C_KEY)
                        i = j
                        continue
                    }
                }
                opdone = true
                if j - i == 1 and (wbuf[0] == iso:'a' or wbuf[0] == iso:'x' or wbuf[0] == iso:'y') and i > 0
                    fillc(i, j, C_REG)
                else
                    fillc(i, j, C_NORM)
                i = j
                continue
            }
            cls[i] = C_NORM
            i++
        }
        return st
    }

    ; Colour one line of Prog8: `;` comments, strings (with encoding prefixes like iso:),
    ; $hex / %bin numbers, %directives, keywords, types and builtin functions.
    ; A `%asm {{ ... }}` block spans lines: bit 0 of the state means 'inside the block',
    ; and those lines are coloured with hl_asm(). Returns the state at the end of the line.
    sub hl_p8(uword s, ubyte n, ubyte st) -> ubyte {
        ubyte i = 0
        ubyte j
        ubyte c
        ubyte k
        bool same

        if st & ST_BLOCK != 0 {
            ; inside %asm {{ ... }}
            j = 0
            while j < n and not (@(s + j) == iso:'}' and j + 1 < n and @(s + j + 1) == iso:'}')
                j++
            void hl_asm(s, n, 0)
            if j < n {
                fillc(j, j + 2, C_PRE)
                st &= $fe
            }
            return st
        }
        while i < n {
            c = @(s + i)
            if c == SP or c == TAB {
                cls[i] = C_NORM
                i++
                continue
            }
            if c == iso:';' {
                fillc(i, n, C_COM)
                return st
            }
            if c == iso:'"' or c == iso:'\'' {
                j = i + 1
                while j < n and @(s + j) != c {
                    if @(s + j) == iso:'\\'
                        j++
                    j++
                }
                if j < n
                    j++
                if j > n
                    j = n
                fillc(i, j, C_STR)
                i = j
                continue
            }
            if c == iso:'%' and i + 1 < n and is_idstart(@(s + i + 1)) {
                ; directive
                j = i + 1
                while j < n and is_idchar(@(s + j))
                    j++
                fillc(i, j, C_PRE)
                if j - i == 4 and @(s + i + 1) == iso:'a' and @(s + i + 2) == iso:'s' and @(s + i + 3) == iso:'m' {
                    ; %asm {{ : block continues on following lines unless closed here
                    k = j
                    while k < n and not (@(s + k) == iso:'{' and k + 1 < n and @(s + k + 1) == iso:'{')
                        k++
                    if k < n {
                        fillc(j, k, C_NORM)
                        fillc(k, k + 2, C_PRE)
                        k += 2
                        j = k
                        while j < n and not (@(s + j) == iso:'}' and j + 1 < n and @(s + j + 1) == iso:'}')
                            j++
                        if j < n {
                            fillc(k, j, C_NORM)
                            fillc(j, j + 2, C_PRE)
                            j += 2
                        } else {
                            fillc(k, n, C_NORM)
                            st |= ST_BLOCK
                            j = n
                        }
                    }
                }
                i = j
                continue
            }
            if c == iso:'$' or c == iso:'%' {
                j = i + 1
                while j < n and is_hex(@(s + j))
                    j++
                if j > i + 1 {
                    fillc(i, j, C_NUM)
                    i = j
                    continue
                }
                cls[i] = C_NORM
                i++
                continue
            }
            if is_digit(c) {
                j = i + 1
                while j < n and (is_idchar(@(s + j)) or @(s + j) == iso:'.')
                    j++
                fillc(i, j, C_NUM)
                i = j
                continue
            }
            if is_idstart(c) {
                j = i
                while j < n and is_idchar(@(s + j))
                    j++
                getword(s, n, i, false)
                same = true
                k = 0
                while k < j - i and k < 14 {
                    if @(s + i + k) != wbuf[k] {
                        same = false
                        break
                    }
                    k++
                }
                if same and (in_list(kw_p8, &wbuf) or in_list(kw_p82, &wbuf))
                    fillc(i, j, C_KEY)
                else if same and (in_list(ty_p81, &wbuf) or in_list(ty_p82, &wbuf))
                    fillc(i, j, C_TYPE)
                else
                    fillc(i, j, C_NORM)
                i = j
                continue
            }
            cls[i] = C_NORM
            i++
        }
        return st
    }

    ; Colour line s (n16 chars) for the current language. Fills cls[0..n]; returns the
    ; end-of-line state. Only the first 255 characters of a line are coloured.
    sub highlight(uword s, uword n16, ubyte st) -> ubyte {
        ubyte n
        ubyte k
        if n16 > 255
            n = 255
        else
            n = lsb(n16)
        k = 0
        repeat {
            cls[k] = C_NORM
            if k == n
                break
            k++
        }
        when lang {
            L_C -> return hl_c(s, n, st)
            L_BAS -> return hl_bas(s, n, st)
            L_ASM -> return hl_asm(s, n, st)
            L_P8 -> return hl_p8(s, n, st)
        }
        return st
    }

    ; State (see hl_c) at the START of line l. C/Prog8 need it for multi-line constructs.
    ; cstate holds one cached bit per line; we extend the cache by highlighting forward
    ; from cstate_valid, so an edit only invalidates the lines below it.
    sub line_state(uword l) -> ubyte {
        ubyte st
        ubyte bit
        uword ix
        if lang != L_C and lang != L_P8
            return 0
        while cstate_valid < l {
            if cstate_valid == 0
                st = 0
            else {
                ix = cstate_valid >> 3
                bit = lsb(cstate_valid) & 7
                st = (@(cstate + ix) >> bit) & 1
            }
            st = highlight(buf + ls(cstate_valid), linelen(cstate_valid), st)
            cstate_valid++
            ix = cstate_valid >> 3
            bit = lsb(cstate_valid) & 7
            if st & ST_BLOCK != 0
                @(cstate + ix) |= (1 << bit)
            else
                @(cstate + ix) &= ((1 << bit) ^ $ff)
        }
        if l == 0
            return 0
        ix = l >> 3
        bit = lsb(l) & 7
        return (@(cstate + ix) >> bit) & 1
    }

    ; extension table: name, NUL, language byte ...
    str extlist = iso:"c h bas bi asm s inc a65 a p8 prog8 "
    ubyte[11] extlang = [L_C, L_C, L_BAS, L_BAS, L_ASM, L_ASM, L_ASM, L_ASM, L_ASM, L_P8, L_P8]

    ; Choose the highlighting language from the file extension (case-insensitive).
    sub detect_lang(uword name) {
        ubyte dot = 255
        ubyte i = 0
        ubyte n = 0
        ubyte c
        if @(name) == 0
            return
        while @(name + i) != 0 {
            if @(name + i) == iso:'.'
                dot = i
            i++
        }
        if dot == 255
            return
        dot++
        while @(name + dot) != 0 and n < 5 {
            c = @(name + dot)
            if c >= iso:'A' and c <= iso:'Z'
                c += 32
            wbuf[n] = c
            n++
            dot++
        }
        wbuf[n] = 0
        cstate_valid = 0
        ; walk the extension list
        i = 0
        n = 0
        while i < 11 {
            if in_list(extlist_single(i), &wbuf) {
                lang = extlang[i]
                return
            }
            i++
        }
    }

    ; helper: a one-word list (for matching a single extension)
    ubyte[10] extword

    ; Helper for detect_lang: build a one-word list for extension number idx.
    sub extlist_single(ubyte idx) -> uword {
        ; find word number idx in extlist and copy it (plus trailing space) to extword
        uword p = extlist
        ubyte w = 0
        ubyte n = 0
        while w < idx {
            while @(p) != SP
                p++
            p++
            w++
        }
        while @(p) != SP {
            extword[n] = @(p)
            n++
            p++
        }
        extword[n] = SP
        extword[n + 1] = 0
        return &extword
    }

    ; ---------------------------------------------------------------
    ; drawing
    ; ---------------------------------------------------------------
    ; Screen column of character index `upto` in line l, expanding tabs to the tab width.
    sub visual_col(uword l, uword upto) -> uword {
        uword s = buf + ls(l)
        uword i = 0
        uword v = 0
        while i < upto {
            if @(s + i) == TAB
                v += tabw - (v % tabw)
            else
                v++
            i++
        }
        return v
    }

    ; Width of the line-number gutter (0 when :set nonu).
    sub gutter() -> ubyte {
        if shownum
            return 5
        return 0
    }

    ; Draw a NUL-terminated string on a full screen row, padding with spaces.
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

    ubyte[6] nb

    ; Draw text-area row `row`: the line at top+row with syntax colours, tabs expanded and
    ; horizontal scroll applied; past the end of the file it draws a `~` like vi.
    sub draw_row(ubyte row) {
        uword l = top + row
        ubyte g = gutter()
        ubyte x
        uword vcol = 0
        uword n
        uword i
        uword s
        ubyte st
        ubyte ch
        ubyte col
        ubyte width = scrw
        uword v
        ubyte p
        uword w

        vera_at(0, row)
        if l >= nlines {
            cx16.VERA_DATA0 = iso:'~'
            cx16.VERA_DATA0 = C_LAB
            x = 1
            while x < width {
                cx16.VERA_DATA0 = SP
                cx16.VERA_DATA0 = C_NORM
                x++
            }
            return
        }
        s = buf + ls(l)
        n = linelen(l)
        st = line_state(l)
        void highlight(s, n, st)
        x = 0
        if g != 0 {
            v = l + 1
            p = 3
            nb[0] = SP
            nb[1] = SP
            nb[2] = SP
            nb[3] = SP
            nb[4] = SP
            nb[5] = 0
            repeat {
                nb[p] = lsb(v % 10) + '0'
                v /= 10
                if v == 0 or p == 0
                    break
                p--
            }
            while x < 4 {
                cx16.VERA_DATA0 = nb[x]
                cx16.VERA_DATA0 = C_LNO
                x++
            }
            cx16.VERA_DATA0 = SP
            cx16.VERA_DATA0 = C_NORM
            x++
        }
        i = 0
        while i < n and x < width {
            ch = @(s + i)
            if i < 255
                col = cls[lsb(i)]
            else
                col = C_NORM
            if ch == TAB {
                w = tabw - (vcol % tabw)
                while w != 0 {
                    w--
                    if vcol >= leftcol and x < width {
                        cx16.VERA_DATA0 = SP
                        cx16.VERA_DATA0 = col
                        x++
                    }
                    vcol++
                }
            } else {
                if ch < 32
                    ch = iso:'?'
                if vcol >= leftcol {
                    cx16.VERA_DATA0 = ch
                    cx16.VERA_DATA0 = col
                    x++
                }
                vcol++
            }
            i++
        }
        while x < width {
            cx16.VERA_DATA0 = SP
            cx16.VERA_DATA0 = C_NORM
            x++
        }
    }

    ; Screen column of the cursor.
    sub cursor_scrx() -> ubyte {
        return lsb(visual_col(cy, cx) - leftcol) + gutter()
    }

    ; Append src to sline at offset d; returns the new offset.
    sub scat(ubyte d, uword src) -> ubyte {
        while @(src) != 0 {
            sline[d] = @(src)
            d++
            src++
        }
        return d
    }

    ubyte[84] sline
    ubyte[24] rbuf

    ; Append the decimal number v to rbuf at offset e; returns the new offset.
    sub rnum(ubyte e, uword v) -> ubyte {
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
            rbuf[e] = tmp[t]
            e++
        }
        return e
    }

    ; Draw the bottom line. With cmdline set it shows the `:` / `/` prompt instead;
    ; otherwise mode or file name on the left and language, line,column on the right.
    sub draw_status(uword cmdline) {
        ubyte d = 0
        ubyte e
        ubyte i
        if cmdline != 0 {
            draw_text(scrh - 1, cmdline, (C_BG << 4) | C_NORM)
            return
        }
        if mode == 1
            d = scat(d, iso:"-- INSERT --")
        else if mode == 2
            d = scat(d, iso:"-- REPLACE --")
        else {
            if fname[0] != 0
                d = scat(d, &fname)
            else
                d = scat(d, iso:"[No Name]")
            if modified
                d = scat(d, iso:" [+]")
        }
        sline[d] = SP
        d++
        d = scat(d, &msg)
        while d < scrw {
            sline[d] = SP
            d++
        }
        ; right side
        e = 0
        when lang {
            L_NONE -> {
                rbuf[0] = iso:'t'
                rbuf[1] = iso:'e'
                rbuf[2] = iso:'x'
                rbuf[3] = iso:'t'
                e = 4
            }
            L_C -> {
                rbuf[0] = iso:'C'
                e = 1
            }
            L_BAS -> {
                rbuf[0] = iso:'B'
                rbuf[1] = iso:'A'
                rbuf[2] = iso:'S'
                rbuf[3] = iso:'I'
                rbuf[4] = iso:'C'
                e = 5
            }
            L_ASM -> {
                rbuf[0] = iso:'a'
                rbuf[1] = iso:'s'
                rbuf[2] = iso:'m'
                e = 3
            }
            else -> {
                rbuf[0] = iso:'p'
                rbuf[1] = iso:'r'
                rbuf[2] = iso:'o'
                rbuf[3] = iso:'g'
                rbuf[4] = iso:'8'
                e = 5
            }
        }
        rbuf[e] = SP
        e++
        e = rnum(e, cy + 1)
        rbuf[e] = iso:','
        e++
        e = rnum(e, cx + 1)
        i = 0
        while i < e {
            sline[scrw - e + i] = rbuf[i]
            i++
        }
        sline[scrw] = 0
        draw_text(scrh - 1, &sline, (C_NORM << 4) | C_BG)
    }

    ; Show the cursor by inverting the colours of the cell under it
    ; (block in normal mode, a different colour in insert/replace).
    sub place_cursor() {
        ubyte x = cursor_scrx()
        ubyte y = lsb(cy - top)
        ubyte col
        ubyte ch
        vera_at(x, y)
        ch = cx16.VERA_DATA0
        if mode == 0
            col = (C_NORM << 4) | C_BG
        else
            col = (C_LAB << 4) | C_BG
        put_cell(x, y, ch, col)
    }

    ; Adjust top / leftcol so the cursor is visible. center=true puts it mid-screen.
    sub scroll_to_cursor(bool center) {
        uword vc = visual_col(cy, cx)
        ubyte g = gutter()
        ubyte w = scrw - g
        uword half = textrows / 2
        if cy < top {
            if center {
                if cy > half
                    top = cy - half
                else
                    top = 0
            } else
                top = cy
            redraw_all = true
        } else if cy >= top + textrows {
            if center
                top = cy - half
            else
                top = cy - textrows + 1
            redraw_all = true
        }
        if vc < leftcol {
            leftcol = vc
            redraw_all = true
        } else if vc >= leftcol + w {
            leftcol = vc - w + 1
            redraw_all = true
        }
    }

    ; Redraw what changed (everything if redraw_all is set, otherwise just the line we
    ; left and the line we are on), then the status line and the cursor.
    sub refresh(bool center) {
        ubyte r
        scroll_to_cursor(center)
        if redraw_all {
            r = 0
            while r < textrows {
                draw_row(r)
                r++
            }
            redraw_all = false
        } else {
            if prev_cy >= top and prev_cy < top + textrows and prev_cy != cy
                draw_row(lsb(prev_cy - top))
            draw_row(lsb(cy - top))
        }
        prev_cy = cy
        draw_status(0)
        place_cursor()
    }

    ; ---------------------------------------------------------------
    ; cursor helpers
    ; ---------------------------------------------------------------
    ; Keep the cursor on the line: in normal mode it cannot sit past the last character.
    sub clamp_cx() {
        uword n = linelen(cy)
        uword maxx
        if mode == 0 and n != 0
            maxx = n - 1
        else
            maxx = n
        if cx > maxx
            cx = maxx
    }

    ; Remember the cursor's screen column so j/k can return to it on shorter lines.
    sub set_want() {
        want = visual_col(cy, cx)
    }

    ; Move cx on the current line to the character nearest the remembered column.
    sub apply_want() {
        uword n = linelen(cy)
        uword i = 0
        uword v = 0
        uword w
        uword s = buf + ls(cy)
        while i < n {
            if @(s + i) == TAB
                w = tabw - (v % tabw)
            else
                w = 1
            if v + w > want
                break
            v += w
            i++
        }
        cx = i
        clamp_cx()
    }

    ; Jump to line l (clamped) and put the cursor on its first non-blank character.
    sub goto_line(uword l) {
        uword s
        uword n
        if l >= nlines
            l = nlines - 1
        cy = l
        cx = 0
        s = buf + ls(cy)
        n = linelen(cy)
        while cx < n and (@(s + cx) == SP or @(s + cx) == TAB)
            cx++
        clamp_cx()
        set_want()
    }

    ; j: down n lines, keeping the wanted column.
    sub move_down(uword n) {
        if cy + n >= nlines
            cy = nlines - 1
        else
            cy += n
        apply_want()
    }

    ; k: up n lines, keeping the wanted column.
    sub move_up(uword n) {
        if n > cy
            cy = 0
        else
            cy -= n
        apply_want()
    }

    ; A 'word' character for w/b motions: letter, digit or underscore.
    sub is_word(ubyte c) -> bool {
        return is_idchar(c)
    }

    ; Buffer offset of the cursor.
    sub cur_pos() -> uword {
        return ls(cy) + cx
    }

    ; Place the cursor at buffer offset pos.
    sub set_pos(uword pos) {
        cy = find_line(pos)
        cx = pos - ls(cy)
        clamp_cx()
        set_want()
    }

    ; Offset of the start of the next word after p (vi's `w`).
    sub word_fwd(uword p) -> uword {
        ubyte c
        if p >= blen - 1
            return blen - 1
        c = @(buf + p)
        if is_word(c) {
            while p < blen - 1 and is_word(@(buf + p))
                p++
        } else if c != SP and c != TAB and c != NL {
            while p < blen - 1 and not is_word(@(buf + p)) and @(buf + p) != SP and @(buf + p) != TAB and @(buf + p) != NL
                p++
        }
        while p < blen - 1 and (@(buf + p) == SP or @(buf + p) == TAB)
            p++
        if p < blen - 1 and @(buf + p) == NL {
            p++                      ; move onto next line start
            while p < blen - 1 and (@(buf + p) == SP or @(buf + p) == TAB)
                p++
        }
        return p
    }

    ; Offset of the start of the word before p (vi's `b`).
    sub word_back(uword p) -> uword {
        if p == 0
            return 0
        p--
        while p > 0 and (@(buf + p) == SP or @(buf + p) == TAB or @(buf + p) == NL)
            p--
        if is_word(@(buf + p)) {
            while p > 0 and is_word(@(buf + p - 1))
                p--
        } else {
            while p > 0 and not is_word(@(buf + p - 1)) and @(buf + p - 1) != SP and @(buf + p - 1) != TAB and @(buf + p - 1) != NL
                p--
        }
        return p
    }

    ; ---------------------------------------------------------------
    ; register (yank) handling
    ; ---------------------------------------------------------------
    ; Copy buffer[a..b) into the register (the paste buffer). linewise = whole lines.
    sub yank_range(uword a, uword b, bool linewise) {
        uword n = b - a
        if n > REGSZ {
            n = REGSZ
            setmsg(iso:"Yank truncated")
        }
        sys.memcopy(buf + a, reg, n)
        reglen = n
        reglines = linewise
    }

    ; Yank buffer[a..b) into the register, then delete it (vi's `d`).
    sub delete_range(uword a, uword b, bool linewise) {
        yank_range(a, b, linewise)
        buf_delete(a, b - a)
    }

    uword lr_a
    uword lr_b

    ; For cnt lines starting at l, set lr_a/lr_b to the buffer range they cover.
    sub line_range(uword l, uword cnt) {
        uword last = l + cnt
        if last > nlines
            last = nlines
        lr_a = ls(l)
        lr_b = ls(last)
    }

    ; ---------------------------------------------------------------
    ; search
    ; ---------------------------------------------------------------
    ; Search for `lastsearch` (a plain string, no regex) from the cursor, wrapping around the
    ; file. dir = +1 forward, -1 backward. Moves the cursor and returns true if found.
    sub do_search(byte dir, bool from_next) -> bool {
        uword plen = slen(&lastsearch)
        uword p
        uword start
        uword i
        if plen == 0 {
            setmsg(iso:"No previous search")
            return false
        }
        start = cur_pos()
        if dir > 0 {
            p = start
            if from_next
                p++
            i = 0
            while i < blen {
                if p >= blen
                    p -= blen
                if p + plen <= blen and @(buf + p) == lastsearch[0] and memeq(buf + p, &lastsearch, plen) {
                    set_pos(p)
                    return true
                }
                i++
                p++
            }
        } else {
            p = start
            i = 0
            while i < blen {
                if p != 0
                    p--
                else
                    p = blen - 1
                if p + plen <= blen and @(buf + p) == lastsearch[0] and memeq(buf + p, &lastsearch, plen) {
                    set_pos(p)
                    return true
                }
                i++
            }
        }
        setmsg(iso:"Pattern not found")
        return false
    }

    ; `%`: jump to the bracket matching the one under the cursor, counting nesting.
    sub match_bracket() {
        uword p = cur_pos()
        uword q
        ubyte c = @(buf + p)
        ubyte t
        byte d
        uword depth = 0
        when c {
            iso:'(' -> {
                t = iso:')'
                d = 1
            }
            iso:'[' -> {
                t = iso:']'
                d = 1
            }
            iso:'{' -> {
                t = iso:'}'
                d = 1
            }
            iso:')' -> {
                t = iso:'('
                d = -1
            }
            iso:']' -> {
                t = iso:'['
                d = -1
            }
            iso:'}' -> {
                t = iso:'{'
                d = -1
            }
            else -> return
        }
        q = p
        repeat {
            if d > 0 {
                q++
                if q >= blen
                    return
            } else {
                if q == 0
                    return
                q--
            }
            if @(buf + q) == c
                depth++
            else if @(buf + q) == t {
                if depth == 0 {
                    set_pos(q)
                    return
                }
                depth--
            }
        }
    }

    ; ---------------------------------------------------------------
    ; file I/O
    ; ---------------------------------------------------------------
    ; CMDR-DOS wants PETSCII file names: convert ASCII in place (a-z -> $41-$5A, A-Z -> $C1-$DA).
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

    ubyte[40] dstat

    ; Read the drive's status line (e.g. "62,file not found,00,00") via channel 15.
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

    ; Load a file into the buffer (device 8). Converts CR / CRLF to LF, drops NULs, makes
    ; sure the text ends in a newline and sets `truncated` if it did not fit.
    ; Returns false (and a message) if the file could not be read.
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
            ; 62 = file not found, etc
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

    ; Write the buffer to a file, replacing it (the `@:` prefix means overwrite).
    ; Reports the drive's status if it is not "00".
    sub save_file(uword name) -> bool {
        uword o = 0
        ubyte c

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

    ; `:e name`: load a file, reset the cursor and undo state, and pick the syntax language.
    sub open_file(uword name) {
        bool ok
        copystr(&fname, name, FNLEN)
        lang = L_NONE
        ok = load_file(name)
        if not ok {
            new_buffer()
        } else {
            cy = 0
            cx = 0
            want = 0
            top = 0
            leftcol = 0
            modified = false
            uvalid = false
            if truncated
                setmsg(iso:"File truncated (too big)!")
            else
                setmsg(iso:"File loaded")
        }
        detect_lang(name)
        redraw_all = true
    }

    ; ---------------------------------------------------------------
    ; line reading for ':' and '/' prompts
    ; ---------------------------------------------------------------
    ubyte[84] rline

    ; Prompt on the bottom line and read a line of text with simple editing (backspace, Esc
    ; cancels). prompt is the leading character (':' or '/' or '?'). Returns false if cancelled.
    sub read_line(ubyte prompt, uword out, ubyte maxn) -> bool {
        ubyte n = 0
        ubyte k
        ubyte i
        repeat {
            rline[0] = prompt
            i = 0
            while i < n {
                rline[i + 1] = @(out + i)
                i++
            }
            rline[n + 1] = iso:'_'
            rline[n + 2] = 0
            draw_status(&rline)
            k = getkey()
            if k == ESC {
                @(out) = 0
                return false
            }
            if k == 13 or k == 10 {
                @(out + n) = 0
                return true
            }
            if k == $14 or k == $08 or k == $7f {
                if n == 0 {
                    @(out) = 0
                    return false
                }
                n--
                continue
            }
            if k >= 32 and k < 127 and n < maxn - 1 {
                @(out + n) = k
                n++
            }
        }
    }

    ; ---------------------------------------------------------------
    ; :commands
    ; ---------------------------------------------------------------
    uword pp          ; parse pointer

    ; Read a decimal number at the command parse pointer pp, advancing past it.
    sub parse_num() -> uword {
        uword v = 0
        while is_digit(@(pp)) {
            v = v * 10 + (@(pp) - '0')
            pp++
        }
        return v
    }

    ubyte[12] cword

    ; `:set syntax=...` / `:syntax ...`: choose the highlighting language by name.
    sub set_syntax(uword v) {
        if streq(v, iso:"c")
            lang = L_C
        else if streq(v, iso:"basic") or streq(v, iso:"bas")
            lang = L_BAS
        else if streq(v, iso:"asm") or streq(v, iso:"s")
            lang = L_ASM
        else if streq(v, iso:"prog8") or streq(v, iso:"p8")
            lang = L_P8
        else
            lang = L_NONE
        cstate_valid = 0
        redraw_all = true
    }

    ubyte[32] spat
    ubyte[32] srep

    ; `:[range]s/old/new/[g]` -- plain-text substitute (no regular expressions).
    ; pp points at the delimiter after the `s`. Any delimiter works; `\x` gives a literal x.
    ; Without g only the first match on each line is replaced. The whole substitute is one
    ; undo step, the replacement is inserted before the old text is removed (so a full
    ; buffer leaves the text untouched), and the cursor ends on the last changed line.
    sub do_subst(uword l1, uword l2) {
        ubyte delim = @(pp)
        ubyte n
        ubyte plen
        ubyte rlen
        bool global = false
        bool changed = false
        bool abort = false
        bool found
        uword l
        uword q
        uword endp
        uword nsub = 0
        uword lastl = 0
        ubyte e

        if delim == 0 {
            setmsg(iso:"Usage: :s/old/new/[g]")
            return
        }
        pp++
        n = 0
        while @(pp) != 0 and @(pp) != delim {
            if @(pp) == iso:'\\' and @(pp + 1) != 0
                pp++
            if n < 31 {
                spat[n] = @(pp)
                n++
            }
            pp++
        }
        spat[n] = 0
        plen = n
        if @(pp) == delim
            pp++
        n = 0
        while @(pp) != 0 and @(pp) != delim {
            if @(pp) == iso:'\\' and @(pp + 1) != 0
                pp++
            if n < 31 {
                srep[n] = @(pp)
                n++
            }
            pp++
        }
        srep[n] = 0
        rlen = n
        if @(pp) == delim
            pp++
        while @(pp) != 0 {
            if @(pp) == iso:'g'
                global = true
            pp++
        }
        if plen == 0 {
            setmsg(iso:"Empty pattern")
            return
        }
        if l2 >= nlines
            l2 = nlines - 1
        if l1 > l2 {
            setmsg(iso:"Invalid range")
            return
        }
        l = l1
        while l <= l2 and not abort {
            q = ls(l)
            repeat {
                endp = ls(l + 1) - 1
                found = false
                while q + plen <= endp {
                    if @(buf + q) == spat[0] and memeq(buf + q, &spat, plen) {
                        found = true
                        break
                    }
                    q++
                }
                if not found
                    break
                if not changed {
                    snap()
                    changed = true
                }
                if rlen != 0 {
                    ; insert first so a full buffer leaves the text untouched
                    if not buf_insert(q, &srep, rlen) {
                        abort = true
                        break
                    }
                }
                buf_delete(q + rlen, plen)
                nsub++
                lastl = l
                q += rlen
                if not global
                    break
            }
            l++
        }
        if nsub == 0 {
            if not abort
                setmsg(iso:"Pattern not found")
            return
        }
        cy = lastl
        goto_line(cy)
        e = rnum(0, nsub)
        rbuf[e] = 0
        copystr(&sline, &rbuf, 20)
        if nsub == 1
            appendstr(&sline, iso:" substitution")
        else
            appendstr(&sline, iso:" substitutions")
        setmsg(&sline)
        redraw_all = true
    }

    ; Parse and run an ex command typed after `:`. Syntax: [range] word[!] arguments, where the
    ; range is %, N, $, ., or N,M. Supports w q wq x e s set syntax help and a bare
    ; line number (go to line).
    sub exec_cmd(uword cmd) {
        uword l1 = 0
        uword l2 = 0
        bool haverange = false
        bool bang = false
        ubyte w = 0
        uword v
        uword t

        pp = cmd
        while @(pp) == SP
            pp++
        if @(pp) == iso:'%' {
            l1 = 0
            l2 = nlines - 1
            haverange = true
            pp++
        } else if is_digit(@(pp)) or @(pp) == iso:'$' or @(pp) == iso:'.' {
            if @(pp) == iso:'$' {
                l1 = nlines - 1
                pp++
            } else if @(pp) == iso:'.' {
                l1 = cy
                pp++
            } else {
                l1 = parse_num()
                if l1 != 0
                    l1--
            }
            l2 = l1
            haverange = true
            if @(pp) == iso:',' {
                pp++
                if @(pp) == iso:'$' {
                    l2 = nlines - 1
                    pp++
                } else if @(pp) == iso:'.' {
                    l2 = cy
                    pp++
                } else {
                    l2 = parse_num()
                    if l2 != 0
                        l2--
                }
            }
        }
        while @(pp) == SP
            pp++
        if @(pp) == 0 {
            if haverange
                goto_line(l2)
            return
        }
        while is_idstart(@(pp)) and w < 10 {
            cword[w] = @(pp)
            w++
            pp++
        }
        cword[w] = 0
        if @(pp) == iso:'!' {
            bang = true
            pp++
        }
        while @(pp) == SP
            pp++

        if streq(&cword, iso:"s") {
            if not haverange {
                l1 = cy
                l2 = cy
            }
            do_subst(l1, l2)
        } else if streq(&cword, iso:"w") or streq(&cword, iso:"write") {
            if @(pp) != 0 {
                copystr(&fname, pp, FNLEN)
                detect_lang(&fname)
            }
            if fname[0] == 0 {
                setmsg(iso:"No file name")
                return
            }
            if truncated and not bang {
                setmsg(iso:"File was truncated; use :w! to force")
                return
            }
            void save_file(&fname)
            redraw_all = true
        } else if streq(&cword, iso:"q") or streq(&cword, iso:"quit") {
            if modified and not bang
                setmsg(iso:"No write since last change (add ! to override)")
            else
                quit = true
        } else if streq(&cword, iso:"wq") or streq(&cword, iso:"x") or streq(&cword, iso:"exit") {
            if @(pp) != 0
                copystr(&fname, pp, FNLEN)
            if fname[0] == 0 {
                setmsg(iso:"No file name")
                return
            }
            if save_file(&fname)
                quit = true
        } else if streq(&cword, iso:"e") or streq(&cword, iso:"edit") {
            if modified and not bang {
                setmsg(iso:"No write since last change (add ! to override)")
                return
            }
            if @(pp) != 0
                open_file(pp)
            else if fname[0] != 0
                open_file(&fname)
            else
                setmsg(iso:"No file name")
        } else if streq(&cword, iso:"set") or streq(&cword, iso:"se") {
            if strneq(pp, iso:"syntax=", 7) {
                set_syntax(pp + 7)
            } else if strneq(pp, iso:"syn=", 4) {
                set_syntax(pp + 4)
            } else if strneq(pp, iso:"ft=", 3) {
                set_syntax(pp + 3)
            } else if strneq(pp, iso:"ts=", 3) {
                pp += 3
                t = parse_num()
                if t >= 1 and t <= 16 {
                    tabw = lsb(t)
                    redraw_all = true
                }
            } else if streq(pp, iso:"nu") or streq(pp, iso:"number") {
                shownum = true
                redraw_all = true
            } else if streq(pp, iso:"nonu") or streq(pp, iso:"nonumber") {
                shownum = false
                redraw_all = true
            } else if streq(pp, iso:"ai") or streq(pp, iso:"autoindent")
                autoind = true
            else if streq(pp, iso:"noai") or streq(pp, iso:"noautoindent")
                autoind = false
            else
                setmsg(iso:"Unknown option")
        } else if streq(&cword, iso:"syntax") or streq(&cword, iso:"syn") {
            set_syntax(pp)
        } else if streq(&cword, iso:"help") or streq(&cword, iso:"h") {
            setmsg(iso:":w :q :wq :e f :set syntax=c|basic|asm|prog8 :%s/a/b/g")
        } else {
            setmsg(iso:"Not an editor command")
        }
    }

    ; ---------------------------------------------------------------
    ; insert mode
    ; ---------------------------------------------------------------
    ; Insert one character at the cursor and advance.
    sub insert_char(ubyte c) {
        chbuf[0] = c
        if buf_insert(cur_pos(), &chbuf, 1)
            cx++
    }

    ubyte[40] ins

    ; Enter in insert mode: split the line, copying leading whitespace if autoindent is on.
    sub do_newline() {
        ubyte n = 1
        uword s
        uword i
        ins[0] = NL
        if autoind {
            s = buf + ls(cy)
            i = 0
            while i < cx and i < 36 and (@(s + i) == SP or @(s + i) == TAB) {
                ins[n] = @(s + i)
                n++
                i++
            }
        }
        if buf_insert(cur_pos(), &ins, n) {
            cy++
            cx = n - 1
        }
    }

    ; Insert mode: read keys and edit until Esc. Handles Enter, backspace/delete, cursor
    ; keys and printable characters. On exit the cursor steps back one, like vi.
    sub insert_loop() {
        ubyte k
        repeat {
            refresh(false)
            k = getkey()
            if k == ESC
                break
            msg[0] = 0
            when k {
                13, 10 -> do_newline()
                $14, $08, $7f -> {          ; backspace
                    if cx > 0 {
                        cx--
                        buf_delete(cur_pos(), 1)
                    } else if cy > 0 {
                        cx = linelen(cy - 1)
                        cy--
                        buf_delete(cur_pos(), 1)
                    }
                }
                $19 -> {                    ; delete
                    if cx < linelen(cy) or cy + 1 < nlines
                        buf_delete(cur_pos(), 1)
                }
                $9d -> {
                    if cx != 0
                        cx--
                }
                $1d -> {
                    if cx < linelen(cy)
                        cx++
                }
                $91 -> {
                    if cy != 0 {
                        cy--
                        if cx > linelen(cy)
                            cx = linelen(cy)
                    }
                }
                $11 -> {
                    if cy + 1 < nlines {
                        cy++
                        if cx > linelen(cy)
                            cx = linelen(cy)
                    }
                }
                TAB -> insert_char(TAB)
                else -> {
                    if k >= 32 and k != 127
                        insert_char(k)
                }
            }
        }
        mode = 0
        if cx != 0
            cx--
        clamp_cx()
        set_want()
    }

    ; Replace mode (`R`): each typed character overwrites the one under the cursor.
    sub replace_loop() {
        ubyte k
        repeat {
            refresh(false)
            k = getkey()
            if k == ESC
                break
            if k == 13 {
                do_newline()
                continue
            }
            if k == $14 or k == $08 {
                if cx != 0
                    cx--
                continue
            }
            if k < 32
                continue
            if cx < linelen(cy)
                buf_delete(cur_pos(), 1)
            insert_char(k)
        }
        mode = 0
        if cx != 0
            cx--
        clamp_cx()
        set_want()
    }

    ; Enter insert mode.
    sub start_insert() {
        mode = 1
        msg[0] = 0
        insert_loop()
    }

    ; ---------------------------------------------------------------
    ; normal mode
    ; ---------------------------------------------------------------
    ; `o` / `O`: open a new (auto-indented) line below/above and enter insert mode.
    sub open_line(bool below) {
        uword pos
        ubyte n = 0
        uword s = buf + ls(cy)
        uword i = 0
        uword ll = linelen(cy)
        ubyte j
        if autoind {
            while i < ll and n < 36 and (@(s + i) == SP or @(s + i) == TAB) {
                ins[n] = @(s + i)
                n++
                i++
            }
        }
        if below {                       ; "\n" + indent, before this line's newline
            j = n
            while j != 0 {
                ins[j] = ins[j - 1]
                j--
            }
            ins[0] = NL
            n++
            pos = ls(cy + 1) - 1
        } else {
            ins[n] = NL
            n++
            pos = ls(cy)
        }
        snap()
        if buf_insert(pos, &ins, n) {
            if below
                cy++
            cx = n - 1
            mode = 1
            insert_loop()
        }
    }

    ; `p` / `P`: paste the register `count` times. Whole-line registers go on a new line
    ; below/above; character registers go after/before the cursor.
    sub paste(bool after, uword count) {
        uword pos
        uword c
        if reglen == 0 {
            setmsg(iso:"Nothing in register")
            return
        }
        snap()
        if reglines {
            if after {
                pos = ls(cy + 1) - 1
                c = 0
                while c < count {
                    if not buf_insert(pos, &nlbuf, 1)
                        break
                    if not buf_insert(pos + 1, reg, reglen - 1)
                        break
                    c++
                }
                cy = find_line(pos + 1)
            } else {
                pos = ls(cy)
                c = 0
                while c < count {
                    if not buf_insert(pos, reg, reglen)
                        break
                    c++
                }
                cy = find_line(pos)
            }
            goto_line(cy)
        } else {
            pos = cur_pos()
            if after and linelen(cy) != 0
                pos++
            c = 0
            while c < count {
                if not buf_insert(pos, reg, reglen)
                    break
                c++
            }
            set_pos(pos + reglen * count - 1)
        }
    }

    ; `J`: join count lines, collapsing the leading blanks of each into one space.
    sub join_lines(uword count) {
        uword c
        uword pos
        uword n
        snap()
        if count < 2
            count = 2
        c = 1
        while c < count {
            if cy + 1 >= nlines
                break
            pos = ls(cy + 1) - 1             ; the newline
            n = 1
            while pos + n < blen - 1 and (@(buf + pos + n) == SP or @(buf + pos + n) == TAB)
                n++
            buf_delete(pos, n)
            if linelen(cy) != 0 and pos > ls(cy) and @(buf + pos - 1) != SP and @(buf + pos) != NL
                void buf_insert(pos, " ", 1)
            cx = pos - ls(cy)
            c++
        }
        clamp_cx()
        set_want()
    }

    ; Operators d (delete), c (change), y (yank): read an optional count and a motion
    ; (w b $ 0 ^ l h) or the same key again for whole lines (dd, cc, yy), then apply
    ; the operator to the range the motion covers.
    sub operator_cmd(ubyte op, uword count) {
        ubyte k
        bool mcount_set = false
        uword mcount = 0
        uword a
        uword b
        uword p0 = cur_pos()
        uword q
        uword cc
        uword eol

        repeat {
            k = getkey()
            if (k >= iso:'1' and k <= iso:'9') or (mcount_set and k == iso:'0') {
                mcount = mcount * 10 + (k - '0')
                mcount_set = true
                continue
            }
            break
        }
        if mcount_set
            count *= mcount
        if count == 0
            count = 1

        if k == ESC
            return
        if k == op {                              ; dd, yy, cc
            line_range(cy, count)
            a = lr_a
            b = lr_b
            if op == iso:'y' {
                yank_range(a, b, true)
                setmsg(iso:"yanked")
                return
            }
            snap()
            if op == iso:'c' {
                ; keep indentation-less empty line
                yank_range(a, b, true)
                buf_delete(a, b - a - 1)
                cx = 0
                start_insert()
                return
            }
            delete_range(a, b, true)
            if cy >= nlines
                cy = nlines - 1
            goto_line(cy)
            return
        }
        when k {
            iso:'w' -> {
                q = p0
                eol = ls(cy + 1) - 1
                cc = 0
                while cc < count {
                    q = word_fwd(q)
                    cc++
                }
                if op == iso:'c' {                ; cw acts like ce
                    q = p0
                    cc = 0
                    while cc < count {
                        if q < blen - 1 and @(buf + q) != SP and @(buf + q) != TAB {
                            if is_word(@(buf + q)) {
                                while q < blen - 1 and is_word(@(buf + q))
                                    q++
                            } else
                                q++
                        }
                        if cc + 1 < count {
                            while q < blen - 1 and (@(buf + q) == SP or @(buf + q) == TAB)
                                q++
                        }
                        cc++
                    }
                }
                if q > eol and count == 1
                    q = eol
                a = p0
                b = q
            }
            iso:'$' -> {
                a = p0
                b = ls(cy + count) - 1
                if cy + count > nlines
                    b = ls(nlines) - 1
            }
            iso:'0' -> {
                a = ls(cy)
                b = p0
            }
            iso:'^' -> {
                q = ls(cy)
                while @(buf + q) == SP or @(buf + q) == TAB
                    q++
                if q < p0 {
                    a = q
                    b = p0
                } else {
                    a = p0
                    b = q
                }
            }
            iso:'b' -> {
                q = p0
                cc = 0
                while cc < count {
                    q = word_back(q)
                    cc++
                }
                a = q
                b = p0
            }
            iso:'l' -> {
                a = p0
                b = p0 + count
                if b > ls(cy + 1) - 1
                    b = ls(cy + 1) - 1
            }
            iso:'h' -> {
                if p0 > ls(cy) + count
                    a = p0 - count
                else
                    a = ls(cy)
                b = p0
            }
            else -> return
        }
        if a >= b {
            if op == iso:'c'
                start_insert()
            return
        }
        snap()
        if op == iso:'y' {
            yank_range(a, b, false)
            set_pos(a)
            return
        }
        delete_range(a, b, false)
        set_pos(a)
        if op == iso:'c' {
            cx = a - ls(cy)
            start_insert()
        }
    }

    ubyte[32] tsearch
    ubyte[70] tcmd

    ; Execute one normal-mode command. k is the key, count the numeric prefix (0 = none).
    ; Covers motions, search, entering insert mode, the single-key edits (x X D C s r J),
    ; the operators, paste, undo, ZZ/ZQ and the `:` prompt.
    sub normal_key(ubyte k, uword count) {
        uword c
        uword n
        uword p
        ubyte k2
        uword s

        if k != iso:':' and k != iso:'/' and k != iso:'?'
            msg[0] = 0
        when k {
            ; movement
            iso:'h', $9d, $08 -> {
                if cx > count
                    cx -= count
                else
                    cx = 0
                set_want()
            }
            iso:'l', $1d, SP -> {
                cx += count
                clamp_cx()
                set_want()
            }
            iso:'j', $11, NL -> move_down(count)
            iso:'k', $91 -> move_up(count)
            iso:'0' -> {
                cx = 0
                set_want()
            }
            iso:'^' -> goto_line(cy)
            iso:'$' -> {
                cx = linelen(cy)
                clamp_cx()
                want = $fff
            }
            iso:'w' -> {
                p = cur_pos()
                c = 0
                while c < count {
                    p = word_fwd(p)
                    c++
                }
                set_pos(p)
            }
            iso:'b' -> {
                p = cur_pos()
                c = 0
                while c < count {
                    p = word_back(p)
                    c++
                }
                set_pos(p)
            }
            iso:'G' -> {
                if count != 0
                    goto_line(count - 1)
                else
                    goto_line(nlines - 1)
                refresh(true)
            }
            iso:'g' -> {
                k2 = getkey()
                if k2 == iso:'g' {
                    if count != 0
                        goto_line(count - 1)
                    else
                        goto_line(0)
                }
            }
            $06 -> {                    ; ^F
                move_down(textrows - 2)
                top = cy
            }
            $02 -> move_up(textrows - 2)         ; ^B
            iso:'%' -> match_bracket()

            ; search
            iso:'/', iso:'?' -> {
                tsearch[0] = 0
                if read_line(k, &tsearch, 32) and tsearch[0] != 0
                    copystr(&lastsearch, &tsearch, 31)
                if k == iso:'/'
                    searchdir = 1
                else
                    searchdir = -1
                if do_search(searchdir, true)
                    refresh(true)
            }
            iso:'n' -> {
                c = 0
                while c < count {
                    void do_search(searchdir, true)
                    c++
                }
            }
            iso:'N' -> {
                c = 0
                while c < count {
                    void do_search(-searchdir, true)
                    c++
                }
            }

            ; entering insert
            iso:'i' -> {
                snap()
                start_insert()
            }
            iso:'a' -> {
                snap()
                if linelen(cy) != 0
                    cx++
                start_insert()
            }
            iso:'I' -> {
                snap()
                goto_line(cy)
                cx = 0
                s = buf + ls(cy)
                while cx < linelen(cy) and (@(s + cx) == SP or @(s + cx) == TAB)
                    cx++
                start_insert()
            }
            iso:'A' -> {
                snap()
                cx = linelen(cy)
                start_insert()
            }
            iso:'o' -> open_line(true)
            iso:'O' -> open_line(false)
            iso:'R' -> {
                snap()
                mode = 2
                replace_loop()
            }

            ; editing
            iso:'x', $19 -> {
                n = linelen(cy) - cx
                if n != 0 {
                    if n > count
                        n = count
                    snap()
                    delete_range(cur_pos(), cur_pos() + n, false)
                    clamp_cx()
                    set_want()
                }
            }
            iso:'X' -> {
                if cx > count
                    n = count
                else
                    n = cx
                if n != 0 {
                    snap()
                    delete_range(cur_pos() - n, cur_pos(), false)
                    cx -= n
                    set_want()
                }
            }
            iso:'D', iso:'C' -> {
                snap()
                p = ls(cy + 1) - 1
                if p > cur_pos()
                    delete_range(cur_pos(), p, false)
                if k == iso:'C' {
                    cx = linelen(cy)
                    start_insert()
                } else {
                    clamp_cx()
                    set_want()
                }
            }
            iso:'s' -> {
                snap()
                n = linelen(cy) - cx
                if n > count
                    n = count
                if n != 0
                    delete_range(cur_pos(), cur_pos() + n, false)
                start_insert()
            }
            iso:'r' -> {
                k2 = getkey()
                if k2 >= 32 and k2 != 127 and cx + count <= linelen(cy) {
                    snap()
                    c = 0
                    while c < count {
                        buf_delete(cur_pos(), 1)
                        chbuf[0] = k2
                        void buf_insert(cur_pos(), &chbuf, 1)
                        cx++
                        c++
                    }
                    cx--
                    set_want()
                }
            }
            iso:'J' -> join_lines(count)
            iso:'d', iso:'c', iso:'y' -> {
                if count == 0
                    count = 1
                operator_cmd(k, count)
            }
            iso:'Y' -> {
                if count == 0
                    count = 1
                line_range(cy, count)
                yank_range(lr_a, lr_b, true)
            }
            iso:'p' -> {
                if count == 0
                    count = 1
                paste(true, count)
            }
            iso:'P' -> {
                if count == 0
                    count = 1
                paste(false, count)
            }
            iso:'u' -> {
                do_undo()
                clamp_cx()
                set_want()
            }
            iso:'Z' -> {
                k2 = getkey()
                if k2 == iso:'Z' {
                    if fname[0] == 0 or save_file(&fname)
                        quit = true
                } else if k2 == iso:'Q'
                    quit = true
            }
            iso:':' -> {
                tcmd[0] = 0
                if read_line(iso:':', &tcmd, CMDLEN) and tcmd[0] != 0 {
                    msg[0] = 0
                    exec_cmd(&tcmd)
                }
            }
        }
    }

    ; ---------------------------------------------------------------
    ; Main loop: redraw, read a key, collect a numeric prefix, run the command; until :q etc.
    sub editor() {
        ubyte k
        uword count
        bool center

        redraw_all = true
        while not quit {
            center = false
            refresh(false)
            k = getkey()
            count = 0
            if k >= iso:'1' and k <= iso:'9' {
                count = k - '0'
                repeat {
                    k = getkey()
                    if is_digit(k)
                        count = count * 10 + (k - '0')
                    else
                        break
                }
            }
            if k == ESC {
                count = 0
                msg[0] = 0
                continue
            }
            if count == 0 {
                when k {
                    iso:'x', iso:'X', iso:'p', iso:'P', iso:'J', iso:'h', iso:'l', iso:'j', iso:'k', iso:'w',
                    iso:'b', iso:'r', iso:'s', $9d, $1d, $11, $91, SP, iso:'n', iso:'N', iso:'d', iso:'c', iso:'y' -> count = 1
                }
            }
            if k == iso:'G' or k == iso:'g'
                center = true
            normal_key(k, count)
            if center
                refresh(true)
        }
    }

    ;@SELFTEST-SUBS

    ; Program entry: set up the screen, run the editor, then restore the console on exit.
    sub start() {
        ubyte x
        ubyte y
        sys.memset(cstate, 70, 0)
        init_screen()
        iso_mode()
        ; clear screen to black and hide the kernal cursor
        y = 0
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
        cx16.VERA_CTRL &= $fe
        cx16.VERA_DC_BORDER = 0
        new_buffer()
        fname[0] = 0
        msg[0] = 0
        ;@SELFTEST-INIT
        setmsg(iso:"vi for X16 - :e <file>  :help")
        editor()
        cbm.CHROUT($8f)        ; ISO mode off (back to PETSCII)
        cbm.CHROUT($93)        ; clear screen
    }
}
