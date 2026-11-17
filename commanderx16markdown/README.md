# MD - Markdown editor for the Commander X16

A modeless Markdown editor written in C (cc65). Write in the editor, press **Ctrl-P** (or **F5**) and the
document is shown rendered with fonts, titles, tables and a table of contents. Press it again to go back.

## Build / run

Needs [cc65](https://cc65.github.io/) and the x16emu emulator (paths at the top of the `Makefile`).
A prebuilt `MD.PRG` is included.

    make          # -> MD.PRG
    make run      # starts x16emu with this folder as the SD card

On the X16: `LOAD "MD.PRG"` then `RUN`. Try the included `DEMO.MD`: `Ctrl-O`, type `DEMO.MD`, Enter, then `Ctrl-P`.

## Keys

| key                | action                                                      |
|--------------------|-------------------------------------------------------------|
| `Ctrl-P` / `F5`    | **toggle preview** (also `Esc` inside the preview)          |
| `Ctrl-G` / `F4`    | **table of contents**: pick a heading and jump to it        |
| `Ctrl-W` / `F2`    | save (asks for a name if the document has none)             |
| `Ctrl-O` / `F3`    | open a file                                                 |
| `Ctrl-X` / `F8`    | quit (press twice to discard unsaved changes)               |
| `F1`               | help                                                        |
| `Ctrl-B` `Ctrl-E` `Ctrl-K` | insert `**bold**`, `*italic*`, `` `code` `` with the cursor inside |
| `Ctrl-A`           | insert a table template                                     |
| `Ctrl-R`           | insert a `[TOC]` marker                                     |
| `Ctrl-Z`           | undo (one level; press again to redo)                       |
| `Ctrl-U`           | delete the current line                                     |
| `Ctrl-F`           | find (Enter on an empty prompt repeats the last search)     |
| arrows, Home, End  | move; `F6` / `F7` = page up / page down                     |

Enter continues `-`, `*`, `+` lists and `>` quotes; pressing Enter on an empty item ends the list.

In the preview: `Up`/`Down` scroll, `Space`/`F7` and `b`/`F6` page, `n`/`p` next/previous heading,
`Home`/`End`, `F4` (or `t`) contents menu, `Esc` / `Ctrl-P` back to the editor.

## What the preview renders

* **Fonts** - at start-up the editor builds *bold* and *italic* faces from the ISO character set and stores
  them in the unused upper half of VERA's character memory, so bold/italic are real glyph shapes, not just colours.
  Headings are bold and coloured per level (`#` to `######`); `#` and `##` also get a rule underneath.
  Setext headings (`Title` + `====` / `----`) work too.
* **Inline** - `**bold**`, `__bold__`, `*italic*`, `_italic_`, `` `code` ``, `~~strike~~`, `[links](url)`, `![images](url)`
  (shown in colour with the URL hidden), backslash escapes.
* **Blocks** - paragraphs (word wrapped), `-`/`*`/`+` and `1.` lists (nested by indent), `>` quotes (nestable),
  `---` rules, fenced code blocks, and **tables** (`|` with a `---` separator row, `:--` `:-:` `--:` alignment)
  drawn with box-drawing characters. Wide tables shrink their widest columns to fit the screen.
* **Table of contents** - a line containing only `[TOC]` becomes a linked-free contents list of all headings in the
  preview. `Ctrl-G` / `F4` gives a jump menu in both the editor and the preview.

The editor itself colours headings, bold/italic/code, links, lists, quotes, tables and code fences, and wraps long
lines on screen.

## Limits

* The document buffer is **8000 bytes / 500 lines** (the editor plus preview renderer use most of the X16's ~38 KB
  of main RAM). Bigger files are truncated on load and the status line shows the free bytes.
* The preview is rendered into banked RAM: up to 510 rows; longer documents show `(too long: end cut off)`.
* One undo level. Tables: up to 8 columns. Headings tracked for the contents: 100.
* ASCII only (ISO mode); other bytes show as `?`.

## Notes

* The control-key bindings assume the X16 keyboard delivers `Ctrl-<letter>` as codes 1-26 in ISO mode. The
  function keys (`F1`-`F8`) give the same commands for save, open, quit, preview and contents, in case a key
  combination is not delivered by your keyboard / host.
* `Ctrl-S`, `Ctrl-T`, `Ctrl-Q` and `Ctrl-H` are not used: on the X16 they are the same codes as Home, Backspace,
  Cursor-down and Backspace.

## Self test

`./runtest.sh '<keys>' [rows]` builds a variant that feeds scripted keystrokes (C escapes: `\x10` = Ctrl-P, `\r` =
Enter), dumps the VERA text screen to `tests/scr.out` and prints it with the bold/italic/box glyphs mapped back to
plain characters. `FILE=name ./runtest.sh ...` chooses the preloaded file from `tests/` (default `test.md`).
Beware that C hex escapes are greedy: write `\x02""b` to send Ctrl-B followed by a literal `b`.

    ./runtest.sh '\x10'                      # preview of tests/test.md
    ./runtest.sh '\x8a\x11\x11\r'            # open the TOC menu, go down twice, jump

## Prog8 port

`md.p8` is a Prog8 port of the editor with the same keys, preview, fonts and contents menu (the screen
output, colours and glyphs match the C build in the self test). Build with `make p8` (needs `~/prog8c.jar`,
Prog8 12.x, or set `PROG8C`) -> `p8build/md.prg`, or `make runp8`. `./runtest_p8.sh '<keys>' [rows]` is the
scripted-key test (`FILE=big.md` picks the preloaded file).
