# VI for the Commander X16

A small vi clone written in [Prog8](https://prog8.readthedocs.io/) with syntax highlighting for **C**, **BASIC**, **6502 assembly** and **Prog8**.
It draws directly into VERA text memory in ISO mode, so files are plain ASCII.

## Build / run

Requires the [Prog8](https://github.com/irmen/prog8/releases) compiler (`prog8c-12.x-all.jar`, needs Java; put it at
`~/prog8c.jar` or set `PROG8C`) and the [x16emu](https://github.com/X16Community/x16-emulator) emulator
(paths are set at the top of the `Makefile`). A prebuilt `VI.PRG` is included.

    make            # -> VI.PRG
    make run        # runs it in x16emu with this folder as the SD card root
    make run FILE=tests/test.p8   # ...and opens that file (path relative to this folder)

On the X16: `LOAD "VI.PRG"` then `RUN`.

## Quick start

1. **Get it running**
   * Emulator: `make run` (builds, then starts x16emu with this folder as the SD card).
   * Real hardware / emulator: copy `VI.PRG` to the SD card, then `LOAD "VI.PRG"` and `RUN`.
2. **Open a file**: type `:e hello.c` and press Enter (a new name starts an empty file).
3. **Edit**: press `i` to insert text, `Esc` to return to normal mode.
4. **Save and quit**: `:wq` (or `ZZ`). Use `:q!` to quit without saving.

### A first session

    :e demo.bas        open (or create) a BASIC file; syntax is picked from the extension
    i                  enter insert mode
    10 PRINT "HELLO"   type some text
    Esc                back to normal mode
    yy  p              copy the line and paste it below
    u                  undo (press again to redo)
    /PRINT  n          search forward, jump to the next match
    :w                 save
    :q                 quit

### Modes

| mode    | how to enter                  | what it does                          |
|---------|-------------------------------|---------------------------------------|
| normal  | `Esc`                         | movement and editing commands         |
| insert  | `i a I A o O s C`             | type text                             |
| replace | `R`                           | overwrite characters as you type      |
| command | `:`                           | ex commands, `/` and `?` for search   |

Type `:help` inside the editor for a command summary.

## Syntax highlighting

Chosen from the file extension, or set manually with `:set syntax=c|basic|asm|prog8|none`.

| language | extensions            | highlights                                                        |
|----------|-----------------------|-------------------------------------------------------------------|
| C        | .c .h                 | keywords, types, `#preprocessor`, strings, numbers, `//` and `/* */` (multi-line) |
| BASIC    | .bas .bi              | keywords (incl. X16 BASIC 2: VPOKE, LOCATE, ...), functions, line numbers, REM, strings, numbers |
| assembly | .asm .s .inc .a65 .a  | 65C02 mnemonics, `.directives`, labels, `$hex`/`%bin`, `;` comments, registers |
| Prog8    | .p8 .prog8            | keywords, types and builtins, `%directives`, strings, `$hex`/`%bin`, `;` comments, `%asm {{ }}` blocks as assembly |

## Commands

Normal mode: `h j k l` / arrows, `0 ^ $`, `w b`, `gg G` (`12G`), `%`, `Ctrl-F`/`Ctrl-B`,
`i a I A o O R`, `x X r s D C J`, `dd dw d$ d0 db` (also `y` and `c` forms), `yy Y p P`,
`u` (undo / redo toggle), `/text ? n N`, counts (`3dd`, `5x`), `ZZ`.

Ex commands: `:w [file]`, `:q`, `:q!`, `:wq`, `:x`, `:e[!] file`, `:N` (go to line),
`:[range]s/old/new/[g]` (`:%s/a/b/g`, `:1,$ s/a/b/g`, `\/` for a literal delimiter),
`:set nu|nonu`, `:set ts=N`, `:set ai|noai`, `:set syntax=...`, `:help`.

## Limits

* **Large files.** A file is not read into memory by `:e`: it is scanned once and cut into 1 KB pages, and each page
  is read from the file when you get to it (scrolling, `G`, searching) and cached in banked RAM. Unchanged pages
  are dropped from the cache whenever room is needed, so a file can be much larger than memory: up to
  **65,000 lines** or about **3.5 MB** (whichever comes first), even on a 512 KB X16. Files with more lines are truncated on load and `:w` is
  refused until you force it with `:w!`.
* **Changed pages stay in memory** until you `:w`. If they fill it you get
  `Memory full of changes: save (:w) to free it`; writing the file makes all of it free again. Since pages are read
  back from the file while you work, do not change the file behind vi's back.
* `:w` over the file that is open writes `vi.tmp` first and then copies it over the file (so the old text can be read
  until the end); if that copy fails, your text is still in `vi.tmp`. Paging needs the X16's SD card / host file
  system (CMDR-DOS, which can seek in a file). Run the emulator with `-ram 2048` (the Makefile does) for the
  biggest cache.
* Line endings: CR, LF and CRLF are read (and written as LF).
* Lines longer than 700 characters are split when a file is loaded (and cannot be typed longer); only the first
  255 characters of a line are syntax-coloured.
* Undo is single level, page based (unchanged pages are shared with the snapshot, so it is cheap).
* `dd` on the last line now really removes it (it used to leave an empty line behind).
* BASIC keywords are only highlighted as whole words (`FOR I=1 TO 10`, not `FORI=1TO10`).

## Self test

`./runtest.sh '<keys>' [rows]` builds a variant that feeds scripted keystrokes (`\x1b` = Esc, `\r` = Enter), dumps the
VERA screen (characters and colour indexes) to `tests/scr.out` and prints it. `TESTFILE=test.p8 ./runtest.sh ...`
picks the file to open from `tests/` (default `test.c`; samples for every highlighted language are there).
It uses `~/prog8c.jar` unless `PROG8C` is set.
The keys (at most 254) are passed in `tests/keys.in`. `RAM=256 ./runtest.sh ...` runs the emulator with less banked
RAM (default 2048), which makes the page cache small, so large files are really read back from disk as you move.
