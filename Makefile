CC65 = cl65
X16  = /usr/local/x16emu/x16emu
ROM  = /usr/local/x16emu/rom.bin

PROG8C = java -jar $(HOME)/prog8c.jar

all: VI.PRG

VI.PRG: vi.c
	$(CC65) -t cx16 -O -Wl -D,__STACKSIZE__=0x0600 -m vi.map -o $@ vi.c

# headless-ish screenshot test with scripted keys (see selftest.c)
selftest.prg: vi.c selftest.c
	$(CC65) -t cx16 -O -DSELFTEST -DBUFSZ=7000u -Wl -D,__STACKSIZE__=0x0600 -o $@ vi.c selftest.c

run: VI.PRG
	cd $(CURDIR) && $(X16) -rom $(ROM) -fsroot $(CURDIR) -prg VI.PRG -run

# Prog8 port (needs prog8c-12.x-all.jar, path in PROG8C above) -> p8build/vi.prg
p8: p8build/vi.prg
p8build/vi.prg: vi.p8
	mkdir -p p8build && $(PROG8C) -target cx16 -out p8build vi.p8

runp8: p8
	cd $(CURDIR) && $(X16) -rom $(ROM) -fsroot $(CURDIR) -prg p8build/vi.prg -run

clean:
	rm -rf p8build build_test
	rm -f VI.PRG selftest.prg *.o
