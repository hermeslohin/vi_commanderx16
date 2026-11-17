#!/bin/sh
# usage: runtest.sh 'keys' [rows]   (keys use C escapes, e.g. '\x1b' for ESC, '\r' for Enter)
# Builds a self-test binary that feeds scripted keys to the editor (test.md from tests/ is
# preloaded), then dumps the VERA text screen to tests/scr.out and prints it.
# FILE=name chooses the preloaded file (default test.md; a missing name starts an empty document).
# NB: C hex escapes are greedy - write '\\x02' followed by a hex-digit letter as '\\x02""b' (or avoid it).
cd "$(dirname "$0")"
printf '#include "asciimap.h"\nconst char *selftest_file = "%s";\nconst char *selftest_keys = "%s";\n' "${FILE:-test.md}" "$1" > selftest.c
make selftest.prg 2>&1 | grep -E "rror"
rm -f tests/scr.out tests/SCR.OUT
(/usr/local/x16emu/x16emu -rom /usr/local/x16emu/rom.bin -fsroot tests -prg selftest.prg -run -warp >emu.log 2>&1 &)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sleep 1; [ -s tests/scr.out ] && sleep 4 && break; done
pkill x16emu
python3 - "${2:-60}" <<'PY'
import sys
n=int(sys.argv[1])
b=open('tests/scr.out','rb').read()
G={27:'-',28:'|',29:'+',30:'+',31:'+',127:'+',154:'+',155:'+',156:'+',157:'+',158:'+',159:'*'}
def f(c):
    if c>=160 and c!=255 and c not in G: c-=128      # bold face -> plain
    if 128<=c<=153: c=c-128+97-0 if False else ord('a')+c-128   # italic face -> plain
    if 1<=c<=26: c=ord('A')+c-1
    return G.get(c,chr(c)) if (c>=127 or c<32) else chr(c)
for r in range(min(n,len(b)//162)):
    print('%2d|%s'%(r,''.join(f(c) for c in b[r*162:r*162+80]).rstrip()))
PY
