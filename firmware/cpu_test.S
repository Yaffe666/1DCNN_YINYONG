.text
.globl _start
_start:
    addi x1, x0, 5
    addi x2, x0, 7
    add x3, x1, x2
    addi x4, x3, 1
    addi x5, x0, 13
    bne x4, x5, fail1
    sub x6, x4, x1
    slli x7, x6, 2
    srli x8, x7, 1
    srai x9, x8, 1
    slt x10, x1, x2
    sltu x11, x2, x1
    slti x24, x1, 6
    sltiu x25, x1, 4
    addi x26, x0, 1
    bne x24, x26, fail2
    bne x25, x0, fail3
    xori x12, x9, 15
    ori x12, x12, 16
    andi x12, x12, 7
    sw x12, 0(x0)
    lw x13, 0(x0)
    addi x14, x13, 1
    addi x15, x0, 8
    bne x14, x15, fail4
    beq x14, x15, taken_ok
    jal x0, fail5

taken_ok:
    jal x16, jal_ok
    jal x0, fail6

jal_ok:
    addi x17, x16, 0
    auipc x18, 0
    addi x18, x18, 16
    jalr x19, 0(x18)
    jal x0, fail7

jalr_target:
    addi x20, x19, 0
    blt x1, x2, blt_ok
    jal x0, fail8

blt_ok:
    bge x2, x1, bge_ok
    jal x0, fail9

bge_ok:
    bltu x11, x10, bltu_ok
    jal x0, fail10

bltu_ok:
    bgeu x10, x11, bgeu_ok
    jal x0, fail11

bgeu_ok:
    addi x21, x0, 3
    addi x0, x0, 0
    add x22, x21, x21
    addi x23, x0, 6
    bne x22, x23, fail12
    fence
    lui x30, 0x10000
    addi x30, x30, 32
    lui x31, 0xcafec
    addi x31, x31, -1346
    sw x31, 0(x30)
    ebreak

fail1:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 1
    sw x31, 0(x30)
    ebreak

fail2:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 2
    sw x31, 0(x30)
    ebreak

fail3:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 3
    sw x31, 0(x30)
    ebreak

fail4:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 4
    sw x31, 0(x30)
    ebreak

fail5:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 5
    sw x31, 0(x30)
    ebreak

fail6:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 6
    sw x31, 0(x30)
    ebreak

fail7:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 7
    sw x31, 0(x30)
    ebreak

fail8:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 8
    sw x31, 0(x30)
    ebreak

fail9:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 9
    sw x31, 0(x30)
    ebreak

fail10:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 10
    sw x31, 0(x30)
    ebreak

fail11:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 11
    sw x31, 0(x30)
    ebreak

fail12:
    lui x30, 0x10000
    addi x30, x30, 32
    addi x31, x0, 12
    sw x31, 0(x30)
    ebreak
