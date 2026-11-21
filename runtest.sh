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
assert len(keys) < 255, 'at most 254 keys'
open('tests/keys.in','wb').write(keys.encode('latin1')+b'\0')
s=open('vi.p8').read()
s=s.replace(';@SELFTEST-HOOK','''k = bget(B_FRM, $1900 + selfk)
        if k != 0 {
            selfk++
            return k
        }
        selftest_dump()''')
s=s.replace(';@SELFTEST-SUBS','''uword selfk
    ; the keys come from tests/keys.in (written by this script), kept in bank B_FRM at $b900
    sub selftest_load() {
        cbm.SETNAM(7, "keys.in")
        cbm.SETLFS(4, 8, 4)
        void cbm.OPEN()
        void cbm.CHKIN(4)
        cx16.rambank(B_FRM)
        void cx16.MACPTR(255, $b900, false)
        cx16.rambank(0)
        cbm.CLRCHN()
        cbm.CLOSE(4)
    }
    sub selftest_dump() {
        ubyte y
        cbm.SETNAM(13, "@:scr.out,s,w")
        cbm.SETLFS(3, 8, 3)
        void cbm.OPEN()
        cbm.CHKOUT(3)
        for y in 0 to scrh-1 {
            vera_at(0, y)
            repeat 160
                cbm.CHROUT(cx16.VERA_DATA0)
        }
        cbm.CLRCHN()
        cbm.CLOSE(3)
        @($9fb5) = 1
        repeat { }
    }''')
s=s.replace(';@SELFTEST-INIT','selftest_load()\n        open_file(iso:"%s")'%__import__('os').environ.get('TESTFILE','test.c'))
open('build_test/vit.p8','w').write(s)
PY
rm -f build_test/vit.prg
(cd build_test && java -jar "$J" -target cx16 vit.p8 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "ERROR|error")
[ -f build_test/vit.prg ] || { echo "build failed"; exit 1; }
rm -f tests/scr.out
(/usr/local/x16emu/x16emu -ram ${RAM:-2048} -rom /usr/local/x16emu/rom.bin -fsroot tests -prg build_test/vit.prg -run -warp >emu.log 2>&1 &)
for i in $(seq 1 ${WAIT:-20}); do sleep 1; [ -s tests/scr.out ] && sleep 1 && break; done
pkill x16emu
python3 - "${2:-20}" <<'PY'
import sys
n=int(sys.argv[1])
b=open('tests/scr.out','rb').read()     # rows of 80 x (character, colour)
for r in range(len(b)//160):
    if r>=n and r<59: continue
    t=b[r*160:r*160+160:2].decode('latin1').rstrip()
    print('%2d|%s'%(r,t))
    if r<n: print('  |%s'%''.join('%x'%(c&15) for c in b[r*160+1:r*160+160:2])[:len(t)])
PY
