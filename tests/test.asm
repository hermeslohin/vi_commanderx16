; hello world for X16
CHROUT = $ffd2
.org $0801
.segment "CODE"

start:  ldx #0          ; counter
@loop:  lda msg,x
        beq done
        jsr CHROUT
        inx
        bne @loop
done:   rts
msg:    .byte "HELLO", $0d, 0
        .word %1010, 1234
