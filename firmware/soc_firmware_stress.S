.text
.globl _start
_start:
    lui  x1, 0x10000
    lui  x5, 0xA5A50
    addi x5, x5, 1

    # Back-to-back MMIO stores that all reuse x2 as the source register,
    # reassigning x2 between each store with no spacing. This stresses the
    # MEM-stage external-request latch: if any subsequent x2 reassignment
    # leaked into an in-flight store, the slave would observe the wrong
    # value at INPUT_LEN / LAYER_CFG / NUM_CLASSES.
    addi x2, x0, 1
    slli x2, x2, 11     # x2 = 2048
    sw   x2, 8(x1)      # INPUT_LEN = 2048
    addi x2, x0, 5      # x2 <= 5 with store still in flight
    sw   x2, 12(x1)     # LAYER_CFG = 5
    addi x2, x0, 10     # x2 <= 10 with store still in flight
    sw   x2, 16(x1)     # NUM_CLASSES = 10
    addi x2, x0, 1      # x2 <= 1 with store still in flight
    sw   x2, 0(x1)      # CTRL.start = 1

poll_done:
    lw   x3, 4(x1)
    andi x3, x3, 2
    beq  x3, x0, poll_done

    lw   x4, 24(x1)
    sw   x5, 32(x1)

halt_loop:
    beq  x0, x0, halt_loop
