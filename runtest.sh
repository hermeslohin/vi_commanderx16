#!/bin/sh
# usage: runtest.sh 'keys' [rows]   keys: python-style escapes e.g. '\x1b' ESC, '\r' Enter
# Builds a self-test copy of vi.p8 that feeds scripted keys, dumps the VERA text screen
# (chars + colour per cell) to tests/scr.out and prints it.
cd "$(dirname "$0")"
J=${PROG8C:-$HOME/prog8c.jar}
mkdir -p build_test
python3 - "$1" <<'PY'
import sys
keys=sys.argv[1].encode().decode('unicode_escape')
esc=''.join(c if (32<=ord(c)<127 and c not in '"\\') else '\\x%02x'%ord(c) for c in keys)
s=open('vi.p8').read()
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
s=s.replace(';@SELFTEST-INIT','open_file(iso:"%s")'%__import__('os').environ.get('TESTFILE','test.c'))
open('build_test/vit.p8','w').write(s)
PY
rm -f build_test/vit.prg
(cd build_test && java -jar "$J" -target cx16 vit.p8 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "ERROR|error")
[ -f build_test/vit.prg ] || { echo "build failed"; exit 1; }
rm -f tests/scr.out
(/usr/local/x16emu/x16emu -rom /usr/local/x16emu/rom.bin -fsroot tests -prg build_test/vit.prg -run -warp >emu.log 2>&1 &)
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
