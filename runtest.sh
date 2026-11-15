#!/bin/sh
# usage: runtest.sh 'keys' [rows]   (keys use C escapes, e.g. '\x1b' for ESC, '\r' for Enter)
# Builds a self-test binary that feeds scripted keys to the editor, then dumps the
# VERA text screen (chars + colour per cell) to scr.out and prints it.
cd "$(dirname "$0")"
printf '#include "asciimap.h"\nconst char *selftest_keys = "%s";\n' "$1" > selftest.c
make selftest.prg 2>&1 | grep -E "rror"
rm -f tests/scr.out
(/usr/local/x16emu/x16emu -rom /usr/local/x16emu/rom.bin -fsroot tests -prg selftest.prg -run -warp >emu.log 2>&1 &)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do sleep 1; [ -s tests/scr.out ] && sleep 1 && break; done
pkill x16emu
python3 - "${2:-20}" <<'PY'
import sys
n=int(sys.argv[1])
L=open('tests/scr.out','rb').read().decode('latin1').replace('\r','\n').split('\n')
for i in range(0,len(L)-1,2):
    if i//2>=n and i//2<59: continue
    t=L[i].rstrip()
    print('%2d|%s'%(i//2,t))
    if i//2<n: print('  |%s'%L[i+1][:len(t)])
PY
