%import syslib
%zeropage basicsafe   ; comment

main {
    const ubyte MAXV = $1F
    uword buf = memory("buf", 100, 0)
    sub start() {
        ubyte x = %1010
        str s = iso:"hi\n"
        if x == 'a' and not true
            cx16.rambank(1)
        %asm {{
            lda #$01   ; load
            sta $9f20
        }}
        void cbm.CHROUT(peek(x))
    }
}
