.text
# Program B - Nested function calls with stack frames.
# Computes choose(5,2) via two-level call to a triangular-sum helper.
# Outputs word at 0x2004 = sum_to(4) = 10.

_start:
    lui  sp, 0xC          # sp = 0xC000
    addi sp, sp, -16
    addi a0, x0, 5
    jal  ra, choose2
    lui  t0, 0x2
    sw   a0, 4(t0)
    ebreak

choose2:
    addi sp, sp, -16
    sw   ra, 12(sp)
    addi a0, a0, -1       # 5 - 1 = 4
    jal  ra, sum_to
    lw   ra, 12(sp)
    addi sp, sp, 16
    jalr x0, 0(ra)

sum_to:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    addi s0, x0, 0
sum_loop:
    beq  a0, x0, sum_done
    add  s0, s0, a0
    addi a0, a0, -1
    jal  x0, sum_loop
sum_done:
    add  a0, s0, x0
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    jalr x0, 0(ra)
