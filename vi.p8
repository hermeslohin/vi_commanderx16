; VI for the Commander X16  (Prog8, target cx16)
;
; A small vi clone with syntax highlighting for C, BASIC, 6502 assembly and Prog8.
; (It started life as a C / cc65 program; Prog8 gives smaller, faster code.)
;
; HOW IT WORKS
;   * The file lives in BANKED RAM, not main RAM: a chain of 2 KB pages (runs of whole lines)
;     with one page-sized window in main RAM. Lines are addressed by number through
;     lp(l) / linelen(l); every edit goes through splice(). See "paged document store".
;     That allows ~1 MB / tens of thousands of lines on a 2 MB machine.
;   * The screen is drawn by writing character/colour pairs straight into VERA's
;     text map. The X16 is put in ISO mode ($0F), so a screen code is plain ASCII.
;   * Syntax colouring is done per line when it is drawn: highlight() fills the
;     `cls` array with one colour per character. C and Prog8 need one bit of state
;     carried from line to line (inside a /* */ comment or an %asm block); those
;     bits are cached in banked RAM (bank 2) and recomputed lazily with a fast scanner (see line_state()).
;   * Undo keeps ONE level: a copy of the (small) page table; pages are copied only when
;     first edited. `u` swaps with it, so pressing `u` again redoes.
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
    const uword PG     = 2048         ; bytes in one document page (4 pages per 8K bank)
    const uword MAXLN  = 700          ; longest line (a page must be able to hold it)
    const ubyte LPP    = 160          ; most lines in one page
    const uword PMAX   = 850          ; most physical pages
    const uword NIL    = $ffff
    const uword MAXLINES = 60000
    const uword FILL   = 1800         ; the loader starts a new page when one is this full
    const ubyte TBANK  = 1            ; bank 1 holds the page tables
    const ubyte CSBANK = 2            ; bank 2 holds the syntax-state bits (1 per line)
    const ubyte DOC_BANK0 = 3         ; document pages start at bank 3
    const uword TSET   = $09fc        ; size of one table copy: NEXT (uword per page), then NL (ubyte per page)
    const uword T_NL   = $06a8
    const uword T_FLAGS = $13f8       ; per physical page: shared with the undo snapshot?
    const uword T_FREE = $1750        ; stack of free physical pages
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
    ; The page window and its line-start table are raw RAM slabs (see "paged document store").
    uword pbuf = memory("pbuf", 2052, 0)         ; the one resident page
    uword pls  = memory("pls", 332, 0)           ; its line-start offsets
    uword jbuf = memory("jbuf", 704, 0)          ; scratch: joins across pages
    uword c_pg                ; page held ($ffff = none)
    uword c_fl                ;   its first line number
    uword c_nl                ;   number of lines (0 = nothing resident)
    uword c_bl                ;   bytes used
    ubyte c_dirty             ;   changed since it was loaded?
    uword f_li                ; result of fetch(): line index within the page
    uword nbanks              ; RAM banks in this machine
    ubyte db0                 ; first bank used for document pages
    uword ndocpg              ; physical pages available
    uword nfree               ; free physical pages
    uword head                ; first page of the working chain
    uword snap_head
    uword snap_nlines
    ubyte tsel                ; which table copy is the working one
    uword wbase               ; its offset in bank 1
    uword sbase               ; offset of the snapshot copy
    uword sm_cx
    uword sm_cy
    uword nlines              ; lines in the document
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

    ; undo (single level, copy-on-write pages)
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
    ; paged document store
    ; ---------------------------------------------------------------
    ; The document does NOT live in main RAM. It is a chain of PAGES kept in banked RAM (a page is
    ; a run of whole lines, at most PG bytes and LPP lines; four pages fit in one 8 KB bank).
    ; Main RAM only holds one page-sized WINDOW caching the page being looked at or edited.
    ; Lines are addressed by line number everywhere:
    ;     lp(l)       pointer to the text of line l (valid until another page has to be loaded)
    ;     linelen(l)  its length
    ; fetch(l) makes the page that holds line l resident (reading it from banked RAM, and writing
    ; the page it replaces back first if that was changed). Pointers from lp() are therefore only
    ; valid until the next call that touches another line.
    ;
    ; A page is identified by its physical page number g (a node of a linked list). Bank 1 holds,
    ; for every g, the next page in document order (NEXT) and its line count (NL), in two copies:
    ; "working" and "snapshot". Undo is copy-on-write on whole pages: snap() copies the (small)
    ; arrays and marks every page shared; the first edit to a shared page moves the working
    ; chain to a fresh copy. Ctrl-Z just swaps which copy is the working one.
    ;
    ; All edits go through splice() (replace some bytes of a line by other bytes); ed_insert,
    ; del_chars, del_line and join_next are thin wrappers.

    ; --- page tables (bank 1) ---
    sub tb_get(uword off) -> uword {
        uword v
        cx16.rambank(TBANK)
        v = peekw($a000 + off)
        cx16.rambank(0)
        return v
    }

    sub tb_set(uword off, uword v) {
        cx16.rambank(TBANK)
        pokew($a000 + off, v)
        cx16.rambank(0)
    }

    sub tb_getb(uword off) -> ubyte {
        ubyte v
        cx16.rambank(TBANK)
        v = @($a000 + off)
        cx16.rambank(0)
        return v
    }

    sub tb_setb(uword off, ubyte v) {
        cx16.rambank(TBANK)
        @($a000 + off) = v
        cx16.rambank(0)
    }

    ; Next page after g in the working chain / number of lines in page g.
    sub nx(uword g) -> uword {
        return tb_get(wbase + (g << 1))
    }

    sub setnx(uword g, uword v) {
        tb_set(wbase + (g << 1), v)
    }

    sub nlc(uword g) -> ubyte {
        return tb_getb(wbase + T_NL + g)
    }

    ; Choose which of the two table copies is the working one.
    sub set_tsel(ubyte t) {
        tsel = t
        wbase = (t as uword) * TSET
        sbase = ((t ^ 1) as uword) * TSET
    }

    ; Free physical pages are kept on a stack.
    sub alloc_pg() -> uword {
        nfree--
        return tb_get(T_FREE + (nfree << 1))
    }

    sub free_pg(uword g) {
        tb_set(T_FREE + (nfree << 1), g)
        nfree++
    }

    ; The page before g in the working chain.
    sub pred_of(uword g) -> uword {
        uword p = head
        while p != NIL {
            if nx(p) == g
                return p
            p = nx(p)
        }
        return NIL
    }

    ; Replace page g by g2 in the working chain (g2 takes over g's place and line count).
    sub relink(uword g, uword g2) {
        uword p = pred_of(g)
        setnx(g2, nx(g))
        tb_setb(wbase + T_NL + g2, nlc(g))
        if p == NIL
            head = g2
        else
            setnx(p, g2)
    }

    ; --- physical pages: page g lives in bank db0 + g/4 at offset (g%4)*2048 ---
    sub pg_read(uword g, uword dst, uword n) {
        cx16.rambank(db0 + lsb(g >> 2))
        sys.memcopy($a000 + ((g & 3) << 11), dst, n)
        cx16.rambank(0)
    }

    sub pg_write(uword g, uword src, uword n) {
        if n == 0
            return
        cx16.rambank(db0 + lsb(g >> 2))
        sys.memcopy(src, $a000 + ((g & 3) << 11), n)
        cx16.rambank(0)
    }

    ; --- the two resident slots ---
    ; Line-start offset of line index i within slot k (entry nl is the end marker).
    sub lso(uword i) -> uword {
        return peekw(pls + (i << 1))
    }

    ; Rebuild slot k's line-start table from its bytes (nl lines); also sets s_bl.
    sub slot_scan(uword nl) {
        uword b = pbuf
        uword t = pls
        uword i = 0
        uword j = 0
        pokew(t, 0)
        while j < nl {
            if @(b + i) == NL {
                j++
                pokew(t + (j << 1), i + 1)
            }
            i++
        }
        c_bl = i
    }

    ; Write slot k back to its physical page if it was changed.
    sub slot_flush() {
        if c_dirty == 0
            return
        pg_write(c_pg, pbuf, c_bl)
        c_dirty = 0
    }

    sub flush_all() {
        slot_flush()
    }

    ; Forget what is cached (after flushing).
    sub slots_drop() {
        flush_all()
        c_nl = 0
        c_pg = NIL
    }

    ; Load page g (whose first line is number fl) into slot k.
    sub slot_load(uword g, uword fl) {
        uword nl
        slot_flush()
        nl = nlc(g)
        pg_read(g, pbuf, PG)
        c_pg = g
        c_fl = fl
        c_nl = nl
        slot_scan(nl)
    }

    ; Make the page holding line l resident (the single window). Result: f_li = line index in it.
    sub fetch(uword l) {
        uword g
        uword fl
        uword n
        if l - c_fl < c_nl {
            f_li = l - c_fl
            return
        }
        ; walk the chain, starting from the resident page if it is not after l
        g = head
        fl = 0
        if c_nl != 0 and c_fl <= l {
            g = c_pg
            fl = c_fl
        }
        repeat {
            n = nlc(g)
            if l - fl < n or nx(g) == NIL
                break
            fl += n
            g = nx(g)
        }
        slot_load(g, fl)
        f_li = l - fl
    }

    ; Pointer to the text of line l.
    sub lp(uword l) -> uword {
        fetch(l)
        return pbuf + lso(f_li)
    }

    ; Number of characters in line l (not counting its newline).
    sub linelen(uword l) -> uword {
        fetch(l)
        return lso(f_li + 1) - lso(f_li) - 1
    }

    ; Set up the page pool: all physical pages free, no document.
    sub pool_reset() {
        uword i
        ndocpg = (nbanks - db0) * 4
        if ndocpg > PMAX
            ndocpg = PMAX
        cx16.rambank(TBANK)
        sys.memset($a000 + T_FLAGS, PMAX, 0)
        i = 0
        while i < ndocpg {
            pokew($a000 + T_FREE + (i << 1), ndocpg - 1 - i)
            i++
        }
        cx16.rambank(0)
        nfree = ndocpg
        head = NIL
        nlines = 0
        uvalid = false
        set_tsel(0)
        slots_drop()
        c_dirty = 0
        cstate_valid = 0
    }

    ; Reset to an empty document (a single newline).
    sub new_buffer() {
        uword g
        pool_reset()
        @(pbuf) = NL
        g = alloc_pg()
        pg_write(g, pbuf, 1)
        setnx(g, NIL)
        tb_setb(wbase + T_NL + g, 1)
        head = g
        nlines = 1
        cy = 0
        cx = 0
        want = 0
        top = 0
        leftcol = 0
        modified = false
    }

    ; Before changing the page in slot k: if it is shared with the undo snapshot, move the working
    ; chain to a private copy (the slot's content is flushed into it later); then mark it changed.
    sub mod_begin() {
        uword g = c_pg
        uword g2
        if tb_getb(T_FLAGS + g) != 0 {
            g2 = alloc_pg()
            tb_setb(T_FLAGS + g, 0)
            relink(g, g2)
            c_pg = g2
        }
        c_dirty = 1
    }

    ; Split the page in slot k (already mod_begin'ed) at line index m. The slot keeps the part that
    ; holds the line being edited (f_li): the upper part if keep_upper, else the lower part; the
    ; other part goes to its own physical page. f_li is updated.
    sub page_split(uword m, bool keep_upper) {
        uword g = c_pg
        uword nl = c_nl
        uword cut = lso(m)
        uword tail = c_bl - cut
        uword g2 = alloc_pg()
        setnx(g2, nx(g))
        setnx(g, g2)
        tb_setb(wbase + T_NL + g, lsb(m))
        tb_setb(wbase + T_NL + g2, lsb(nl - m))
        if keep_upper {
            pg_write(g, pbuf, cut)            ; the lower part stays in page g
            cx16.memory_copy(pbuf + cut, pbuf, tail)
            c_pg = g2
            c_fl += m
            c_nl = nl - m
            slot_scan(nl - m)
            f_li -= m
        } else {
            pg_write(g2, pbuf + cut, tail)
            c_nl = m
            c_bl = cut
        }
        c_dirty = 1
    }

    ; Make room in slot k's page for `bytes` more bytes and `lines` more lines, splitting the page
    ; if needed. The line being edited is f_li in slot k.
    sub ensure_room(uword bytes, uword lines) -> bool {
        ubyte tries = 0
        uword m
        uword half
        while c_bl + bytes > PG or c_nl + lines > LPP {
            if c_nl < 2 or tries == 3 {
                setmsg(iso:"Page full!")
                return false
            }
            half = c_bl >> 1
            m = 1
            while m < c_nl - 1 and lso(m) < half
                m++
            page_split(m, f_li >= m)
            tries++
        }
        return true
    }

    ; An edit at line l invalidates the cached syntax state of the lines below it.
    sub fc_inv(uword l) {
        if l < cstate_valid
            cstate_valid = l
    }

    ; Can we afford an edit? Every edit may need a couple of fresh pages (copy-on-write, split).
    sub edit_ok() -> bool {
        if nfree < 4 {
            setmsg(iso:"Document full!")
            return false
        }
        return true
    }

    ; THE editing primitive: in line l, replace ndel bytes starting at column c by the nins bytes at
    ; src (either may be 0; src may contain newlines; deleted bytes must lie in this page, i.e. they
    ; may include the newline that ends the line only if it is not the last line of its page).
    sub splice(uword l, uword c, uword ndel, uword src, uword nins) -> bool {
        uword g
        uword pos
        uword i
        uword add_nl = 0
        uword del_nl = 0
        uword newnl
        uword need
        if not edit_ok()
            return false
        i = 0
        while i < nins {
            if @(src + i) == NL
                add_nl++
            i++
        }
        fetch(l)
        if ndel == 0 and add_nl == 0 and nins != 0 and lso(f_li + 1) - lso(f_li) - 1 + nins > MAXLN {
            setmsg(iso:"Line too long!")
            return false
        }
        if add_nl != 0 and nlines + add_nl > MAXLINES {
            setmsg(iso:"Too many lines!")
            return false
        }
        mod_begin()
        if nins > ndel
            need = nins - ndel
        else
            need = 0
        if need != 0 or add_nl != 0 {
            if not ensure_room(need, add_nl)
                return false
        }
        pos = lso(f_li) + c
        i = pos
        while i < pos + ndel {
            if @(pbuf + i) == NL
                del_nl++
            i++
        }
        i = c_bl - pos - ndel                      ; bytes after the replaced range
        if i != 0
            cx16.memory_copy(pbuf + pos + ndel, pbuf + pos + nins, i)
        if nins != 0
            sys.memcopy(src, pbuf + pos, nins)
        g = c_pg
        newnl = c_nl + add_nl - del_nl
        if newnl == 0 {                               ; the page became empty: drop it
            relink_out(g)
            free_pg(g)
            c_nl = 0
            c_pg = NIL
            c_dirty = 0
        } else {
            c_nl = newnl
            tb_setb(wbase + T_NL + g, lsb(newnl))
            if add_nl == 0 and del_nl == 0 {          ; same lines: just shift the later line starts
                c_bl += nins - ndel
                i = f_li + 1
                while i <= newnl {
                    pokew(pls + (i << 1), lso(i) + nins - ndel)
                    i++
                }
            } else
                slot_scan(newnl)
        }
        if add_nl != del_nl {
            nlines += add_nl - del_nl
        }
        modified = true
        redraw_all = true
        fc_inv(l)
        return true
    }

    ; Take page g out of the working chain.
    sub relink_out(uword g) {
        uword p = pred_of(g)
        if p == NIL
            head = nx(g)
        else
            setnx(p, nx(g))
    }

    ; Insert n bytes (which may contain newlines) at line l, column c.
    sub ed_insert(uword l, uword c, uword src, uword n) -> bool {
        return splice(l, c, 0, src, n)
    }

    ; Delete n bytes from line l starting at column c (all inside the line).
    sub del_chars(uword l, uword c, uword n) {
        void splice(l, c, n, 0, 0)
    }

    ; Delete the whole of line l including its newline (never the last remaining line).
    sub del_line(uword l) {
        if nlines > 1
            void splice(l, 0, linelen(l) + 1, 0, 0)
    }

    ; Join line l and line l+1 (delete the newline that ends line l). Returns false if the result
    ; would be too long.
    sub join_next(uword l) -> bool {
        uword n1
        uword n2
        if l + 1 >= nlines
            return false
        n1 = linelen(l)
        n2 = linelen(l + 1)
        if n1 + n2 > MAXLN {
            setmsg(iso:"Line too long!")
            return false
        }
        fetch(l)
        if f_li + 1 < c_nl
            return splice(l, n1, 1, 0, 0)
        ; l is the last line of its page: put its text in front of line l+1 (next page), then delete
        ; line l. Only one page is resident at a time, so the text travels through jbuf.
        sys.memcopy(pbuf + lso(f_li), jbuf, n1)
        if not splice(l + 1, 0, 0, jbuf, n1)
            return false
        del_line(l)
        return true
    }

    ; ---------------------------------------------------------------
    ; undo (copy-on-write page tables, see the note at the top of this section)
    ; ---------------------------------------------------------------
    ; Take an undo snapshot of the current state; called before each change. Pages that only the
    ; previous snapshot still used are freed; every page of the new snapshot is marked shared.
    sub snap() {
        uword g
        flush_all()
        cx16.rambank(TBANK)
        if uvalid {
            g = snap_head
            while g != NIL {
                if @($a000 + T_FLAGS + g) == 0 {
                    pokew($a000 + T_FREE + (nfree << 1), g)
                    nfree++
                }
                g = peekw($a000 + sbase + (g << 1))
            }
        }
        cx16.memory_copy($a000 + wbase, $a000 + sbase, TSET)
        g = head
        while g != NIL {
            @($a000 + T_FLAGS + g) = 1
            g = peekw($a000 + wbase + (g << 1))
        }
        cx16.rambank(0)
        snap_head = head
        snap_nlines = nlines
        sm_cx = cx
        sm_cy = cy
        uvalid = true
    }

    ; Ctrl-Z: swap the working tables with the snapshot. The state we leave becomes the snapshot,
    ; so pressing Ctrl-Z again redoes.
    sub do_undo() {
        uword t
        if not uvalid {
            setmsg(iso:"Nothing to undo")
            return
        }
        slots_drop()
        set_tsel(tsel ^ 1)
        t = head
        head = snap_head
        snap_head = t
        t = nlines
        nlines = snap_nlines
        snap_nlines = t
        t = cx
        cx = sm_cx
        sm_cx = t
        t = cy
        cy = sm_cy
        sm_cy = t
        if cy >= nlines
            cy = nlines - 1
        if cx > linelen(cy)
            cx = linelen(cy)
        cstate_valid = 0
        modified = true
        redraw_all = true
        setmsg(iso:"Undo (Ctrl-Z again = redo)")
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

    ; Syntax state bits live in bank 2, one bit per line: "line l starts inside /* */ (or %asm {{)".
    sub cs_get(uword l) -> ubyte {
        ubyte v
        cx16.rambank(CSBANK)
        v = (@($a000 + (l >> 3)) >> (lsb(l) & 7)) & 1
        cx16.rambank(0)
        return v
    }

    sub cs_put(uword l, ubyte st) {
        ubyte m = 1 << (lsb(l) & 7)
        cx16.rambank(CSBANK)
        if st & ST_BLOCK != 0
            @($a000 + (l >> 3)) |= m
        else
            @($a000 + (l >> 3)) &= (m ^ $ff)
        cx16.rambank(0)
    }

    ; Skip a string/char literal starting at s[i] (the quote); returns the index after it.
    sub skip_lit(uword s, ubyte n, ubyte i) -> ubyte {
        ubyte c = @(s + i)
        i++
        while i < n and @(s + i) != c {
            if @(s + i) == iso:'\\'
                i++
            i++
        }
        if i < n
            i++
        return i
    }

    ; Fast version of what hl_c / hl_p8 return: only follows the multi-line state, no colouring.
    ; (Scanning a whole file with the real highlighters would take far too long.)
    sub fast_state(uword s, ubyte n, ubyte st) -> ubyte {
        ubyte i = 0
        ubyte c
        ubyte j
        ubyte k
        if lang == L_C {
            while i < n {
                c = @(s + i)
                if st & ST_BLOCK != 0 {
                    if c == iso:'*' and i + 1 < n and @(s + i + 1) == iso:'/' {
                        st = 0
                        i++
                    }
                    i++
                } else if c == iso:'/' and i + 1 < n and @(s + i + 1) == iso:'/' {
                    return st
                } else if c == iso:'/' and i + 1 < n and @(s + i + 1) == iso:'*' {
                    st = ST_BLOCK
                    i += 2
                } else if c == iso:'"' or c == iso:'\'' {
                    i = skip_lit(s, n, i)
                } else
                    i++
            }
            return st
        }
        ; Prog8
        if st & ST_BLOCK != 0 {
            while i < n {
                if @(s + i) == iso:'}' and i + 1 < n and @(s + i + 1) == iso:'}'
                    return 0
                i++
            }
            return st
        }
        while i < n {
            c = @(s + i)
            if c == iso:';'
                return st
            if c == iso:'"' or c == iso:'\'' {
                i = skip_lit(s, n, i)
                continue
            }
            if c == iso:'%' and i + 4 <= n and @(s + i + 1) == iso:'a' and @(s + i + 2) == iso:'s' and @(s + i + 3) == iso:'m' and (i + 4 == n or not is_idchar(@(s + i + 4))) {
                j = i + 4
                while j < n and not (@(s + j) == iso:'{' and j + 1 < n and @(s + j + 1) == iso:'{')
                    j++
                if j < n {
                    j += 2
                    k = j
                    while k < n and not (@(s + k) == iso:'}' and k + 1 < n and @(s + k + 1) == iso:'}')
                        k++
                    if k >= n
                        return ST_BLOCK
                    i = k + 2
                    continue
                }
                i += 4
                continue
            }
            i++
        }
        return st
    }

    ; State (see hl_c) at the START of line l. C/Prog8 need it for multi-line constructs.
    ; We extend the cached bits by scanning forward from cstate_valid, so an edit only
    ; invalidates the lines below it.
    sub line_state(uword l) -> ubyte {
        ubyte st
        uword n
        if lang != L_C and lang != L_P8
            return 0
        while cstate_valid < l {
            if cstate_valid == 0
                st = 0
            else
                st = cs_get(cstate_valid)
            n = linelen(cstate_valid)
            if n > 255
                n = 255
            st = fast_state(lp(cstate_valid), lsb(n), st)
            cstate_valid++
            cs_put(cstate_valid, st)
        }
        if l == 0
            return 0
        return cs_get(l)
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
        uword s = lp(l)
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
        st = line_state(l)               ; (before lp: it walks other lines)
        s = lp(l)
        n = linelen(l)
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
        uword s = lp(cy)
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
        s = lp(cy)
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

    ; Scan position for the character-stream helpers below (the text is seen as one stream of
    ; characters in which the end of each line reads as a newline).
    uword pl
    uword pc

    ; Are we on the final newline of the document / at its very start?
    sub at_end() -> bool {
        return pl + 1 >= nlines and pc >= linelen(pl)
    }

    sub at_start() -> bool {
        return pl == 0 and pc == 0
    }

    ; Character at the scan position (NL at the end of a line).
    sub pch() -> ubyte {
        if pc >= linelen(pl)
            return NL
        return @(lp(pl) + pc)
    }

    ; Character just before the scan position (NL at the start of a line).
    sub pprev_ch() -> ubyte {
        if pc == 0
            return NL
        return @(lp(pl) + pc - 1)
    }

    ; Step the scan position forward / back one character (stays put at the ends).
    sub pnext() {
        if pc < linelen(pl)
            pc++
        else if pl + 1 < nlines {
            pl++
            pc = 0
        }
    }

    sub pprev() {
        if pc > 0
            pc--
        else if pl > 0 {
            pl--
            pc = linelen(pl)
        }
    }

    ; Place the cursor at line l, column c.
    sub set_pos(uword l, uword c) {
        cy = l
        cx = c
        clamp_cx()
        set_want()
    }

    ; Move the scan position to the start of the next word (vi's `w`).
    sub word_fwd() {
        ubyte c
        if at_end()
            return
        c = pch()
        if is_word(c) {
            while not at_end() and is_word(pch())
                pnext()
        } else if c != SP and c != TAB and c != NL {
            while not at_end() and not is_word(pch()) and pch() != SP and pch() != TAB and pch() != NL
                pnext()
        }
        while not at_end() and (pch() == SP or pch() == TAB)
            pnext()
        if not at_end() and pch() == NL {
            pnext()                  ; move onto next line start
            while not at_end() and (pch() == SP or pch() == TAB)
                pnext()
        }
    }

    ; Move the scan position to the start of the word before it (vi's `b`).
    sub word_back() {
        if at_start()
            return
        pprev()
        while not at_start() and (pch() == SP or pch() == TAB or pch() == NL)
            pprev()
        if is_word(pch()) {
            while not at_start() and is_word(pprev_ch())
                pprev()
        } else {
            while not at_start() and not is_word(pprev_ch()) and pprev_ch() != SP and pprev_ch() != TAB and pprev_ch() != NL
                pprev()
        }
    }

    ; A range of text is ra..rb (line, column; rb excluded). Linewise ranges run from column 0 of
    ; one line to column 0 of a later line, so they include the final newline.
    uword ra_l
    uword ra_c
    uword rb_l
    uword rb_c

    ; Copy the range into the register (the paste buffer). linewise = whole lines.
    sub yank_range(bool linewise) {
        uword l = ra_l
        uword c = ra_c
        uword n = 0
        uword e
        uword s
        bool trunc = false
        while l < rb_l or (l == rb_l and c < rb_c) {
            e = linelen(l)
            s = lp(l)
            if l == rb_l and rb_c < e
                e = rb_c
            while c < e {
                if n < REGSZ {
                    @(reg + n) = @(s + c)
                    n++
                } else
                    trunc = true
                c++
            }
            if l < rb_l {
                if n < REGSZ {
                    @(reg + n) = NL
                    n++
                } else
                    trunc = true
                l++
                c = 0
            } else
                break
        }
        if trunc
            setmsg(iso:"Yank truncated")
        reglen = n
        reglines = linewise
    }

    ; Yank the range into the register, then delete it (vi's `d`).
    sub delete_range(bool linewise) {
        uword l
        yank_range(linewise)
        if linewise {
            l = ra_l
            while l < rb_l {
                if nlines > 1
                    del_line(ra_l)
                else
                    del_chars(ra_l, 0, linelen(ra_l))
                l++
            }
            return
        }
        if ra_l == rb_l {
            del_chars(ra_l, ra_c, rb_c - ra_c)
            return
        }
        del_chars(rb_l, 0, rb_c)                  ; head of the last line
        l = rb_l
        while l > ra_l + 1 {                      ; whole lines in between
            l--
            del_line(l)
        }
        del_chars(ra_l, ra_c, linelen(ra_l) - ra_c)   ; tail of the first line
        void join_next(ra_l)
    }

    ; Set the range to cnt whole lines starting at line l (linewise).
    sub line_range(uword l, uword cnt) {
        ra_l = l
        ra_c = 0
        rb_l = l + cnt
        if rb_l > nlines
            rb_l = nlines
        rb_c = 0
    }

    ; Search for `lastsearch` (a plain string, no regex) from the cursor, wrapping around the
    ; file. dir = +1 forward, -1 backward. Moves the cursor and returns true if found.
    sub do_search(byte dir, bool from_next) -> bool {
        uword plen = slen(&lastsearch)
        uword l
        uword n
        uword s
        uword i
        uword lo
        uword hi
        uword cnt = 0
        if plen == 0 {
            setmsg(iso:"No previous search")
            return false
        }
        l = cy
        if dir > 0 {
            lo = cx
            if from_next
                lo++
            while cnt <= nlines {
                n = linelen(l)
                s = lp(l)
                hi = n
                if cnt == nlines {
                    hi = cx + plen
                    if hi > n
                        hi = n
                }
                i = lo
                while i + plen <= hi {
                    if @(s + i) == lastsearch[0] and memeq(s + i, &lastsearch, plen) {
                        set_pos(l, i)
                        return true
                    }
                    i++
                }
                l++
                if l >= nlines
                    l = 0
                lo = 0
                cnt++
            }
        } else {
            while cnt <= nlines {
                n = linelen(l)
                s = lp(l)
                lo = 0
                hi = n + 1
                if cnt == 0
                    hi = cx
                else if cnt == nlines
                    lo = cx
                i = hi
                while i > lo {
                    i--
                    if i + plen <= n and @(s + i) == lastsearch[0] and memeq(s + i, &lastsearch, plen) {
                        set_pos(l, i)
                        return true
                    }
                }
                if l == 0
                    l = nlines - 1
                else
                    l--
                cnt++
            }
        }
        setmsg(iso:"Pattern not found")
        return false
    }

    ; `%`: jump to the bracket matching the one under the cursor, counting nesting.
    sub match_bracket() {
        ubyte c
        ubyte t
        byte d
        uword depth = 0
        pl = cy
        pc = cx
        c = pch()
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
        repeat {
            if d > 0 {
                if at_end()
                    return
                pnext()
            } else {
                if at_start()
                    return
                pprev()
            }
            if pch() == c
                depth++
            else if pch() == t {
                if depth == 0 {
                    set_pos(pl, pc)
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

    uword ld_o                ; bytes waiting in the page accumulator (pbuf)
    uword ld_lc               ; complete lines among them
    uword ld_cl               ; length of the line being read
    uword ld_tail             ; last page stored so far

    ; Store the first nb bytes (nlns complete lines) of the accumulator as a new page; whatever
    ; follows (a partly read line) moves to the front.
    sub ld_commit(uword nb, uword nlns) {
        uword g
        if nfree <= 8 {
            truncated = true
            return
        }
        g = alloc_pg()
        pg_write(g, pbuf, nb)
        setnx(g, NIL)
        tb_setb(wbase + T_NL + g, lsb(nlns))
        if head == NIL
            head = g
        else
            setnx(ld_tail, g)
        ld_tail = g
        nlines += nlns
        if ld_o > nb
            cx16.memory_copy(pbuf + nb, pbuf, ld_o - nb)
        ld_o -= nb
        ld_lc -= nlns
    }

    ; Append one byte to the accumulator, starting a new page when the current one is full.
    sub ld_put(ubyte c) {
        if ld_o >= FILL or ld_lc >= LPP - 2
            ld_commit(ld_o - ld_cl, ld_lc)
        if truncated
            return
        @(pbuf + ld_o) = c
        ld_o++
        if c == NL {
            ld_lc++
            ld_cl = 0
        } else
            ld_cl++
    }

    ; Load a file (device 8) into the paged document: CR/CRLF become LF, NULs are dropped, a final
    ; newline is added, lines longer than MAXLN are broken, and `truncated` is set if it did not fit.
    ; The file streams straight into pages in banked RAM. Returns false if it could not be read.
    sub load_file(uword name) -> bool {
        ubyte c
        ubyte prev = 0
        ubyte stt
        bool wrapped = false

        pool_reset()
        copystr(&iobuf2, name, 44)
        appendstr(&iobuf2, iso:",s,r")
        dosname(&iobuf2)
        cbm.SETNAM(slen(&iobuf2), &iobuf2)
        cbm.SETLFS(2, DEVICE, 2)
        void cbm.OPEN()
        truncated = false
        ld_o = 0
        ld_lc = 0
        ld_cl = 0
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
                if c != NL and ld_cl >= MAXLN {
                    ld_put(NL)
                    wrapped = true
                }
                ld_put(c)
                if truncated
                    break
            }
            if stt & $40 != 0
                break
        }
        cbm.CLRCHN()
        cbm.CLOSE(2)
        dos_status(&dstat, 40)
        if dstat[0] == iso:'6' or dstat[0] == iso:'7' or (dstat[0] == iso:'5' and dstat[1] != iso:'0') {
            if ld_o == 0 and nlines == 0 {
                setmsg(&dstat)
                return false
            }
        }
        if not truncated {
            if ld_o == 0 or @(pbuf + ld_o - 1) != NL
                ld_put(NL)
        }
        if ld_o > 0 and not truncated
            ld_commit(ld_o, ld_lc)
        if nlines == 0 {
            @(pbuf) = NL
            ld_o = 1
            ld_lc = 1
            truncated = false
            ld_commit(1, 1)
        }
        if wrapped
            setmsg(iso:"Very long lines were split")
        return true
    }

    ; Write the document to a file, replacing it (`@:`). Reports the drive status unless it is "00".
    sub save_file(uword name) -> bool {
        uword p
        uword o
        uword n

        copystr(&iobuf2, iso:"@:", 4)
        appendstr(&iobuf2, name)
        appendstr(&iobuf2, iso:",s,w")
        dosname(&iobuf2)
        flush_all()
        cbm.SETNAM(slen(&iobuf2), &iobuf2)
        cbm.SETLFS(2, DEVICE, 2)
        void cbm.OPEN()
        cbm.CHKOUT(2)
        p = head
        while p != NIL {
            slot_load(p, 0)
            o = 0
            n = c_bl
            while o < n {
                cbm.CHROUT(@(pbuf + o))
                o++
            }
            p = nx(p)
        }
        slots_drop()                      ; slot 0 was borrowed with made-up line numbers
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
            q = 0
            repeat {
                endp = linelen(l)
                found = false
                while q + plen <= endp {
                    if @(lp(l) + q) == spat[0] and memeq(lp(l) + q, &spat, plen) {
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
                    if not ed_insert(l, q, &srep, rlen) {
                        abort = true
                        break
                    }
                }
                del_chars(l, q + rlen, plen)
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
        if ed_insert(cy, cx, &chbuf, 1)
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
            s = lp(cy)
            i = 0
            while i < cx and i < 36 and (@(s + i) == SP or @(s + i) == TAB) {
                ins[n] = @(s + i)
                n++
                i++
            }
        }
        if ed_insert(cy, cx, &ins, n) {
            cy++
            cx = n - 1
        }
    }

    ; Insert mode: read keys and edit until Esc. Handles Enter, backspace/delete, cursor
    ; keys and printable characters. On exit the cursor steps back one, like vi.
    sub insert_loop() {
        ubyte k
        uword n
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
                        del_chars(cy, cx, 1)
                    } else if cy > 0 {
                        n = linelen(cy - 1)
                        if join_next(cy - 1) {
                            cy--
                            cx = n
                        }
                    }
                }
                $19 -> {                    ; delete
                    if cx < linelen(cy)
                        del_chars(cy, cx, 1)
                    else if cy + 1 < nlines
                        void join_next(cy)
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
                del_chars(cy, cx, 1)
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

    ; `o` / `O`: open a new (auto-indented) line below/above and enter insert mode.
    sub open_line(bool below) {
        uword lcol
        ubyte n = 0
        uword s = lp(cy)
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
        if below {                       ; "\n" + indent, at the end of this line
            j = n
            while j != 0 {
                ins[j] = ins[j - 1]
                j--
            }
            ins[0] = NL
            n++
            lcol = ll
        } else {                         ; indent + "\n", at the start of this line
            ins[n] = NL
            n++
            lcol = 0
        }
        snap()
        if ed_insert(cy, lcol, &ins, n) {
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
        uword lcol
        uword c
        uword nn
        uword tailn
        uword i
        if reglen == 0 {
            setmsg(iso:"Nothing in register")
            return
        }
        snap()
        if reglines {
            if after {
                lcol = linelen(cy)
                c = 0
                while c < count {
                    if not ed_insert(cy, lcol, &nlbuf, 1)
                        break
                    if not ed_insert(cy + 1, 0, reg, reglen - 1)
                        break
                    c++
                }
                cy++
            } else {
                c = 0
                while c < count {
                    if not ed_insert(cy, 0, reg, reglen)
                        break
                    c++
                }
            }
            goto_line(cy)
        } else {
            lcol = cx
            if after and linelen(cy) != 0
                lcol++
            c = 0
            while c < count {
                if not ed_insert(cy, lcol, reg, reglen)
                    break
                c++
            }
            ; cursor goes to the last pasted character: count newlines and the tail after the last one
            nn = 0
            tailn = reglen
            i = 0
            while i < reglen {
                if @(reg + i) == NL {
                    nn++
                    tailn = reglen - 1 - i
                }
                i++
            }
            if nn == 0
                set_pos(cy, lcol + reglen * count - 1)
            else if tailn > 0
                set_pos(cy + nn * count, tailn - 1)
            else
                set_pos(cy + nn * count - 1, 65000)
        }
    }

    ; `J`: join count lines, collapsing the leading blanks of each into one space.
    sub join_lines(uword count) {
        uword c
        uword e
        uword n
        uword m
        snap()
        if count < 2
            count = 2
        c = 1
        while c < count {
            if cy + 1 >= nlines
                break
            e = linelen(cy)
            m = linelen(cy + 1)
            n = 0
            while n < m and (@(lp(cy + 1) + n) == SP or @(lp(cy + 1) + n) == TAB)
                n++
            if n != 0
                del_chars(cy + 1, 0, n)
            if not join_next(cy)
                break
            if e > 0 and m > n and @(lp(cy) + e - 1) != SP
                void ed_insert(cy, e, " ", 1)
            cx = e
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
        uword al
        uword ac
        uword bl
        uword bc
        uword cc
        uword e

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
            if op == iso:'y' {
                yank_range(true)
                setmsg(iso:"yanked")
                return
            }
            snap()
            if op == iso:'c' {
                ; keep one empty line in place of the lines
                yank_range(true)
                cc = ra_l + 1
                while cc < rb_l {
                    del_line(ra_l + 1)
                    cc++
                }
                del_chars(cy, 0, linelen(cy))
                cx = 0
                start_insert()
                return
            }
            delete_range(true)
            if cy >= nlines
                cy = nlines - 1
            goto_line(cy)
            return
        }
        al = cy
        ac = cx
        bl = cy
        bc = cx
        when k {
            iso:'w' -> {
                pl = cy
                pc = cx
                cc = 0
                while cc < count {
                    word_fwd()
                    cc++
                }
                if op == iso:'c' {                ; cw acts like ce
                    pl = cy
                    pc = cx
                    cc = 0
                    while cc < count {
                        if not at_end() and pch() != SP and pch() != TAB {
                            if is_word(pch()) {
                                while not at_end() and is_word(pch())
                                    pnext()
                            } else
                                pnext()
                        }
                        if cc + 1 < count {
                            while not at_end() and (pch() == SP or pch() == TAB)
                                pnext()
                        }
                        cc++
                    }
                }
                if pl > cy and count == 1 {       ; a single word stops at the end of the line
                    pl = cy
                    pc = linelen(cy)
                }
                bl = pl
                bc = pc
            }
            iso:'$' -> {
                bl = cy + count
                if bl > nlines
                    bl = nlines
                bl--
                bc = linelen(bl)
            }
            iso:'0' -> ac = 0
            iso:'^' -> {
                e = 0
                while e < linelen(cy) and (@(lp(cy) + e) == SP or @(lp(cy) + e) == TAB)
                    e++
                if e < cx {
                    ac = e
                    bc = cx
                } else {
                    ac = cx
                    bc = e
                }
            }
            iso:'b' -> {
                pl = cy
                pc = cx
                cc = 0
                while cc < count {
                    word_back()
                    cc++
                }
                al = pl
                ac = pc
            }
            iso:'l' -> {
                bc = cx + count
                if bc > linelen(cy)
                    bc = linelen(cy)
            }
            iso:'h' -> {
                if cx > count
                    ac = cx - count
                else
                    ac = 0
            }
            else -> return
        }
        if al > bl or (al == bl and ac >= bc) {
            if op == iso:'c'
                start_insert()
            return
        }
        ra_l = al
        ra_c = ac
        rb_l = bl
        rb_c = bc
        snap()
        if op == iso:'y' {
            yank_range(false)
            set_pos(al, ac)
            return
        }
        delete_range(false)
        set_pos(al, ac)
        if op == iso:'c' {
            cy = al
            cx = ac
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
                pl = cy
                pc = cx
                c = 0
                while c < count {
                    word_fwd()
                    c++
                }
                set_pos(pl, pc)
            }
            iso:'b' -> {
                pl = cy
                pc = cx
                c = 0
                while c < count {
                    word_back()
                    c++
                }
                set_pos(pl, pc)
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
                s = lp(cy)
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
                    ra_l = cy
                    ra_c = cx
                    rb_l = cy
                    rb_c = cx + n
                    delete_range(false)
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
                    ra_l = cy
                    ra_c = cx - n
                    rb_l = cy
                    rb_c = cx
                    delete_range(false)
                    cx -= n
                    set_want()
                }
            }
            iso:'D', iso:'C' -> {
                snap()
                if linelen(cy) > cx {
                    ra_l = cy
                    ra_c = cx
                    rb_l = cy
                    rb_c = linelen(cy)
                    delete_range(false)
                }
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
                if n != 0 {
                    ra_l = cy
                    ra_c = cx
                    rb_l = cy
                    rb_c = cx + n
                    delete_range(false)
                }
                start_insert()
            }
            iso:'r' -> {
                k2 = getkey()
                if k2 >= 32 and k2 != 127 and cx + count <= linelen(cy) {
                    snap()
                    c = 0
                    while c < count {
                        del_chars(cy, cx, 1)
                        chbuf[0] = k2
                        void ed_insert(cy, cx, &chbuf, 1)
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
                yank_range(true)
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

    ubyte[41] argbuf

    ; Startup file hand-off used by `make run FILE=name`: if a small file called VI.ARG exists
    ; on the drive, its first line is a file name to open at start-up. Normally it does not
    ; exist, and this does nothing. Returns true (name in argbuf) if a name was read.
    sub startup_arg() -> bool {
        ubyte n = 0
        ubyte c
        ubyte stt
        cbm.SETNAM(10, "vi.arg,s,r")
        cbm.SETLFS(2, DEVICE, 2)
        void cbm.OPEN()
        void cbm.CHKIN(2)
        repeat {
            c = cbm.CHRIN()
            stt = cbm.READST()
            if stt & $bf != 0
                break
            if c == 13 or c == 10
                break
            if n < FNLEN {
                argbuf[n] = c
                n++
            }
            if stt & $40 != 0
                break
        }
        argbuf[n] = 0
        cbm.CLRCHN()
        cbm.CLOSE(2)
        dos_status(&dstat, 40)          ; also clears the drive's error light if the file was missing
        return n != 0
    }

    ;@SELFTEST-SUBS

    ; Program entry: set up the screen, run the editor, then restore the console on exit.
    sub start() {
        ubyte x
        ubyte y
        bool opened
        nbanks = cx16.numbanks()
        db0 = DOC_BANK0
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
        opened = startup_arg()
        if opened
            open_file(&argbuf)
        if not opened
            setmsg(iso:"vi for X16 - :e <file>  :help")
        editor()
        cbm.CHROUT($8f)        ; ISO mode off (back to PETSCII)
        cbm.CHROUT($93)        ; clear screen
    }
}
