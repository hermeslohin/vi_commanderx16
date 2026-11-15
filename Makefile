CC65 = cl65
X16  = /usr/local/x16emu/x16emu
ROM  = /usr/local/x16emu/rom.bin

all: VI.PRG

VI.PRG: vi.c
	$(CC65) -t cx16 -O -Wl -D,__STACKSIZE__=0x0600 -m vi.map -o $@ vi.c

# headless-ish screenshot test with scripted keys (see selftest.c)
selftest.prg: vi.c selftest.c
	$(CC65) -t cx16 -O -DSELFTEST -DBUFSZ=7000u -Wl -D,__STACKSIZE__=0x0600 -o $@ vi.c selftest.c

run: VI.PRG
	cd $(CURDIR) && $(X16) -rom $(ROM) -fsroot $(CURDIR) -prg VI.PRG -run

clean:
	rm -f VI.PRG selftest.prg *.o
