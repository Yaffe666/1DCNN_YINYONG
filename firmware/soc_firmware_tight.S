.text
.globl _start
_start:
    lui  x1, 0x10000
    addi x2, x0, 1
    slli x2, x2, 11
    addi x6, x0, 5
    addi x7, x0, 10
    addi x8, x0, 1
    lui  x5, 0xA5A50
    addi x5, x5, 1

    sw   x2, 8(x1)
    sw   x6, 12(x1)
    sw   x7, 16(x1)
    sw   x8, 0(x1)

poll_done:
    lw   x3, 4(x1)
    andi x3, x3, 2
    beq  x3, x0, poll_done

    lw   x4, 24(x1)
    sw   x5, 32(x1)

halt_loop:
    beq  x0, x0, halt_loop
