#!/bin/sh
# usage: runtest_p8.sh 'keys' [rows]   keys use python-style escapes ('\x10' = Ctrl-P, '\r' = Enter)
# Builds a self-test copy of md.p8 that feeds scripted keys (tests/<FILE> is preloaded, default test.md),
# dumps the VERA text screen to tests/scr.out and prints it with bold/italic/box glyphs mapped to plain chars.
# PROG8C=path/to/prog8c.jar (default ~/prog8c.jar)
cd "$(dirname "$0")"
J=${PROG8C:-$HOME/prog8c.jar}
mkdir -p build_test
FILE=${FILE:-test.md} python3 - "$1" <<'PY'
import sys, os
keys=sys.argv[1].encode().decode('unicode_escape')
esc=''.join(c if (32<=ord(c)<127 and c not in '"\\') else '\\x%02x'%ord(c) for c in keys)
s=open('md.p8').read()
s=s.replace(';@SELFTEST-HOOK','''if @(selfkeys) != 0 {
            k = @(selfkeys)
            selfkeys++
            return k
        }
        selftest_dump()''')
s=s.replace(';@SELFTEST-SUBS','''uword selfkeys = &keystr
    str keystr = iso:"%s"
    ubyte[170] dbuf
    sub selftest_dump() {
        ubyte y
        ubyte x
        ubyte c
        cbm.SETNAM(13, "@:scr.out,s,w")
        cbm.SETLFS(3, 8, 3)
        void cbm.OPEN()
        cbm.CHKOUT(3)
        for y in 0 to scrh-1 {
            vera_at(0, y)
            for x in 0 to scrw-1 {
                c = cx16.VERA_DATA0
                dbuf[x] = c
                c = cx16.VERA_DATA0
                dbuf[x+80] = c
            }
            for x in 0 to scrw-1
                cbm.CHROUT(dbuf[x])
            cbm.CHROUT(10)
            for x in 0 to scrw-1 {
                c = dbuf[x+80] & 15
                if c < 10
                    cbm.CHROUT(c + 48)
                else
                    cbm.CHROUT(c + 87)
            }
            cbm.CHROUT(10)
        }
        cbm.CLRCHN()
        cbm.CLOSE(3)
        @($9fb5) = 1
        repeat { }
    }'''%esc)
s=s.replace(';@SELFTEST-INIT','open_file(iso:"%s")'%os.environ['FILE'])
open('build_test/mdt.p8','w').write(s)
PY
rm -f build_test/mdt.prg tests/scr.out tests/SCR.OUT
(cd build_test && java -jar "$J" -target cx16 mdt.p8 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "ERROR|error")
[ -f build_test/mdt.prg ] || { echo "build failed"; exit 1; }
(/usr/local/x16emu/x16emu -rom /usr/local/x16emu/rom.bin -fsroot tests -prg build_test/mdt.prg -run -warp >emu.log 2>&1 &)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sleep 1; [ -s tests/scr.out ] && sleep 3 && break; done
pkill x16emu
python3 - "${2:-60}" <<'PY'
import sys
n=int(sys.argv[1])
b=open('tests/scr.out','rb').read()
G={27:'-',28:'|',29:'+',30:'+',31:'+',127:'+',154:'+',155:'+',156:'+',157:'+',158:'+',159:'*'}
def f(c):
    if c>=160 and c!=255 and c not in G: c-=128      # bold face -> plain
    if 128<=c<=153: c=ord('a')+c-128                  # italic face -> plain
    if 1<=c<=26: c=ord('A')+c-1
    return G.get(c,chr(c)) if (c>=127 or c<32) else chr(c)
for r in range(min(n,len(b)//162)):
    print('%2d|%s'%(r,''.join(f(c) for c in b[r*162:r*162+80]).rstrip()))
PY
