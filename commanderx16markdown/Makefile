CC65 = cl65
X16  = /usr/local/x16emu/x16emu
ROM  = /usr/local/x16emu/rom.bin

PROG8C = java -jar $(HOME)/prog8c.jar

all: MD.PRG

MD.PRG: md.c asciimap.h
	$(CC65) -t cx16 -O -Wl -D,__STACKSIZE__=0x0500 -m md.map -o $@ md.c

# scripted-keystroke build used by runtest.sh
selftest.prg: md.c selftest.c asciimap.h
	$(CC65) -t cx16 -O -DSELFTEST -DBUFSZ=7600u -Wl -D,__STACKSIZE__=0x0500 -o $@ md.c selftest.c

run: MD.PRG
	$(X16) -rom $(ROM) -fsroot $(CURDIR) -prg MD.PRG -run

# Prog8 port (needs prog8c-12.x-all.jar, path in PROG8C above) -> p8build/md.prg
p8: p8build/md.prg
p8build/md.prg: md.p8
	mkdir -p p8build && $(PROG8C) -target cx16 -out p8build md.p8

runp8: p8
	$(X16) -rom $(ROM) -fsroot $(CURDIR) -prg p8build/md.prg -run

clean:
	rm -rf p8build build_test
	rm -f MD.PRG selftest.prg *.o md.map
