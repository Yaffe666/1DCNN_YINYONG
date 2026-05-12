# CPU standalone back-to-back MMIO store stress test.
# Writes 4 values to consecutive AXI addresses reusing x2 across stores
# with no NOP spacing. Used to verify inst_rom ce fix.
.text
.globl _start
_start:
    lui  x1, 0x10000         # x1 = 0x10000000

    # Back-to-back stores reusing x2
    addi x2, x0, 0x123
    sw   x2, 0(x1)           # 0x10000000 = 0x00000123
    addi x2, x0, 0x456
    sw   x2, 4(x1)           # 0x10000004 = 0x00000456
    addi x2, x0, 0x789
    sw   x2, 8(x1)           # 0x10000008 = 0x00000789
    addi x2, x0, 0x321
    sw   x2, 12(x1)          # 0x1000000C = 0x00000321

    # Write CAFE_BABE to test output
    lui  x2, 0xCAFEC
    addi x2, x2, 0xABE       # x2 = 0xCAFE_BABE
    sw   x2, 32(x1)          # TEST_OUTPUT = 0xCAFE_BABE

halt_loop:
    jal  x0, halt_loop
